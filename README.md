<!-- Copyright (C) 2026 Stanislav Yaglo -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# UbiquittyKit

| You are building | Reach for | Repository |
|---|---|---|
| A terminal view to drop into a macOS or iOS app | UbiquittyKit's Swift `TerminalSurface` and Metal renderer | [ubiquitty-kit](https://github.com/ubiquitty/kit) |
| Linux rendering, font rasterization or GTK integration | the Vulkan, FreeType and software renderers and the GTK platform libraries | [ubiquitty-kit](https://github.com/ubiquitty/kit) |
| A renderer for a texture or layer your UI presents | UbiquittyRenderKit (Metal) or the Vulkan renderer's exportable frames | [ubiquitty-kit](https://github.com/ubiquitty/kit) |
| Your own UI, drawing from the portable terminal model | Core's C++23 API, session facade and render plan | [ubiquitty-core](https://github.com/ubiquitty/core) |
| Persistent sessions, a session daemon, attach and reattach across machines | `ubiquitty-host`, Sync, `ubq` and the agent | [ubiquitty-core](https://github.com/ubiquitty/core) |
| The Ubiquitty apps themselves | the macOS, iOS, Linux and web frontends | [ubiquitty](https://github.com/ubiquitty/ubiquitty) |

Ubiquitty is three repositories. Each depends only on the ones below it:
`ubiquitty` → `kit` → `core`. This is the middle one.

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

Apple hosts use the Swift view API. Linux hosts link the C++ rendering and
platform libraries above and supply their own application shell. Portable
hosts use [Core's C++23 embedding API](https://github.com/ubiquitty/core/blob/main/Docs/libubiquittycore.md).

## Embed `TerminalSurface`

`TerminalSurface` is the view: an `NSView` on macOS and a `UIView` on iOS. Built
with a font, it creates its own Metal device and renderer, and in a window it
owns its Metal layer and its display link, takes the keyboard and the pointer,
and keeps its selection and accessibility. Build `UbiquittyKit.framework`
(below), add it to the app, import it, and put the view where the terminal goes:

```swift
import AppKit
import UbiquittyKit

@MainActor
func addTerminal(to container: NSView) -> TerminalSurface? {
    guard let terminal = TerminalSurface(rows: 24, columns: 80, fontFamily: "Menlo", pointSize: 13) else {
        return nil
    }
    terminal.frame = container.bounds
    terminal.autoresizingMask = [.width, .height]
    container.addSubview(terminal)
    terminal.launchShell()
    return terminal
}
```

Naming the font is what makes the view ready to draw: `TerminalSurface(rows:columns:)`
alone is a complete terminal with no renderer, which paints nothing. The grid
follows the view's size, and `terminalSurface(_:didResizeGridTo:columns:)` on the
view's observer reports each change. `launchShell()` runs the user's login shell
on the view's pseudo-terminal; `feed(_:)` writes bytes to the screen for a host
that supplies its own; `attachRemote` shows a session a host daemon keeps.

### Draw into your own layer

A host that presents the terminal in a layer or texture of its own skips the
view's presentation and drives the renderer itself. It sizes its
`CAMetalLayer` and calls this function on the main actor to feed bytes and draw
a frame. `Scripts/check-ubiquittykit.sh` exercises these public entry points
from a separate host linked to the built framework:

```swift
import Foundation
import Metal
import QuartzCore
import UbiquittyKit

@MainActor
func drawHello(in layer: CAMetalLayer) -> Bool {
    guard let device = MTLCreateSystemDefaultDevice(),
          let surface = TerminalSurface(rows: 24, columns: 80),
          let renderer = TerminalSurface.makeRenderer(
              device: device, fontFamily: "JetBrains Mono") else { return false }
    layer.device = device
    layer.pixelFormat = .bgra8Unorm_srgb
    surface.renderer = renderer
    surface.feed(Data("hello\r\n".utf8))
    return renderer.encodeFrame(for: surface, into: layer)
}
```

The Swift API is documented on
[`TerminalSurface`](Source/UbiquittyKit/Swift/TerminalSurface.swift) and its
[renderer factory](Source/UbiquittyKit/Swift/TerminalSurface+Factory.swift).
[The Swift renderer](Docs/swift-renderer.md) describes the rendering backend;
[the C++ session guide](Docs/ubiquittykit-api.md) covers the separate session
facade supplied by Core. An application
that compiles the kit into its own build includes
`Scripts/cmake/UbiquittyKit.cmake` at its top directory after the Core modules,
in the order [Core's build module](https://github.com/ubiquitty/core/blob/main/Scripts/cmake/UbiquittyCoreRoot.cmake)
lays out, and links the modules the file creates.

## Build

Clone with the submodule:

```sh
git clone --recurse-submodules https://github.com/ubiquitty/kit.git
cd kit
```

In an existing clone, run `git submodule update --init --recursive`.

The kit builds as C++23 and Swift 6 with warnings as errors, and needs CMake
with C++23 support, Ninja or Make, Python 3 and Bash. The first QUIC-enabled build
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
BUILD="$(python3 Libraries/ubiquitty-core/Scripts/build_root.py .)/ios-simulator"
cmake -S . -B "$BUILD" -G Ninja -DUBIQUITTY_FRONTEND=iOS -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build "$BUILD"
```

**Linux** needs GTK 4.16, Pango, FreeType, HarfBuzz, fontconfig, Vulkan and
`glslc`; `Scripts/check-linux-build-prerequisites.sh` names what is missing.
`Scripts/run-linux.sh` runs any command in the container that has them:

```sh
BUILD="$(python3 Libraries/ubiquitty-core/Scripts/build_root.py .)/linux"
cmake -S . -B "$BUILD" -G Ninja -DUBIQUITTY_FRONTEND=Linux
cmake --build "$BUILD"          # the libraries, the shaders and ubiquitty-kit-linux-check
```

## Test

```sh
BUILD="$(python3 Libraries/ubiquitty-core/Scripts/build_root.py .)/tests"
cmake -S . -B "$BUILD" -G Ninja -DUBIQUITTY_FRONTEND=Linux \
    -DUBIQUITTY_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug     # or macOS
cmake --build "$BUILD"
ctest --test-dir "$BUILD" --output-on-failure
```

A `test_*.cpp` file anywhere under `Tests/` is a CTest case; no list names it.
The Linux tests run on Linux and the macOS ones on a Mac. The Swift check drivers
(`Scripts/check-*.sh`) compile a renderer module with a driver of their own and
need a Mac.

Read [the architecture](https://github.com/ubiquitty/core/blob/main/Docs/architecture.md) and
[the coding conventions](https://github.com/ubiquitty/core/blob/main/Docs/coding-conventions.md)
before changing behavior, and [Contributing](.github/contributing.md) before
opening a pull request.

## License

Apache-2.0; see [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt),
[NOTICE](NOTICE) and [the licensing guide](https://github.com/ubiquitty/core/blob/main/Docs/licensing.md). "Ubiquitty" and
the Ubiquitty logo are trademarks of Stanislav Yaglo; see
[TRADEMARKS.md](TRADEMARKS.md).
