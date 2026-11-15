// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Rendering/AtlasConfiguration.h"
#include "Core/Rendering/LigatureSheet.h"
#include "Core/Rendering/ProportionalGlyphSheet.h"
#include "Platform/Linux/VulkanColorGlyphAtlas.h"
#include "Platform/Linux/VulkanCoverageSheet.h"
#include "Platform/Linux/VulkanDevice.h"
#include "Platform/Linux/VulkanGlyphAtlas.h"

#include <array>
#include <memory>
#include <optional>
#include <string>

namespace Ubiquitty::Linux {

/// Font content shared by compatible views. No retained frame, instance buffer,
/// descriptor set or terminal belongs here. The device mutex protects mutation.
class VulkanFontAtlas {
public:
    /// Identifies one view's retained-slot lease in each coverage cache.
    struct ViewLease {
        std::array<int, 5> slots { -1, -1, -1, -1, -1 };
    };
    /// Reports shared raster work and the currently protected cache slots.
    struct Statistics {
        std::uint64_t rasterizedSlots = 0;
        std::uint64_t uploadBatches = 0;
        int pinnedSlots = 0;
        int activeLeases = 0;
        int slotCapacity = 0;
    };

    /// Releases GPU coverage images while retaining the device through teardown.
    ~VulkanFontAtlas();
    /// Acquires an atlas compatible with the provider, device and slot geometry.
    ///
    /// - Parameters:
    ///   - owner: The lifetime lease for the monochrome and shaping providers.
    ///   - mono: The provider that rasterizes ordinary and wide glyph masks.
    ///   - shaper: The provider that supplies shaped and proportional masks.
    ///   - maxTextureDimension: The device's maximum texture edge.
    ///   - cellsInWidestScreen: The largest grid the coverage caches must accommodate.
    /// - Returns: A shared atlas, or a private atlas for borrowed providers.
    [[nodiscard]] static std::shared_ptr<VulkanFontAtlas> acquire(std::shared_ptr<VulkanDevice>,
        std::shared_ptr<Rendering::GlyphRasterizer> owner, Rendering::GlyphRasterizer* mono,
        Rendering::GlyphRasterizer* shaper, std::shared_ptr<const Rendering::AtlasConfiguration>,
        int maxTextureDimension, int cellsInWidestScreen);
    /// Acquires retained-slot tokens for a newly participating view.
    ///
    /// - Returns: Tokens that keep that view's touched slots protected.
    [[nodiscard]] ViewLease acquireViewLease();
    /// Releases a view's retained-slot tokens and clears them in the lease.
    ///
    /// - Parameter lease: The view's tokens; already released tokens are harmless.
    void releaseViewLease(ViewLease&);
    /// Protects the slots touched by the view's completed frame.
    ///
    /// - Parameter lease: The view whose retained slot sets receive the touches.
    void retainViewLease(const ViewLease&);
    /// Reconciles a view's protected slots with a rebuilt frame's contents.
    ///
    /// - Parameter lease: The view whose retained baselines are replaced.
    void rebaselineViewLease(const ViewLease&);
    /// Samples cache work and lease counts under the shared device lock.
    ///
    /// - Returns: A consistent snapshot of the atlas's counters.
    [[nodiscard]] Statistics statistics();
    /// Reports whether any coverage sheet still needs a GPU upload.
    ///
    /// - Returns: Whether initialization or dirty coverage remains pending.
    [[nodiscard]] bool hasPendingUploads() const;

    // Strong provider/device ownership makes a cache independent of whichever
    // window first populated it. The registry itself contains only weak values.
    std::shared_ptr<VulkanDevice> device;
    std::shared_ptr<Rendering::GlyphRasterizer> rasterizerOwner;
    std::string sharingKey;
    std::optional<VulkanGlyphAtlas> atlas;
    std::optional<VulkanColorGlyphAtlas> colorAtlas;
    std::optional<Rendering::ProportionalGlyphSheet> proportionalSheet;
    VulkanCoverageSheet proportionalImage;
    std::optional<Rendering::LigatureSheet> proportionalStripSheet;
    VulkanCoverageSheet proportionalStripImage;
    std::optional<Rendering::LigatureSheet> ligatureSheet;
    VulkanCoverageSheet ligatureImage;
    bool isCreated = false;
    std::uint64_t uploadBatches = 0;

private:
    /// Constructs coverage caches for providers retained by a device domain.
    VulkanFontAtlas(std::shared_ptr<VulkanDevice>, std::shared_ptr<Rendering::GlyphRasterizer>,
        Rendering::GlyphRasterizer*, Rendering::GlyphRasterizer*, int, int);
    /// Returns the slot caches in the stable order used by view leases.
    ///
    /// - Returns: Cache pointers, with null entries for unavailable sheets.
    [[nodiscard]] std::array<Rendering::GlyphSlotCache*, 5> caches();
    int m_activeLeases = 0;
};

}
