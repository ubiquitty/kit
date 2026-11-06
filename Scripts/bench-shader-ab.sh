#!/bin/bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

# bench-shader-ab.sh — time one of the terminal's shading passes on the GPU,
# two shader revisions against each other.
#
#   ./Scripts/bench-shader-ab.sh <refA> <refB> [grid|cell|glyph|blit|copy|clear] [fraction] [rounds]
#
# refA/refB name any git revision, or WORKTREE for the file as it sits now:
#
#   ./Scripts/bench-shader-ab.sh main WORKTREE grid      # what a branch costs
#   ./Scripts/bench-shader-ab.sh main main glyph          # the null control
#   ./Scripts/bench-shader-ab.sh main main blit           # one pass's absolute cost
#
# The shader includes Core's headers, read from the ubiquitty-core checkout
# (UBQ_CORE_ROOT, else Libraries/ubiquitty-core, else this checkout when it
# holds Core too). From this checkout they are taken at each arm's ref. From
# another they are taken as its working tree holds them, the same for both arms,
# so the two arms differ only by the shader's own revision.
#
# `grid` is the default because it encodes cells and glyphs into one pass, which
# is what a frame records. The single-pass modes each charge themselves a full
# load and store of the render target, so their figures do not add up to a frame
# and a pass timed alone can be bound by something it is not bound by in one.
#
# Run the null control first. Whichever arm is measured second can read faster
# on a busy machine; the harness alternates the order per round so that
# cancels, and refA-vs-refA is what proves it did on the day.
#
# The harness renders both arms once and compares every pixel before it times
# anything, because a shader that is faster because it draws less is not
# faster. It also counts the ink, so two arms cannot agree by both drawing
# nothing into a target no one looked at.
#
# The passes are driven with a synthetic screen at a fixed size, so the
# absolute milliseconds describe this corpus rather than a session. The ratio
# is the number to read.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034  # read by ubq-library.sh
ROOT="${root}"
# shellcheck source=Scripts/ubq-library.sh
. "${root}/Scripts/ubq-library.sh"
core="$(cd "${UBQ_CORE_ROOT}" && pwd)"
shader="Source/UbiquittyRenderKit/UBShaders.metal"
out="${root}/BuildBench/shader-ab"

refA="${1:-main}"
refB="${2:-WORKTREE}"
pass="${3:-grid}"
fraction="${4:-}"
rounds="${5:-21}"

if [[ -z "${fraction}" ]]; then
    fraction=$([[ "${pass}" == "glyph" || "${pass}" == "grid" ]] && echo 0.4 || echo 0.0)
fi

mkdir -p "${out}"

# One repository path with its `.` and `..` segments folded, refusing a path
# that climbs out of the checkout.
normalise() { # <path>
    local path="$1" pattern='^(.*/)?([^/]+)/\.\./(.*)$'
    path="${path//\/.\//\/}"
    while [[ "${path}" =~ ${pattern} ]] && [[ "${BASH_REMATCH[2]}" != ".." ]]; do
        path="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
    done
    case "/${path}/" in
        */../*) echo "bench-shader-ab.sh: $1 leaves the checkout" >&2; return 1 ;;
    esac
    printf '%s\n' "${path}"
}

# Whether <path> is a file at <ref> in <checkout>.
present() { # <checkout> <ref> <path>
    if [[ "$2" == "WORKTREE" ]]; then
        [[ -f "$1/$3" ]]
    else
        git -C "$1" cat-file -e "$2:$3" 2>/dev/null
    fi
}

# <path> at <ref> in <checkout>.
content() { # <checkout> <ref> <path>
    if [[ "$2" == "WORKTREE" ]]; then
        cat "$1/$3"
    else
        git -C "$1" show "$2:$3"
    fi
}

# Materialises the shader at one ref under <destination>, with every file it
# includes by a quoted path, transitively. A quoted include resolves as the
# compiler resolves it: beside the including file, then under Core's Source
# root, the one directory the compile below names with -I. The shader's own
# files land at their paths in this checkout and Core's under core/. A copy on
# its own does not compile, and a copy that found the headers in this working
# tree would time one ref's shader against the other's headers.
fetch() { # <ref> <destination>
    local ref="$1" destination="$2" coreRef="$1" pending="shader ${shader}"$'\n' seen=$'\n'
    local entry side path checkout from target include resolved
    [[ "${core}" == "${root}" ]] || coreRef="WORKTREE"
    rm -rf "${destination}"
    while [[ -n "${pending}" ]]; do
        entry="${pending%%$'\n'*}"
        pending="${pending#*$'\n'}"
        case "${seen}" in *$'\n'"${entry}"$'\n'*) continue ;; esac
        seen="${seen}${entry}"$'\n'
        side="${entry%% *}"
        path="${entry#* }"
        if [[ "${side}" == "shader" ]]; then
            checkout="${root}" from="${ref}" target="${destination}/${path}"
        else
            checkout="${core}" from="${coreRef}" target="${destination}/core/${path}"
        fi
        mkdir -p "$(dirname "${target}")"
        content "${checkout}" "${from}" "${path}" > "${target}"
        while IFS= read -r include; do
            resolved="$(normalise "$(dirname "${path}")/${include}")"
            if present "${checkout}" "${from}" "${resolved}"; then
                pending="${pending}${side} ${resolved}"$'\n'
            else
                pending="${pending}core $(normalise "Source/${include}")"$'\n'
            fi
        done < <(sed -n 's/^[[:space:]]*#[[:space:]]*include[[:space:]]*"\([^"]*\)".*/\1/p' \
            "${target}")
    done
}

fetch "${refA}" "${out}/A"
fetch "${refB}" "${out}/B"
xcrun metal -O2 -I "${out}/A/core/Source" -o "${out}/A.metallib" "${out}/A/${shader}"
xcrun metal -O2 -I "${out}/B/core/Source" -o "${out}/B.metallib" "${out}/B/${shader}"

if diff -r -q "${out}/A" "${out}/B" > /dev/null; then
    echo "note: ${refA} and ${refB} hold the same shader and includes — this is a null control run"
fi

xcrun swiftc -O -parse-as-library -swift-version 6 -warnings-as-errors \
    -o "${out}/bench_shaders" "${root}/Tests/Performance/bench_shaders.swift"

echo "A = ${refA}   B = ${refB}   pass = ${pass}"
"${out}/bench_shaders" "${out}/A.metallib" "${out}/B.metallib" \
    "${pass}" "${fraction}" "${rounds}" "${@:6}"
