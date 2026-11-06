#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# check-swift-module-compiles.sh — compile the Swift renderer from nothing.
#
# The macOS gate builds incrementally, so it links a `.swiftmodule` already on
# disk and never asks whether the module still compiles. A change that crashes
# swiftc from clean passes every push, because every push has that file already
# built.
#
# The whole module is one job: swiftc takes `-wmo`, so every file in it compiles
# together and a diagnostic names the job rather than a file. That is what makes
# a warm build so misleading here — there is no per-file staleness to notice, and
# the one artefact either exists or does not.
#
# The cost is that one compile and nothing else: the build reuses a configured
# directory, and `cmake --build --target` reaches the module without rebuilding
# what it links against — the log is two steps, a glob re-check and the swiftc
# job. It grows with the module rather than with the tree: 53 files
# [= Source/UbiquittyRenderKit/*.swift]. The count carries its pathspec, so
# check-census-claims.py re-derives it instead of trusting it.
#
# What it deletes is what the build graph says the module's edge produces, read
# from ninja, and a graph that names nothing to delete is a refusal. A path
# spelled here would go stale with the CMake layout and turn the gate into a
# no-op that still prints ok.
#
#   ./Scripts/check-swift-module-compiles.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/ubq-library.sh
. "$ROOT/Scripts/ubq-library.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh in ubiquitty-core.
# shellcheck source=/dev/null
. "$UBQ_CORE_ROOT/Scripts/build-root.sh"
cd "$ROOT" || exit 1

BUILD="$UBQ_BUILD_ROOT/swift-module-check"
TARGET="UbiquittyRenderKit"

# Debug, and named in every verdict. One change can compile at -O and crash at
# -Onone, so "macOS builds clean" without a build type can be both true and
# false of one commit. A build type is part of what a build verdict says, and
# this is also the type the test suite compiles at.
BUILD_TYPE="Debug"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "check-swift-module-compiles: SKIPPED — the Swift renderer is macOS only."
    exit 0
fi
if ! command -v swiftc >/dev/null 2>&1; then
    echo "check-swift-module-compiles: SKIPPED — no swiftc on this machine." >&2
    exit 0
fi

LOG="${TMPDIR:-/tmp}/swift-module-check.log"
CONFIGURE_LOG="${TMPDIR:-/tmp}/swift-module-configure.log"

if [ ! -f "$BUILD/build.ninja" ]; then
    if ! cmake -S "$ROOT" -B "$BUILD" -G Ninja \
            -DUBIQUITTY_CORE_SOURCE_DIR="$UBQ_CORE_ROOT" \
            -DUBIQUITTY_FRONTEND=macOS \
            -DCMAKE_BUILD_TYPE="$BUILD_TYPE" > "$CONFIGURE_LOG" 2>&1; then
        echo "check-swift-module-compiles: cannot configure $BUILD — see" \
             "$CONFIGURE_LOG" >&2
        exit 2
    fi
fi

# The module's products, and only those: every output of the one edge that links
# the module, which is its objects, its .swiftmodule and .swiftdoc, and its
# archive. The target's CMakeFiles directory also holds output-file-map.json,
# which cmake writes at CONFIGURE time — deleting the directory makes swiftc
# fail on a missing map, and that reads as a caught break from a gate that
# compiled nothing. It did, the first time this ran.
PRODUCTS="$(ninja -C "$BUILD" -t targets all 2>/dev/null \
    | sed -n "s|^\([^:]*\): [A-Za-z_]*LINKER__${TARGET}_.*|\1|p")"
if [ -z "$PRODUCTS" ]; then
    echo "check-swift-module-compiles: REFUSED — $BUILD's build graph names no product of" \
         "$TARGET, so there is nothing to delete and a pass would mean nothing." >&2
    exit 2
fi
# Objects of the target, not of its dependencies: the rule name carries the target.
while IFS= read -r product; do
    case "$product" in
        /*) rm -f "$product" ;;
        *) rm -f "$BUILD/$product" ;;
    esac
done <<< "$PRODUCTS"
rm -rf "$BUILD/$TARGET.swiftmodule" "$BUILD/$TARGET.swiftdoc"

# Every product has to come back from this build and not from the one before it:
# the marker is no newer than anything the build writes, and newer than anything
# the deletion above failed to remove.
MARKER="$(mktemp "${TMPDIR:-/tmp}/swift-module-check.XXXXXX")"
trap 'rm -f "$MARKER"' EXIT

if cmake --build "$BUILD" --target "$TARGET" > "$LOG" 2>&1; then
    while IFS= read -r product; do
        case "$product" in /*) built="$product" ;; *) built="$BUILD/$product" ;; esac
        if [ ! -e "$built" ] || [ "$MARKER" -nt "$built" ]; then
            echo "check-swift-module-compiles: FAILED — the build succeeded but $product was not produced by it" >&2
            exit 1
        fi
    done <<< "$PRODUCTS"
    echo "check-swift-module-compiles: ok ($TARGET compiles from nothing at $BUILD_TYPE: $(printf '%s\n' "$PRODUCTS" | wc -l | tr -d ' ') products rebuilt)"
    exit 0
fi

echo "check-swift-module-compiles: FAILED — $TARGET does not compile from clean at $BUILD_TYPE" >&2
echo "  The build type is part of the verdict: this module compiles at -O and" >&2
echo "  crashes at -Onone, so a green elsewhere may be answering another question." >&2
if grep -qE 'due to signal [0-9]+|Please submit a bug report' "$LOG"; then
    echo "  The compiler crashed rather than diagnosing, and -wmo means the" >&2
    echo "  whole module is one job — so no file is named. Split the module or" >&2
    echo "  drop -wmo to get one." >&2
fi
grep -E '(^|[[:space:]])error:' "$LOG" | head -5 >&2
echo "  full log: $LOG" >&2
exit 1
