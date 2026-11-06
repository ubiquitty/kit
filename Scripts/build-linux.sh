#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# build-linux.sh — build the kit's Linux libraries, and with --test run its host
# tests.
#
#   Scripts/build-linux.sh           the libraries, the shaders and ubiquitty-kit-linux-check
#   Scripts/build-linux.sh --test    also the host tests, run with ctest
#
# Needs the prerequisites Scripts/check-linux-build-prerequisites.sh names;
# Scripts/run-linux.sh runs this in a container that has them. UBQ_BUILD_JOBS
# bounds the compilers; extra arguments go to cmake's configure.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/ubq-library.sh
. "$ROOT/Scripts/ubq-library.sh"
CORE="$UBQ_CORE_ROOT"
# Build output lives outside the checkout; see Libraries/ubiquitty-core/Scripts/build-root.sh.
# shellcheck source=/dev/null
. "$CORE/Scripts/build-root.sh"

# Names the development package a machine lacks, where cmake would name only
# the module it could not find.
"$ROOT/Scripts/check-linux-build-prerequisites.sh"

test=0
if [ "${1:-}" = --test ]; then
    test=1
    shift
fi
if [ "$test" = 1 ]; then
    BUILD="$UBQ_BUILD_ROOT/BuildHostTests/linux-kit"
    configuration=(-DUBIQUITTY_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug)
else
    BUILD="$UBQ_BUILD_ROOT/linux-kit"
    configuration=(-DCMAKE_BUILD_TYPE=Release)
fi
jobs="${UBQ_BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN)}"

cmake -S "$ROOT" -B "$BUILD" -G Ninja -DUBIQUITTY_FRONTEND=Linux "${configuration[@]}" "$@"
cmake --build "$BUILD" -j "$jobs"
if [ "$test" = 1 ]; then
    ctest --test-dir "$BUILD" --output-on-failure -j "$jobs"
fi
