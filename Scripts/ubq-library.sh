#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# ubq-library.sh — where ubiquitty-core is, for a script of ubiquitty-kit.
#
# Sourced, not run, by a script that has set ROOT to the kit checkout holding it:
#
#     ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#     . "$ROOT/Scripts/ubq-library.sh"
#     . "$UBQ_CORE_ROOT/Scripts/build-root.sh"
#
# Sets UBQ_CORE_ROOT to the value already set, else Libraries/ubiquitty-core
# under $ROOT when that path exists, else $ROOT, so a checkout that holds every
# repository reads one tree. Scripts/ubq_library.py derives the same answer for
# python callers. Nothing is exported: a child resolves its own, the same way.
#
# Also fills UBQ_SWIFT_INCLUDES with the -I arguments a swiftc driver needs to
# see Core's headers and module maps and the kit's, Core's first, each root
# once: the roots Scripts/cmake/UbiquittyKit.cmake gives the Swift targets.

if [ -z "${UBQ_CORE_ROOT:-}" ]; then
    if [ -e "$ROOT/Libraries/ubiquitty-core" ]; then
        UBQ_CORE_ROOT="$ROOT/Libraries/ubiquitty-core"
    else
        UBQ_CORE_ROOT="$ROOT"
    fi
fi

UBQ_SWIFT_INCLUDES=()
for ubqSourceRoot in "$UBQ_CORE_ROOT" "$ROOT"; do
    case " ${ubqSeenRoots:-} " in *" $ubqSourceRoot "*) continue ;; esac
    ubqSeenRoots="${ubqSeenRoots:-} $ubqSourceRoot"
    UBQ_SWIFT_INCLUDES+=(-I"$ubqSourceRoot/Source" -I"$ubqSourceRoot/Source/Platform/Apple" -I"$ubqSourceRoot/Source/Platform/macOS")
done
unset ubqSourceRoot ubqSeenRoots

# Prints the compiled shader library a driver loads: the macOS app build's when
# there is one, else the one Scripts/build-metallib.sh leaves. Prints the app
# build's path when neither exists, so the refusal names a file.
ubq_metallib() {
    local candidate
    for candidate in "$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/default.metallib" \
        "$(find "$UBQ_BUILD_ROOT/metallib" -name default.metallib -print -quit 2>/dev/null)"; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf '%s' "$UBQ_BUILD_ROOT/macos/Source/Platform/macOS/default.metallib"
}
