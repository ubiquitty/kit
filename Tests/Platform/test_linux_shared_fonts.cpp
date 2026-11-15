// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"
#include "Platform/Linux/FreeTypeRasterizer.h"
#include "Platform/Linux/SharedFontResources.h"

#include <array>
#include <cmath>
#include <limits>
#include <thread>
#include <vector>

namespace {

Ubiquitty::Linux::SharedFontRequest request()
{
    Ubiquitty::Linux::SharedFontRequest result;
    result.family = "JetBrains Mono";
    result.pixelSize = 18;
    result.pointSize = 12;
    result.pixelsPerPoint = 1.5;
    result.primaryPath = std::string(UBQ_BUNDLED_FONTS_DIR) + "/JetBrainsMono[wght].ttf";
    result.fallbackPath = std::string(UBQ_BUNDLED_FONTS_DIR) + "/SymbolsNerdFontMono-Regular.ttf";
    return result;
}

} // namespace

TEST(equivalentWindowsShareNativeFacesAndImmutableDecorators)
{
    using Ubiquitty::Linux::SharedFontResources;
    using Ubiquitty::Rendering::FontRasterizerKind;
    auto first = SharedFontResources::acquire(request());
    auto second = SharedFontResources::acquire(request());
    REQUIRE(first && second);
    CHECK(first == second);
    CHECK(first->nativeFace() == second->nativeFace());
    CHECK(first->nativeFace()->ready());
    CHECK(first->rasterizer(FontRasterizerKind::Native) == second->rasterizer(FontRasterizerKind::Native));
    CHECK(first->rasterizer(FontRasterizerKind::EmbeddedBitmap) == second->rasterizer(FontRasterizerKind::EmbeddedBitmap));
    CHECK(first->rasterizer(FontRasterizerKind::Native) != first->rasterizer(FontRasterizerKind::EmbeddedBitmap));
    std::weak_ptr<SharedFontResources> weak = first;
    auto independentProvider = first->rasterizer(FontRasterizerKind::Native);
    first.reset();
    second.reset();
    CHECK(!weak.expired());
    CHECK(independentProvider->cellMetrics().cellWidth > 0);
    independentProvider.reset();
    CHECK(weak.expired());
}

TEST(eachNativeConstructionInputIsolatedByTheCanonicalCoreIdentity)
{
    using namespace Ubiquitty::Linux;
    auto first = SharedFontResources::acquire(request());
    REQUIRE(first);
    for (auto member : { &SharedFontRequest::deviceScale,
             &SharedFontRequest::lineSpacing, &SharedFontRequest::tracking,
             &SharedFontRequest::uprightWeight, &SharedFontRequest::boldWeight, &SharedFontRequest::bitmapScale }) {
        auto changed = request();
        ++(changed.*member);
        auto other = SharedFontResources::acquire(std::move(changed));
        CHECK(other && other != first);
    }
    for (auto member : { &SharedFontRequest::pixelSize, &SharedFontRequest::pointSize, &SharedFontRequest::pixelsPerPoint, &SharedFontRequest::widthPercent }) {
        auto changed = request();
        changed.*member = std::nextafter(changed.*member, std::numeric_limits<double>::infinity());
        CHECK(SharedFontResources::acquire(std::move(changed)) != first);
    }
    for (auto member : { &SharedFontRequest::family, &SharedFontRequest::fallbackFamily,
             &SharedFontRequest::fallbackPath, &SharedFontRequest::primaryPath,
             &SharedFontRequest::variations, &SharedFontRequest::features }) {
        auto changed = request();
        changed.*member += "Different";
        CHECK(SharedFontResources::acquire(std::move(changed)) != first);
    }
    auto changed = request();
    changed.ligatures = Ubiquitty::Rendering::Ligatures::Disabled;
    CHECK(SharedFontResources::acquire(std::move(changed)) != first);
    changed = request();
    ++changed.catalogGeneration;
    CHECK(SharedFontResources::acquire(std::move(changed)) != first);
}

TEST(fallbackPolicyIsKeyedWhileWindowColorsAndPaddingAreNot)
{
    using namespace Ubiquitty::Linux;
    auto first = SharedFontResources::acquire(request());
    auto changed = request();
    changed.preferences.shouldMatchFallbackSize = false;
    CHECK(SharedFontResources::acquire(std::move(changed)) != first);
    changed = request();
    changed.preferences.emojiFallbackFont = "Chosen Emoji";
    CHECK(SharedFontResources::acquire(std::move(changed)) != first);
    changed = request();
    changed.preferences.rangeMap.push_back({ 0x300, 0x36f, {}, {}, "Noto Sans", false });
    CHECK(SharedFontResources::acquire(std::move(changed)) != first);
    changed = request();
    changed.preferences.languageFallbacks.push_back({ "han", "ja", {}, "Chosen CJK" });
    CHECK(SharedFontResources::acquire(std::move(changed)) != first);
    changed = request();
    changed.preferences.backgroundOpacity = 0.5;
    changed.preferences.padding = 31;
    CHECK(SharedFontResources::acquire(std::move(changed)) == first);
}

TEST(concurrentAcquisitionBuildsOneProviderAndTheRegistryRetainsNoOwner)
{
    using Ubiquitty::Linux::SharedFontResources;
    std::array<std::shared_ptr<SharedFontResources>, 4> owners;
    std::vector<std::thread> workers;
    for (std::size_t index = 0; index < owners.size(); ++index)
        workers.emplace_back([&, index] { owners[index] = SharedFontResources::acquire(request()); });
    for (auto& worker : workers)
        worker.join();
    REQUIRE(owners.front());
    for (const auto& owner : owners)
        CHECK(owner == owners.front());
    std::weak_ptr<SharedFontResources> weak = owners.front();
    owners.fill(nullptr);
    CHECK(weak.expired());
}

UBIQUITTY_TEST_MAIN()
