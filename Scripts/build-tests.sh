#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# build-tests.sh — compile every test of ubiquitty-kit, run none of them.
#
# No arm build compiles Tests/, so the libraries can build while a test file
# cannot. Compiling is cheap and running is not, so this is the half that belongs
# in a gate every push pays. The tree is the one the kit's run-tests.sh runs
# CTest in, so neither pays for the other's configure.
#
# The build is incremental: what a green run proves is that every translation
# unit it CHOSE to compile did. The count is printed, and
# Libraries/ubiquitty-core/Scripts/check-build-reached.py names whether the
# translation units the branch's changes reach were among them. UBQ_TESTS_CLEAN=1
# wipes the directory first, for when the strong claim is the one wanted.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/ubq-library.sh
. "$ROOT/Scripts/ubq-library.sh"
# shellcheck source=/dev/null
. "$UBQ_CORE_ROOT/Scripts/build-jobs.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh in ubiquitty-core.
# shellcheck source=/dev/null
. "$UBQ_CORE_ROOT/Scripts/build-root.sh"

# The tests target carries a precompiled header, and a PCH cannot be shared
# between build directories: its AST records the absolute path of the source it
# was built from.
export CCACHE_HASHDIR=true
BUILD="${UBQ_TESTS_BUILD:-$UBQ_BUILD_ROOT/BuildHostTests/ctest}"
JOBS="${BUILD_JOBS:-$(ubq_build_jobs)}"

# A CMakeCache records the absolute path it was configured at, and CMake refuses
# to reuse one naming anywhere else. run-linux.sh bind-mounts this tree, so a
# container run leaves a cache no host configure can touch.
if [ -f "$BUILD/CMakeCache.txt" ]; then
    configured_at="$(sed -n 's/^CMAKE_CACHEFILE_DIR:INTERNAL=//p' "$BUILD/CMakeCache.txt" | head -1)"
    configuredResolved="$( (cd "$configured_at" 2>/dev/null && pwd -P) || printf '%s' "$configured_at")"
    if [ -n "$configured_at" ] && [ "$configuredResolved" != "$(cd "$BUILD" && pwd -P)" ]; then
        echo "build-tests: $BUILD was configured at $configured_at, reconfiguring here" >&2
        rm -rf "$BUILD"
    fi
fi
if [ "${UBQ_TESTS_CLEAN:-0}" = "1" ]; then
    rm -rf "$BUILD"
fi

# The arm is the kit's default for this machine: macOS on a Mac, Linux on Linux.
cmake -S "$ROOT" -B "$BUILD" -G Ninja \
    -DUBIQUITTY_CORE_SOURCE_DIR="$UBQ_CORE_ROOT" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DUBIQUITTY_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug >/dev/null

BUILD_LOG="$(mktemp -t ubq-build-tests.XXXXXX)"
trap 'rm -f "$BUILD_LOG"' EXIT
cmake --build "$BUILD" -j"$JOBS" 2>&1 | tee "$BUILD_LOG"
# PIPESTATUS, because tee's success is not the compiler's.
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "build-tests: the build failed (above)" >&2
    exit 1
fi

COMPILED="$(grep -c 'Building CXX object' "$BUILD_LOG" || true)"
TOTAL="$(find "$BUILD" -name '*.o' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$COMPILED" -eq 0 ]; then
    echo "build-tests: 0 of $TOTAL translation units compiled — all were up to date."
    echo "  This run proves nothing about any file it did not build."
else
    echo "build-tests: $COMPILED of $TOTAL translation units compiled ($((TOTAL - COMPILED)) up to date)."
    echo "  A file this run did not build is not a file this run checked."
fi

python3 "$UBQ_CORE_ROOT/Scripts/check-build-reached.py" "$BUILD" || exit 1
