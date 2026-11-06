#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# Scripts/pre-push-gates-kit.sh — the pre-push gates ubiquitty-kit answers for.
#
# Sourced after Scripts/pre-push-gates-lib.sh by the Scripts/pre-push-gates.sh of
# a repository that holds ubiquitty-kit's files: ubiquitty-kit itself, and a
# repository that holds everything. Each `kit_gate_*` function is one family of
# gates, named by the `./Scripts/` path the gate has in ubiquitty-kit. The Apple
# arms stand down off macOS through SKIPPED, because a gate that returns quietly
# reads in the summary exactly like one that ran and found nothing.

# Whether the branch's diff against origin/main reaches the Swift renderer: its
# own sources, the build modules that give it its flags and source lists, or a
# header the Metal shaders include. The list of changed paths arrives as $1;
# with none, the diff against origin/main's merge base is read.
#
# The shaders' quoted includes are followed transitively and folded to
# repository paths: beside the including file, then under Source/ of the checkout
# that holds ubiquitty-core, the root the shader compile names with -I. A library
# a checkout carries is read as the files between its pins; a mount whose pins
# cannot be read selects the arm, since a library that moved may have moved a
# header the shader includes. With no shader to read, every Core header selects
# the arm, since an include list that could not be read is not an empty one.
kit_swift_arm_reached() {
    local changed="${1-}" shaderInputs="" pending="" source include resolved pattern selectsShader=0
    local kitRoot="${UBQ_KIT_ROOT:-.}" coreRoot="${UBQ_CORE_ROOT:-.}"
    if [ -z "$changed" ]; then
        changed="$(ubq_changed_with_libraries)" || return 1
    fi
    # Native snapshots use the same Swift surface and Metal encoder as the app,
    # built by the Kit's build modules, which hold the render kit's Swift flags,
    # its source lists and the shader library.
    if printf '%s\n' "$changed" | grep -v '^Source/Platform/macOS/UITest/' \
        | grep -qE '^Source/(Platform/macOS|UbiquittyRenderKit|UbiquittyKit)/|^Scripts/cmake/(UbiquittyKit|AppleSharedSwift)\.cmake$'; then
        return 0
    fi
    # A library mount that could not be read between its pins may have changed anything.
    if grep -qE '^Libraries/ubiquitty-(core|kit)$' <<<"$changed"; then
        return 0
    fi
    # The shaders belong to the Kit and the headers they include to Core: a path
    # is repository-relative, and the file is read from the checkout holding it.
    ubq_checkout_file() {
        local candidate
        for candidate in "$1" "$kitRoot/$1" "$coreRoot/$1"; do
            [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
        done
        return 1
    }
    pattern='^(.*/)?([^/]+)/\.\./(.*)$'
    for source in "$kitRoot"/Source/UbiquittyRenderKit/*.metal; do
        [ -f "$source" ] && pending="$pending${source#"$kitRoot"/}"$'\n'
    done
    # With no shader to read, every Core header selects the arm: an include
    # list that could not be read is not an empty one.
    if [ -z "$pending" ]; then
        grep -qE '^Source/Core/.*\.(h|hpp|inc)$' <<<"$changed" && selectsShader=1
    fi
    while [ -n "$pending" ]; do
        source="${pending%%$'\n'*}"
        pending="${pending#*$'\n'}"
        while IFS= read -r include; do
            resolved="$(dirname "$source")/$include"
            ubq_checkout_file "$resolved" >/dev/null || resolved="Source/$include"
            resolved="${resolved//\/.\//\/}"
            while [[ "$resolved" =~ $pattern ]] && [ "${BASH_REMATCH[2]}" != ".." ]; do
                resolved="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
            done
            case $'\n'"$shaderInputs" in
                *$'\n'"$resolved"$'\n'*) continue ;;
            esac
            shaderInputs="$shaderInputs$resolved"$'\n'
            ubq_checkout_file "$resolved" >/dev/null && pending="$pending$resolved"$'\n'
        done < <(sed -n 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*"\([^"]*\)".*/\1/p' "$(ubq_checkout_file "$source")")
    done
    if [ -n "$shaderInputs" ] && grep -qxF "${shaderInputs%$'\n'}" <<<"$changed"; then
        selectsShader=1
    fi
    # The native snapshot command reads its words, states its configuration and
    # draws its portable frame through these Core headers, so a change to them
    # changes what the swift arm renders.
    grep -qE '^Source/Core/(Diagnostics/SnapshotArguments|App/SnapshotRequest)\.h$' <<<"$changed" && selectsShader=1
    [ "$selectsShader" = 1 ]
}

# The Apple arms of the host tier: the Swift renderer compiled from clean and the
# framework product.
kit_gate_apple() {
    # In the quick tier rather than beside an app, which only `full` reaches. An
    # incremental build links a .swiftmodule already on disk, so it never asks
    # whether the module still compiles: a change that crashes swiftc from clean
    # passes every push. Three seconds, and it stands down off macOS.
    run_scoped "Swift renderer from clean" \
        "Source/Platform/macOS Source/UbiquittyRenderKit Source/UbiquittyKit Source/Platform/Apple CMakeLists.txt cmake Source/Core Source/Base Source/PAL Scripts/cmake Scripts/portable-core-sources.txt Scripts/check-core-layer-partition.sh Scripts/check-swift-module-compiles.sh Scripts/build-root.sh Scripts/build_root.py Scripts/ubq-library.sh" \
        ./Scripts/check-swift-module-compiles.sh
    # The framework is built separately from an app's static modules, so its
    # source lists, bundle layout, shipped resources and Core catalogs all
    # select its external consumer check.
    if ! git diff --quiet origin/main -- Source/Platform/macOS Source/UbiquittyKit Source/UbiquittyRenderKit \
            Scripts/cmake/UbiquittyKit.cmake Scripts/cmake/AppleSharedSwift.cmake cmake \
            Resources/fonts Resources/phosphor Resources/process-icons \
            Source/Core/Rendering/BundledFonts.h Source/Core/Rendering/FontSelection.h \
            Source/Core/Rendering/UnifontRasterizer.h Source/Core/Preferences/PreferencesDefaults.h \
            Source/Core/Title/ProcessIconCatalog.h Source/Core/Title/ProcessIcons.h \
            Libraries/ubiquitty-core Scripts/check-ubiquittykit.sh Scripts/check-swift-cxx-exports.py 2>/dev/null; then
        run "UbiquittyKit consumer" ./Scripts/check-ubiquittykit.sh
    fi
}

# Every driver over the Swift renderer, each building a piece of it and reading
# a result back. Two passes with different reach: the type-check runs on every
# branch, the drawing pass when the branch reaches the Swift renderer.
#
# A harness nobody runs fails in the compiler, without reaching an assertion: a
# `package` declaration its compile line has no -package-name for, a source list
# behind the directory, a protocol member its stubs do not implement. Such
# breaks arrive from OUTSIDE the Swift renderer, which is why the halves are
# selected differently: a Core protocol growing a member breaks a stub's
# conformance on a branch that touches no Swift source at all.
kit_gate_renderer_drivers() {
    # Both passes need swiftc against Metal-importing sources, so both stand
    # down off Darwin — through SKIPPED.
    [ "$(uname -s)" = "Darwin" ] || {
        SKIPPED+=("swift-renderer drivers (needs macOS toolchain; this host is $(uname -s))")
        return 0
    }
    # The type-check pass on every branch. It links nothing and opens no device,
    # so it costs seconds.
    run_scoped "swift-renderer drivers (type-check)" \
        "Source Scripts Resources/fonts CMakeLists.txt cmake" \
        ./Scripts/check-swift-renderer.sh --typecheck-only
    if ! kit_swift_arm_reached; then
        printf '  %-34s %s\n' "swift-renderer drivers (draw)" "none — this branch changes no Swift renderer source"
        return 0
    fi
    run_scoped "swift-renderer drivers (draw)" \
        "Source Scripts Resources/fonts CMakeLists.txt cmake" \
        ./Scripts/check-swift-renderer.sh
}

# The kit's protected-file backend, which only a simulator process exercises.
kit_gate_ios() {
    [ "$(uname -s)" = "Darwin" ] || {
        SKIPPED+=("iOS protected file (needs the iPhone SDK; this host is $(uname -s))")
        return 0
    }
    if ! xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
        SKIPPED+=("iOS protected file (no iphonesimulator SDK in this Xcode)")
        return 0
    fi
    if ! xcrun simctl list runtimes 2>/dev/null | grep -q "iOS"; then
        SKIPPED+=("iOS protected file (no iOS simulator runtime installed)")
        return 0
    fi
    run_scoped "iOS protected file" \
        "Source/Platform/iOS/ProtectedFile.h Source/UbiquittyKit/Swift/ProtectedFile.swift Source/Platform/POSIX/SystemPAL.cpp Tests/Platform/test_ios_protected_file.cpp Tests/Platform/test_ios_protected_file_probe.swift Tests/Harness.h Scripts/run-ios-protected-file-tests.sh Scripts/ios-simulator.sh Scripts/build-root.sh Scripts/ubq-library.sh" \
        ./Scripts/run-ios-protected-file-tests.sh
}

# ubiquitty-kit's own tiers: the shared families of ubiquitty-core that judge any
# repository's tree, and the kit's arms. The host, agent, PGO and wasm gates
# judge Core's binaries and are ubiquitty-core's.
# What the monorepo's quick tier runs for a change to the kit's paths and the kit's
# list cannot, said out loud so a green run does not read as covering them. Each
# is named only when the change reaches its scope.
kit_gate_not_in_this_list() {
    local changed
    changed="$(ubq_changed_with_libraries 2>/dev/null)" || return 0
    case "$TIER" in
        linux | full) ;;
        *)
            if grep -qE '^Source/(Platform/Linux|Core|Base|PAL)/|^Libraries/ubiquitty-core$' <<<"$changed"; then
                SKIPPED+=("Linux compile (the container build is the linux tier: UBIQUITTY_PREPUSH=linux)")
            fi
            ;;
    esac
    if grep -qE '^Source/(UbiquittyRenderKit|UbiquittyKit|Platform/macOS|Core/Rendering)/|^Libraries/ubiquitty-core$' <<<"$changed"; then
        SKIPPED+=("renderer snapshots (the harness reads the goldens of the three repositories together; the app's checkout runs it)")
        SKIPPED+=("core builder frames (needs the app's binary; the app's list runs it)")
    fi
}

kit_tier() {
    case "$TIER" in
        lint) core_gate_style_without_builds; core_gate_commit_rules ;;
        quick | default) core_gate_style; core_gate_commit_rules; kit_gate_apple; kit_gate_renderer_drivers; kit_gate_ios; kit_gate_tests; kit_gate_not_in_this_list ;;
        ctest) core_gate_style; core_gate_commit_rules; kit_gate_apple; kit_gate_renderer_drivers; kit_gate_ios; kit_gate_tests; kit_gate_ctest; kit_gate_not_in_this_list ;;
        linux) core_gate_style; core_gate_commit_rules; kit_gate_apple; kit_gate_renderer_drivers; kit_gate_ios; kit_gate_tests; kit_gate_linux; kit_gate_not_in_this_list ;;
        full) core_gate_style; core_gate_commit_rules; kit_gate_apple; kit_gate_renderer_drivers; kit_gate_ios; kit_gate_tests; kit_gate_ctest; kit_gate_linux; kit_gate_not_in_this_list ;;
        *)
            echo "pre-push gates: unknown tier '$TIER' (want lint|quick|ctest|linux|full)" >&2
            exit 1
            ;;
    esac
}

# Tests/ COMPILES, and the tests this branch can break RUN. No arm build compiles
# Tests/, so a test file can be unable to compile behind a green arm.
kit_gate_tests() {
    run_scoped "Tests/ compiles" \
        "Source Tests CMakeLists.txt Scripts/cmake cmake Scripts/build-tests.sh Scripts/check-build-reached.py Scripts/build-root.sh Scripts/build_root.py Scripts/build-jobs.sh Scripts/build_jobs.py Scripts/ubq-library.sh" \
        ./Scripts/build-tests.sh
    run_scoped "tests reaching the diff" \
        "Source Tests CMakeLists.txt cmake Scripts Tools Docs" \
        ./Scripts/check-tests-reaching-the-diff.py "$(python3 "$UBQ_CORE_ROOT/Scripts/build_root.py")/BuildHostTests/ctest" --jobs "$JOBS"
}

# The complete suite is selected by the ctest and full tiers.
kit_gate_ctest() {
    run "ctest suite" ./Scripts/run-tests.sh
}

# The kit's Linux libraries and host tests, in the container the Linux tier
# runs. Absent docker is SKIPPED, counted as having checked nothing.
kit_gate_linux() {
    if [ "${UBIQUITTY_LINUX_GATE:-on}" = "off" ]; then
        SKIPPED+=("linux build (paused; UBIQUITTY_LINUX_GATE=off pauses it)")
        printf '  %-34s %s\n' "linux build" "PAUSED (UBIQUITTY_LINUX_GATE=off)"
        return
    fi
    if ! command -v docker >/dev/null 2>&1; then
        SKIPPED+=("linux build (no docker; install OrbStack or Docker Desktop)")
        printf '  %-34s %s\n' "linux build" "SKIPPED (no docker)"
        return
    fi
    run "kit on Linux" ./Scripts/run-linux.sh test
}
