// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Platform/Linux/SharedFontResources.h"

#include "Core/Preferences/PreferencesAccessors.h"
#include "Core/Preferences/RenderConfigurationFold.h"
#include "Core/Rendering/BoxDrawingRasterizer.h"
#include "Core/Rendering/BundledFonts.h"
#include "Core/Rendering/UnifontRasterizer.h"
#include "Platform/Linux/BundledFontDirectory.h"
#include "Platform/Linux/FreeTypeRasterizer.h"

#include <map>
#include <mutex>
#include <sys/stat.h>

#include <fontconfig/fontconfig.h>

namespace Ubiquitty::Linux {
namespace {

void addResource(Rendering::FontProviderResourceFacts& facts, std::string role, std::string path, int index = 0)
{
    Rendering::FontResourceFact resource;
    resource.role = std::move(role);
    resource.path = std::move(path);
    resource.faceIndex = static_cast<std::uint64_t>(index);
    struct stat metadata {};
    if (!resource.path.empty() && stat(resource.path.c_str(), &metadata) == 0) {
        resource.device = metadata.st_dev;
        resource.inode = metadata.st_ino;
        resource.byteSize = metadata.st_size;
        resource.modifiedSeconds = metadata.st_mtim.tv_sec;
        resource.modifiedNanoseconds = metadata.st_mtim.tv_nsec;
    }
    facts.faces.push_back(std::move(resource));
}

void addMatchedResource(Rendering::FontProviderResourceFacts& facts, std::string role, const std::string& family, Rendering::FontFace style)
{
    std::unique_ptr<FcPattern, decltype(&FcPatternDestroy)> pattern(FcNameParse(reinterpret_cast<const FcChar8*>(family.c_str())), FcPatternDestroy);
    if (!pattern)
        return;
    FcPatternAddInteger(pattern.get(), FC_WEIGHT, Rendering::isBold(style) ? FC_WEIGHT_BOLD : FC_WEIGHT_REGULAR);
    FcPatternAddInteger(pattern.get(), FC_SLANT, Rendering::isItalic(style) ? FC_SLANT_ITALIC : FC_SLANT_ROMAN);
    FcConfigSubstitute(FcConfigGetCurrent(), pattern.get(), FcMatchPattern);
    FcDefaultSubstitute(pattern.get());
    FcResult result;
    std::unique_ptr<FcPattern, decltype(&FcPatternDestroy)> match(FcFontMatch(FcConfigGetCurrent(), pattern.get(), &result), FcPatternDestroy);
    FcChar8* file = nullptr;
    int index = 0;
    if (match && FcPatternGetString(match.get(), FC_FILE, 0, &file) == FcResultMatch && file) {
        FcPatternGetInteger(match.get(), FC_INDEX, 0, &index);
        addResource(facts, std::move(role), reinterpret_cast<const char*>(file), index);
    }
}

std::shared_ptr<Rendering::AtlasConfiguration> configurationFor(const SharedFontRequest& request, const Preferences::FontRoutePreferences& fallback)
{
    auto result = std::make_shared<Rendering::AtlasConfiguration>();
    result->familyName = request.family.empty() ? "monospace" : request.family;
    result->pointSize = request.pointSize;
    result->pixelsPerPoint = request.pixelsPerPoint;
    result->fontWeight = request.uprightWeight;
    result->boldFontWeight = request.boldWeight;
    result->fontWidthPercent = request.widthPercent;
    result->symbolFamilyName = request.fallbackFamily;
    result->symbolFontPath = request.fallbackPath;
    result->userFeatureSpecification = request.features;
    result->userVariationSpecification = request.variations;
    result->wantsLigatures = request.ligatures == Rendering::Ligatures::Enabled;
    auto& facts = result->providerResourceFacts;
    facts.catalogIdentity = reinterpret_cast<std::uintptr_t>(FcConfigGetCurrent());
    facts.catalogGeneration = request.catalogGeneration;
    facts.rasterPixelSize = request.pixelSize;
    facts.deviceScale = request.deviceScale;
    facts.lineSpacingInPixels = request.lineSpacing;
    facts.trackingInPixels = request.tracking;
    facts.bitmapScale = request.bitmapScale;
    facts.configuration = Preferences::Effective::renderConfiguration(request.preferences);
    facts.cjkFallbackFamily = fallback.cjkFallbackFamily;
    facts.symbolFallbackFamily = fallback.symbolFallbackFamily;
    facts.emojiFallbackFamily = fallback.emojiFallbackFamily;
    facts.shouldMatchFallbackSize = fallback.shouldMatchFallbackSize;
    for (const auto& rule : fallback.languageFallbacks)
        facts.languageFallbacks.push_back({ static_cast<int>(rule.script), std::string(rule.language.value), std::string(rule.family) });
    for (const auto& rule : fallback.rangeMaps)
        facts.rangeMaps.push_back({ 0, {}, std::string(rule.family), rule.firstCodePoint, rule.lastCodePoint, static_cast<int>(rule.sizing), rule.shouldYieldToEmoji });
    result->proportionalFamilyName = facts.configuration.proportionalFontFamily.string();
    result->proportionalPointSize = facts.configuration.proportionalFontSizePoints;
    const std::string directory = request.fallbackPath.substr(0, request.fallbackPath.find_last_of('/') + 1);
    if (!request.primaryPath.empty()) {
        addResource(facts, "primary", request.primaryPath);
        for (auto style : { Rendering::FontFace::Bold, Rendering::FontFace::Italic, Rendering::FontFace::BoldItalic }) {
            const auto file = style == Rendering::FontFace::Bold ? Rendering::bundledBoldFontFile(request.family)
                : style == Rendering::FontFace::Italic           ? Rendering::bundledItalicFontFile(request.family)
                                                                 : Rendering::bundledBoldItalicFontFile(request.family);
            if (!file.empty())
                addResource(facts, "primary-style-" + std::to_string(static_cast<int>(style)), directory + std::string(file));
        }
    } else {
        for (auto style : { Rendering::FontFace::Regular, Rendering::FontFace::Bold, Rendering::FontFace::Italic, Rendering::FontFace::BoldItalic })
            addMatchedResource(facts, "primary-style-" + std::to_string(static_cast<int>(style)), result->familyName, style);
    }
    addResource(facts, "symbols-bundled", request.fallbackPath);
    if (!request.fallbackFamily.empty())
        addMatchedResource(facts, "symbols-matched", request.fallbackFamily, Rendering::FontFace::Regular);
    for (const auto* family : { "Noto Sans", "Noto Color Emoji" }) {
        const auto file = Rendering::bundledFontFile(family);
        if (!file.empty())
            addResource(facts, family, directory + std::string(file));
    }
    return result;
}

} // namespace

struct SharedFontResources::Impl {
    std::shared_ptr<FreeTypeRasterizer> native;
    std::shared_ptr<Rendering::UnifontRasterizer> bitmap;
    std::shared_ptr<Rendering::BoxDrawingRasterizer> nativeBox;
    std::shared_ptr<Rendering::BoxDrawingRasterizer> bitmapBox;
    std::shared_ptr<Rendering::AtlasConfiguration> nativeConfiguration;
    std::shared_ptr<Rendering::AtlasConfiguration> bitmapConfiguration;
};

SharedFontResources::SharedFontResources(std::unique_ptr<Impl> implementation)
    : m_impl(std::move(implementation))
{
}
SharedFontResources::~SharedFontResources() = default;

std::shared_ptr<SharedFontResources> SharedFontResources::acquire(SharedFontRequest request)
{
    auto fallback = Preferences::buildFontRoutePreferences(request.preferences);
    auto configuration = configurationFor(request, fallback);
    const std::string key = configuration->fontSharingKey();
    if (key.empty())
        return nullptr;
    static std::mutex mutex;
    static std::map<std::string, std::weak_ptr<SharedFontResources>> registry;
    const std::scoped_lock lock(mutex);
    std::erase_if(registry, [](const auto& entry) { return entry.second.expired(); });
    if (auto found = registry.find(key); found != registry.end()) {
        if (auto live = found->second.lock())
            return live;
    }
    auto implementation = std::make_unique<Impl>();
    implementation->nativeConfiguration = std::move(configuration);
    implementation->native = std::make_shared<FreeTypeRasterizer>(request.pixelSize, request.family, request.fallbackFamily, request.fallbackPath,
        request.primaryPath, request.deviceScale, request.lineSpacing, request.tracking, request.uprightWeight, request.boldWeight,
        request.widthPercent, request.variations, request.features, request.ligatures, std::move(fallback));
    implementation->bitmap = std::make_shared<Rendering::UnifontRasterizer>(request.bitmapScale, request.lineSpacing, request.tracking);
    implementation->nativeBox = std::make_shared<Rendering::BoxDrawingRasterizer>(*implementation->native);
    implementation->bitmapBox = std::make_shared<Rendering::BoxDrawingRasterizer>(*implementation->bitmap);
    implementation->nativeBox->setShadeStyle(implementation->nativeConfiguration->providerResourceFacts.configuration.shadeStyle);
    implementation->bitmapBox->setShadeStyle(implementation->nativeConfiguration->providerResourceFacts.configuration.shadeStyle);
    implementation->bitmapConfiguration = std::make_shared<Rendering::AtlasConfiguration>(*implementation->nativeConfiguration);
    implementation->bitmapConfiguration->familyName = "GNU Unifont";
    implementation->bitmapConfiguration->unifontScale = request.bitmapScale;
    auto owner = std::shared_ptr<SharedFontResources>(new SharedFontResources(std::move(implementation)));
    registry[key] = owner;
    return owner;
}

std::shared_ptr<FreeTypeRasterizer> SharedFontResources::nativeFace() const { return m_impl->native; }
std::shared_ptr<Rendering::GlyphRasterizer> SharedFontResources::rasterizer(Rendering::FontRasterizerKind rasterizerKind) const
{
    auto* pointer = rasterizerKind == Rendering::FontRasterizerKind::EmbeddedBitmap ? m_impl->bitmapBox.get() : m_impl->nativeBox.get();
    // Decorators borrow their inner faces. The alias retains this whole owner,
    // not merely the decorator, until every renderer and atlas releases it.
    return std::shared_ptr<Rendering::GlyphRasterizer>(shared_from_this(), pointer);
}
std::shared_ptr<const Rendering::AtlasConfiguration> SharedFontResources::configuration(Rendering::FontRasterizerKind rasterizerKind) const
{
    return rasterizerKind == Rendering::FontRasterizerKind::EmbeddedBitmap ? m_impl->bitmapConfiguration : m_impl->nativeConfiguration;
}

} // namespace Ubiquitty::Linux
