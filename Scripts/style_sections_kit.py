#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""style_sections_kit — the sections ubiquitty-kit owns.

check-style.py loads this table beside ubiquitty-core's in a checkout that holds
ubiquitty-kit's files. A section runs in ubiquitty-kit's checkout, and in a checkout that
holds every repository.
"""

REPOSITORY = "kit"

HAND = {}

SECTIONS = (
    {
        "title": 'the atlas pin window outlasts the frames in flight (Scripts/check-inflight-depths.py)',
        "after": 'module boundaries (Scripts/check-boundaries.py)',
        "kind": "gate",
        "gate": 'check-inflight-depths.py',
        "command": ['./Scripts/check-inflight-depths.py'],
        "ok": 'ok',
        "bad": 'all',
        "fail": None,
    },
    {
        "title": 'a shared Apple source imports no platform-only module (Scripts/check-shared-kit-imports.py)',
        "after": 'the Welcome icon Core embeds is the committed PNGs (Scripts/export-welcome-icon.py --check)',
        "kind": "gate",
        "gate": 'check-shared-kit-imports.py',
        "command": ['python3', './Scripts/check-shared-kit-imports.py'],
        "ok": 'all',
        "bad": 'all',
        "fail": None,
    },
    {
        "title": 'an adopted terminal seeds its cursor policy (Scripts/check-adopted-term-cursor.py)',
        "after": 'Swift gains no new raw pointer (Scripts/check-swift-unsafe.py)',
        "kind": "gate",
        "gate": 'check-adopted-term-cursor.py',
        "command": ['python3', './Scripts/check-adopted-term-cursor.py'],
        "ok": 'all',
        "bad": 'all',
        "fail": None,
    },
)
