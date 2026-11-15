// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Rendering/Font/FontInventory.h"
#include "Core/Rendering/FontMetrics.h"

#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

struct FT_FaceRec_;
struct FT_LibraryRec_;

struct hb_font_t;
struct hb_buffer_t;

namespace Ubiquitty::Linux {

class LinuxFontInventory : public Rendering::Font::FontInventory {
public:
    /// Builds an inventory over one pixel size.
    ///
    /// - Parameter fontPixelSize: The size every face is opened at.
    /// - Parameter primaryFamily: The configured family, or empty for the
    ///   platform's monospace.
    /// - Parameter bundledFontDirectory: Where this binary's shipped faces
    ///   were staged; empty derives it from the executable's own path. Named so
    ///   a test can point it at the repository's fonts with no staged binary.
    explicit LinuxFontInventory(double fontPixelSize, std::string primaryFamily = std::string(),
        std::string bundledFontDirectory = std::string(), Rendering::FontMetrics::FallbackSizing = Rendering::FontMetrics::FallbackSizing::MatchPrimary);
    ~LinuxFontInventory() override;

    [[nodiscard]] std::uint32_t catalogGeneration() const override { return m_generation; }
    void bumpCatalogGeneration() override { ++m_generation; }

    Rendering::Font::FontHandle primaryFont(Rendering::Font::FontStyle, std::uint8_t variableWeight) override;
    Rendering::Font::FontHandle validateFamily(const Rendering::Font::FontFamilyRequest&) override;
    Rendering::Font::GlyphProbeResult glyphForCodePoint(Rendering::Font::FontHandle, std::uint32_t codePoint) override;
    /// Proves complete same-face cluster coverage and the requested presentation.
    ///
    /// - Parameters:
    ///   - font: The face to probe without native substitution.
    ///   - codePoints: The complete grapheme cluster.
    ///   - presentation: Whether the result must draw as text or color.
    /// - Returns: A present glyph only when the complete request can be drawn.
    Rendering::Font::GlyphProbeResult glyphForCluster(Rendering::Font::FontHandle font, std::span<const std::uint32_t> codePoints, Rendering::Font::Presentation presentation) override;
    Rendering::Font::CascadeResult cascadeForCodePoint(const Rendering::Font::CascadeRequest&) override;
    Rendering::Font::CascadeResult cascadeForRun(const Rendering::Font::CascadeRequest&) override;
    [[nodiscard]] bool isLastResort(Rendering::Font::FontHandle) const override;
    [[nodiscard]] std::string_view familyName(Rendering::Font::FontHandle) const override;
    [[nodiscard]] std::string_view postScriptName(Rendering::Font::FontHandle) const override;

    /// The bundled file a handle was opened from, or empty for one fontconfig
    /// answered.
    ///
    /// A family name cannot tell the two apart: the file this project ships and
    /// a copy a machine has installed carry the same family, and which of them
    /// is open decides what every cell routed to that family draws.
    ///
    /// - Parameter handle: A handle this inventory returned.
    /// - Returns: The path, or an empty view.
    [[nodiscard]] std::string_view bundledSourceFor(Rendering::Font::FontHandle) const;

    /// Retains the rasterizer's configured primary faces without changing their axes or size.
    ///
    /// The rasterizer releases this inventory before its FreeType library.
    /// - Parameters:
    ///   - regular: The primary face, or null when it failed to load.
    ///   - bold: Its static bold member, or null when bold uses the regular face's axes.
    void setPrimaryFaces(FT_FaceRec_* regular, FT_FaceRec_* bold);

    /// Borrows the face owned by a resolved handle.
    ///
    /// A caller changing its size must restore it before another route uses it.
    /// - Parameter handle: A handle returned by this inventory.
    /// - Returns: The face, or null for an invalid handle.
    [[nodiscard]] FT_FaceRec_* faceFor(Rendering::Font::FontHandle handle) const;

    /// The exact source of an owned routed face, including system fonts.
    ///
    /// - Parameter face: A face owned by this inventory.
    /// - Returns: A path borrowed until the inventory changes, or an empty view.
    [[nodiscard]] std::string_view sourceFileFor(FT_FaceRec_* face) const;
    /// Reports the routed face's unrounded effective font size.
    ///
    /// - Parameter face: A face owned by this inventory.
    /// - Returns: Its device-pixel em, or the primary em for an unknown face.
    [[nodiscard]] double pixelSizeFor(FT_FaceRec_* face) const;

private:
    /// Identifies whether a font file comes from the application bundle or system inventory.
    enum class FontFileSource : std::uint8_t {
        Bundled,
        System
    };

    /// Releases cached HarfBuzz font references before their FreeType faces.
    struct ProbeFontDeleter {
        /// Releases one retained HarfBuzz font.
        /// - Parameter font: The owned font reference to release.
        void operator()(hb_font_t* font) const;
    };
    /// Releases the reusable buffer owned by the coverage probe.
    struct ProbeBufferDeleter {
        /// Releases one retained HarfBuzz buffer.
        /// - Parameter buffer: The owned buffer reference to release.
        void operator()(hb_buffer_t* buffer) const;
    };

    struct FaceRecord {
        Rendering::Font::FontHandle handle;
        FT_FaceRec_* face { nullptr };
        std::string family;
        std::string postScriptName;
        /// The bundled file this face came from, empty when fontconfig named
        /// it. Read by the test that holds two machines to one file.
        std::string bundledSource;
        bool lastResort { false };
        std::string file {};
        int faceIndex = 0;
        Rendering::Font::FontStyle style = Rendering::Font::FontStyle::Regular;
        std::uint8_t variableWeight = 0;
        double emSize = 0;
        Rendering::Font::FontHandle sizingBase {};
        Rendering::FontMetrics::FallbackSizing sizing { Rendering::FontMetrics::FallbackSizing::Inherit };
        // The probe retains this face until explicitly destroyed before the FT
        // library. Its metrics are refreshed whenever native face state changes.
        std::unique_ptr<hb_font_t, ProbeFontDeleter> probeFont {};
        std::array<long, 10> probeNativeState {};
        unsigned probeAxisCount { 0 };
        std::vector<long> probeCoordinates {};
        std::vector<long> probeCurrentCoordinates {};
    };

    Rendering::Font::FontHandle loadFamily(const Rendering::Font::FontFamilyRequest&, bool requireExactFamily); // bool-ok: Validates the fontconfig family-match predicate.
    Rendering::Font::FontHandle loadCascade(const Rendering::Font::CascadeRequest&);
    /// Opens one file and style once, keeping handle identity stable across cache eviction.
    ///
    /// - Parameters:
    ///   - file: The resolved font file.
    ///   - faceIndex: The face or named instance within the file.
    ///   - request: The requested style and weight.
    ///   - fileSource: Whether the file belongs to the staged font bundle or the system catalogue.
    /// - Returns: The stable face handle, or an invalid handle when loading fails.
    Rendering::Font::FontHandle loadFile(std::string file, int faceIndex, const Rendering::Font::FontFamilyRequest&, FontFileSource fileSource, Rendering::Font::FontHandle sizingBase = {});
    Rendering::Font::FontHandle rememberFace(FT_FaceRec_* face, std::string family, std::string postScriptName,
        std::string bundledSource = std::string());
    /// Synchronizes a cached shaper with its face's current size and axes.
    ///
    /// - Parameter record: The inventory-owned face and cached probe state.
    /// - Returns: A font borrowed until the record or inventory is destroyed.
    hb_font_t* probeFontFor(FaceRecord& record);
    FaceRecord* recordFor(Rendering::Font::FontHandle);
    [[nodiscard]] const FaceRecord* recordFor(Rendering::Font::FontHandle) const;

    // Test-only seam: reach the private rememberFace to assert a last-resort
    // family sets the isLastResort flag (guards the assignment-order regression).
    friend struct LinuxFontInventoryTestSeam;

    FT_LibraryRec_* m_library { nullptr };
    std::unique_ptr<hb_buffer_t, ProbeBufferDeleter> m_probeBuffer {};
    double m_fontPixelSize { 16 };
    Rendering::FontMetrics::FallbackSizing m_fallbackSizing;
    std::string m_primaryFamily;
    std::string m_bundledFontDirectory;
    std::uint32_t m_generation { 1 };
    std::array<Rendering::Font::FontHandle, 4> m_primary;
    std::vector<FaceRecord> m_faces;
};

} // namespace Ubiquitty::Linux
