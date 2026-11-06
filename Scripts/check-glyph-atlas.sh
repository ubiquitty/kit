#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# check-glyph-atlas.sh — slots are distinct, stable, and keyed per face.
#
# The atlas turns a slot index from Core's cache into an atlas rectangle. Every
# way that goes wrong yields a rectangle rather than an error: a key on the code
# point alone gives bold and regular one slot, a colliding key gives two
# characters one image, and a slot-to-rect map with the wrong stride puts every
# glyph a row off. All of it draws.
#
# A count-based assertion cannot see any of it, because a cache returning a
# constant satisfies "a slot was assigned" every time. So the checks are
# relational — distinct code points differ, one code point repeats, the same
# code point in two faces differs.
#
# This one earned its place on the first run: it caught a segfault in code that
# compiled, linked, and carried 63 symbols in the app binary. Swift substitutes
# a zero-initialising init() for a C++ class that declares no default
# constructor, and reports the substitution as a deprecation warning.
#
# Links Core, so build it first.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/ubq-library.sh
. "$ROOT/Scripts/ubq-library.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh in ubiquitty-core.
# shellcheck source=/dev/null
. "$UBQ_CORE_ROOT/Scripts/build-root.sh"
cd "$ROOT"

SWIFT_DIRECTORY="$ROOT/Source/UbiquittyRenderKit"
CORE_BUILD="$UBQ_BUILD_ROOT/core"
OUT="${TMPDIR:-/tmp}/ubiquitty-glyph-atlas-driver"

# The whole render kit, from the list its targets compile; see
# Scripts/renderkit-sources.sh.
# shellcheck source=Scripts/renderkit-sources.sh
source "$ROOT/Scripts/renderkit-sources.sh"
renderkit_sources_load "$ROOT" check-glyph-atlas

# One list, read by both passes below — a second spelling for the type-check
# pass would be a mirror of this one.
SWIFT_ARGUMENTS=(
    -O -wmo -swift-version 6 -enforce-exclusivity=checked -parse-as-library
    -module-name GlyphAtlasDriver
    -target "$RENDERKIT_TARGET"
    -package-name ubiquitty
    -cxx-interoperability-mode=default
    -Xcc -std=c++23
    -I"$SWIFT_DIRECTORY"
    "${UBQ_SWIFT_INCLUDES[@]}"
    -framework Metal
    -framework CoreText
    -framework CoreGraphics
    "${RENDERKIT_SOURCES[@]}"
    "$ROOT/Scripts/drive-glyph-atlas.swift"
)

# Above the archive checks, because type-checking links nothing: refusing a
# missing archive here would make the cheap pass carry the expensive pass's
# prerequisite, which is the arrangement that kept this gate off every branch.
# shellcheck source=Scripts/swift-driver-typecheck.sh
source "$ROOT/Scripts/swift-driver-typecheck.sh"
swift_driver_typecheck_if_requested check-glyph-atlas "${SWIFT_ARGUMENTS[@]}"

if [[ ! -f "$CORE_BUILD/libubiquitty-core.a" ]]; then
    echo "check-glyph-atlas: $CORE_BUILD/libubiquitty-core.a is missing." >&2
    echo "  Build it first: $UBQ_CORE_ROOT/Scripts/build-core-snapshot.sh" >&2
    exit 2
fi

# The archive can also be present and older than the headers this driver just
# parsed. That links, then crashes inside Core; refuse it the same way.
# shellcheck source=/dev/null
source "$UBQ_CORE_ROOT/Scripts/build-provenance.sh"
build_provenance_require "$UBQ_CORE_ROOT" "$CORE_BUILD" "check-glyph-atlas" "$UBQ_CORE_ROOT/Scripts/build-core-snapshot.sh"

# The whole kit reaches the runtime, which calls the PAL for clocks, the PTY
# and the clipboard; the snapshot archives carry no backend, so the same stub
# check-terminal-renderer links stands in for one.
# shellcheck source=/dev/null
source "$UBQ_CORE_ROOT/Scripts/portable-core-lib.sh"
ubiquitty_core_pal_stub_source "$OUT-pal.cpp"
xcrun clang++ -std=c++23 -target "$RENDERKIT_TARGET" -I"$UBQ_CORE_ROOT/Source" -c "$OUT-pal.cpp" -o "$OUT-pal.o"

# All three archives, as every consumer of the aggregate needs: CMake's
# ubiquitty-core links behaviour PUBLIC, and a driver spelling its own link line
# gets no such transitive edge. The font router reads the preferences store,
# which is L2, so without this the driver stops linking and checks nothing.
xcrun swiftc "${SWIFT_ARGUMENTS[@]}" \
    "$OUT-pal.o" \
    "$CORE_BUILD/libubiquitty-core.a" \
    "$CORE_BUILD/libubiquitty-core-model.a" \
    "$CORE_BUILD/libubiquitty-behaviour.a" \
    -o "$OUT"

"$OUT" "$UBQ_CORE_ROOT/Resources/fonts/SymbolsNerdFontMono-Regular.ttf"
