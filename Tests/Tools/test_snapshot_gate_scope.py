#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Runs the real Swift snapshot selector under pipefail with bounded fixture input."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def gate_library_function(name):
    """A function of Core's gate library, as the hook defines it."""
    source = (ROOT / "Libraries/ubiquitty-core/Scripts/pre-push-gates-lib.sh").read_text()
    start = source.index(name + "() {\n")
    return source[start:source.index("\n}\n", start) + 3]


class SwiftSnapshotScope(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ubiquitty-swift-snapshot-scope-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.kit = self.directory / "kit"
        self.core = self.directory / "core"
        shader = self.kit / "Source/UbiquittyRenderKit/Fixture.metal"
        shader.parent.mkdir(parents=True)
        shader.write_text('#include "Core/Tek/BeamRaster.h"\n')
        header = self.core / "Source/Core/Tek/BeamRaster.h"
        header.parent.mkdir(parents=True)
        header.write_text("// Fixture shader input.\n")
        source = (ROOT / "Scripts/pre-push-gates-kit.sh").read_text()
        start = source.index("kit_swift_arm_reached() {\n")
        self.function = source[start:source.index("\n}\n", start) + 3]

    def reached(self, changed, *, status=0, select_all=False):
        diff = self.directory / "diff"
        diff.write_text(changed)
        script = '''set -euo pipefail
ubq_changed_with_libraries() {
    cat "$SCOPE_DIFF"
    return "$SCOPE_DIFF_STATUS"
}
'''
        script += gate_library_function("ubq_select_all")
        script += self.function
        script += '''
if kit_swift_arm_reached "$(cat "$SCOPE_DIFF")"; then
    printf 'selected\\n'
else
    printf 'none\\n'
fi
'''
        environment = dict(os.environ, SCOPE_DIFF=str(diff), SCOPE_DIFF_STATUS=str(status),
                           UBQ_KIT_ROOT=str(self.kit), UBQ_CORE_ROOT=str(self.core))
        environment.pop("UBQ_PREPUSH_SELECT", None)
        if select_all:
            environment["UBQ_PREPUSH_SELECT"] = "all"
        checked = subprocess.run(["bash", "-c", script], env=environment, text=True,
                                 capture_output=True, timeout=20)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(checked.stderr, "")
        return checked.stdout == "selected\n"

    def test_large_early_match_consumes_the_whole_changed_list(self):
        suffix = "".join(f"Docs/unrelated-{index:06d}-{'x' * 80}.md\n" for index in range(40000))
        for first in ("Source/Platform/macOS/main.swift", "Source/UbiquittyRenderKit/FrameInstances.swift",
                      "Source/UbiquittyKit/Swift/Surface.swift", "Scripts/cmake/UbiquittyKit.cmake",
                      "Scripts/cmake/AppleSharedSwift.cmake"):
            with self.subTest(path=first):
                self.assertTrue(self.reached(first + "\n" + suffix))

    def test_each_unresolved_dependency_mount_is_conservative(self):
        for path in ("Libraries/ubiquitty-core", "Libraries/ubiquitty-kit"):
            with self.subTest(path=path):
                self.assertTrue(self.reached(path))

    def test_shader_headers_and_snapshot_arguments_keep_their_existing_reach(self):
        for path in ("Source/Core/Tek/BeamRaster.h", "Source/Core/Diagnostics/SnapshotArguments.h",
                     "Source/Core/App/SnapshotRequest.h"):
            with self.subTest(path=path):
                self.assertTrue(self.reached(path))

    def test_unrelated_and_ui_test_paths_remain_unselected(self):
        for path in ("", "Docs/guide.md", "Source/Core/Terminal.cpp",
                     "Source/Platform/macOS/UITest/Scenario.swift", "Libraries/ubiquitty-kit-other"):
            with self.subTest(path=path):
                self.assertFalse(self.reached(path))

    def test_unread_changed_list_preserves_the_existing_refusal(self):
        self.assertFalse(self.reached("", status=128))

    def test_a_run_that_selects_every_gate_reaches_the_arm_whatever_the_diff(self):
        for path, status in (("", 0), ("Docs/guide.md", 0), ("", 128)):
            with self.subTest(path=path, status=status):
                self.assertTrue(self.reached(path, status=status, select_all=True))


if __name__ == "__main__":
    unittest.main()
