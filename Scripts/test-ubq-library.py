#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""test-ubq-library.py — a kit script finds ubiquitty-core the same way in both languages.

Scripts/ubq_library.py and Scripts/ubq-library.sh give a script of ubiquitty-kit
the checkout of ubiquitty-core: $UBQ_CORE_ROOT, else Libraries/ubiquitty-core
under the kit checkout when that path exists, else the kit checkout itself. This
plants a kit checkout of each shape and holds the two to the same answer.

    python3 Scripts/test-ubq-library.py
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class LibraryRootTests(unittest.TestCase):
    def plant(self, base, library):
        """A kit checkout holding the two scripts under test, with or without a mounted library."""
        checkout = Path(base) / "kit"
        (checkout / "Scripts").mkdir(parents=True)
        for name in ("ubq_library.py", "ubq-library.sh"):
            (checkout / "Scripts" / name).write_bytes((SCRIPTS / name).read_bytes())
        if library:
            (checkout / "Libraries" / "ubiquitty-core" / "Scripts").mkdir(parents=True)
        return checkout

    def environment(self, extra=None):
        environment = {name: value for name, value in os.environ.items() if name != "UBQ_CORE_ROOT"}
        environment.update(extra or {})
        return environment

    def asked_of_python(self, checkout, extra=None):
        finished = subprocess.run(
            [sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import ubq_library; print(ubq_library.CORE_ROOT)",
             str(checkout / "Scripts")],
            capture_output=True, text=True, env=self.environment(extra), check=True)
        return finished.stdout.strip()

    def asked_of_shell(self, checkout, extra=None):
        finished = subprocess.run(
            ["bash", "-c", 'ROOT="$1"; . "$1/Scripts/ubq-library.sh"; printf "%s\\n" "$UBQ_CORE_ROOT"; printf "%s\\n" "${UBQ_SWIFT_INCLUDES[@]}"',
             "_", str(checkout)],
            capture_output=True, text=True, env=self.environment(extra), check=True)
        lines = finished.stdout.splitlines()
        return lines[0], lines[1:]

    def test_a_mounted_library_is_the_core_checkout(self):
        with tempfile.TemporaryDirectory() as base:
            checkout = self.plant(base, library=True)
            expected = str((checkout / "Libraries" / "ubiquitty-core").resolve())
            self.assertEqual(str(Path(self.asked_of_python(checkout)).resolve()), expected)
            root, includes = self.asked_of_shell(checkout)
            self.assertEqual(str(Path(root).resolve()), expected)
            self.assertEqual(includes[0], f"-I{root}/Source")
            self.assertIn(f"-I{checkout}/Source", includes)

    def test_without_a_library_the_checkout_holds_core_itself(self):
        with tempfile.TemporaryDirectory() as base:
            checkout = self.plant(base, library=False)
            self.assertEqual(str(Path(self.asked_of_python(checkout)).resolve()), str(checkout.resolve()))
            root, includes = self.asked_of_shell(checkout)
            self.assertEqual(str(Path(root).resolve()), str(checkout.resolve()))
            # One tree is one set of roots, not the same three twice.
            self.assertEqual(len(includes), 3)

    def test_the_variable_beats_the_mount(self):
        with tempfile.TemporaryDirectory() as base:
            checkout = self.plant(base, library=True)
            elsewhere = Path(base) / "elsewhere"
            elsewhere.mkdir()
            self.assertEqual(self.asked_of_python(checkout, {"UBQ_CORE_ROOT": str(elsewhere)}), str(elsewhere))
            self.assertEqual(self.asked_of_shell(checkout, {"UBQ_CORE_ROOT": str(elsewhere)})[0], str(elsewhere))

    def test_the_librarys_scripts_follow_the_checkouts_own_on_the_import_path(self):
        with tempfile.TemporaryDirectory() as base:
            checkout = self.plant(base, library=True)
            library_scripts = checkout / "Libraries" / "ubiquitty-core" / "Scripts"
            (library_scripts / "shared.py").write_text("WHO = 'library'\n")
            (checkout / "Scripts" / "shared.py").write_text("WHO = 'kit'\n")
            finished = subprocess.run(
                [sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import ubq_library, shared; print(shared.WHO)",
                 str(checkout / "Scripts")],
                capture_output=True, text=True, env=self.environment(), check=True)
            self.assertEqual(finished.stdout.strip(), "kit")


if __name__ == "__main__":
    unittest.main(verbosity=2)
