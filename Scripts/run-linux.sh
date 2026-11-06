#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

#
# run-linux.sh — run a command on Linux from macOS, natively, over this checkout.
#
# The Linux libraries need GTK 4 and Vulkan development files, which do not
# exist on macOS. Core's Scripts/run-linux.sh provides the container that has
# them; this runs it with this checkout bind-mounted in place of Core's.
#
# Usage:
#   Scripts/run-linux.sh                    build the Linux libraries
#   Scripts/run-linux.sh test               build and run the kit's host tests on Linux
#   Scripts/run-linux.sh shell              interactive shell in the container
#   Scripts/run-linux.sh <command…>         run any command in the repo root
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/ubq-library.sh
. "$ROOT/Scripts/ubq-library.sh"
CORE="$UBQ_CORE_ROOT"
export UBIQUITTY_LINUX_ROOT="$ROOT"
case "${1:-build}" in
    build) exec "$CORE/Scripts/run-linux.sh" ./Scripts/build-linux.sh ;;
    test) exec "$CORE/Scripts/run-linux.sh" ./Scripts/build-linux.sh --test ;;
    *) exec "$CORE/Scripts/run-linux.sh" "$@" ;;
esac
