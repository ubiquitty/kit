#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Plant missing header dependencies in mixed Swift/C++ CMake targets."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
SPEC = importlib.util.spec_from_file_location("swift_core_dependencies", ROOT / "Scripts/check-swift-modules-depend-on-core.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class SwiftCoreDependencies(unittest.TestCase):
    def checkTarget(self, target, *, stamp, interop=True, commentedStamp=False):
        source = f'add_library({target} SHARED "probe/LayoutProbe.swift" "probe/ArchiveLayout.cpp")\n'
        if interop:
            source += f'target_compile_options({target} PRIVATE "-cxx-interoperability-mode=default")\n'
        if stamp or commentedStamp:
            source += ("# " if commentedStamp else "") + f'target_sources({target} PRIVATE "${{UBIQUITTY_SWIFT_INTEROP_STAMP}}")\n'
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "CMakeLists.txt").write_text(source)
            findings, covered, exempt = [], set(), set()
            verdict = GATE.checkOneList(directory, "CMakeLists.txt", set(), findings, covered, exempt)
        return verdict, findings, covered, exempt

    def testMixedTargetsRequireTheStampWithoutAModuleName(self):
        for target in ("layout-probe", "${target}"):
            with self.subTest(target=target):
                verdict, findings, covered, _ = self.checkTarget(target, stamp=False)
                self.assertTrue(verdict or findings)
                self.assertFalse(covered)

    def testStampedMixedTargetsPass(self):
        for target in ("layout-probe", "${target}"):
            with self.subTest(target=target):
                verdict, findings, covered, _ = self.checkTarget(target, stamp=True)
                self.assertIsNone(verdict)
                self.assertEqual(findings, [])
                self.assertEqual(len(covered), 1)

    def testACommentedDependencyStillFails(self):
        verdict, findings, covered, _ = self.checkTarget("${target}", stamp=False, commentedStamp=True)
        self.assertTrue(verdict or findings)
        self.assertFalse(covered)

    def testPureSwiftNeedsNoCoreDependency(self):
        verdict, findings, covered, exempt = self.checkTarget("pure-swift", stamp=False, interop=False)
        self.assertIsNone(verdict)
        self.assertEqual(findings, [])
        self.assertFalse(covered)
        self.assertEqual(len(exempt), 1)


if __name__ == "__main__":
    unittest.main()
