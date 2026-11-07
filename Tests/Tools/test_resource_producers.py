#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0
"""Exercises shared generated resources through the real staging helper."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("cmake"), "CMake is unavailable")
class ResourceProducers(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ubq resource producers ")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.source = self.directory / "source"
        self.source.mkdir()
        self.environment = {**os.environ, "CMAKE_BUILD_PARALLEL_LEVEL": "4"}
        self.environment.pop("SDKROOT", None)

    def runCommand(self, *command):
        result = subprocess.run(command, capture_output=True, text=True, env=self.environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def writeFixture(self, producer="shared-resources"):
        (self.source / "input").write_bytes(b"original generated resource")
        (self.source / "ordinary").write_bytes(b"ordinary resource")
        (self.source / "generate.py").write_text(
            "from pathlib import Path\n"
            "import sys\n"
            "source, destination = map(Path, sys.argv[1:])\n"
            "destination.mkdir(parents=True, exist_ok=True)\n"
            "with (destination / 'executions').open('ab') as log:\n"
            "    log.write(b'generated\\n')\n"
            "for name in ('LICENSE', 'licensing.md'):\n"
            "    (destination / name).write_bytes(source.read_bytes())\n")
        (self.source / "CMakeLists.txt").write_text(f'''cmake_minimum_required(VERSION 3.13)
project(ResourceProducerFixture LANGUAGES NONE)
include("{ROOT}/cmake/BundleResources.cmake")
# The fixture has no executable. Only the bundle destination is supplied;
# production staging and its generated-input dependencies remain unchanged.
function(ubiquitty_bundle_resource_root target output)
    set(${{output}} "${{CMAKE_BINARY_DIR}}/resources" PARENT_SCOPE)
endfunction()
set(generated "${{CMAKE_BINARY_DIR}}/generated")
set(outputs "${{generated}}/LICENSE" "${{generated}}/licensing.md")
add_custom_command(OUTPUT ${{outputs}}
    COMMAND "{sys.executable}" "${{CMAKE_SOURCE_DIR}}/generate.py"
        "${{CMAKE_SOURCE_DIR}}/input" "${{generated}}"
    DEPENDS "${{CMAKE_SOURCE_DIR}}/input" "${{CMAKE_SOURCE_DIR}}/generate.py"
    VERBATIM)
add_custom_target(shared-resources DEPENDS ${{outputs}})
set_source_files_properties(${{outputs}} PROPERTIES UBIQUITTY_RESOURCE_PRODUCER "{producer}")
add_custom_target(ResourceFixture)
ubiquitty_bundle_resources(ResourceFixture "" "${{generated}}/LICENSE")
ubiquitty_bundle_resources(ResourceFixture "Docs" "${{generated}}/licensing.md")
ubiquitty_bundle_resources(ResourceFixture "" "${{CMAKE_SOURCE_DIR}}/ordinary")
''')

    def testParallelResourceGroupsShareOneProducer(self):
        self.writeFixture()
        generators = [("Ninja", "ninja"), ("Unix Makefiles", "make")]
        available = [(name, tool) for name, tool in generators if shutil.which(tool)]
        if len(available) != len(generators):
            self.skipTest("Ninja and Make are needed for both generated build graphs")
        for index, (generator, _) in enumerate(available):
            with self.subTest(generator=generator):
                build = self.directory / f"build-{index}"
                self.runCommand("cmake", "-S", str(self.source), "-B", str(build), "-G", generator)
                command = ("cmake", "--build", str(build), "--target", "ResourceFixture", "--parallel", "4")

                def check(expectedExecutions):
                    self.runCommand(*command)
                    generated = build / "generated"
                    self.assertEqual((generated / "executions").read_bytes().splitlines(),
                                     [b"generated"] * expectedExecutions)
                    expected = (self.source / "input").read_bytes()
                    self.assertEqual((build / "resources/LICENSE").read_bytes(), expected)
                    self.assertEqual((build / "resources/Docs/licensing.md").read_bytes(), expected)
                    self.assertEqual((build / "resources/ordinary").read_bytes(),
                                     (self.source / "ordinary").read_bytes())

                check(1)
                # Make can compare whole-second times. Model stale generated
                # files explicitly instead of waiting for the clock to advance.
                for name in ("LICENSE", "licensing.md"):
                    os.utime(build / "generated" / name, (1, 1))
                (self.source / "input").write_bytes(f"changed original resource {index}".encode())
                check(2)
                (build / "generated/LICENSE").unlink()
                (build / "generated/licensing.md").unlink()
                check(3)
                (self.source / "ordinary").write_bytes(f"changed ordinary resource {index}".encode())
                check(3)

    def testMissingOrInvalidProducerRefusesConfiguration(self):
        for index, producer in enumerate(("missing-producer", "", "shared-resources;missing-producer")):
            with self.subTest(producer=producer):
                self.writeFixture(producer)
                result = subprocess.run(
                    ["cmake", "-S", str(self.source), "-B", str(self.directory / f"invalid-{index}")],
                    capture_output=True, text=True, env=self.environment)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("names missing producer", " ".join((result.stdout + result.stderr).split()))
                self.assertFalse((self.directory / f"invalid-{index}" / "generated").exists())


if __name__ == "__main__":
    unittest.main()
