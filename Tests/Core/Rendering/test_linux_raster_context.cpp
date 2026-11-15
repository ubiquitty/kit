// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

#include "Core/Rendering/BeamLayout.h"
#include "Core/Rendering/GlyphRasterizer.h"
#include "Core/Rendering/HintToastLayout.h"
#include "Core/Rendering/TerminalFrameInputs.h"
#include "Core/Rendering/UnifontRasterizer.h"
#include "Core/Runtime/TerminalSession.h"
#include "Core/Screen/Addressing.h"
#include "Core/Terminal.h"
#include "Core/TerminalOperations.h"
#include "Platform/Linux/Raster.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <type_traits>
#include <vector>

namespace {

/// Supplies deterministic coverage and metrics without consulting a font system.
struct MetricsRasterizer final : Ubiquitty::Rendering::GlyphRasterizer {
    MetricsRasterizer(int width, int height)
    {
        metrics.cellWidth = static_cast<float>(width);
        metrics.cellHeight = static_cast<float>(height);
        metrics.baselineFromTop = static_cast<float>(height - 3);
    }

    Ubiquitty::Rendering::CellMetrics cellMetrics() const override { return metrics; }

    bool rasterizeGlyph(std::uint32_t codePoint, Ubiquitty::Rendering::FontFace, std::uint32_t,
        int width, int height, std::uint8_t* coverage) override
    {
        if (!coverage || width <= 0 || height <= 0)
            return false;
        ++paints;
        std::fill_n(coverage, static_cast<std::size_t>(width) * static_cast<std::size_t>(height), codePoint == ' ' ? 0 : 220);
        return true;
    }

    Ubiquitty::Rendering::CellMetrics metrics;
    unsigned paints = 0;
};

/// Creates only a passive in-memory model; no stream, process or event loop.
std::unique_ptr<Ubiquitty::Terminal> passiveTerminal()
{
    auto term = std::make_unique<Ubiquitty::Terminal>();
    Ubiquitty::resize(*term, 3, 8);
    Ubiquitty::processBytes(term.get(), "abc");
    return term;
}

} // namespace

TEST(twoLinuxRasterContextsKeepTheirOwnMetricsScaleAndCursorStyle)
{
    using Ubiquitty::Linux::RasterContext;
    static_assert(!std::is_copy_constructible_v<RasterContext>);
    static_assert(!std::is_move_constructible_v<RasterContext>);
    MetricsRasterizer firstFace(7, 13);
    MetricsRasterizer secondFace(11, 19);
    RasterContext first;
    RasterContext second;
    first.setGlyphRasterizer(firstFace);
    second.setGlyphRasterizer(secondFace);
    first.setDeviceScale(2);
    second.setDeviceScale(3);
    first.setEmbeddedBitmapScale(2);
    second.setEmbeddedBitmapScale(0);
    auto firstStyle = first.renderConfiguration();
    firstStyle.backgroundOpacity = 0.25;
    firstStyle.cursorAlpha = 0.25;
    firstStyle.shouldCursorInvertText = false;
    first.setRenderConfiguration(firstStyle);
    auto secondStyle = second.renderConfiguration();
    secondStyle.backgroundOpacity = 0.75;
    secondStyle.cursorAlpha = 0.75;
    secondStyle.shouldCursorInvertText = true;
    second.setRenderConfiguration(secondStyle);
    CHECK(first.cellWidth() == 7 && first.cellHeight() == 13);
    CHECK(second.cellWidth() == 11 && second.cellHeight() == 19);
    CHECK(first.deviceScale() == 2 && second.deviceScale() == 3);
    CHECK(first.embeddedBitmapScale() == 2 && second.embeddedBitmapScale() == 0);
    CHECK(first.backgroundOpacity() == 0.25f && second.backgroundOpacity() == 0.75f);

    auto terminal = passiveTerminal();
    Ubiquitty::Rendering::CursorRenderState firstCursor;
    Ubiquitty::Rendering::CursorRenderState secondCursor;
    Ubiquitty::Linux::CursorOverlay cursor;
    cursor.visible = true;
    first.fillCursorState(terminal.get(), 0, &cursor, firstCursor);
    second.fillCursorState(terminal.get(), 0, &cursor, secondCursor);
    CHECK(firstCursor.rgb.w == 0.25f && secondCursor.rgb.w == 0.75f);
    CHECK(!firstCursor.shouldInvertText && secondCursor.shouldInvertText);
    first.setDeviceScale(0);
    CHECK(first.deviceScale() == 1 && second.deviceScale() == 3);
    firstStyle.backgroundOpacity = 0.5;
    first.setRenderConfiguration(firstStyle);
    CHECK(second.backgroundOpacity() == 0.75f);
}

TEST(linuxFrameGeometryKeepsProceduralPhasesSeparateFromBitmapMasks)
{
    using namespace Ubiquitty::Rendering;
    struct NativeRasterizer final : GlyphRasterizer {
        CellMetrics cellMetrics() const override { return { .cellWidth = 8, .cellHeight = 16 }; }
        int glyphPhaseCount() const override { return 4; }
        bool rasterizeGlyph(std::uint32_t, FontFace, std::uint32_t, int, int, std::uint8_t*) override { return false; }
    } native;
    UnifontRasterizer bitmap;
    Ubiquitty::Linux::RasterContext context;
    context.setGlyphRasterizer(bitmap);
    for (int bitmapScale : { 1, 2 }) {
        context.setEmbeddedBitmapScale(bitmapScale);
        CHECK_EQ(context.glyphPhaseCount(), 1);
        CHECK_EQ(context.frameGeometryPhaseCount(), 8);
        CHECK_EQ(context.frameCaptureGeometry().subpixelPhaseCount, 8);
    }
    // Switching the same context back to a native face must publish its own
    // grid in captures as well as in the live Vulkan frame's query.
    context.setGlyphRasterizer(native);
    context.setEmbeddedBitmapScale(0);
    CHECK_EQ(context.glyphPhaseCount(), 4);
    CHECK_EQ(context.frameGeometryPhaseCount(), 4);
    CHECK_EQ(context.frameCaptureGeometry().subpixelPhaseCount, 4);
}

TEST(linuxCapturesPublishHealingParticipationBeforeEitherAtlasExists)
{
    using namespace Ubiquitty::Rendering;
    struct ContextualRasterizer final : GlyphRasterizer {
        CellMetrics cellMetrics() const override { return { .cellWidth = 8, .cellHeight = 16 }; }
        bool hasLigatureShaping() const override { return true; }
        bool rasterizeGlyph(std::uint32_t, FontFace, std::uint32_t, int, int, std::uint8_t*) override { return false; }
        int shapeTextRun(std::span<const std::uint32_t> codePoints, std::uint32_t, std::span<ShapedGlyph> glyphs) override
        {
            ++shapeCalls;
            if (glyphs.size() < codePoints.size())
                return 0;
            for (std::size_t index = 0; index < codePoints.size(); ++index)
                glyphs[index] = { codePoints[index] + (shouldHeal && codePoints.size() > 1 ? 1000u : 0u), 8, 0, 0, static_cast<int>(index) };
            return static_cast<int>(codePoints.size());
        }
        bool shouldHeal = false;
        unsigned shapeCalls = 0;
    } healing, operators;
    healing.shouldHeal = true;

    Ubiquitty::Linux::RasterContext context;
    CHECK(context.frameCaptureGeometry().glyphSlot.ligatureParticipation == LigatureParticipation::OperatorRuns);
    context.setGlyphRasterizer(healing);
    const unsigned firstProbeCalls = healing.shapeCalls;
    REQUIRE(firstProbeCalls > 1);
    const auto firstGeometry = context.frameCaptureGeometry();
    CHECK(firstGeometry.glyphSlot.ligatureParticipation == LigatureParticipation::AllEligibleRuns);
    auto terminal = passiveTerminal();
    TerminalFrameInputs capture;
    TerminalSnapshotOptions options;
    REQUIRE(capture.capture(*terminal, options, firstGeometry.metrics, firstGeometry.glyphSlot));
    CHECK(capture.inputs().ligatureParticipation == LigatureParticipation::AllEligibleRuns);
    CHECK(context.frameCaptureGeometry().glyphSlot.ligatureParticipation == LigatureParticipation::AllEligibleRuns);
    CHECK_EQ(healing.shapeCalls, firstProbeCalls);

    context.setGlyphRasterizer(operators);
    const unsigned secondProbeCalls = operators.shapeCalls;
    REQUIRE(secondProbeCalls > 1);
    CHECK(context.frameCaptureGeometry().glyphSlot.ligatureParticipation == LigatureParticipation::OperatorRuns);
    CHECK_EQ(operators.shapeCalls, secondProbeCalls);
    CHECK_EQ(healing.shapeCalls, firstProbeCalls);
    // A queued immutable capture retains the old face's decision after a swap.
    CHECK(capture.inputs().ligatureParticipation == LigatureParticipation::AllEligibleRuns);
    context.setGlyphRasterizer(healing);
    CHECK(context.frameCaptureGeometry().glyphSlot.ligatureParticipation == LigatureParticipation::AllEligibleRuns);
    CHECK(healing.shapeCalls > firstProbeCalls);
}

// kitty's cursor_text reaches the cursor both Linux renderers draw: the GTK
// software path and the Vulkan one build it through fillCursorState, and a
// reset hands the glyph back to the renderer's own contrast.
TEST(theLinuxCursorDrawsItsGlyphInTheCursorTextColor)
{
    MetricsRasterizer face(7, 13);
    Ubiquitty::Linux::RasterContext context;
    context.setGlyphRasterizer(face);
    auto terminal = passiveTerminal();
    Ubiquitty::Linux::CursorOverlay overlay;
    overlay.visible = true;
    Ubiquitty::Rendering::CursorRenderState cursor;
    context.fillCursorState(terminal.get(), 0, &overlay, cursor);
    CHECK(!cursor.hasTextColor);

    Ubiquitty::processBytes(terminal.get(), "\033]21;cursor_text=#336699\033\\");
    context.fillCursorState(terminal.get(), 0, &overlay, cursor);
    CHECK(cursor.hasTextColor);
    CHECK(cursor.textRGB.x == 0x33 / 255.0f && cursor.textRGB.y == 0x66 / 255.0f && cursor.textRGB.z == 0x99 / 255.0f);
    context.fillCursorState(terminal.get(), 0, nullptr, cursor);
    CHECK_MSG(cursor.hasTextColor, "the static cursor of a headless dump takes it too");

    Ubiquitty::processBytes(terminal.get(), "\033]21;cursor_text\033\\");
    context.fillCursorState(terminal.get(), 0, &overlay, cursor);
    CHECK(!cursor.hasTextColor);
}

TEST(twoLinuxRasterContextsDoNotSharePreeditPaletteOrHintCaptures)
{
    auto terminal = passiveTerminal();
    const auto original = *Ubiquitty::Screen::visibleCell(terminal.get(), 0, 0, 3);
    Ubiquitty::Linux::RasterContext first;
    Ubiquitty::Linux::RasterContext second;
    const std::uint32_t firstPreedit[] = { 0x732b };
    const std::uint32_t secondPreedit[] = { 'Q' };
    first.setPreedit(firstPreedit, 1);
    second.setPreedit(secondPreedit, 1);
    Ubiquitty::Rendering::BeamGeometry palette;
    palette.canvas.resizeAndBlank(1, 1);
    palette.canvas.cells[0].codePoint = 'B';
    palette.originRow = 2;
    first.setBeamChrome(&palette);
    Ubiquitty::Rendering::HintToastGeometry hint;
    hint.canvas.resizeAndBlank(1, 1);
    hint.canvas.cells[0].codePoint = 'H';
    hint.originRow = 2;
    hint.originColumn = 2;
    second.setHintChrome(&hint);

    std::vector<Ubiquitty::Cell> firstGrid;
    std::vector<Ubiquitty::Cell> secondGrid;
    first.snapshotVisibleGrid(terminal.get(), 0, firstGrid);
    second.snapshotVisibleGrid(terminal.get(), 0, secondGrid);
    REQUIRE(firstGrid.size() == 24 && secondGrid.size() == 24);
    CHECK(firstGrid[3].codePoint == 0x732b);
    CHECK(secondGrid[3].codePoint == 'Q');
    CHECK(firstGrid[16].codePoint == 'B');
    CHECK(secondGrid[18].codePoint == 'H');
    CHECK(firstGrid[18].codePoint != 'H');
    CHECK(secondGrid[16].codePoint != 'B');
    CHECK(Ubiquitty::Screen::visibleCell(terminal.get(), 0, 0, 3)->codePoint == original.codePoint);
    CHECK(first.snapshotCompositesOverlay() && second.snapshotCompositesOverlay());
    first.setPreedit(nullptr, 0);
    first.setBeamChrome(nullptr);
    CHECK(!first.snapshotCompositesOverlay());
    CHECK(second.snapshotCompositesOverlay());
    first.snapshotVisibleGrid(terminal.get(), 0, firstGrid);
    second.snapshotVisibleGrid(terminal.get(), 0, secondGrid);
    CHECK(firstGrid[3].codePoint == original.codePoint);
    CHECK(secondGrid[3].codePoint == 'Q');
    CHECK(secondGrid[18].codePoint == 'H');
}

TEST(resetAndAlternatingCPUFramesStayInsideTheirLinuxRasterContext)
{
    MetricsRasterizer firstFace(7, 13);
    MetricsRasterizer secondFace(11, 19);
    MetricsRasterizer replacementFace(9, 15);
    Ubiquitty::Linux::RasterContext first;
    Ubiquitty::Linux::RasterContext second;
    first.setGlyphRasterizer(firstFace);
    second.setGlyphRasterizer(secondFace);
    auto terminal = passiveTerminal();
    Ubiquitty::processBytes(terminal.get(), "\033[?25l");
    std::vector<std::uint8_t> firstPixels;
    std::vector<std::uint8_t> secondPixels;
    int firstWidth = 0;
    int firstHeight = 0;
    int secondWidth = 0;
    int secondHeight = 0;
    REQUIRE(first.rasterizeTerm(terminal.get(), firstPixels, firstWidth, firstHeight));
    REQUIRE(second.rasterizeTerm(terminal.get(), secondPixels, secondWidth, secondHeight));
    CHECK(firstWidth == 56 && firstHeight == 39);
    CHECK(secondWidth == 88 && secondHeight == 57);
    CHECK(!firstPixels.empty() && !secondPixels.empty());
    const auto stableSecondPixels = secondPixels;
    const unsigned secondPaints = secondFace.paints;
    CHECK(firstFace.paints && secondPaints);

    first.resetSoftwareRenderer();
    first.setGlyphRasterizer(replacementFace);
    REQUIRE(first.rasterizeTerm(terminal.get(), firstPixels, firstWidth, firstHeight));
    CHECK(firstWidth == 72 && firstHeight == 45);
    CHECK(replacementFace.paints > 0);
    CHECK(secondFace.paints == secondPaints);
    REQUIRE(second.rasterizeTerm(terminal.get(), secondPixels, secondWidth, secondHeight));
    CHECK(secondWidth == 88 && secondHeight == 57);
    CHECK(secondPixels == stableSecondPixels);
    CHECK(second.cellWidth() == 11 && second.cellHeight() == 19);
}

// A Tektronix frame is the tube, not the grid the terminal left behind: the
// CPU raster composites Core's tube and beam over the whole surface, the pass
// the portable reference runs. Without it the frame showed the text grid in
// the tube's place and every Tek case on the Linux arm drew a blank page.
TEST(aTektronixFrameIsTheTubeOnTheLinuxCPURaster)
{
    MetricsRasterizer face(7, 13);
    Ubiquitty::Linux::RasterContext context;
    context.setGlyphRasterizer(face);
    auto style = context.renderConfiguration();
    style.usesCustomTekColors = true;
    style.tekBeamRGB = 0x33FF66u;
    style.tekBackgroundRGB = 0x802040u;
    context.setRenderConfiguration(style);
    auto terminal = passiveTerminal();
    std::vector<std::uint8_t> pixels;
    int width = 0;
    int height = 0;
    REQUIRE(context.rasterizeTerm(terminal.get(), pixels, width, height));
    const auto isTube = [&](int x, int y) {
        const std::size_t offset = (static_cast<std::size_t>(y) * static_cast<std::size_t>(width) + static_cast<std::size_t>(x)) * 4;
        return pixels[offset] == 0x80 && pixels[offset + 1] == 0x20 && pixels[offset + 2] == 0x40 && pixels[offset + 3] == 255;
    };
    CHECK(!isTube(width - 1, height - 1));
    Ubiquitty::processBytes(terminal.get(), "\033[?38h");
    REQUIRE(terminal->isTekModeActive);
    REQUIRE(context.rasterizeTerm(terminal.get(), pixels, width, height));
    CHECK(isTube(0, 0));
    CHECK(isTube(width - 1, height - 1));
}

UBIQUITTY_TEST_MAIN()

TEST(linuxFrameViewportPreservesInternalPaddingAndItsBackground)
{
    MetricsRasterizer face(7, 13);
    Ubiquitty::Linux::RasterContext context;
    context.setGlyphRasterizer(face);
    auto configuration = context.renderConfiguration();
    configuration.backgroundOpacity = 128.0 / 255.0;
    context.setRenderConfiguration(configuration);
    auto terminal = passiveTerminal();
    terminal->palette.defaultBackground = { 0x1212, 0x2222, 0x3333 };
    Ubiquitty::Linux::CursorOverlay cursor;
    for (const auto origin : { Ubiquitty::FloatPoint { 4, 6 }, Ubiquitty::FloatPoint { 9, 3 } }) {
        const auto geometry = context.frameCaptureGeometry(origin, { 68, 58 });
        CHECK(geometry.originInPixels.x == origin.x && geometry.originInPixels.y == origin.y);
        std::vector<std::uint8_t> pixels;
        int width = 0;
        int height = 0;
        CHECK(context.rasterizeTerm(terminal.get(), pixels, width, height, 0, nullptr, &cursor, 0, nullptr, &geometry));
        CHECK(width == 68 && height == 58);
        for (const auto corner : { Ubiquitty::IntPoint { 0, 0 }, Ubiquitty::IntPoint { 67, 0 }, Ubiquitty::IntPoint { 0, 57 }, Ubiquitty::IntPoint { 67, 57 } }) {
            const auto offset = (static_cast<std::size_t>(corner.y) * width + corner.x) * 4;
            CHECK(pixels[offset] == 0x12 && pixels[offset + 1] == 0x22 && pixels[offset + 2] == 0x33 && pixels[offset + 3] == 128);
        }
        const auto firstInk = (static_cast<std::size_t>(origin.y) * width + static_cast<std::size_t>(origin.x)) * 4;
        CHECK(pixels[firstInk] != 0x12 || pixels[firstInk + 1] != 0x22 || pixels[firstInk + 2] != 0x33);
    }
}

TEST(richLayerOcclusionUsesTheAuthoredPaddedGridOrigin)
{
    MetricsRasterizer face(7, 13);
    Ubiquitty::Linux::RasterContext context;
    context.setGlyphRasterizer(face);
    auto terminal = passiveTerminal();
    Ubiquitty::Rendering::BeamGeometry beam;
    beam.canvas.resizeAndBlank(1, 1);
    beam.originColumn = 1;
    beam.originRow = 2;
    context.setBeamChrome(&beam);
    Ubiquitty::Rendering::HintToastGeometry hint;
    hint.canvas.resizeAndBlank(1, 1);
    hint.originColumn = 3;
    hint.originRow = 1;
    context.setHintChrome(&hint);
    const std::uint32_t preedit[] = { 0x732b };
    context.setPreedit(preedit, 1);
    const auto regions = context.snapshotOverlayRegions(*terminal, 0, { 11, 17 });
    REQUIRE(regions.size() == 3);
    CHECK(regions[0].origin.x == 18 && regions[0].origin.y == 43);
    CHECK(regions[1].origin.x == 32 && regions[1].origin.y == 30);
    CHECK(regions[2].origin.x == 32 && regions[2].origin.y == 17);
    CHECK(regions[0].size.width == 7 && regions[0].size.height == 13);
    CHECK(regions[2].size.width == 14 && regions[2].size.height == 13);
    const auto otherPane = context.snapshotOverlayRegions(*terminal, 0, { 5, 3 });
    REQUIRE(otherPane.size() == 3);
    CHECK(otherPane[0].origin.x == 12 && otherPane[0].origin.y == 29);
    CHECK(otherPane[2].origin.x == 26 && otherPane[2].origin.y == 3);
    const auto legacy = context.snapshotOverlayRegions(*terminal, 0);
    REQUIRE(legacy.size() == 3);
    CHECK(legacy[2].origin.x == 21 && legacy[2].origin.y == 0);
}
