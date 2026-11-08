#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Exercises the real renderer drivers' compiler arguments without compiling."""

import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
DRIVERS = ("font-catalogue", "glyph-rasterizer", "glyph-atlas", "frame-instances",
           "frame-encoder", "terminal-renderer")


class SwiftDriverTarget(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ubq Swift driver target ")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.kit = self.directory / "kit with spaces"
        scripts = self.kit / "Scripts"
        scripts.mkdir(parents=True)
        for name in ("ubq-library.sh", "renderkit-sources.sh", "swift-driver-typecheck.sh",
                     *(f"check-{driver}.sh" for driver in DRIVERS)):
            shutil.copyfile(ROOT / "Scripts" / name, scripts / name)
        cmake = scripts / "cmake"
        cmake.mkdir()
        shutil.copyfile(ROOT / "Scripts/cmake/AppleSharedSwift.cmake", cmake / "AppleSharedSwift.cmake")
        self.core = self.kit / "Libraries/ubiquitty-core"
        self.writeCore(self.core, "26.2")
        self.build = self.directory / "build with spaces"
        metallib = self.build / "metallib/default.metallib"
        metallib.parent.mkdir(parents=True)
        metallib.write_bytes(b"fixture shader library")
        tools = self.directory / "tools"
        tools.mkdir()
        self.calls = self.directory / "compiler calls.jsonl"
        xcrun = tools / "xcrun"
        xcrun.write_text(f"#!{sys.executable}\n" + '''import json
import os
from pathlib import Path
import sys

with Path(os.environ["DRIVER_FIXTURE_CALLS"]).open("a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
if os.environ.get("DRIVER_FIXTURE_DIAGNOSTIC") and "-warnings-as-errors" in sys.argv:
    print("fixture compiler rejected a diagnostic", file=sys.stderr)
    sys.exit(1)
''')
        xcrun.chmod(0o755)
        self.environment = dict(os.environ, PATH=f"{tools}{os.pathsep}{os.environ['PATH']}",
                                UBQ_BUILD_ROOT=str(self.build), UBIQUITTY_DRIVER_TYPECHECK_ONLY="1",
                                DRIVER_FIXTURE_CALLS=str(self.calls))
        for name in ("UBQ_CORE_ROOT", "UBQ_KIT_ROOT", "UBQ_TESTS_ROOT", "UBIQUITTY_CORE_SOURCE_DIR",
                     "UBIQUITTY_KIT_SOURCE_DIR", "DRIVER_FIXTURE_DIAGNOSTIC"):
            self.environment.pop(name, None)

    def writeCore(self, core, floor):
        scripts = core / "Scripts"
        scripts.mkdir(parents=True)
        selected = ROOT / "Libraries/ubiquitty-core/Scripts"
        for name in ("build-root.sh", "ccache-env.sh"):
            shutil.copyfile(selected / name, scripts / name)
        (scripts / "macos-deployment-target.txt").write_text(f"cxx=13.3\napp={floor}\n")

    def runDriver(self, driver):
        self.calls.unlink(missing_ok=True)
        checked = subprocess.run(["bash", str(self.kit / "Scripts" / f"check-{driver}.sh")],
                                 env=self.environment, capture_output=True, text=True, timeout=20)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        return checked, calls

    def assertCompilerArguments(self, driver, floor):
        checked, calls = self.runDriver(driver)
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertEqual(checked.stderr, "")
        self.assertEqual(len(calls), 2 if driver == "terminal-renderer" else 1)
        self.assertIn("-typecheck", calls[-1])
        for arguments in calls:
            self.assertEqual(arguments[0], "swiftc")
            self.assertEqual(arguments.count("-target"), 1, arguments)
            self.assertEqual(arguments[arguments.index("-target") + 1],
                             f"{platform.machine()}-apple-macos{floor}")
            self.assertEqual(arguments.count("-warnings-as-errors"), 1, arguments)

    def testEachDriverAndOverlayUseTheConfiguredSwiftFloor(self):
        for driver in DRIVERS:
            with self.subTest(driver=driver):
                self.assertCompilerArguments(driver, "26.2")

    def testExplicitExternalCoreOwnsTheFloor(self):
        external = self.directory / "external Core with spaces"
        self.writeCore(external, "25.8")
        self.environment["UBQ_CORE_ROOT"] = str(external)
        for driver in DRIVERS:
            with self.subTest(driver=driver):
                self.assertCompilerArguments(driver, "25.8")

    def testMissingSwiftFloorRefusesBeforeCompilerInvocation(self):
        (self.core / "Scripts/macos-deployment-target.txt").write_text("cxx=13.3\n")
        for driver in DRIVERS:
            with self.subTest(driver=driver):
                checked, calls = self.runDriver(driver)
                self.assertNotEqual(checked.returncode, 0, checked.stdout + checked.stderr)
                self.assertIn("read no app floor", checked.stderr)
                self.assertEqual(calls, [])

    def testCompilerDiagnosticCannotBecomeASuccessfulDriver(self):
        self.environment["DRIVER_FIXTURE_DIAGNOSTIC"] = "1"
        for driver in DRIVERS:
            with self.subTest(driver=driver):
                checked, calls = self.runDriver(driver)
                self.assertNotEqual(checked.returncode, 0, checked.stdout + checked.stderr)
                self.assertEqual(len(calls), 1)
                self.assertIn("fixture compiler rejected a diagnostic", checked.stderr)
                self.assertNotIn("ok (type-checked", checked.stdout)


if __name__ == "__main__":
    unittest.main()
