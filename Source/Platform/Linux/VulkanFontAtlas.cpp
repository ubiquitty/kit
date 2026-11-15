// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/VulkanFontAtlas.h"
#include "Platform/Linux/Raster.h"

#include "Core/Rendering/CellDecisions.h"

#include <map>
#include <mutex>

namespace Ubiquitty::Linux {

VulkanFontAtlas::VulkanFontAtlas(std::shared_ptr<VulkanDevice> sharedDevice,
    std::shared_ptr<Rendering::GlyphRasterizer> owner, Rendering::GlyphRasterizer* mono,
    Rendering::GlyphRasterizer* shaper, int maximum, int cells)
    : device(std::move(sharedDevice))
    , rasterizerOwner(std::move(owner))
{
    if (mono)
        atlas.emplace(*mono, maximum, cells);
    else
        atlas.emplace(fallbackCellWidth, fallbackCellHeight, maximum, cells);
    auto& source = mono ? *mono : atlas->rasterizer();
    const auto metrics = source.cellMetrics();
    const int width = atlas->cellWidth();
    const int height = atlas->cellHeight();
    colorAtlas.emplace(source, static_cast<int>(Rendering::colourGlyphSquareInPixels(metrics.cellWidth, metrics.cellHeight)));
    if (shaper && shaper->hasLigatureShaping()) {
        const auto slot = Rendering::computeGlyphSlot(shaper->glyphOverhang());
        ligatureSheet.emplace(width, height, slot.marginInPixels.width, slot.marginInPixels.height, shaper);
    }
    if (shaper && shaper->hasProportionalFace()) {
        const auto slot = Rendering::computeGlyphSlot(shaper->glyphOverhang());
        proportionalStripSheet.emplace(width, height, slot.marginInPixels.width, slot.marginInPixels.height, shaper);
    }
    auto& proportional = shaper && shaper->hasProportionalFace() ? *shaper : atlas->rasterizer();
    const auto slot = Rendering::computeGlyphSlot(proportional.glyphOverhang());
    proportionalSheet.emplace(width, height, slot.marginInPixels.width, slot.marginInPixels.height, &proportional, maximum);
}

std::shared_ptr<VulkanFontAtlas> VulkanFontAtlas::acquire(std::shared_ptr<VulkanDevice> device,
    std::shared_ptr<Rendering::GlyphRasterizer> owner, Rendering::GlyphRasterizer* mono,
    Rendering::GlyphRasterizer* shaper, std::shared_ptr<const Rendering::AtlasConfiguration> configuration,
    int maximum, int cells)
{
    // One lock order everywhere, including callers which do not already hold
    // the render lock: device first, registry second.
    const std::scoped_lock deviceLock(device->mutex());
    struct Registry {
        std::mutex mutex;
        std::map<std::string, std::weak_ptr<VulkanFontAtlas>> atlases;
    };
    static Registry registry;
    std::string key;
    if (owner && configuration && mono == owner.get() && shaper == mono) {
        auto identity = *configuration;
        const auto sizing = VulkanGlyphAtlas::sizingFor(*mono, maximum, cells);
        identity.resourceDomain = reinterpret_cast<std::uintptr_t>(device.get());
        identity.geometry = sizing.geometry;
        identity.slotCapacity = sizing.capacity;
        identity.baselinePenInPixels = mono->cellMetrics().baselineFromTop + sizing.geometry.glyphMarginInPixels.height;
        identity.doesFontLigate = shaper->hasLigatureShaping();
        key = identity.sharingKey();
    }
    const std::scoped_lock registryLock(registry.mutex);
    std::erase_if(registry.atlases, [](const auto& entry) { return entry.second.expired(); });
    if (!key.empty()) {
        if (const auto found = registry.atlases.find(key); found != registry.atlases.end()) {
            if (auto existing = found->second.lock())
                return existing;
        }
    }
    // Private construction also supports borrowed rasterizers used by renderer
    // oracles. Such a provider is never inserted in the sharing registry.
    auto result = std::shared_ptr<VulkanFontAtlas>(new VulkanFontAtlas(std::move(device), std::move(owner), mono, shaper, maximum, cells));
    result->sharingKey = std::move(key);
    if (!result->sharingKey.empty())
        registry.atlases[result->sharingKey] = result;
    return result;
}

VulkanFontAtlas::~VulkanFontAtlas()
{
    const std::scoped_lock lock(device->mutex());
    const VkDevice handle = device->device();
    proportionalImage.destroy(handle);
    proportionalStripImage.destroy(handle);
    ligatureImage.destroy(handle);
    if (colorAtlas)
        colorAtlas->destroy(handle);
    if (atlas)
        atlas->destroy(handle);
}

std::array<Rendering::GlyphSlotCache*, 5> VulkanFontAtlas::caches()
{
    return { atlas ? atlas->bindMonoAtlas().cache : nullptr,
        colorAtlas ? colorAtlas->bindColorAtlas().cache : nullptr,
        proportionalSheet ? proportionalSheet->binding().cache : nullptr,
        proportionalStripSheet ? &proportionalStripSheet->slotCache() : nullptr,
        ligatureSheet ? &ligatureSheet->slotCache() : nullptr };
}

VulkanFontAtlas::ViewLease VulkanFontAtlas::acquireViewLease()
{
    const std::scoped_lock lock(device->mutex());
    ViewLease result;
    const auto sheets = caches();
    for (std::size_t index = 0; index < sheets.size(); ++index) {
        if (sheets[index])
            result.slots[index] = sheets[index]->acquireRetainLease();
    }
    ++m_activeLeases;
    return result;
}

void VulkanFontAtlas::releaseViewLease(ViewLease& lease)
{
    const std::scoped_lock lock(device->mutex());
    const auto sheets = caches();
    bool hasLease = false;
    for (std::size_t index = 0; index < sheets.size(); ++index) {
        if (sheets[index] && lease.slots[index] >= 0) {
            sheets[index]->releaseRetainLease(lease.slots[index]);
            hasLease = true;
        }
        lease.slots[index] = -1;
    }
    if (hasLease)
        --m_activeLeases;
}

void VulkanFontAtlas::retainViewLease(const ViewLease& lease)
{
    const std::scoped_lock lock(device->mutex());
    const auto sheets = caches();
    for (std::size_t index = 0; index < sheets.size(); ++index) {
        if (sheets[index] && lease.slots[index] >= 0)
            sheets[index]->retainTouchedSlots(lease.slots[index]);
    }
}

void VulkanFontAtlas::rebaselineViewLease(const ViewLease& lease)
{
    const std::scoped_lock lock(device->mutex());
    const auto sheets = caches();
    for (std::size_t index = 0; index < sheets.size(); ++index) {
        if (sheets[index] && lease.slots[index] >= 0)
            sheets[index]->rebaselineRetainedSlots(lease.slots[index]);
    }
}

VulkanFontAtlas::Statistics VulkanFontAtlas::statistics()
{
    const std::scoped_lock lock(device->mutex());
    Statistics result { atlas ? atlas->rasterizedSlots() : 0, uploadBatches, 0, m_activeLeases, atlas ? atlas->bindMonoAtlas().cache->capacity() : 0 };
    for (auto* cache : caches()) {
        if (cache)
            result.pinnedSlots += cache->pinnedSlots();
    }
    return result;
}

bool VulkanFontAtlas::hasPendingUploads() const
{
    return !isCreated || (atlas && atlas->hasPendingUploads()) || (colorAtlas && colorAtlas->hasPendingUploads())
        || (proportionalSheet && proportionalSheet->isUsable() && (proportionalSheet->dirtyRows().rowCount > 0 || !proportionalImage.isReadable()))
        || (proportionalStripSheet && proportionalStripSheet->isUsable() && (proportionalStripSheet->isDirty() || !proportionalStripImage.isReadable()))
        || (ligatureSheet && ligatureSheet->isUsable() && (ligatureSheet->isDirty() || !ligatureImage.isReadable()));
}

}
