#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# run-tests.sh — ubiquitty-kit's test entry point.
#
# The kit's tests that need no app are registered with CTest by Tests/CMakeLists.txt
# and built against ubiquitty-core's library. This script hands those to CTest and
# runs the shell stanzas of Scripts/run-tests-stanzas-kit.sh, written against the
# helpers of ubiquitty-core's Scripts/run-tests-lib.sh.
#
# Usage:
#   ./Scripts/run-tests.sh                 the CTest suite, then every stanza
#   ./Scripts/run-tests.sh --list-stanzas  the shell recipe names accepted here
#   ./Scripts/run-tests.sh swift_cxx_exports test_metal_shader_library
#                                          the named stanzas, without CTest
#   ./Scripts/run-tests.sh --help          show this help
#
# Stanza names and CTest case names are different namespaces. A case is run from
# the tree the driver configures:
#
#   ctest --test-dir "$(python3 Libraries/ubiquitty-core/Scripts/build_root.py .)/BuildHostTests/ctest" -R '^test_selection$'
#
# A stanza that cannot run on this machine says so with a `SKIP:` line and is
# counted as declined in the verdict; UBQ_REQUIRED_TOOLS names the tools an
# environment promises, whose absence fails instead.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/ubq-library.sh
. "$ROOT/Scripts/ubq-library.sh"
LIBRARY_SCRIPTS="$UBQ_CORE_ROOT/Scripts"
# shellcheck source=/dev/null
source "$LIBRARY_SCRIPTS/gate-report-lib.sh"
# shellcheck source=/dev/null
. "$LIBRARY_SCRIPTS/build-jobs.sh"
# Build output lives outside the checkout; see Scripts/build-root.sh in ubiquitty-core.
# shellcheck source=/dev/null
. "$LIBRARY_SCRIPTS/build-root.sh"
# shellcheck source=/dev/null
. "$LIBRARY_SCRIPTS/run-tests-lib.sh"
# shellcheck source=/dev/null
. "$LIBRARY_SCRIPTS/test-run-hygiene.sh"

# State the helpers of run-tests-lib.sh read.
# shellcheck disable=SC2034
FUZZ_ONLY=0
FILTERS=()
FILTERS_MATCHED=" "
BUILD_JOBS="${BUILD_JOBS:-$(ubq_build_jobs)}"
UBQ_STANZA_FILES=("$ROOT"/Scripts/run-tests-stanzas-*.sh)

ubq_list_stanzas() {
    awk -v mode=list -v platform="$(uname -s)" \
        -f "$LIBRARY_SCRIPTS/stanza-declarations.awk" \
        -f "$LIBRARY_SCRIPTS/stanza-inventories.awk" "${UBQ_STANZA_FILES[@]}" | LC_ALL=C sort -u
}

for arg in "$@"; do
    case "$arg" in
        --help|-h) sed -n '/^#!/d; /^[^#]/q; s/^# \{0,1\}//; p' "$0"; exit 0 ;;
        --list-stanzas) ubq_list_stanzas; exit 0 ;;
        --*) echo "run-tests.sh: unknown flag: $arg" >&2; exit 2 ;;
        *) FILTERS+=("$arg") ;;
    esac
done

if [ "${#FILTERS[@]}" -gt 0 ]; then
    ubq_stanzas="$(ubq_list_stanzas)"
    ubq_unmatched=()
    for ubq_filter in "${FILTERS[@]}"; do
        case "$ubq_filter" in
            *[!a-zA-Z_0-9-]*|'') ubq_unmatched+=("$ubq_filter") ;;
            *) printf '%s\n' "$ubq_stanzas" | grep -xF -- "$ubq_filter" >/dev/null || ubq_unmatched+=("$ubq_filter") ;;
        esac
    done
    if [ "${#ubq_unmatched[@]}" -gt 0 ]; then
        printf 'run-tests.sh: not a stanza name:' >&2
        printf ' %q' "${ubq_unmatched[@]}" >&2
        printf '\n  Stanza names: ./Scripts/run-tests.sh --list-stanzas\n' >&2
        exit 1
    fi
fi

# Where a stanza puts its objects and its binary, and the tree CTest runs.
OUT="${UBQ_OUT:-$UBQ_BUILD_ROOT/BuildHostTests}"
CTEST_BUILD_DIR="${CTEST_BUILD_DIR:-$OUT/ctest}"
# shellcheck disable=SC2034
CTEST_COVERED="$CTEST_BUILD_DIR/ctest-covered.txt"
# shellcheck disable=SC2034
CTEST_COVERED_CONSULTED=0

ubq_hygiene_begin
ubq_end_run() {
    local status=$?
    trap - EXIT INT TERM HUP
    if [ "$1" = completed ]; then
        ubq_hygiene_judge run-tests.sh || status=1
    else
        status=$((128 + $1))
    fi
    ubq_hygiene_reap || status=1
    exit "$status"
}
trap 'ubq_end_run completed' EXIT
trap 'ubq_end_run 2' INT
trap 'ubq_end_run 15' TERM
trap 'ubq_end_run 1' HUP

# The build type is named because an unnamed one is not neutral: Release defines
# NDEBUG, which changes the layout of types the tests assert on. The frontend is
# the kit's default for this machine: macOS on a Mac, Linux on Linux.
ubq_configure_ctest_tree() {
    cmake -S "$ROOT" -B "$1" -G Ninja \
        -DUBIQUITTY_CORE_SOURCE_DIR="$UBQ_CORE_ROOT" \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DUBIQUITTY_BUILD_TESTS=ON \
        -DCMAKE_BUILD_TYPE=Debug
}

USE_CTEST=1
if [ "${NO_CTEST:-0}" = "1" ] || [ ${#FILTERS[@]} -gt 0 ]; then
    USE_CTEST=0
fi
SKIP_CTEST_COVERED="${SKIP_CTEST_COVERED:-$USE_CTEST}"

CTEST_FAILED=0
if [ "$USE_CTEST" = "1" ]; then
    echo "=== ctest (CMake-covered tests) ==="
    if ubq_configure_ctest_tree "$CTEST_BUILD_DIR" >/dev/null &&
        "$LIBRARY_SCRIPTS/run-ctest.sh" "$CTEST_BUILD_DIR" -j"${CTEST_JOBS:-8}" --output-on-failure; then
        :
    else
        CTEST_FAILED=1
    fi
fi

RAN=0
SKIPPED=0
SKIPPED_REASONS=()

for ubq_stanza_file in "${UBQ_STANZA_FILES[@]}"; do
    # shellcheck source=/dev/null
    . "$ubq_stanza_file"
done

# A filter that no stanza answered is a typo worth flagging, and a request for
# a stanza must not read as a pass when nothing ran.
ubq_unmatched=()
for ubq_filter in ${FILTERS+"${FILTERS[@]}"}; do
    case "$FILTERS_MATCHED" in *" $ubq_filter "*) ;; *) ubq_unmatched+=("$ubq_filter") ;; esac
done
if [ "${#ubq_unmatched[@]}" -gt 0 ]; then
    echo "run-tests.sh: no stanza answered: ${ubq_unmatched[*]}" >&2
    exit 1
fi
if [ ${#FILTERS[@]} -gt 0 ] && [ "$((RAN + SKIPPED))" -eq 0 ]; then
    echo "run-tests.sh: no tests matched filter: ${FILTERS[*]}" >&2
    exit 1
fi
if [ "$CTEST_FAILED" != 0 ]; then
    echo "run-tests.sh: ctest failed; its failing entries are listed in the ctest section above" >&2
    exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
    echo "run-tests.sh: $SKIPPED stanza(s) declined for want of a dependency" >&2
fi
if [ "$USE_CTEST" = "1" ]; then
    echo "run-tests.sh: PASSED — $RAN ran, $SKIPPED skipped after ctest, whose result is above"
else
    echo "run-tests.sh: PASSED — $RAN ran, $SKIPPED skipped"
fi
if [ "${#SKIPPED_REASONS[@]}" -gt 0 ]; then
    printf '%s\n' ${SKIPPED_REASONS[@]+"${SKIPPED_REASONS[@]}"} \
        | sort | uniq -c \
        | sed -E 's/^ *([0-9]+) /  did not run (\1 stanza(s)): /'
fi
