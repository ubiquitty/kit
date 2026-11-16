#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Exercises the test driver's configuration handoff without compiling a product."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class HostTestDriver(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ubiquitty-host-test-driver-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        scripts = self.directory / "kit/Scripts"
        scripts.mkdir(parents=True)
        for name in ("run-tests.sh", "ubq-library.sh"):
            shutil.copy2(ROOT / "Scripts" / name, scripts / name)
        (scripts / "run-tests-stanzas-fixture.sh").write_text(
            'echo "SHOULD_NOT_RUN_STANZAS"\nexit 91\n')
        tools = self.directory / "tools"
        tools.mkdir()
        self.calls = self.directory / "cmake.json"
        cmake = tools / "cmake"
        cmake.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "pathlib.Path(os.environ['DRIVER_CMAKE_CALLS']).write_text(json.dumps(sys.argv[1:]))\n"
            "print('fixture: configure refused', file=sys.stderr)\n"
            "sys.exit(23)\n")
        cmake.chmod(0o755)
        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("UBQ_", "UBIQUITTY_", "GIT_"))
        }
        self.build = self.directory / "build/subject"
        self.environment.update(
            PATH=str(tools) + os.pathsep + os.environ["PATH"],
            UBQ_CORE_ROOT=str(ROOT / "Libraries/ubiquitty-core"),
            UBQ_BUILD_ROOT=str(self.build),
            DRIVER_CMAKE_CALLS=str(self.calls))
        self.driver = scripts / "run-tests.sh"

    def configure(self):
        checked = subprocess.run(
            ["/bin/bash", str(self.driver)], cwd=self.driver.parents[1],
            env=self.environment, capture_output=True, text=True, timeout=20)
        self.assertTrue(self.calls.exists(), checked.stdout + checked.stderr)
        self.assertNotIn("Traceback", checked.stderr)
        return checked, json.loads(self.calls.read_text())

    def test_external_quic_prefix_survives_the_isolated_subject_build(self):
        prefix = self.directory / "shared cache with 'quotes' and $literal/quic-deps"
        self.environment["UBIQUITTY_QUIC_PREFIX"] = str(prefix)
        _, arguments = self.configure()
        self.assertEqual(
            [value for value in arguments if value.startswith("-DUBIQUITTY_QUIC_PREFIX=")],
            ["-DUBIQUITTY_QUIC_PREFIX=" + str(prefix)])

    def test_missing_or_empty_quic_prefix_uses_this_build_root(self):
        for value in (None, ""):
            with self.subTest(value=value):
                if value is None:
                    self.environment.pop("UBIQUITTY_QUIC_PREFIX", None)
                else:
                    self.environment["UBIQUITTY_QUIC_PREFIX"] = value
                _, arguments = self.configure()
                self.assertIn("-DUBIQUITTY_QUIC_PREFIX=" + str(self.build / "quic-deps"), arguments)

    def test_failed_configuration_stops_before_using_the_unbuilt_test_tree(self):
        checked, arguments = self.configure()
        self.assertEqual(checked.returncode, 1, checked.stdout + checked.stderr)
        self.assertIn("-S", arguments)
        self.assertIn("fixture: configure refused", checked.stderr)
        self.assertIn("ctest configure failed", checked.stderr)
        self.assertNotIn("SHOULD_NOT_RUN_STANZAS", checked.stdout + checked.stderr)


if __name__ == "__main__":
    unittest.main()
