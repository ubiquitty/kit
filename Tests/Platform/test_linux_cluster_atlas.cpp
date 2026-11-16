// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"
#include "Platform/Linux/VulkanGlyphAtlas.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <vector>

namespace {

struct ClusterRasterizer final : Ubiquitty::Rendering::GlyphRasterizer {
    int calls { 0 };
    std::uint32_t lastWeight { 0 };
    Ubiquitty::Rendering::ClusterRasterBounds lastBounds;
    std::vector<std::uint32_t> lastCluster;

    Ubiquitty::Rendering::CellMetrics cellMetrics() const override
    {
        Ubiquitty::Rendering::CellMetrics metrics;
        metrics.cellWidth = 10;
        metrics.cellHeight = 20;
        return metrics;
    }

    Ubiquitty::Rendering::GlyphOverhangInputs glyphOverhang() const override
    {
        Ubiquitty::Rendering::GlyphOverhangInputs metrics;
        metrics.advanceWidth = 10;
        metrics.lineHeight = 20;
        metrics.ascent = 16;
        metrics.descent = 4;
        metrics.primaryBboxX = -3;
        metrics.primaryBboxWidth = 16;
        return metrics;
    }

    bool rasterizeGlyph(std::uint32_t, Ubiquitty::Rendering::FontFace, std::uint32_t, int, int, std::uint8_t*) override
    {
        return false;
    }

    bool rasterizeClusterInCell(const std::uint32_t* points, int count, Ubiquitty::Rendering::FontFace, std::uint32_t weight,
        double, Ubiquitty::Rendering::ClusterRasterBounds bounds, int width, int height, std::uint8_t* coverage) override
    {
        ++calls;
        lastWeight = weight;
        lastBounds = bounds;
        lastCluster.assign(points, points + count);
        std::fill_n(coverage, static_cast<std::size_t>(width) * height, std::uint8_t { 0 });
        for (int row = 0; row < height; ++row) {
            for (int column = 0; column < width; ++column) {
                if (column >= bounds.left && column < bounds.left + bounds.width)
                    coverage[static_cast<std::size_t>(row) * width + column] = static_cast<std::uint8_t>(calls);
            }
        }
        return true;
    }
};

} // namespace

TEST(vulkanMarkedClustersKeepWholeSourcesAndSeparateOneAndTwoColumnSlots)
{
    ClusterRasterizer rasterizer;
    Ubiquitty::Linux::VulkanGlyphAtlas atlas(rasterizer, 4096, 4);
    auto backend = atlas.glyphBackend();
    CHECK(backend.clusterGlyph != nullptr);
    CHECK(backend.wideClusterGlyph != nullptr);
    constexpr std::array<std::uint32_t, 4> points { 0x915, 0x94d, 0x937, 0x93f };
    const auto mono = backend.clusterGlyph(backend.context, points, Ubiquitty::Rendering::FontFace::Regular, 0, 0);
    CHECK(mono.present);
    CHECK_EQ(mono.maxUV.x - mono.minUV.x, 10.0f);
    CHECK_EQ(rasterizer.lastBounds.left, 3.0);
    CHECK_EQ(rasterizer.lastBounds.width, 10.0);
    CHECK(std::ranges::equal(rasterizer.lastCluster, points));
    const auto wide = backend.wideClusterGlyph(backend.context, points, Ubiquitty::Rendering::FontFace::Regular, 0, 0);
    CHECK(wide.present);
    CHECK_EQ(wide.maxUV.x - wide.minUV.x, 20.0f);
    CHECK_EQ(rasterizer.lastBounds.left, 0.0);
    CHECK_EQ(rasterizer.lastBounds.width, 20.0);
    CHECK(std::ranges::equal(rasterizer.lastCluster, points));
    CHECK_EQ(rasterizer.calls, 2);
    const auto repeatedMono = backend.clusterGlyph(backend.context, points, Ubiquitty::Rendering::FontFace::Regular, 0, 0);
    const auto repeatedWide = backend.wideClusterGlyph(backend.context, points, Ubiquitty::Rendering::FontFace::Regular, 0, 0);
    CHECK_EQ(rasterizer.calls, 2);
    CHECK_EQ(repeatedMono.minUV.x, mono.minUV.x);
    CHECK_EQ(repeatedWide.minUV.x, wide.minUV.x);
    const auto coverage = atlas.monoCoverage();
    const int pitch = atlas.atlasWidthInPixels();
    CHECK_EQ(coverage[static_cast<std::size_t>(mono.minUV.y) * pitch + static_cast<int>(mono.minUV.x)], 1);
    CHECK_EQ(coverage[static_cast<std::size_t>(wide.minUV.y) * pitch + static_cast<int>(wide.minUV.x)], 2);
}

TEST(vulkanWideMarkedClustersKeepDefaultWeightOnMissesAndHits)
{
    ClusterRasterizer rasterizer;
    Ubiquitty::Linux::VulkanGlyphAtlas atlas(rasterizer, 4096, 4);
    const auto backend = atlas.glyphBackend();
    constexpr std::array<std::uint32_t, 2> points { 0x6771, 0x301 };
    CHECK(backend.wideClusterGlyph(backend.context, points, Ubiquitty::Rendering::FontFace::Regular, 6, 0).present);
    CHECK_EQ(rasterizer.lastWeight, 0u);
    CHECK_EQ(rasterizer.calls, 1);
    CHECK(backend.wideClusterGlyph(backend.context, points, Ubiquitty::Rendering::FontFace::Regular, 2, 0).present);
    CHECK_EQ(rasterizer.calls, 1);
    CHECK(backend.wideClusterGlyph(backend.context, points, Ubiquitty::Rendering::FontFace::Bold, 7, 0).present);
    CHECK_EQ(rasterizer.lastWeight, 0u);
    CHECK_EQ(rasterizer.calls, 2);
}

UBIQUITTY_TEST_MAIN()
