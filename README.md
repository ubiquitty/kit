<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# ubiquitty-kit

| You are building | Reach for | Repository |
|---|---|---|
| A terminal view to drop into a macOS or iOS app | UbiquittyKit's `TerminalSurface` (Metal) | `ubiquitty-kit` |
| A terminal view in a Linux app, or a software-rendered surface | the Vulkan, FreeType and software renderers and the GTK platform layer | `ubiquitty-kit` |
| Core's renderer drawing into a texture or layer your app owns | UbiquittyRenderKit (Metal) or the Vulkan renderer's exportable frames | `ubiquitty-kit` |
| Your own UI that draws the terminal itself: a GPU UI toolkit, a game engine, or an editor with its own text system | libubiquitty's C++ session facade and Core headers | `ubiquitty-core` |
| The same from C++, linking Core in your own CMake graph | the C++ session facade and Core's headers | `ubiquitty-core` |
| Persistent sessions, a session daemon, attach and reattach across machines | the multiplexer: `ubiquitty-host`, Sync, the `ubq` command and the agent | `ubiquitty-core` |
| The Ubiquitty apps themselves | the macOS, iOS, Linux and web frontends | `ubiquitty` |

Ubiquitty is three repositories. Each depends only on the ones below it:
`ubiquitty` → `ubiquitty-kit` → `ubiquitty-core`. This is the middle one.

## What this repository holds

**UbiquittyKit** is the terminal view for Apple platforms. `TerminalSurface`
owns a terminal session's input, selection, accessibility and presentation, and
draws it with the Metal renderer, **UbiquittyRenderKit** (Swift, with the shader
library `UBShaders.metal`). It ships as `UbiquittyKit.framework`: a consumer
imports one Swift module and needs no C++ interoperability flag, module map or
include path, because the module imports Core internally and exposes no C++
type. The static modules an application links are the same sources.

**The Linux libraries** draw the same terminal on Linux, as static libraries a
consumer links beside Core:

| Library | Holds |
|---|---|
| `UbiquittyKitVulkan` | the Vulkan renderer, its glyph and color-glyph atlases and image textures; the SPIR-V shaders it loads |
| `UbiquittyKitFreeType` | the FreeType, HarfBuzz and fontconfig glyph rasterizer, the font inventory and routing, the COLRv1 painter |
| `UbiquittyKitSoftware` | the CPU surface that renders a terminal to RGBA8 |
| `UbiquittyKitGTK` | the GDK clipboard, relative pointer lock, the AT-SPI element and the Pango rich-text shaper |
| `UbiquittyKitGTKPAL` | the GTK PAL backend, opt-in because a PAL function is defined once per executable |

The Wscons sources under `Source/Platform/Wscons` are the console renderer for
OpenBSD and NetBSD.

The kit draws what Core's render plan describes and owns native presentation
and input integration. Everything a program can observe about its terminal
stays in `ubiquitty-core`, which this repository carries as the submodule
`Libraries/ubiquitty-core`.

## Embed `TerminalSurface`

Build `UbiquittyKit.framework` (below), add it to the app and import it. This is
the whole of a host that draws a frame; `Scripts/check-ubiquittykit.sh` builds
and runs the same program against the built framework:

```swift
import UbiquittyKit

MainActor.assumeIsolated {
    guard let surface = TerminalSurface(rows: 24, columns: 80),
          let renderer = TerminalSurface.makeRenderer() else { return }
    surface.renderer = renderer
    surface.feed(Data("hello\r\n".utf8))
    let layer = CAMetalLayer()   // sized and given a device by the host
    _ = renderer.encodeFrame(for: surface, into: layer)
}
```

The API is described in [UbiquittyKit's API](Docs/ubiquittykit-api.md) and the
Swift renderer in [the Swift renderer](Docs/swift-renderer.md). An application
that compiles the kit into its own build includes
`Scripts/cmake/UbiquittyKit.cmake` at its top directory after the Core modules,
in the order `Libraries/ubiquitty-core/Scripts/cmake/UbiquittyCoreRoot.cmake`
lays out, and links the modules the file creates.

## Build

Clone with the submodule:

```sh
git clone --recurse-submodules <url> ubiquitty-kit
git submodule update --init     # in an existing clone
```

The kit builds as C++23 and Swift 6 with warnings as errors, and needs CMake
3.13 or newer, Ninja or Make, Python 3 and Bash. The first QUIC-enabled build
fetches and builds its QUIC dependencies, which needs network access, Go and
Perl; `-DUBIQUITTY_QUIC=OFF` leaves QUIC out. Build output goes outside the
checkout; `python3 Libraries/ubiquitty-core/Scripts/build_root.py .` prints its
root, and `UBQ_BUILD_ROOT` overrides it.

**macOS** needs full Xcode with the Metal toolchain:

```sh
Scripts/check-ubiquittykit.sh   # builds UbiquittyKit.framework, then draws a frame from a host outside the tree
```

**iOS** configures with an iOS toolchain, one SDK per tree:

```sh
cmake -S . -B "$BUILD" -G Ninja -DUBIQUITTY_FRONTEND=iOS -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build "$BUILD"
```

**Linux** needs GTK 4.16, Pango, FreeType, HarfBuzz, fontconfig, Vulkan and
`glslc`; `Scripts/check-linux-build-prerequisites.sh` names what is missing.
`Scripts/run-linux.sh` runs any command in the container that has them:

```sh
cmake -S . -B "$BUILD" -G Ninja -DUBIQUITTY_FRONTEND=Linux
cmake --build "$BUILD"          # the libraries, the shaders and ubiquitty-kit-linux-check
```

## Test

```sh
cmake -S . -B "$BUILD" -G Ninja -DUBIQUITTY_FRONTEND=Linux \
    -DUBIQUITTY_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug     # or macOS
cmake --build "$BUILD"
ctest --test-dir "$BUILD" --output-on-failure
```

A `test_*.cpp` file anywhere under `Tests/` is a CTest case; no list names it.
The Linux tests run on Linux and the macOS ones on a Mac. The Swift check drivers
(`Scripts/check-*.sh`) compile a renderer module with a driver of their own and
need a Mac.

Read [the architecture](Libraries/ubiquitty-core/Docs/architecture.md) and
[the coding conventions](Libraries/ubiquitty-core/Docs/coding-conventions.md)
before changing behavior, and [Contributing](.github/contributing.md) before
opening a pull request.

## License

Apache-2.0; see [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt),
[NOTICE](NOTICE) and [the licensing guide](Docs/licensing.md). "Ubiquitty" and
the Ubiquitty logo are trademarks of Stanislav Yaglo; see
[TRADEMARKS.md](TRADEMARKS.md).
