// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Core/Preferences/FontRoutePreferences.h"
#include "Core/Rendering/AtlasConfiguration.h"
#include "Core/Rendering/FontFeatureSpecification.h"
#include "Core/Rendering/FontSelection.h"

#include <memory>
#include <string>

namespace Ubiquitty::Rendering {
struct GlyphRasterizer;
}

namespace Ubiquitty::Linux {
class FreeTypeRasterizer;

/// Immutable construction inputs; all raster-affecting preferences are keyed
/// by Core, including font resources and the full ordered fallback rules.
struct SharedFontRequest {
    double pixelSize = 16;
    double pointSize = 12;
    double pixelsPerPoint = 1;
    int deviceScale = 1;
    int lineSpacing = 0;
    int tracking = 0;
    int uprightWeight = 0;
    int boldWeight = 0;
    double widthPercent = 0;
    int bitmapScale = 1;
    std::uint64_t catalogGeneration = 0;
    std::string family;
    std::string fallbackFamily;
    std::string fallbackPath;
    std::string primaryPath;
    std::string variations;
    std::string features;
    Rendering::Ligatures ligatures { Rendering::Ligatures::Enabled };
    Preferences::Values preferences;
};

/// Process-shared native faces and immutable procedural decorators.
/// Raster calls remain on the presentation thread; registry lookup/build/prune
/// is atomic, and leases keep every borrowed face alive across window closure.
class SharedFontResources : public std::enable_shared_from_this<SharedFontResources> {
public:
    /// Releases the faces and decorators after their final shared owner dies.
    ~SharedFontResources();
    /// Acquires compatible native faces and decorators from the weak registry.
    ///
    /// - Parameter request: The complete raster-affecting font configuration.
    /// - Returns: A shared owner whose faces remain alive through derived leases.
    [[nodiscard]] static std::shared_ptr<SharedFontResources> acquire(SharedFontRequest request);
    /// Returns the native face used for shaping and font metrics.
    ///
    /// - Returns: A strong reference to the configured FreeType provider.
    [[nodiscard]] std::shared_ptr<FreeTypeRasterizer> nativeFace() const;
    /// Selects a procedural decorator while retaining its borrowed inner face.
    ///
    /// - Parameter rasterizerKind: The native or embedded bitmap provider to select.
    /// - Returns: An aliasing lease that retains the entire font owner.
    [[nodiscard]] std::shared_ptr<Rendering::GlyphRasterizer> rasterizer(Rendering::FontRasterizerKind rasterizerKind) const;
    /// Returns the immutable cache identity for the selected provider.
    ///
    /// - Parameter rasterizerKind: The native or embedded bitmap provider to select.
    /// - Returns: The resource facts that distinguish compatible atlas contents.
    [[nodiscard]] std::shared_ptr<const Rendering::AtlasConfiguration> configuration(Rendering::FontRasterizerKind rasterizerKind) const;

private:
    struct Impl;
    /// Adopts the completed font inventory and its procedural decorators.
    ///
    /// - Parameter implementation: The exclusively owned font state.
    explicit SharedFontResources(std::unique_ptr<Impl>);
    std::unique_ptr<Impl> m_impl;
};

} // namespace Ubiquitty::Linux
