#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# Scripts/run-tests-stanzas-kit.sh — the stanzas of ubiquitty-kit.
#
# Sourced by Scripts/run-tests.sh in a checkout that holds ubiquitty-kit, after the stanzas
# of ubiquitty-core. Every stanza is written against that driver's helpers
# (`wanted`, `build_and_run`, `ubq_build_test`, `OUT`, `ROOT`, `RAN`), and its
# name is literal so Scripts/stanza-declarations.awk can list it.

# Whether a drawable comes back holding what was last drawn into it — the one
# fact a partial composite would rest on, asked of the pool on this machine
# rather than assumed. Metal documents drawable contents as undefined at
# acquisition; undefined is not discarded, and a partial composite needs the
# difference to fall the right way.
#
# Informational while the composite is still full-screen: it prints what the
# pool did and passes as long as it reached the state it asks about. It becomes
# a gate the day a partial composite ships, because losing persistence then is a
# user-visible stale-row bug with no other alarm on it.
#
# Metal + QuartzCore, so Darwin-only. Plain `xcrun swiftc`, as
# test_macos_settings_search is built.
if [ "$(uname -s)" = "Darwin" ] && wanted drawable_persistence; then
    NAME=test_drawable_persistence
    OUT_BIN="$OUT/$NAME"
    mkdir -p "$OUT"
    echo "=== $NAME ==="
    xcrun swiftc -parse-as-library -warnings-as-errors \
        "$ROOT/Tests/Platform/test_drawable_persistence.swift" \
        -o "$OUT_BIN" || exit 1
    "$OUT_BIN" || exit 1
    RAN=$((RAN + 1))
fi

if [ "$(uname -s)" = "Darwin" ] && wanted test_rich_text_native_geometry; then
    NAME=test_rich_text_native_geometry
    OUT_BIN="$OUT/$NAME"
    mkdir -p "$OUT"
    echo "=== $NAME ==="
    ubq_build_test test_rich_text_native_geometry "$OUT_BIN" "$OUT/test_rich_text_native_geometry-build.log" || { cat "$OUT/test_rich_text_native_geometry-build.log" >&2; exit 1; }
    "$OUT_BIN" || exit 1
    RAN=$((RAN + 1))
fi

# ideographicCharacterFaceCentre (Source/UbiquittyRenderKit/IdeographicFace.swift) —
# where a CJK face sets its ideographs, read from its BASE table's icfb and icft
# baselines, which the wide sheet aligns with the primary face's cap height.
# Plain `xcrun swiftc` with IdeographicFace.swift alone: the system CJK faces
# name the box and their ideographs centre on it, a Latin face names none, and
# truncated or garbage tables read as absent.
if [ "$(uname -s)" = "Darwin" ] && wanted test_macos_ideographic_face; then
    NAME=test_macos_ideographic_face
    OUT_BIN="$OUT/$NAME"
    mkdir -p "$OUT"
    echo "=== $NAME ==="
    xcrun swiftc -parse-as-library -warnings-as-errors \
        "$ROOT/Tests/Platform/test_macos_ideographic_face.swift" \
        "$ROOT/Source/UbiquittyRenderKit/IdeographicFace.swift" \
        -o "$OUT_BIN" || exit 1
    "$OUT_BIN" || exit 1
    RAN=$((RAN + 1))
fi

# LastResort guard: ctLineHasLastResortRun (Source/UbiquittyRenderKit/LastResort.swift)
# — the CTLine run scan that stops the glyph atlas, colour sheet and ligature
# strips baking a CoreText LastResort ?-box tofu into a cached image (where the
# grid cache freezes it). Plain `xcrun swiftc` with LastResort.swift alone, as
# test_macos_settings_search is built: it detects a LastResort-attributed run,
# ignores a covered (Menlo) run, reports nothing for an empty line, and keeps
# the characters outside LastResort runs.
if [ "$(uname -s)" = "Darwin" ] && wanted test_macos_lastresort_guard; then
    NAME=test_macos_lastresort_guard
    OUT_BIN="$OUT/$NAME"
    mkdir -p "$OUT"
    echo "=== $NAME ==="
    xcrun swiftc -parse-as-library -warnings-as-errors \
        "$ROOT/Tests/Platform/test_macos_lastresort_guard.swift" \
        "$ROOT/Source/UbiquittyRenderKit/LastResort.swift" \
        -o "$OUT_BIN" || exit 1
    "$OUT_BIN" || exit 1
    RAN=$((RAN + 1))
fi

# Shader library residency: MetalPipelines.moduleShaderLibrary
# (Source/UbiquittyRenderKit/MetalPipelines.swift) hands every renderer the
# library its device first loaded, so a window or tab asked for while the
# application is being replaced still has shaders, and a load that failed is
# tried again. Plain `xcrun swiftc` with MetalPipelines.swift and the bundle it
# reads from, ShippedResources.swift. The binary runs beside a one-function
# library compiled here, because a command-line tool's bundle is the directory
# it runs from; it moves that file away and back itself, so it reads no
# application's bundle.
if [ "$(uname -s)" = "Darwin" ] && wanted test_metal_shader_library; then
    NAME=test_metal_shader_library
    echo "=== $NAME ==="
    if ! xcrun -f metal >/dev/null 2>&1 || ! xcrun -f metallib >/dev/null 2>&1; then
        ubq_skip_unless_required metal "$NAME needs the Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)"
    else
        BUNDLE_DIR="$OUT/$NAME.bundle-directory"
        rm -rf "$BUNDLE_DIR"
        mkdir -p "$BUNDLE_DIR"
        printf '%s\n' '#include <metal_stdlib>' 'kernel void residencyKernel() {}' >"$BUNDLE_DIR/residency.metal"
        xcrun metal -c "$BUNDLE_DIR/residency.metal" -o "$BUNDLE_DIR/residency.air" || exit 1
        xcrun metallib "$BUNDLE_DIR/residency.air" -o "$BUNDLE_DIR/default.metallib" || exit 1
        xcrun swiftc -parse-as-library -warnings-as-errors -package-name ubiquitty \
            "$ROOT/Tests/Platform/test_metal_shader_library.swift" \
            "$ROOT/Source/UbiquittyRenderKit/MetalPipelines.swift" \
            "$ROOT/Source/UbiquittyRenderKit/ShippedResources.swift" \
            -o "$BUNDLE_DIR/$NAME" || exit 1
        "$BUNDLE_DIR/$NAME" || exit 1
    fi
    RAN=$((RAN + 1))
fi

# linux_build_prerequisites — the Linux frontend's prerequisite check names
# what is missing and accepts what is present, against a fixture PATH.
if wanted linux_build_prerequisites; then
    echo "=== linux_build_prerequisites ==="
    RAN=$((RAN + 1))
    "$ROOT/Tests/test-linux-build-prerequisites.sh" || exit 1
fi

# check-swift-cxx-exports reports nothing on a tree whose interop-typed Swift
# exports all survive into the generated header, the same output it would give if
# its census matched nothing. Its self-test runs the detector against a header
# drop, a total absence and a survivor, and confirms the census picks only
# public/package interop funcs -- the rule is proven, not asserted. The real
# check runs post-build inside check-ubiquittykit, where the header and archive
# it reads exist.
if wanted swift_cxx_exports; then
    echo "=== swift_cxx_exports ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/check-swift-cxx-exports.py" --self-test || exit 1
fi

# check-swift-modules-depend-on-core holds each Swift module that inlines C++
# to a declared dependency on it. Without one, editing a Core header rebuilds the
# ObjC TUs and relinks while the Swift libraries keep their old objects, so the
# app runs the previous Core on the Swift arm and nothing says so. It refuses on
# a tree whose modules it cannot find rather than passing.
if wanted swift_modules_depend_on_core; then
    echo "=== swift_modules_depend_on_core ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/check-swift-modules-depend-on-core.py" || exit 1
fi

# ubq_library — a kit script finds ubiquitty-core through $UBQ_CORE_ROOT, else the
# mounted library, else its own checkout, and the shell and python doors agree.
if wanted ubq_library; then
    echo "=== ubq_library ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Scripts/test-ubq-library.py" || exit 1
fi

if wanted test_snapshot_gate_scope; then
    echo "=== test_snapshot_gate_scope ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Tests/Tools/test_snapshot_gate_scope.py" || exit 1
fi

if wanted test_resource_producers; then
    echo "=== test_resource_producers ==="
    RAN=$((RAN + 1))
    python3 "$ROOT/Tests/Tools/test_resource_producers.py" || exit 1
fi
