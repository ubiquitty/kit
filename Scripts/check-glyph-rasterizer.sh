#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# check-glyph-rasterizer.sh — a glyph reaches the coverage plane as ink.
#
# The rasteriser draws through a CoreGraphics context into bytes the atlas
# uploads as R8. Everything that can go wrong there yields a plane rather than
# an error: a context with the wrong colour space gives premultiplied values
# where coverage was wanted, a pen outside the slot draws nothing, and a missing
# clear leaves the previous glyph under the new one.
#
# So the bytes are read, and the assertions are relative — M inks more than i, a
# space inks nothing — because absolute coverage is a property of the installed
# face and would pin the check to one version of Menlo.
#
# Needs no Core library and no Metal device: CoreText and CoreGraphics are the
# whole dependency, so it runs in about a second.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/ubq-library.sh
. "$ROOT/Scripts/ubq-library.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh in ubiquitty-core.
# shellcheck source=/dev/null
. "$UBQ_CORE_ROOT/Scripts/build-root.sh"
cd "$ROOT"

SWIFT_DIRECTORY="$ROOT/Source/UbiquittyRenderKit"
OUT="${TMPDIR:-/tmp}/ubiquitty-glyph-rasterizer-driver"

# One list, read by both passes below — a second spelling for the type-check
# pass would be a mirror of this one.
SWIFT_ARGUMENTS=(
    -O -wmo -enforce-exclusivity=unchecked
    -module-name GlyphRasterizerDriver
    -package-name ubiquitty
    -cxx-interoperability-mode=default
    -Xcc -std=c++23
    -I"$SWIFT_DIRECTORY"
    "${UBQ_SWIFT_INCLUDES[@]}"
    -framework CoreText
    -framework CoreGraphics
    "$SWIFT_DIRECTORY/FontFaces.swift"
    "$SWIFT_DIRECTORY/ShippedResources.swift"
    "$SWIFT_DIRECTORY/GlyphRasterizer.swift"
    "$ROOT/Scripts/drive-glyph-rasterizer.swift"
)

# shellcheck source=Scripts/swift-driver-typecheck.sh
source "$ROOT/Scripts/swift-driver-typecheck.sh"
swift_driver_typecheck_if_requested check-glyph-rasterizer "${SWIFT_ARGUMENTS[@]}"

# FontFaces resolves the reader's features through Core's one grammar, so the
# driver links the portable Core archive the sibling drivers link.
CORE_BUILD="$UBQ_BUILD_ROOT/core"
if [[ ! -f "$CORE_BUILD/libubiquitty-core.a" ]]; then
    echo "check-glyph-rasterizer: $CORE_BUILD/libubiquitty-core.a is missing." >&2
    echo "  Build it first: $UBQ_CORE_ROOT/Scripts/build-core-snapshot.sh" >&2
    exit 2
fi
# shellcheck source=/dev/null
source "$UBQ_CORE_ROOT/Scripts/build-provenance.sh"
build_provenance_require "$UBQ_CORE_ROOT" "$CORE_BUILD" "check-glyph-rasterizer" "$UBQ_CORE_ROOT/Scripts/build-core-snapshot.sh"

xcrun swiftc "${SWIFT_ARGUMENTS[@]}" \
    "$CORE_BUILD/libubiquitty-core.a" \
    "$CORE_BUILD/libubiquitty-core-model.a" \
    -o "$OUT"

"$OUT" "$UBQ_CORE_ROOT/Resources/fonts"
