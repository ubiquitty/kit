// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

#include "Platform/Linux/FontInventory.h"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_MULTIPLE_MASTERS_H
#include <hb-ft.h>

using namespace Ubiquitty::Rendering::Font;

// Test-only seam: rememberFace is private. A last-resort family must set the
// isLastResort flag; a use-after-move (moving `family` before the
// containsLastResort read) silently drops it and reaccepts tofu — caught below.

namespace Ubiquitty::Linux {
struct LinuxFontInventoryTestSeam {
    static FontHandle rememberLastResort(LinuxFontInventory& inventory)
    {
        // A null face is safe: the destructor skips FT_Done_Face on a null face,
        // and isLastResort reads only the stored bool.
        return inventory.rememberFace(nullptr, std::string("Last Resort"), std::string("LastResort-Regular"));
    }

    /// The faces the inventory has opened, each one a FreeType open it paid
    /// for and keeps resident.
    static std::size_t openFaceCount(const LinuxFontInventory& inventory) { return inventory.m_faces.size(); }
    static hb_font_t* cachedProbe(LinuxFontInventory& inventory, FontHandle handle) { return inventory.recordFor(handle)->probeFont.get(); }
    static hb_buffer_t* cachedBuffer(LinuxFontInventory& inventory) { return inventory.m_probeBuffer.get(); }
};
} // namespace Ubiquitty::Linux

namespace {

/// Registers the shipped font directory with fontconfig, so the cascade's
/// answers come from faces every host has rather than from what one machine
/// happens to install.
///
/// - Returns: True when fontconfig took the directory.
bool registerBundledFonts()
{
    if (FcInit() != FcTrue)
        return false;
    return FcConfigAppFontAddDir(FcConfigGetCurrent(), reinterpret_cast<const FcChar8*>(UBQ_BUNDLED_FONTS_DIR)) == FcTrue;
}

} // namespace

TEST(linuxFontinventory)
{

    Ubiquitty::Linux::LinuxFontInventory inventory(16);
    FontHandle primary = inventory.primaryFont(FontStyle::Regular, 0);
    CHECK(primary.isValid());

    const std::string_view primaryFamily = inventory.familyName(primary);
    CHECK(!primaryFamily.empty());
    FontHandle exact = inventory.validateFamily({ primaryFamily, FontStyle::Regular, 0 });
    CHECK(exact.isValid());

    std::uint32_t ascii = 'A';
    GlyphProbeResult asciiGlyph = inventory.glyphForCodePoint(primary, ascii);
    CHECK(asciiGlyph.present || !asciiGlyph.lastResort);

    std::uint32_t han = 0x6771;
    CascadeRequest hanRequest;
    hanRequest.baseFont = primary;
    hanRequest.codePoints = { &han, 1 };
    hanRequest.language = { "ja" };
    CascadeResult hanCascade = inventory.cascadeForCodePoint(hanRequest);
    CHECK(!hanCascade.present || hanCascade.font.isValid());

    std::uint32_t arabicRun[] { 0x0633, 0x0644 };
    CascadeRequest runRequest;
    runRequest.baseFont = primary;
    runRequest.codePoints = arabicRun;
    CascadeResult runCascade = inventory.cascadeForRun(runRequest);
    CHECK(!runCascade.present || runCascade.font.isValid());

    inventory.bumpCatalogGeneration();
    CHECK(inventory.catalogGeneration() == 2);

    // A last-resort family must flag isLastResort — guards the rememberFace
    // assignment order. A use-after-move on `family` (moving it before the
    // containsLastResort read) drops the flag and reaccepts tofu; this fails
    // without the read-before-move fix.
    FontHandle lastResort = Ubiquitty::Linux::LinuxFontInventoryTestSeam::rememberLastResort(inventory);
    CHECK(lastResort.isValid());
    CHECK(inventory.isLastResort(lastResort));
}

TEST(aShippedFamilyOpensTheFileThisProjectShips)
{
    // The inventory routes a code point to a family and opens it. A family this
    // project ships must come from the file it ships: the copy a machine has
    // installed carries the same family name and is a different build, so which
    // of the two is open decides what every cell routed here draws, and a
    // golden two machines share records whichever of them minted it.
    const std::string directory(UBQ_BUNDLED_FONTS_DIR);
    Ubiquitty::Linux::LinuxFontInventory inventory(16, std::string(), directory);

    Ubiquitty::Rendering::Font::FontFamilyRequest request;
    request.family = "Monaspace Neon";
    const Ubiquitty::Rendering::Font::FontHandle shipped = inventory.validateFamily(request);
    CHECK_MSG(shipped.isValid(), "a family this project ships resolves");
    CHECK_MSG(inventory.bundledSourceFor(shipped) == directory + "/MonaspaceNeon-Regular.otf",
        "and opens the file beside the binary rather than fontconfig's answer");

    // The control. A family the bundle table does not carry has no shipped file
    // to prefer, so it reaches fontconfig and records no bundled source —
    // without which "every family reports one" would pass for "the table was
    // read". Whether fontconfig resolves it at all is the host's business; the
    // claim here is only that this route is not the bundle's.
    Ubiquitty::Rendering::Font::FontFamilyRequest installed;
    installed.family = "DejaVu Sans Mono";
    const Ubiquitty::Rendering::Font::FontHandle other = inventory.validateFamily(installed);
    CHECK_MSG(inventory.bundledSourceFor(other).empty(),
        "a family the table does not name is not opened from the bundle");
}

TEST(loadedFacesKeepTheirIdentityAcrossRepeatedFamilyRequests)
{
    Ubiquitty::Linux::LinuxFontInventory inventory(20, {}, UBQ_BUNDLED_FONTS_DIR);
    const FontFamilyRequest regular { "Monaspace Neon", FontStyle::Regular, 0 };
    const FontHandle first = inventory.validateFamily(regular);
    CHECK(first.isValid());
    for (int request = 0; request < 100; ++request) {
        CHECK(inventory.validateFamily(regular) == first);
    }
    const FontHandle bold = inventory.validateFamily({ "Monaspace Neon", FontStyle::Bold, 0 });
    CHECK(bold.isValid());
    CHECK(bold != first);
    CHECK(inventory.faceFor(bold) != inventory.faceFor(first));
    CHECK(inventory.bundledSourceFor(bold).find("Bold") != std::string_view::npos);
}

TEST(aClusterProbeRequiresTheWholeClusterInTheSelectedFace)
{
    Ubiquitty::Linux::LinuxFontInventory inventory(20, {}, UBQ_BUNDLED_FONTS_DIR);
    const FontHandle text = inventory.validateFamily({ "Monaspace Neon", FontStyle::Regular, 0 });
    const std::array<std::uint32_t, 2> combining { 'e', 0x0301 };
    CHECK(inventory.glyphForCluster(text, combining, Presentation::Text).present);
    const std::array<std::uint32_t, 2> absent { 'A', 0x10FFFF };
    CHECK(!inventory.glyphForCluster(text, absent, Presentation::Text).present);
    const FontHandle emoji = inventory.validateFamily({ "Noto Color Emoji", FontStyle::Regular, 0 });
    CHECK(emoji.isValid());
    const std::array<std::uint32_t, 3> joined { 0x1F469, 0x200D, 0x1F4BB };
    CHECK(inventory.glyphForCluster(emoji, joined, Presentation::Emoji).present);
    CHECK(!inventory.glyphForCluster(emoji, joined, Presentation::Text).present);
    const std::array<std::uint32_t, 2> emojiHeart { 0x2764, 0xFE0F };
    CHECK(inventory.glyphForCluster(emoji, emojiHeart, Presentation::Emoji).present);
    const std::array<std::uint32_t, 3> unjoined { 0x1F469, 0x200D, 'A' };
    CHECK(!inventory.glyphForCluster(emoji, unjoined, Presentation::Emoji).present);
    const std::array<std::uint32_t, 7> tagged { 0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F };
    CHECK(inventory.glyphForCluster(emoji, tagged, Presentation::Emoji).present);
    const GlyphProbeResult taggedGlyph = inventory.glyphForCluster(emoji, tagged, Presentation::Emoji);
    CHECK(taggedGlyph.glyph.value != inventory.glyphForCodePoint(emoji, tagged.front()).glyph.value);
}

TEST(aColdCascadeHonorsClusterPresentationAndBundledSymbols)
{
    Ubiquitty::Linux::LinuxFontInventory inventory(20, {}, UBQ_BUNDLED_FONTS_DIR);
    const std::array<std::uint32_t, 3> joined { 0x1F469, 0x200D, 0x1F4BB };
    CascadeRequest request;
    request.codePoints = joined;
    request.presentation = Presentation::Emoji;
    const CascadeResult emoji = inventory.cascadeForRun(request);
    CHECK(emoji.present);
    CHECK(inventory.bundledSourceFor(emoji.font).find("NotoColorEmoji") != std::string_view::npos);
    CHECK(inventory.cascadeForRun(request).font == emoji.font);
    const FontHandle symbols = inventory.validateFamily({ "Symbols Nerd Font Mono", FontStyle::Regular, 0 });
    CHECK(inventory.glyphForCodePoint(symbols, 0xF120).present);
    CHECK(inventory.bundledSourceFor(symbols).find("SymbolsNerdFontMono-Regular.ttf") != std::string_view::npos);
}

TEST(theConfiguredPrimaryKeepsItsSizeAndSurvivesItsCallersReference)
{
    FT_Library library = nullptr;
    CHECK(FT_Init_FreeType(&library) == 0);
    FT_Face primary = nullptr;
    const std::string path = std::string(UBQ_BUNDLED_FONTS_DIR) + "/MonaspaceNeon-Regular.otf";
    CHECK(FT_New_Face(library, path.c_str(), 0, &primary) == 0);
    CHECK(FT_Set_Pixel_Sizes(primary, 0, 27) == 0);
    {
        Ubiquitty::Linux::LinuxFontInventory inventory(16, {}, UBQ_BUNDLED_FONTS_DIR);
        inventory.setPrimaryFaces(primary, nullptr);
        const FontHandle handle = inventory.primaryFont(FontStyle::Regular, 0);
        CHECK(inventory.faceFor(handle) == primary);
        CHECK_EQ(primary->size->metrics.y_ppem, 27);
        FT_Done_Face(primary);
        CHECK(inventory.glyphForCodePoint(handle, 'A').present);
        CHECK_EQ(inventory.faceFor(handle)->size->metrics.y_ppem, 27);
    }
    FT_Done_FreeType(library);
}

TEST(theCascadeAnswersTextAndEmojiPresentationFromDifferentFaces)
{
    CHECK_MSG(registerBundledFonts(), "the shipped fonts are registered with fontconfig as the cascade's fixture");
    Ubiquitty::Linux::LinuxFontInventory inventory(16, "JetBrains Mono", UBQ_BUNDLED_FONTS_DIR);
    const FontHandle primary = inventory.primaryFont(FontStyle::Regular, 0);

    // U+263A is in the shipped colour emoji face and in the shipped Monaspace
    // Neon, so both answers exist on every host. A text request is answered by
    // a text face, an emoji request by the colour face, and the two are never
    // the same face.
    const std::array<std::uint32_t, 1> smiley { 0x263A };
    CascadeRequest text;
    text.baseFont = primary;
    text.codePoints = smiley;
    text.presentation = Presentation::Text;
    const CascadeResult textAnswer = inventory.cascadeForCodePoint(text);
    CascadeRequest emoji = text;
    emoji.presentation = Presentation::Emoji;
    const CascadeResult emojiAnswer = inventory.cascadeForCodePoint(emoji);
    CHECK_MSG(textAnswer.present, "a text request finds a text face that carries U+263A");
    CHECK_MSG(emojiAnswer.present, "an emoji request finds the colour face that carries U+263A");
    CHECK_MSG(textAnswer.font != emojiAnswer.font, "text and emoji presentation resolve to different faces");
    CHECK_MSG(inventory.familyName(textAnswer.font).find("Emoji") == std::string_view::npos,
        "a text request is not handed the emoji face");
}

TEST(theCascadeOpensOnlyAFaceThatCarriesTheCharacter)
{
    // The cascade runs on every fallback miss, over every installed face
    // fontconfig ranks. Opening a candidate to ask its cmap would make a
    // character no face carries open the whole list, and keep it open.
    CHECK_MSG(registerBundledFonts(), "the shipped fonts are registered with fontconfig as the cascade's fixture");
    Ubiquitty::Linux::LinuxFontInventory inventory(16, "JetBrains Mono", UBQ_BUNDLED_FONTS_DIR);
    const FontHandle primary = inventory.primaryFont(FontStyle::Regular, 0);
    CHECK(primary.isValid());
    const std::size_t afterPrimary = Ubiquitty::Linux::LinuxFontInventoryTestSeam::openFaceCount(inventory);

    // U+0378 is unassigned: every candidate lacks it.
    const std::array<std::uint32_t, 1> unassigned { 0x0378 };
    CascadeRequest missing;
    missing.baseFont = primary;
    missing.codePoints = unassigned;
    missing.presentation = Presentation::Text;
    CHECK_MSG(!inventory.cascadeForCodePoint(missing).present, "no face carries an unassigned code point");
    CHECK_MSG(Ubiquitty::Linux::LinuxFontInventoryTestSeam::openFaceCount(inventory) == afterPrimary,
        "and answering that opened no face");

    // The control: a character a registered face carries opens that face and
    // no other, so the count above stays still because nothing qualified and
    // not because the cascade never looked.
    const std::array<std::uint32_t, 1> turnedA { 0x0250 };
    CascadeRequest found = missing;
    found.codePoints = turnedA;
    CHECK_MSG(inventory.cascadeForCodePoint(found).present, "a shipped face carries U+0250");
    CHECK_MSG(Ubiquitty::Linux::LinuxFontInventoryTestSeam::openFaceCount(inventory) == afterPrimary + 1,
        "and the cascade opened exactly the face that answered");
}

TEST(nativeFallbackFontsMatchTextSizeAndCanKeepNominalSize)
{
    CHECK(registerBundledFonts());
    using Ubiquitty::Rendering::FontMetrics::FallbackSizing;
    const auto xHeight = [](FT_Face face) {
        const FT_UInt glyph = FT_Get_Char_Index(face, U'x');
        if (!glyph || FT_Load_Glyph(face, glyph, FT_LOAD_NO_HINTING) != 0)
            return 0.0;
        return static_cast<double>(face->glyph->metrics.height) / 64.0;
    };
    for (const auto sizing : { FallbackSizing::MatchPrimary, FallbackSizing::Nominal }) {
        Ubiquitty::Linux::LinuxFontInventory inventory(26, "JetBrains Mono", UBQ_BUNDLED_FONTS_DIR, sizing);
        const FontHandle primary = inventory.primaryFont(FontStyle::Regular, 0);
        REQUIRE(primary.isValid());
        // The bundled Noto Sans supplies turned a, which JetBrains Mono lacks.
        const std::array<std::uint32_t, 1> text { 0x0250 };
        CascadeRequest request;
        request.baseFont = primary;
        request.codePoints = text;
        request.presentation = Presentation::Text;
        const auto answer = inventory.cascadeForCodePoint(request);
        REQUIRE(answer.present);
        FT_Face fallback = inventory.faceFor(answer.font);
        REQUIRE(fallback);
        if (sizing == FallbackSizing::MatchPrimary)
            CHECK(std::abs(xHeight(inventory.faceFor(primary)) - xHeight(fallback)) < 0.1);
        else
            CHECK(fallback->size->metrics.y_ppem == 26);
        CHECK(inventory.cascadeForCodePoint(request).font == answer.font);
    }
}

TEST(namedFallbackSizeOverridesDoNotAliasCachedFaces)
{
    using Ubiquitty::Rendering::FontMetrics::FallbackSizing;
    Ubiquitty::Linux::LinuxFontInventory inventory(26, "JetBrains Mono", UBQ_BUNDLED_FONTS_DIR, FallbackSizing::Nominal);
    const FontHandle primary = inventory.primaryFont(FontStyle::Regular, 0);
    REQUIRE(primary.isValid());
    FontFamilyRequest request;
    request.family = "Noto Sans";
    request.sizingBase = primary;
    request.sizing = FallbackSizing::MatchPrimary;
    const FontHandle matched = inventory.validateFamily(request);
    REQUIRE(matched.isValid());
    const auto matchedHeight = inventory.faceFor(matched)->size->metrics.y_scale;
    request.sizing = FallbackSizing::Nominal;
    const FontHandle nominal = inventory.validateFamily(request);
    REQUIRE(nominal.isValid());
    CHECK(matched != nominal);
    CHECK(matchedHeight != inventory.faceFor(nominal)->size->metrics.y_scale);
    CHECK(inventory.faceFor(nominal)->size->metrics.y_ppem == 26);
    request.sizing = FallbackSizing::MatchPrimary;
    CHECK(inventory.validateFamily(request) == matched);
    CHECK(inventory.faceFor(matched)->size->metrics.y_scale == matchedHeight);
}

TEST(coverageProbeReusesNativeShapersAndTracksBorrowedFaceChanges)
{
    CHECK(registerBundledFonts());
    FT_Library library = nullptr;
    CHECK(FT_Init_FreeType(&library) == 0);
    FT_Face face = nullptr;
    const std::string file = std::string(UBQ_BUNDLED_FONTS_DIR) + "/JetBrainsMono[wght].ttf";
    CHECK(FT_New_Face(library, file.c_str(), 0, &face) == 0);
    CHECK(FT_Set_Pixel_Sizes(face, 0, 18) == 0);
    {
        Ubiquitty::Linux::LinuxFontInventory inventory(18, "JetBrains Mono", UBQ_BUNDLED_FONTS_DIR);
        inventory.setPrimaryFaces(face, nullptr);
        const auto handle = inventory.primaryFont(FontStyle::Regular, 0);
        bool didShapeMissingCanonical = false;
        for (std::uint32_t character : { 0x0340U, 0x0341U, 0x0343U, 0x0344U, 0x2126U, 0x212AU, 0x212BU }) {
            if (FT_Get_Char_Index(face, character) == 0) {
                const std::array<std::uint32_t, 1> points { character };
                if (inventory.glyphForCluster(handle, points, Presentation::Text).present)
                    didShapeMissingCanonical = true;
            }
        }
        CHECK_MSG(didShapeMissingCanonical, "HarfBuzz canonical decomposition covers a character absent from the face's cmap");

        using Seam = Ubiquitty::Linux::LinuxFontInventoryTestSeam;
        const std::array<std::uint32_t, 3> marked { 'a', 0x0301, 0x0308 };
        CHECK(inventory.glyphForCluster(handle, marked, Presentation::Text).present);
        auto* cached = Seam::cachedProbe(inventory, handle);
        auto* buffer = Seam::cachedBuffer(inventory);
        const auto serial = hb_font_get_serial(cached);
        CHECK(inventory.glyphForCluster(handle, marked, Presentation::Text).present);
        CHECK(Seam::cachedProbe(inventory, handle) == cached);
        CHECK(Seam::cachedBuffer(inventory) == buffer);
        CHECK_MSG(hb_font_get_serial(cached) == serial, "an unchanged native face keeps its shaper caches");
        FT_MM_Var* axes = nullptr;
        CHECK(FT_Get_MM_Var(face, &axes) == 0);
        std::vector<FT_Fixed> coordinates(axes->num_axis);
        for (int size : { 12, 27, 18 }) {
            CHECK(FT_Set_Char_Size(face, 0, size * 64 + 16, 72, 72) == 0);
            for (unsigned index = 0; index < axes->num_axis; ++index)
                coordinates[index] = axes->axis[index].tag == FT_MAKE_TAG('w', 'g', 'h', 't') ? axes->axis[index].maximum : axes->axis[index].def;
            CHECK(FT_Set_Var_Design_Coordinates(face, axes->num_axis, coordinates.data()) == 0);
            const auto actual = inventory.glyphForCluster(handle, marked, Presentation::Text);
            CHECK(actual.present);
            CHECK(Seam::cachedProbe(inventory, handle) == cached);
            CHECK(hb_font_get_serial(cached) != serial);
            hb_font_t* fresh = hb_ft_font_create_referenced(face);
            int cachedX = 0, cachedY = 0, freshX = 0, freshY = 0;
            hb_font_get_scale(cached, &cachedX, &cachedY);
            hb_font_get_scale(fresh, &freshX, &freshY);
            CHECK(cachedX == freshX && cachedY == freshY);
            const auto glyph = FT_Get_Char_Index(face, 'M');
            CHECK(hb_font_get_glyph_h_advance(cached, glyph) == hb_font_get_glyph_h_advance(fresh, glyph));
            hb_buffer_t* reference = hb_buffer_create();
            for (unsigned index = 0; index < marked.size(); ++index)
                hb_buffer_add(reference, marked[index], index);
            hb_buffer_set_content_type(reference, HB_BUFFER_CONTENT_TYPE_UNICODE);
            hb_buffer_set_flags(reference, HB_BUFFER_FLAG_PRESERVE_DEFAULT_IGNORABLES);
            hb_buffer_guess_segment_properties(reference);
            hb_shape(fresh, reference, nullptr, 0);
            unsigned count = 0;
            const auto* glyphs = hb_buffer_get_glyph_infos(reference, &count);
            CHECK(count > 0 && actual.glyph.value == static_cast<const hb_glyph_info_t&>(glyphs[0]).codepoint);
            hb_buffer_destroy(reference);
            hb_font_destroy(fresh);
            const std::array<std::uint32_t, 1> missing { 0x10FFFF };
            CHECK(!inventory.glyphForCluster(handle, missing, Presentation::Text).present);
            CHECK(inventory.glyphForCluster(handle, marked, Presentation::Text).present);
        }
        FT_Done_MM_Var(library, axes);
    }
    // Inventory released its retained references before the external owner.
    CHECK(FT_Load_Char(face, 'M', FT_LOAD_DEFAULT) == 0);
    FT_Done_Face(face);
    FT_Done_FreeType(library);
}

UBIQUITTY_TEST_MAIN()
