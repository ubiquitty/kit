#!/usr/bin/env bash
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(python3 "$ROOT/Libraries/ubiquitty-core/Scripts/build_root.py" "$ROOT")"
exec python3 "$ROOT/Scripts/check-coverage-floor.py" --root "$ROOT" \
    --summary "$BUILD/BuildHostTests/coverage/summary.txt"
