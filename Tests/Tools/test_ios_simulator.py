#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Pruning a missing checkout must leave active simulator sessions alone."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RuntimeTests(unittest.TestCase):
    def runtime(self, version, model="iPhone 18 Pro", available=True):
        return {"name": "iOS " + version, "version": version, "identifier": "runtime-" + version,
                "isAvailable": available, "supportedDeviceTypes": [{"name": model}]}

    def selected(self, sdk, runtimes):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "xcrun"
            binary.write_text("#!/usr/bin/env python3\nimport sys\n"
                              f"sdk = {sdk!r}\nruntimes = {json.dumps({'runtimes': runtimes})!r}\n"
                              "if sys.argv[1:] == ['--sdk', 'iphonesimulator', '--show-sdk-version']:\n"
                              "    print(sdk)\n"
                              "elif sys.argv[1:] == ['simctl', 'list', 'runtimes', '-j']:\n"
                              "    print(runtimes)\n"
                              "else:\n"
                              "    raise SystemExit(2)\n")
            binary.chmod(0o700)
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                               UBQ_IOS_DEVICE_TYPE="iPhone 18 Pro")
            script = os.environ.get("UBQ_IOS_SIMULATOR_SCRIPT", str(ROOT / "Scripts/ios-simulator.sh"))
            result = subprocess.run(["bash", "-c", '. "$1"; ubq_ios_newest_runtime', "fixture", script],
                                    env=environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout.strip()

    def test_runtime_does_not_exceed_the_selected_sdk(self):
        self.assertEqual(self.selected("27.1", [self.runtime("27.0"), self.runtime("27.1"), self.runtime("27.2")]),
                         "runtime-27.1")

    def test_selection_is_numeric_and_independent_of_listing_order(self):
        self.assertEqual(self.selected("27.10", [self.runtime("27.10"), self.runtime("27.9"), self.runtime("27.2")]),
                         "runtime-27.10")

    def test_device_must_be_supported_by_the_runtime(self):
        self.assertEqual(self.selected("27.1", [self.runtime("27.0"), self.runtime("27.1", model="iPhone Duo"), self.runtime("27.2")]),
                         "runtime-27.0")

    def test_unavailable_and_too_new_runtimes_do_not_fall_back(self):
        self.assertEqual(self.selected("27.1", [self.runtime("27.0", available=False), self.runtime("27.2")]), "")

    def test_missing_device_support_does_not_fall_back(self):
        self.assertEqual(self.selected("27.1", [self.runtime("27.1", model="iPhone Duo")]), "")

    def test_equivalent_patch_version_is_accepted(self):
        self.assertEqual(self.selected("27.1", [self.runtime("27.1.0")]), "runtime-27.1.0")


class OwnershipTests(unittest.TestCase):
    def test_only_shutdown_devices_from_missing_checkouts_are_pruned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            devices = [{"udid": state, "name": "ubq-ios-test-" + letter * 28, "state": state}
                       for state, letter in [("Booted", "a"), ("Booting", "b"), ("Shutdown", "c")]]
            devices.append({"udid": "existing", "name": "ubq-ios-test-" + "d" * 28, "state": "Shutdown"})
            devices.append({"udid": "unrelated", "name": "my-device", "state": "Shutdown"})
            (root / "devices.json").write_text(json.dumps({"devices": {"runtime": devices}}))
            (root / "events").touch()
            (root / "Library/Developer/Xcode/DerivedData" / ("Ubiquitty-" + "d" * 28)).mkdir(parents=True)
            binary = root / "bin/xcrun"
            binary.parent.mkdir()
            binary.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
root = pathlib.Path(os.environ["SIM_FIXTURE"])
if sys.argv[1:4] == ["simctl", "list", "devices"]:
    print((root / "devices.json").read_text())
else:
    with (root / "events").open("a") as stream: stream.write(" ".join(sys.argv[1:]) + "\\n")
''')
            binary.chmod(0o700)
            script = os.environ.get("UBQ_IOS_SIMULATOR_SCRIPT", str(ROOT / "Scripts/ios-simulator.sh"))
            environment = dict(os.environ, SIM_FIXTURE=str(root), HOME=str(root),
                               PATH=str(binary.parent) + os.pathsep + os.environ["PATH"])
            result = subprocess.run(["bash", "-c", '. "$1"; ubq_ios_prune_simulators', "fixture", script],
                                    env=environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / "events").read_text().splitlines(),
                             ["simctl shutdown Shutdown", "simctl delete Shutdown"])


if __name__ == "__main__":
    unittest.main()
