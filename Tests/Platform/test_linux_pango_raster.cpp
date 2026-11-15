// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Core/Rendering/BoxDrawingRasterizer.h"
#include "Harness.h"
#include "Platform/Linux/FreeTypeRasterizer.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include <pango/pangocairo.h>
#include <pango/pangofc-fontmap.h>

namespace {

using Ubiquitty::Rendering::FontFace;

/// Selects the independent reference's style for a routed mark run.
enum class MarkStyle : std::uint8_t {
    MatchBase,
    Upright,
};

/// Keep the reference's physical fonts independent of desktop aliases.
struct NativeReference {
    FcConfig* previous { FcConfigReference(FcConfigGetCurrent()) };
    FcConfig* configuration { FcConfigCreate() };
    PangoFontMap* map { pango_cairo_font_map_new() };

    NativeReference()
    {
        CHECK(FcConfigAppFontAddDir(configuration, reinterpret_cast<const FcChar8*>(UBQ_BUNDLED_FONTS_DIR)));
        constexpr auto rules = "<fontconfig><match target='font'><edit name='hinting' mode='assign'><bool>false</bool></edit>"
                               "<edit name='hintstyle' mode='assign'><const>hintnone</const></edit>"
                               "<edit name='rgba' mode='assign'><const>none</const></edit></match></fontconfig>";
        CHECK(FcConfigParseAndLoadFromMemory(configuration, reinterpret_cast<const FcChar8*>(rules), FcTrue));
        CHECK(FcConfigSetCurrent(configuration));
        pango_fc_font_map_set_config(PANGO_FC_FONT_MAP(map), configuration);
    }

    ~NativeReference()
    {
        g_object_unref(map);
        FcConfigSetCurrent(previous);
        FcConfigDestroy(previous);
        FcConfigDestroy(configuration);
    }

    std::vector<std::uint8_t> draw(const std::string& text, FontFace style, double pixelSize, int width, int height, int baseline, double penX, const char* markFamily = nullptr, double markSize = 0, MarkStyle markStyle = MarkStyle::MatchBase, double pointSize = 0, double resolution = 96.0)
    {
        auto* context = pango_font_map_create_context(map);
        pango_cairo_context_set_resolution(context, resolution);
        pango_context_set_round_glyph_positions(context, TRUE);
        auto* description = pango_font_description_new();
        pango_font_description_set_family(description, "JetBrains Mono");
        if (pointSize > 0)
            pango_font_description_set_size(description, static_cast<int>(std::lround(pointSize * PANGO_SCALE)));
        else
            pango_font_description_set_absolute_size(description, pixelSize * PANGO_SCALE);
        pango_font_description_set_weight(description, Ubiquitty::Rendering::isBold(style) ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
        pango_font_description_set_style(description, Ubiquitty::Rendering::isItalic(style) ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
        auto* layout = pango_layout_new(context);
        pango_layout_set_font_description(layout, description);
        if (markFamily) {
            auto* marks = pango_font_description_copy(description);
            pango_font_description_set_family(marks, markFamily);
            if (markStyle == MarkStyle::Upright)
                pango_font_description_set_style(marks, PANGO_STYLE_NORMAL);
            if (pointSize > 0 && markSize == pixelSize)
                pango_font_description_set_size(marks, static_cast<int>(std::lround(pointSize * PANGO_SCALE)));
            else
                pango_font_description_set_absolute_size(marks, markSize * PANGO_SCALE);
            auto* attributes = pango_attr_list_new();
            pango_attr_list_insert(attributes, pango_attr_fallback_new(FALSE));
            auto* attribute = pango_attr_font_desc_new(marks);
            attribute->start_index = 1;
            attribute->end_index = G_MAXUINT;
            pango_attr_list_insert(attributes, attribute);
            pango_layout_set_attributes(layout, attributes);
            pango_attr_list_unref(attributes);
            pango_font_description_free(marks);
        }
        pango_layout_set_text(layout, text.data(), static_cast<int>(text.size()));
        auto* surface = cairo_image_surface_create(CAIRO_FORMAT_A8, width, height);
        auto* painter = cairo_create(surface);
        cairo_set_source_rgba(painter, 1, 1, 1, 1);
        cairo_move_to(painter, penX, baseline);
        pango_cairo_show_layout_line(painter, pango_layout_get_line_readonly(layout, 0));
        cairo_surface_flush(surface);
        std::vector<std::uint8_t> result(static_cast<std::size_t>(width) * height);
        for (int row = 0; row < height; ++row)
            std::copy_n(cairo_image_surface_get_data(surface) + row * cairo_image_surface_get_stride(surface), width, result.data() + row * width);
        cairo_destroy(painter);
        cairo_surface_destroy(surface);
        g_object_unref(layout);
        pango_font_description_free(description);
        g_object_unref(context);
        return result;
    }
};

Ubiquitty::Linux::FreeTypeRasterizer rasterizer(double pixelSize, Ubiquitty::Preferences::FontRoutePreferences preferences = {})
{
    return Ubiquitty::Linux::FreeTypeRasterizer(pixelSize, "JetBrains Mono", {},
        std::string(UBQ_BUNDLED_FONTS_DIR) + "/SymbolsNerdFontMono-Regular.ttf",
        std::string(UBQ_BUNDLED_FONTS_DIR) + "/JetBrainsMono[wght].ttf", 1, 0, 0, 0, 0, 0, {}, {}, Ubiquitty::Linux::Ligatures::Enabled, std::move(preferences));
}

// Independent configured reference: apply the documented x-height ratio to
// the native font, then request exactly that effective size from Pango.
double matchedMarkSize(int pixels, const char* fallbackFile)
{
    FT_Library library = nullptr;
    if (FT_Init_FreeType(&library) != 0)
        return 0;
    FT_Face primary = nullptr, fallback = nullptr;
    const std::string directory = std::string(UBQ_BUNDLED_FONTS_DIR) + "/";
    const bool didLoad = FT_New_Face(library, (directory + "JetBrainsMono[wght].ttf").c_str(), 0, &primary) == 0
        && FT_New_Face(library, (directory + fallbackFile).c_str(), 0, &fallback) == 0;
    double result = 0;
    if (didLoad) {
        const auto* first = static_cast<const TT_OS2*>(FT_Get_Sfnt_Table(primary, ft_sfnt_os2));
        const auto* second = static_cast<const TT_OS2*>(FT_Get_Sfnt_Table(fallback, ft_sfnt_os2));
        if (first && second && first->sxHeight > 0 && second->sxHeight > 0) {
            const double ratio = (first->sxHeight / static_cast<double>(primary->units_per_EM)) / (second->sxHeight / static_cast<double>(fallback->units_per_EM));
            result = pixels * ratio;
        }
    }
    if (fallback)
        FT_Done_Face(fallback);
    if (primary)
        FT_Done_Face(primary);
    FT_Done_FreeType(library);
    return result;
}

} // namespace

TEST(bundledASCIIMasksMatchNativePangoAtTheSamePixelSizeAndBaseline)
{
    NativeReference reference;
    constexpr auto ascii = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 !?.,;:()[]{}+-=*/_@#$%&";
    for (int size : { 15, 28, 32 }) {
        auto raster = rasterizer(size);
        CHECK(raster.ready());
        const auto metrics = raster.cellMetrics();
        const int width = static_cast<int>(std::lround(metrics.cellWidth)) + 16;
        const int height = static_cast<int>(std::lround(metrics.cellHeight)) + 64;
        const int baseline = static_cast<int>(std::lround(metrics.baselineFromTop)) + 32;
        for (auto style : { FontFace::Regular, FontFace::Bold, FontFace::Italic, FontFace::BoldItalic }) {
            for (const char* character = ascii; *character; ++character) {
                std::vector<std::uint8_t> actual(static_cast<std::size_t>(width) * height);
                CHECK(raster.rasterizeGlyph(static_cast<unsigned char>(*character), style, 0, width, height, actual.data()));
                CHECK_MSG(actual == reference.draw(std::string(1, *character), style, size, width, height, baseline, 8), "native ASCII mask, including bearings and antialias coverage");
            }
        }
    }
}

TEST(overlappingShapedGlyphsAccumulateLikeCairosNativeGlyphMask)
{
    NativeReference reference;
    for (int size : { 15, 28, 32 }) {
        auto raster = rasterizer(size);
        const auto metrics = raster.cellMetrics();
        const int cellWidth = static_cast<int>(std::lround(metrics.cellWidth));
        const int height = static_cast<int>(std::lround(metrics.cellHeight)) + 64;
        const int baseline = static_cast<int>(std::lround(metrics.baselineFromTop)) + 32;
        for (const std::string text : { "f", "ff", "ffi", "==>", "==>=" }) {
            std::vector<std::uint32_t> codePoints(text.begin(), text.end());
            std::vector<Ubiquitty::Rendering::GlyphRasterizer::ShapedGlyph> glyphs(codePoints.size() * 2);
            const int count = raster.shapeTextRun(codePoints, 0, glyphs);
            CHECK(count > 0);
            const int width = static_cast<int>(text.size()) * cellWidth + 16;
            std::vector<std::uint8_t> actual(static_cast<std::size_t>(width) * height);
            CHECK(raster.rasteriseShapedRun(std::span(glyphs).first(static_cast<std::size_t>(count)), width, height, actual));
            CHECK_MSG(actual == reference.draw(text, FontFace::Regular, size, width, height, baseline, 0), "native shaped mask must retain overlapping glyph edges");
        }
    }
}

TEST(overlappingPrimaryMarksAccumulateLikeCairosNativeGlyphMask)
{
    NativeReference reference;
    auto raster = rasterizer(15);
    const auto metrics = raster.cellMetrics();
    const int width = static_cast<int>(std::lround(metrics.cellWidth)) + 16;
    const int height = static_cast<int>(std::lround(metrics.cellHeight)) + 384;
    const int baseline = static_cast<int>(std::lround(metrics.baselineFromTop)) + 192;
    std::vector<std::uint32_t> codePoints(16, 0x301);
    codePoints[0] = 'a';
    std::string text = "a";
    for (int index = 0; index < 15; ++index)
        text += "\xcc\x81";
    for (auto style : { FontFace::Regular, FontFace::Bold, FontFace::Italic, FontFace::BoldItalic }) {
        std::vector<std::uint8_t> actual(static_cast<std::size_t>(width) * height);
        CHECK(raster.rasterizeCluster(codePoints.data(), static_cast<int>(codePoints.size()), style, 0, width, height, actual.data()));
        CHECK_MSG(actual == reference.draw(text, style, 15, width, height, baseline, 8), "native cluster mask, with enough canvas to isolate glyph compositing from atlas clipping");
    }
}

TEST(mixedFontMarksMatchNativePangoWithTheCoreChosenFallbackFace)
{
    NativeReference reference;
    constexpr std::array<std::uint32_t, 8> points { 'Z', 0x335, 0x34c, 0x35d, 0x30e, 0x321, 0x320, 0x32b };
    const std::string text = "Z̵̡̠̫͌̎͝";
    for (int size : { 15, 28, 32 }) {
        Ubiquitty::Preferences::FontRoutePreferences preferences;
        preferences.shouldMatchFallbackSize = false;
        auto raster = rasterizer(size, std::move(preferences));
        const auto metrics = raster.cellMetrics();
        const int width = static_cast<int>(std::lround(metrics.cellWidth)) + 16;
        const int height = static_cast<int>(std::lround(metrics.cellHeight)) + 128;
        const int baseline = static_cast<int>(std::lround(metrics.baselineFromTop)) + 64;
        for (auto style : { FontFace::Regular, FontFace::Bold, FontFace::Italic, FontFace::BoldItalic }) {
            std::vector<std::uint8_t> actual(static_cast<std::size_t>(width) * height);
            CHECK(raster.rasterizeCluster(points.data(), static_cast<int>(points.size()), style, 0, width, height, actual.data()));
            // Core's complete-run cascade picks the bundled Noto face. Native
            // automatic italic fallback can mix Monaspace into this mark run;
            // configure the reference with the same actual Core-selected face.
            const auto expected = reference.draw(text, style, size, width, height, baseline, 8, "Noto Sans", size, MarkStyle::Upright);
            CHECK_MSG(actual == expected, "native itemization must retain the base and shape the complete fallback mark run");
        }
    }
}

TEST(anExplicitMarkRangeKeepsItsCoreFaceAndSizingOverride)
{
    NativeReference reference;
    constexpr std::array<std::uint32_t, 3> points { 'Z', 0x34c, 0x34c };
    const std::string text = "Z͌͌";
    Ubiquitty::Preferences::FontRoutePreferences preferences;
    preferences.shouldMatchFallbackSize = true;
    preferences.rangeMaps.push_back({ 0x300, 0x36f, "Monaspace Neon", Ubiquitty::Rendering::FontMetrics::FallbackSizing::Nominal });
    auto raster = rasterizer(28, std::move(preferences));
    const auto metrics = raster.cellMetrics();
    const int width = static_cast<int>(std::lround(metrics.cellWidth)) + 16;
    const int height = static_cast<int>(std::lround(metrics.cellHeight)) + 128;
    const int baseline = static_cast<int>(std::lround(metrics.baselineFromTop)) + 64;
    for (auto style : { FontFace::Regular, FontFace::Bold, FontFace::Italic, FontFace::BoldItalic }) {
        std::vector<std::uint8_t> actual(static_cast<std::size_t>(width) * height);
        CHECK(raster.rasterizeCluster(points.data(), static_cast<int>(points.size()), style, 0, width, height, actual.data()));
        const auto expected = reference.draw(text, style, 28, width, height, baseline, 8, "Monaspace Neon", 28);
        CHECK_MSG(actual == expected, "explicit range family and nominal sizing must override automatic optical sizing");
    }
}

TEST(mixedFontNativeMarksRespectCoreOpticalMatching)
{
    NativeReference reference;
    constexpr std::array<std::uint32_t, 8> points { 'Z', 0x335, 0x34c, 0x35d, 0x30e, 0x321, 0x320, 0x32b };
    const std::string text = "Z̵̡̠̫͌̎͝";
    auto raster = rasterizer(28);
    const auto metrics = raster.cellMetrics();
    const int width = static_cast<int>(std::lround(metrics.cellWidth)) + 16;
    const int height = static_cast<int>(std::lround(metrics.cellHeight)) + 128;
    const int baseline = static_cast<int>(std::lround(metrics.baselineFromTop)) + 64;
    for (auto style : { FontFace::Regular, FontFace::Bold, FontFace::Italic, FontFace::BoldItalic }) {
        const double matched = matchedMarkSize(28, Ubiquitty::Rendering::isBold(style) ? "NotoSans-Bold.ttf" : "NotoSans-Regular.ttf");
        CHECK(matched > 0 && matched != 28);
        std::vector<std::uint8_t> actual(static_cast<std::size_t>(width) * height);
        CHECK(raster.rasterizeCluster(points.data(), static_cast<int>(points.size()), style, 0, width, height, actual.data()));
        const auto nominal = reference.draw(text, style, 28, width, height, baseline, 8, "Noto Sans", 28, MarkStyle::Upright);
        const auto expected = reference.draw(text, style, 28, width, height, baseline, 8, "Noto Sans", matched, MarkStyle::Upright);
        CHECK_MSG(expected != nominal, "control proves optical matching changes the native mark mask");
        CHECK_MSG(actual == expected, "Core optical sizing must survive native fallback-run shaping");
    }
}

TEST(nativeASCIIMasksMatchPangoAtEveryQuarterPhaseAndUnroundedPointSize)
{
    NativeReference reference;
    constexpr auto ascii = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 !?.,;:()[]{}+-=*/_@#$%&";
    for (double em : { 15.0, 28.0, 11.0 * 182.4 / 72.0 }) {
        auto raster = rasterizer(em);
        CHECK(raster.glyphPhaseCount() == 4);
        const auto metrics = raster.cellMetrics();
        const int width = static_cast<int>(std::lround(metrics.cellWidth)) + 16;
        const int height = static_cast<int>(std::lround(metrics.cellHeight)) + 64;
        const int baseline = static_cast<int>(std::lround(metrics.baselineFromTop)) + 32;
        for (auto style : { FontFace::Regular, FontFace::Bold, FontFace::Italic, FontFace::BoldItalic }) {
            for (double phase : { 0.0, 0.25, 0.5, 0.75 }) {
                for (const char* character = ascii; *character; ++character) {
                    std::vector<std::uint8_t> actual(static_cast<std::size_t>(width) * height);
                    CHECK(raster.rasterizeGlyphAtPhase(static_cast<unsigned char>(*character), style, 0, phase, width, height, actual.data()));
                    const bool hasFractionalEm = std::floor(em) != em;
                    const auto expected = reference.draw(std::string(1, *character), style, em, width, height, baseline, 8 + phase,
                        nullptr, 0, MarkStyle::MatchBase, hasFractionalEm ? 11 : 0, hasFractionalEm ? 182.4 : 96);
                    CHECK_MSG(actual == expected, "same physical font, exact requested point/DPI matrix and quarter phase as independent native Pango");
                }
            }
        }
    }
}

TEST(unroundedWholeCellLigatureAndASCIIRunsMatchPango)
{
    NativeReference reference;
    constexpr double em = 11.0 * 182.4 / 72.0;
    auto raster = rasterizer(em);
    const auto metrics = raster.cellMetrics();
    const int height = static_cast<int>(std::lround(metrics.cellHeight)) + 64;
    const int baseline = static_cast<int>(std::lround(metrics.baselineFromTop)) + 32;
    for (const std::string text : { "f", "ff", "ffi", "==>", "==>=", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 !?.,;:()[]{}+-=*/_@#$%&" }) {
        std::vector<std::uint32_t> points(text.begin(), text.end());
        std::vector<Ubiquitty::Rendering::GlyphRasterizer::ShapedGlyph> original(points.size() * 2);
        const int count = raster.shapeTextRun(points, 0, original);
        CHECK(count > 0);
        original.resize(static_cast<std::size_t>(count));
        const int width = static_cast<int>(text.size() * std::lround(metrics.cellWidth)) + 16;
        // The Core strip seam carries whole-pixel offsets;
        // quarter phases belong to glyph/cluster/proportional atlas seams.
        std::vector<std::uint8_t> actual(static_cast<std::size_t>(width) * height);
        CHECK(raster.rasteriseShapedRun(original, width, height, actual));
        CHECK_MSG(actual == reference.draw(text, FontFace::Regular, em, width, height, baseline, 0, nullptr, 0, MarkStyle::MatchBase, 11, 182.4), "unrounded native glyph masks retain the whole-cell strip's Pango advances");
    }
}

TEST(unroundedPrimaryMarkClustersMatchPangoAtEveryQuarterPhase)
{
    NativeReference reference;
    constexpr double em = 11.0 * 182.4 / 72.0;
    auto raster = rasterizer(em);
    const auto metrics = raster.cellMetrics();
    const int width = static_cast<int>(std::lround(metrics.cellWidth)) + 16;
    const int height = static_cast<int>(std::lround(metrics.cellHeight)) + 128;
    const int baseline = static_cast<int>(std::lround(metrics.baselineFromTop)) + 64;
    const std::array<std::uint32_t, 3> points { 'a', 0x0301, 0x0308 };
    for (auto style : { FontFace::Regular, FontFace::Bold, FontFace::Italic, FontFace::BoldItalic }) {
        for (double phase : { 0.0, 0.25, 0.5, 0.75 }) {
            std::vector<std::uint8_t> actual(static_cast<std::size_t>(width) * height);
            CHECK(raster.rasterizeClusterAtPhase(points.data(), points.size(), style, 0, phase, width, height, actual.data()));
            CHECK_MSG(actual == reference.draw("á̈", style, em, width, height, baseline, 8 + phase, nullptr, 0, MarkStyle::MatchBase, 11, 182.4), "mark placement and masks retain the same unrounded font matrix as their base");
        }
    }
}

TEST(unroundedMixedFaceClustersMatchTheConfiguredNativePointSize)
{
    NativeReference reference;
    constexpr double em = 11.0 * 182.4 / 72.0;
    Ubiquitty::Preferences::FontRoutePreferences preferences;
    preferences.shouldMatchFallbackSize = false;
    auto raster = rasterizer(em, std::move(preferences));
    const auto metrics = raster.cellMetrics();
    const int width = static_cast<int>(std::lround(metrics.cellWidth)) + 16;
    const int height = static_cast<int>(std::lround(metrics.cellHeight)) + 128;
    const int baseline = static_cast<int>(std::lround(metrics.baselineFromTop)) + 64;
    const std::array<std::uint32_t, 8> points { 'Z', 0x335, 0x34c, 0x35d, 0x30e, 0x321, 0x320, 0x32b };
    for (auto style : { FontFace::Regular, FontFace::Bold, FontFace::Italic, FontFace::BoldItalic }) {
        for (double phase : { 0.0, 0.25, 0.5, 0.75 }) {
            std::vector<std::uint8_t> actual(static_cast<std::size_t>(width) * height);
            CHECK(raster.rasterizeClusterAtPhase(points.data(), points.size(), style, 0, phase, width, height, actual.data()));
            CHECK_MSG(actual == reference.draw("Z̵̡̠̫͌̎͝", style, em, width, height, baseline, 8 + phase, "Noto Sans", em, MarkStyle::Upright, 11, 182.4), "both faces keep the requested point size through native fallback itemization");
        }
    }
}

TEST(repeatedFilledSquaresKeepNativeMasksAndIntegerCellPitch)
{
    NativeReference reference;
    for (double em : { 15.0, 28.0, 11.0 * 182.4 / 72.0 }) {
        auto preferences = Ubiquitty::Preferences::buildFontRoutePreferences(Ubiquitty::Preferences::Values {});
        auto raster = rasterizer(em, std::move(preferences));
        CHECK(raster.ready());
        // The built-in geometric fallback yields to this primary glyph. The
        // oracle must use the actual JetBrains face rather than substitute a
        // square from a family that the routing policy never selects here.
        CHECK(raster.glyphIndexForCodePoint(0x25A0) != 0);
        const auto metrics = raster.cellMetrics();
        CHECK(metrics.cellWidth == std::floor(metrics.cellWidth));
        const int advance = static_cast<int>(metrics.cellWidth);
        const int cellHeight = static_cast<int>(std::lround(metrics.cellHeight));
        const int slotWidth = advance + 16;
        const int height = cellHeight + 64;
        const int tripletWidth = 3 * advance + 16;
        const int baseline = static_cast<int>(std::lround(metrics.baselineFromTop)) + 32;
        for (double phase : { 0.0, 0.25, 0.5, 0.75 }) {
            std::vector<std::uint8_t> first(static_cast<std::size_t>(slotWidth) * height);
            CHECK(raster.rasterizeGlyphAtPhase(0x25A0, FontFace::Regular, 0, phase, slotWidth, height, first.data()));
            CHECK(std::ranges::any_of(first, [](std::uint8_t coverage) { return coverage != 0; }));
            for (int cell = 0; cell < 3; ++cell) {
                std::vector<std::uint8_t> next(first.size());
                CHECK(raster.rasterizeGlyphAtPhase(0x25A0, FontFace::Regular, 0, phase, slotWidth, height, next.data()));
                CHECK_MSG(next == first, "each repeated square retains the same native mask at its common grid phase");
                std::vector<std::uint8_t> placed(static_cast<std::size_t>(tripletWidth) * height);
                for (int y = 0; y < height; ++y) {
                    std::copy_n(next.data() + static_cast<std::size_t>(y) * slotWidth, slotWidth,
                        placed.data() + static_cast<std::size_t>(y) * tripletWidth + cell * advance);
                }
                // This glyph overhangs its advance. Compare each cell's mask
                // independently so differences between batched text-mask
                // compositing and separate terminal glyphs cannot hide a
                // placement or coverage error.
                const bool hasFractionalEm = std::floor(em) != em;
                const auto expected = reference.draw("■", FontFace::Regular, em, tripletWidth, height, baseline, 8 + cell * advance + phase,
                    nullptr, 0, MarkStyle::MatchBase, hasFractionalEm ? 11 : 0, hasFractionalEm ? 182.4 : 96);
                CHECK_MSG(placed == expected, "each fixed cell origin retains the chosen face's native square mask at its exact font em");
            }
        }
        // U+2588 is a cell-filling primitive, unlike the font's U+25A0.
        Ubiquitty::Rendering::BoxDrawingRasterizer decorated(raster);
        std::vector<std::uint8_t> fullBlock(static_cast<std::size_t>(advance) * cellHeight);
        for (double phase : { 0.0, 0.25, 0.5, 0.75 }) {
            CHECK(decorated.rasterizeGlyphAtPhase(0x2588, FontFace::Regular, 0, phase, advance, cellHeight, fullBlock.data()));
            CHECK(std::ranges::all_of(fullBlock, [](std::uint8_t coverage) { return coverage == 255; }));
        }
    }
}

UBIQUITTY_TEST_MAIN()
