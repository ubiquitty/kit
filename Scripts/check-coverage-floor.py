#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Checks Kit's native Linux coverage; see Docs/coverage.md for the measurement."""

import argparse
from decimal import Decimal, InvalidOperation
from pathlib import Path
import sys
import subprocess


FLOORS = {
    "Source/Platform/Linux/Accessibility.cpp": 95,
    "Source/Platform/Linux/AccessibleTerminal.cpp": 81,
    "Source/Platform/Linux/BundledFontDirectory.cpp": 85,
    "Source/Platform/Linux/ColorGlyphPainter.cpp": 71,
    "Source/Platform/Linux/FontInventory.cpp": 83,
    "Source/Platform/Linux/FontRouting.cpp": 83,
    "Source/Platform/Linux/FreeTypeRasterizer.cpp": 80,
    "Source/Platform/Linux/PangoRichText.cpp": 95,
    "Source/Platform/Linux/Raster.cpp": 76,
    "TOTAL": 39,
}


def check(root, summary):
    if not summary.is_file():
        raise ValueError(f"no coverage summary: {summary}; run the instrumented suite first")
    timestamp = summary.stat().st_mtime_ns
    for source in (root / "Source").rglob("*"):
        if source.suffix in (".cpp", ".h") and source.stat().st_mtime_ns > timestamp:
            raise ValueError(f"summary is older than {source}; rerun the instrumented suite")
    rows = [line.split() for line in summary.read_text().splitlines() if line.strip()]
    failures = []
    for source, floor in FLOORS.items():
        matches = [row for row in rows if row[0] == source or row[0].endswith("/" + source)]
        if source != "TOTAL" and not (root / source).is_file():
            raise ValueError(f"floor names an absent source: {source}")
        if len(matches) != 1 or len(matches[0]) != 13:
            raise ValueError(f"expected one complete coverage row for {source}")
        column = matches[0][9]
        try:
            coverage = Decimal(column.removesuffix("%"))
            valid = column.endswith("%") and coverage.is_finite() and 0 <= coverage <= 100
        except InvalidOperation:
            valid = False
        if not valid:
            raise ValueError(f"invalid line coverage for {source}: {column}")
        print(f"{'PASS' if coverage >= floor else 'FAIL'} {source}: {coverage}% (floor {floor}%)")
        if coverage < floor:
            failures.append(source)
    return 1 if failures else 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        root = Path(__file__).resolve().parents[1]
        return subprocess.run([sys.executable, str(root / "Tests/Tools/test_coverage_floor.py")],
                              check=False).returncode
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--summary", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        return check(arguments.root, arguments.summary)
    except (OSError, ValueError) as error:
        print(f"coverage floor: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
