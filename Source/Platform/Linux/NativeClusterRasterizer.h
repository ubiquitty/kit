// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Rendering/GlyphKey.h"

#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <string_view>

struct FT_FaceRec_;

namespace Ubiquitty::Linux {

/// An already routed native face. Its current size and variation coordinates
/// are borrowed; native drawing opens the exact source independently.
struct NativeClusterFont {
    FT_FaceRec_* face { nullptr };
    std::string file;
    Rendering::FontFace style { Rendering::FontFace::Regular };
    double emSize { 0 };
    double horizontalScale { 1 };
};

/// A glyph's ink rectangle in device pixels relative to its baseline pen.
struct NativeGlyphBounds {
    double left { 0 };
    double top { 0 };
    double width { 0 };
    double height { 0 };
};

/// A face-local glyph identity and its baseline pen in device pixels.
struct NativePositionedGlyph {
    std::uint32_t glyph { 0 };
    double x { 0 };
    double y { 0 };
};

/// Native itemization and grayscale coverage for a bounded terminal cluster.
/// Core chooses each fallback run's face and size; Pango owns mark positioning.
class NativeClusterRasterizer {
public:
    /// Resolves a complete fallback run to Core-selected native font facts.
    using ResolveRun = NativeClusterFont (*)(void*, std::span<const std::uint32_t>, Rendering::FontFace);

    /// Creates drawing state that opens exact-source fonts on first use.
    NativeClusterRasterizer();
    /// Releases the owned native fonts, layout state, and drawing surfaces.
    ~NativeClusterRasterizer();

    /// Measures one glyph with the font's exact device matrix.
    ///
    /// Borrows the routed face during the call; cached native fonts own their
    /// independent references to the exact source file.
    /// - Parameters:
    ///   - font: The selected source, style, em size, and horizontal scale.
    ///   - glyph: The face-local glyph identity.
    ///   - bounds: Receives baseline-relative ink bounds in device pixels.
    /// - Returns: True when the native font supplied valid bounds.
    bool glyphBounds(const NativeClusterFont& font, std::uint32_t glyph, NativeGlyphBounds& bounds);

    /// Draws exact-source native masks with an unrounded device font matrix.
    ///
    /// - Parameters:
    ///   - glyphs: Face-local glyphs with their device-pixel baseline pens.
    ///   - font: The borrowed routed face and exact-source drawing facts.
    ///   - width: The coverage plane's width in device pixels.
    ///   - height: The coverage plane's height in device pixels.
    ///   - coverage: Caller-owned storage for exactly `width * height` R8 bytes.
    /// - Returns: True when the native draw filled the coverage plane.
    bool drawGlyphs(std::span<const NativePositionedGlyph> glyphs, const NativeClusterFont& font,
        int width, int height, std::span<std::uint8_t> coverage);

    /// Draws at the shared terminal pen, preserving Core's existing slot bound.
    /// The callback receives complete native fallback runs, never reordered text.
    ///
    /// The faces and callback context are borrowed for the duration of the
    /// call. Native drawing retains independent references to cached fonts.
    /// - Parameters:
    ///   - codePoints: The bounded complete cluster in logical text order.
    ///   - base: The selected primary base font and exact-source drawing facts.
    ///   - resolve: Resolves each fallback run using Core's font policy.
    ///   - context: The borrowed context passed to `resolve`.
    ///   - features: The font feature settings applied to native shaping.
    ///   - penX: The cluster's baseline pen in device-pixel columns.
    ///   - baseline: The primary baseline in device-pixel rows from the top.
    ///   - width: The coverage plane's width in device pixels.
    ///   - height: The coverage plane's height in device pixels.
    ///   - coverage: Caller-owned storage for exactly `width * height` R8 bytes.
    /// - Returns: True when native positioning and drawing filled the plane.
    bool draw(std::span<const std::uint32_t> codePoints, const NativeClusterFont& base,
        ResolveRun resolve, void* context, std::string_view features, double penX, double baseline,
        int width, int height, std::span<std::uint8_t> coverage);

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace Ubiquitty::Linux
