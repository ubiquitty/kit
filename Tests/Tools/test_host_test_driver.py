#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Exercises the test driver's configuration handoff without compiling a product."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class WorkflowCachePaths(unittest.TestCase):
    def test_cache_paths_resolve_from_preceding_canonical_roots(self):
        core = Path(os.environ.get("UBQ_CORE_ROOT") or ROOT / "Libraries/ubiquitty-core")
        spec = importlib.util.spec_from_file_location("workflow_cache_paths", core / "Tests/Tools/test_draft_workflows.py")
        workflow_tests = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(workflow_tests)
        self.assertEqual(workflow_tests.cache_path_problems(ROOT), [])
        self.assertEqual(workflow_tests.container_cache_problems(ROOT), [])


class CTestExecutionOwnership(unittest.TestCase):
    def registration(self, *, native=True, advertise=True, remove_filter=False, record_native=True, preflight=""):
        core = Path(os.environ.get("UBQ_CORE_ROOT") or ROOT / "Libraries/ubiquitty-core")
        temporary = tempfile.TemporaryDirectory(prefix="ubiquitty-kit-test-ownership-")
        self.addCleanup(temporary.cleanup)
        source = Path(temporary.name)
        scripts = source / "Scripts"
        scripts.mkdir()
        driver = scripts / "run-tests.sh"
        stanzas = ["fixture_other", "swift_cxx_exports", "test_coverage_floor"] + (["test_rich_text_native_geometry"] if advertise else [])
        driver.write_text("#!/bin/sh\nprintf '%s\\n' " + " ".join(stanzas) + "\n")
        driver.chmod(0o755)
        owner = (ROOT / "Tests/CMakeLists.txt").read_text()
        start = owner.index("ubiquitty_read_shell_stanzas(_ubq_kit_stanzas ")
        end = owner.index("add_test(NAME test_ios_simulator_ownership", start)
        scheduling = owner[start:end]
        if remove_filter:
            scheduling = scheduling.replace("    list(REMOVE_ITEM _ubq_kit_stanzas test_rich_text_native_geometry)\n", "")
        cmake = [
            "cmake_minimum_required(VERSION 3.20)",
            "project(TestOwnership NONE)",
            "enable_testing()",
            f'set(UBIQUITTY_CORE_SOURCE_DIR "{core}")',
            f'set(UBIQUITTY_KIT_SOURCE_DIR "{source}")',
            f'set(Python3_EXECUTABLE "{sys.executable}")',
            f'include("{core}/Scripts/cmake/UbiquittyTests.cmake")',
        ]
        if native:
            for name in ("test_rich_text_native_geometry", "test_rich_text_font_catalog",
                         "test_resume_sealer", "test_resume_sealer_cxx"):
                cmake.append(f"add_test(NAME {name} COMMAND cmake -E true)")
                cmake.append(f"ubiquitty_set_test_entry_properties({name})")
            if record_native:
                start = owner.index("    set_property(DIRECTORY APPEND PROPERTY UBIQUITTY_HOST_TESTS\n")
                end = owner.index("\nendif()", start)
                cmake.append(owner[start:end])
        cmake += [scheduling, "ubiquitty_finish_host_tests()"]
        (source / "CMakeLists.txt").write_text("\n".join(cmake) + "\n")
        build = source / "build"
        configured = subprocess.run(["cmake", "-S", str(source), "-B", str(build), "-G", "Ninja"],
                                    env={**os.environ, "UBQ_CI_PREFLIGHT_COMPLETE": preflight},
                                    capture_output=True, text=True, timeout=30)
        self.assertEqual(configured.returncode, 0, configured.stdout + configured.stderr)
        listing = subprocess.run(["ctest", "--test-dir", str(build), "--show-only=json-v1"],
                                 capture_output=True, text=True, timeout=15, check=True)
        tests = json.JSONDecoder().raw_decode(listing.stdout)[0]["tests"]
        return {test["name"]: test for test in tests}, (build / "ctest-covered.txt").read_text().splitlines()

    def assert_geometry_has_one_covered_owner(self, tests, covered):
        self.assertEqual(sum(name in tests for name in
                             ("test_rich_text_native_geometry", "shell_test_rich_text_native_geometry")), 1)
        self.assertIn("test_rich_text_native_geometry", covered)

    def test_native_geometry_runs_once_and_the_outer_driver_keeps_all_swift_entries_covered(self):
        tests, covered = self.registration()
        self.assert_geometry_has_one_covered_owner(tests, covered)
        self.assertIn("test_rich_text_native_geometry", tests)
        properties = {row["name"]: row["value"] for row in tests["test_rich_text_native_geometry"]["properties"]}
        self.assertEqual(properties["TIMEOUT"], 60.0)
        self.assertIn("ubq_build_fixture", properties["FIXTURES_REQUIRED"])
        for name in ("test_rich_text_font_catalog", "test_resume_sealer", "test_resume_sealer_cxx"):
            self.assertIn(name, tests)
            self.assertIn(name, covered)

    def test_geometry_keeps_its_shell_owner_without_a_native_entry(self):
        tests, covered = self.registration(native=False)
        self.assert_geometry_has_one_covered_owner(tests, covered)
        self.assertIn("shell_test_rich_text_native_geometry", tests)

    def test_geometry_census_rejects_duplicate_missing_and_unrecorded_owners(self):
        for arguments in ({"remove_filter": True}, {"native": False, "advertise": False}, {"record_native": False}):
            with self.subTest(arguments=arguments):
                tests, covered = self.registration(**arguments)
                with self.assertRaises(AssertionError):
                    self.assert_geometry_has_one_covered_owner(tests, covered)

    def control_calls(self, preflight, filters=()):
        core = Path(os.environ.get("UBQ_CORE_ROOT") or ROOT / "Libraries/ubiquitty-core")
        with tempfile.TemporaryDirectory(prefix="ubiquitty-kit-control-dispatch-") as temporary:
            source = Path(temporary).resolve()
            (source / "Scripts").mkdir()
            # Execute the production adapter. Its self-test still has to reach
            # Kit's own backend; the tool stand-in records that exact command.
            shutil.copy2(ROOT / "Scripts/check-coverage-floor.sh", source / "Scripts/check-coverage-floor.sh")
            tools = source / "tools"
            tools.mkdir()
            trace = source / "calls"
            python = tools / "python3"
            python.write_text(f'#!{sys.executable}\nimport json,os,sys\n'
                              "with open(os.environ['CONTROL_TRACE'], 'a') as output:\n"
                              "    output.write(json.dumps(sys.argv[1:]) + '\\n')\n")
            python.chmod(0o755)
            script = '''
set -euo pipefail
ROOT="$1" CORE_ROOT="$2" FUZZ_ONLY=0 SKIP_CTEST_COVERED=0
CTEST_COVERED=/no-covered-list CTEST_COVERED_CONSULTED=0 FILTERS_MATCHED=" " RAN=0
. "$CORE_ROOT/Scripts/run-tests-lib.sh"
ubq_record_own_stanzas $'swift_cxx_exports\ntest_coverage_floor'
stanzas="$3"
shift 3
FILTERS=("$@")
. "$stanzas"
'''
            result = subprocess.run(["bash", "-c", script, "fixture", str(source), str(core),
                                     str(ROOT / "Scripts/run-tests-stanzas-kit.sh"), *filters],
                                    env={**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                                         "UBQ_CI_PREFLIGHT_COMPLETE": preflight, "CONTROL_TRACE": str(trace)},
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []

    def test_preflight_controls_are_not_replayed_by_ctest_or_the_unfiltered_outer_loop(self):
        tests, covered = self.registration(preflight="1")
        for name in ("swift_cxx_exports", "test_coverage_floor"):
            self.assertNotIn("shell_" + name, tests)
            self.assertNotIn(name, covered)
        self.assertIn("shell_fixture_other", tests)
        self.assert_geometry_has_one_covered_owner(tests, covered)
        self.assertEqual(self.control_calls("1"), [])
        core = Path(os.environ.get("UBQ_CORE_ROOT") or ROOT / "Libraries/ubiquitty-core")
        sys.path.insert(0, str(core / "Scripts"))
        try:
            spec = importlib.util.spec_from_file_location("kit_preflight_controls", core / "Scripts/run-gate-self-tests.py")
            aggregate = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(aggregate)
        finally:
            sys.path.pop(0)
        aggregate.REPO = str(ROOT)
        discovered = set(aggregate.discover())
        for name in ("check-swift-cxx-exports.py", "check-coverage-floor.py", "check-coverage-floor.sh"):
            self.assertIn((name, "--self-test"), discovered)

    def test_pure_controls_still_execute_locally_and_when_explicitly_requested(self):
        tests, covered = self.registration()
        aliases = ("swift_cxx_exports", "test_coverage_floor")
        for name in aliases:
            self.assertIn("shell_" + name, tests)
            self.assertIn(name, covered)
        for preflight, filters in (("", ()), ("1", aliases), ("", aliases)):
            with self.subTest(preflight=preflight, filters=filters):
                calls = self.control_calls(preflight, filters)
                self.assertEqual([Path(call[0]).name for call in calls],
                                 ["check-swift-cxx-exports.py", "check-coverage-floor.py"])
                self.assertTrue(all(call[1:] == ["--self-test"] for call in calls))


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
            NO_CTEST="0", CTEST_BUILD_DIR=str(self.build / "ctest"),
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
