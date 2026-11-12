#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""A missing, stale or regressed Kit coverage report cannot pass the floor."""

from contextlib import redirect_stdout
from importlib.util import module_from_spec, spec_from_file_location
import io
import os
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = spec_from_file_location("kit_coverage", ROOT / "Scripts/check-coverage-floor.py")
COVERAGE = module_from_spec(SPEC)
SPEC.loader.exec_module(COVERAGE)


class CoverageFloorTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ubq-kit-coverage-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.summary = self.root / "summary.txt"
        for source in COVERAGE.FLOORS:
            if source == "TOTAL":
                continue
            path = self.root / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// fixture\n")
        self.rows = [f"{source} 1 0 100% 1 0 100% 100 0 {floor}% 1 0 100%"
                     for source, floor in COVERAGE.FLOORS.items()]

    def run_check(self, rows=None):
        self.summary.write_text("\n".join(self.rows if rows is None else rows))
        with redirect_stdout(io.StringIO()):
            return COVERAGE.check(self.root, self.summary)

    def test_all_floors_must_be_judged(self):
        self.assertEqual(self.run_check(), 0)
        for index in range(len(self.rows)):
            with self.subTest(index=index), self.assertRaises(ValueError):
                self.run_check(self.rows[:index] + self.rows[index + 1:])

    def test_total_cannot_pass_on_per_file_coverage_alone(self):
        self.assertEqual(self.run_check(self.rows[:-1] + [self.rows[-1].replace("39%", "38.99%")]), 1)

    def test_malformed_duplicate_or_absent_source_is_an_error(self):
        for rows in ([*self.rows, self.rows[0]], [self.rows[0].replace("95%", "NaN%"), *self.rows[1:]]):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                self.run_check(rows)
        (self.root / next(iter(COVERAGE.FLOORS))).unlink()
        with self.assertRaises(ValueError):
            self.run_check()

    def test_summary_must_be_newer_than_owned_sources(self):
        self.run_check()
        source = self.root / next(iter(COVERAGE.FLOORS))
        timestamp = self.summary.stat().st_mtime_ns + 1_000_000_000
        os.utime(source, ns=(timestamp, timestamp))
        with self.assertRaisesRegex(ValueError, "older than"):
            with redirect_stdout(io.StringIO()):
                COVERAGE.check(self.root, self.summary)


if __name__ == "__main__":
    unittest.main()
