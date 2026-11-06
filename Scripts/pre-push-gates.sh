#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
#
# Scripts/pre-push-gates.sh — the gates ubiquitty-kit answers to before a push,
# run on this machine. A workflow that is disabled or queued is indistinguishable
# from one that passed: nothing goes red, so the tree looks green while nothing
# has executed.
#
# The shared families are ubiquitty-core's (Scripts/pre-push-gates-core.sh): the
# style and commit-rule gates judge any repository's tree and run here over the
# kit's. The kit's arms are Scripts/pre-push-gates-kit.sh's, the tiers and the
# runner ubiquitty-core's Scripts/pre-push-gates-lib.sh. The host, agent, PGO and
# wasm gates judge Core's binaries and are not in this list.
#
#   TIER=lint    every gate that needs no build                       no toolchain
#   TIER=quick   style + commit rules + the Swift renderer, its drivers, the iOS
#                protected file and the kit's tests
#   TIER=ctest   quick + the kit's ctest suite
#   TIER=linux   quick + the kit's Linux libraries and tests in a container
#   TIER=full    ctest + linux

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=Scripts/ubq-library.sh
. "$ROOT/Scripts/ubq-library.sh"
# shellcheck source=/dev/null
source "$UBQ_CORE_ROOT/Scripts/pre-push-gates-lib.sh"
# shellcheck source=/dev/null
source "$UBQ_CORE_ROOT/Scripts/pre-push-gates-core.sh"
# shellcheck source=Scripts/pre-push-gates-kit.sh
source "$ROOT/Scripts/pre-push-gates-kit.sh"

echo "pre-push gates (tier: $TIER) — the local stand-in for ci.yml" >&2
kit_tier

ubq_pre_push_finish
