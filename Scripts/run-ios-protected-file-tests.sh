#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# run-ios-protected-file-tests.sh — the real iOS protected-file backend, built
# for the simulator and run there, without building or installing the app.
#
#   ./Scripts/run-ios-protected-file-tests.sh                 the checkout's simulator
#   ./Scripts/run-ios-protected-file-tests.sh BOOTED_UDID     a simulator the caller owns
#
# With no argument the run acquires this checkout's simulator through
# Scripts/ios-simulator.sh and shuts it down again if it booted it. A named
# device is used as it is and left running.
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "usage: Scripts/run-ios-protected-file-tests.sh [BOOTED_SIMULATOR_UDID]" >&2
    exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/ubq-library.sh
. "$ROOT/Scripts/ubq-library.sh"
if [[ $# -eq 1 ]]; then
    DEVICE="$1"
else
    # shellcheck source=/dev/null
    . "$UBQ_CORE_ROOT/Scripts/build-root.sh"
    # shellcheck source=Scripts/ios-simulator.sh
    . "$ROOT/Scripts/ios-simulator.sh"
    ubq_ios_device_acquire run-ios-protected-file-tests || exit 2
    DEVICE="$UBQ_IOS_DEVICE"
fi
OUTPUT="$(mktemp -d "${TMPDIR:-/tmp}/ubq-ios-protected-file.XXXXXX")"
ARCH="$(uname -m)"
echo "iOS protected-file evidence: $OUTPUT"
# The creator is Swift (Source/UbiquittyKit/Swift/ProtectedFile.swift) behind
# a C symbol, and so is the suite's protection-class probe, so the C++ units
# are compiled first and swiftc links them with the Swift runtime.
# The suite is the kit's and the PAL it exercises is Core's: each unit is named
# by its path in the repository that owns it, and the headers are read from both.
for unit in "$ROOT/Tests/Platform/test_ios_protected_file.cpp" \
    "$UBQ_CORE_ROOT/Source/Platform/POSIX/SystemPAL.cpp"; do
    xcrun --sdk iphonesimulator clang++ -c \
        -std=c++23 -fno-exceptions -fno-rtti -Wall -Wextra -Werror \
        -DUBIQUITTY_TEST_WITHOUT_CORE=1 -target "$ARCH-apple-ios17.0-simulator" \
        -I"$UBQ_CORE_ROOT/Source" -I"$ROOT/Source" -I"$UBQ_CORE_ROOT/Tests" -I"$ROOT/Tests" \
        "$unit" -o "$OUTPUT/$(basename "$unit").o"
done
xcrun --sdk iphonesimulator swiftc -parse-as-library -O -warnings-as-errors \
    -target "$ARCH-apple-ios17.0-simulator" \
    "$ROOT/Source/UbiquittyKit/Swift/ProtectedFile.swift" \
    "$ROOT/Tests/Platform/test_ios_protected_file_probe.swift" \
    "$OUTPUT/test_ios_protected_file.cpp.o" "$OUTPUT/SystemPAL.cpp.o" \
    -lc++ -framework Foundation -Xlinker -dead_strip -o "$OUTPUT/test_ios_protected_file"
# Complete protection needs a device that applies it. A simulator that cannot
# stores a file asked for with Complete under its default class, and the
# creator then refuses every file, as it must; the suite's first case names the
# class it read back. Only that measured class, other than Complete, is this
# precondition, reported and counted as a skip. A probe that did not run, or
# read back no class, fails the stage.
complete="NSURLFileProtectionComplete"
probeStatus=0
xcrun simctl spawn "$DEVICE" "$OUTPUT/test_ios_protected_file" theDeviceAppliesCompleteProtection \
    >"$OUTPUT/probe.log" 2>&1 || probeStatus=$?
cat "$OUTPUT/probe.log"
readBack="$(sed -n 's/^probe: a file written with Complete protection reads back //p' "$OUTPUT/probe.log" | head -n 1)"
if [[ $probeStatus -ne 0 ]]; then
    if [[ "$readBack" == NSURLFileProtection* && "$readBack" != "$complete" ]]; then
        skip="iOS protected file: SKIPPED — this simulator does not apply Complete protection: a file written with it reads back $readBack"
        echo "$skip"
        if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
            echo "::warning title=iOS protected file skipped::$skip"
        fi
        exit 0
    fi
    echo "iOS protected file: the probe failed (exit $probeStatus) without reading back a protection class" >&2
    exit 1
fi
if [[ "$readBack" != "$complete" ]]; then
    echo "iOS protected file: the probe passed but read back '${readBack:-nothing}', not $complete" >&2
    exit 1
fi
xcrun simctl spawn "$DEVICE" "$OUTPUT/test_ios_protected_file" 2>&1 | tee "$OUTPUT/tests.log"
