#!/usr/bin/env python3
# Copyright (C) 2026 Stanislav Yaglo
# SPDX-License-Identifier: Apache-2.0

"""Rebuild the self-contained COLRv0 fixture with fontTools."""

from io import BytesIO
from pathlib import Path
import subprocess

from fontTools.colorLib.builder import buildCOLR, buildCPAL
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen


def rectangle(left, right):
    pen = TTGlyphPen(None)
    pen.moveTo((left, 0))
    pen.lineTo((right, 0))
    pen.lineTo((right, 768))
    pen.lineTo((left, 768))
    pen.closePath()
    return pen.glyph()


def main():
    builder = FontBuilder(1024, isTTF=True)
    names = [".notdef", "face", "red", "blue"]
    builder.setupGlyphOrder(names)
    builder.setupCharacterMap({0x1F600: "face"})
    builder.setupGlyf({
        ".notdef": TTGlyphPen(None).glyph(),
        "face": TTGlyphPen(None).glyph(),
        "red": rectangle(0, 512),
        "blue": rectangle(512, 1024),
    })
    builder.setupHorizontalMetrics({name: (1024, 0) for name in names})
    builder.font["hmtx"].metrics["blue"] = (1024, 512)
    builder.setupHorizontalHeader(ascent=768, descent=-256)
    builder.setupOS2(sTypoAscender=768, sTypoDescender=-256,
                    usWinAscent=768, usWinDescent=256)
    builder.setupNameTable({
        "familyName": "Ubiquitty COLRv0 Fixture",
        "styleName": "Regular",
        "uniqueFontIdentifier": "Ubiquitty-COLRv0-Fixture-1",
        "fullName": "Ubiquitty COLRv0 Fixture",
        "psName": "UbiquittyCOLRv0Fixture",
        "copyright": "Copyright 2026 Stanislav Yaglo",
        "licenseDescription": "SPDX-License-Identifier: Apache-2.0",
    })
    builder.setupPost()
    builder.setupMaxp()
    builder.font["COLR"] = buildCOLR({"face": [("red", 0), ("blue", 1)]}, version=0)
    builder.font["CPAL"] = buildCPAL([[(1, 0, 0, 1), (0, 0, 1, 0.5)]])
    builder.font["head"].created = 2082844800
    builder.font["head"].modified = 2082844800
    builder.font.recalcTimestamp = False
    stream = BytesIO()
    builder.save(stream)
    data = stream.getvalue()
    rows = ["    " + ", ".join(f"0x{value:02x}" for value in data[start:start + 16])
            for start in range(0, len(data), 16)]
    header = """// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <array>
#include <cstdint>

namespace UbiquittyTest {

// U+1F600: an opaque red half and a half-transparent blue half. No system
// emoji font participates. Rebuild with generate_color_emoji_fixture.py.
inline constexpr std::array<std::uint8_t, %d> colorEmojiCOLRv0 {
%s
};

} // namespace UbiquittyTest
""" % (len(data), ",\n".join(rows))
    output = Path(__file__).with_name("ColorEmojiCOLRv0.h")
    output.write_text(header)
    subprocess.run(["clang-format", "-i", str(output)], check=True)


if __name__ == "__main__":
    main()
