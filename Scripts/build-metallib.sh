#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# build-metallib.sh — the kit's compiled shader library, built alone.
#
# The renderer drivers (check-frame-encoder.sh, check-terminal-renderer.sh) load
# default.metallib. Only the Metal toolchain builds it: no Core library, no
# Swift. A checkout that holds the app gets the same file from the app's own
# build; this builds it where there is none.
#
#   ./Scripts/build-metallib.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/ubq-library.sh
. "$ROOT/Scripts/ubq-library.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh in ubiquitty-core.
# shellcheck source=/dev/null
. "$UBQ_CORE_ROOT/Scripts/build-root.sh"
BUILD="$UBQ_BUILD_ROOT/metallib"

cmake -S "$ROOT" -B "$BUILD" -G Ninja \
    -DUBIQUITTY_FRONTEND=macOS \
    -DCMAKE_BUILD_TYPE=Debug
cmake --build "$BUILD" --target UbiquittyMetalLib
echo "build-metallib: $(find "$BUILD" -name default.metallib -print -quit)"
