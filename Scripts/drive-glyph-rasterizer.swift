// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// drive-glyph-rasterizer.swift — a glyph reaches the coverage plane as ink.
//
// The rasteriser draws through a CoreGraphics context into bytes the atlas
// uploads as R8. Everything that can go wrong there produces a plane rather
// than an error: a context with the wrong colour space gives premultiplied
// values where coverage was wanted, a pen outside the slot draws nothing, and a
// missing clear leaves the previous glyph under the new one. All of it returns
// cleanly.
//
// So the bytes are read. The assertions are relative rather than absolute —
// `M` inks more than `i`, a space inks nothing — because absolute coverage is a
// property of the installed face and would pin this to one version of Menlo.
//
// The clear has its own case. A slot the cache reassigns still holds its last
// glyph, and a blank drawn over a heavy one has to leave the plane empty; the
// symptom otherwise is a character that shows its predecessor, which reads as a
// slot-mapping bug rather than a rasterisation one.

import CoreGraphics
import CoreText
import Foundation
import UbiquittyCore

@main
enum RasterDriver {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            print("drive-glyph-rasterizer: expected the bundled font directory")
            exit(2)
        }
        var failures = 0
        var checks = 0
        // A claim that holds is counted, not named: the closing line says how
        // many were made, and a reader acts on the ones that failed.
        func check(_ l: String, _ ok: Bool, _ d: String = "") {
            checks += 1
            if !ok {
                failures += 1
                print("  FAIL \(l) \(d)")
            }
        }
        guard let faces = FontFaces(family: "Menlo", size: 32.0, pixelsPerPoint: 1),
            let raster = GlyphRasterizer(width: 32, height: 40)
        else {
            print("drive-glyph-rasterizer: setup failed")
            exit(2)
        }
        let font = faces[Ubiquitty.Rendering.FontFace.Regular]

        func glyph(_ ch: UInt16) -> CGGlyph {
            var chars = [ch]
            var glyphs: [CGGlyph] = [0]
            _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
            return glyphs[0]
        }

        let inkedM = raster.rasterise(glyph: glyph(0x4D), in: font, at: CGPoint(x: 2, y: 8))
        let sumM = raster.coverage.reduce(into: 0) { (acc: inout Int, b: UInt8) in acc += Int(b) }
        check("'M' puts down ink", inkedM && sumM > 0, "coverage sum=\(sumM)")

        let inkedI = raster.rasterise(glyph: glyph(0x69), in: font, at: CGPoint(x: 2, y: 8))
        let sumI = raster.coverage.reduce(into: 0) { (acc: inout Int, b: UInt8) in acc += Int(b) }
        check("'i' inks less than 'M'", inkedI && sumI > 0 && sumI < sumM, "i=\(sumI) M=\(sumM)")

        let inkedSpace = raster.rasterise(glyph: glyph(0x20), in: font, at: CGPoint(x: 2, y: 8))
        let sumSpace = raster.coverage.reduce(into: 0) { (acc: inout Int, b: UInt8) in acc += Int(b) }
        check("space inks nothing", !inkedSpace && sumSpace == 0, "sum=\(sumSpace)")

        // The clear is the whole reason a reassigned slot does not show its
        // predecessor: draw a heavy glyph, then a blank, and the plane must be
        // empty rather than still carrying the first.
        _ = raster.rasterise(glyph: glyph(0x4D), in: font, at: CGPoint(x: 2, y: 8))
        _ = raster.rasterise(glyph: glyph(0x20), in: font, at: CGPoint(x: 2, y: 8))
        check("a blank clears the previous glyph", raster.coverage.allSatisfy { $0 == 0 })

        _ = raster.rasterise(glyph: glyph(0x4F), in: font, at: CGPoint(x: 2, y: 8))
        let edges = raster.coverage.filter { $0 > 0 && $0 < 255 }.count
        check("antialiasing produces partial coverage", edges > 0, "\(edges) edge pixel(s)")

        // Compare final slot bytes, including clipping, phases and optical
        // growth. An overhanging neighbor must never enter another tile.
        if let batched = GlyphRasterizer(width: 32, height: 40),
            let scalar = GlyphRasterizer(width: 32, height: 40)
        {
            var consumed = 0
            var mismatches = 0
            var requests = 0
            let batchFonts = [
                font, faces[Ubiquitty.Rendering.FontFace.BoldItalic], CTFontCreateWithName("PingFang SC" as CFString, 32, nil),
            ]
            for batchFont in batchFonts {
                let characters: [UInt16] = [0x4D, 0x69, 0x20, 0x66, 0x4E00, 0x4E8C, 0x4E09, 0x00E9]
                var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                _ = CTFontGetGlyphsForCharacters(batchFont, characters, &glyphs, characters.count)
                for tier in 0..<Ubiquitty.Rendering.rasterTierCount {
                    for (index, batchGlyph) in glyphs.enumerated() where batchGlyph != 0 {
                        for boost in [CGFloat(0), CGFloat(1.2)] {
                            let origin = CGPoint(x: 2 + CGFloat(index % 4) / 4, y: 8)
                            let style = GlyphRasterizer.Style(tier: tier)
                            scalar.rasterise(glyph: batchGlyph, in: batchFont, at: origin, boostCappedTo: boost, style: style)
                            let expected = scalar.coverage
                            batched.enqueue(glyph: batchGlyph, in: batchFont, at: origin, boostCappedTo: boost, style: style) { plane in
                                consumed += 1
                                if !plane.elementsEqual(expected) { mismatches += 1 }
                            }
                            requests += 1
                        }
                    }
                }
            }
            batched.flushBatch()
            check("every queued raster is consumed once", consumed == requests, "\(consumed)/\(requests)")
            check("batched glyphs preserve scalar coverage exactly", mismatches == 0, "\(mismatches) mismatches")
            check(
                "glyph draws are grouped",
                batched.batchDrawCount * 2 < batched.batchedGlyphCount,
                "\(batched.batchedGlyphCount) glyphs / \(batched.batchDrawCount) draws"
            )
            batched.flushBatch()
            check("an empty flush does not replay glyphs", consumed == requests)
        } else {
            check("batch rasterizers allocate", false)
        }

        if let limited = GlyphRasterizer(width: 4096, height: 4),
            let reference = GlyphRasterizer(width: 4096, height: 4)
        {
            let origin = CGPoint(x: -8, y: 0)
            reference.rasterise(glyph: glyph(0x4D), in: font, at: origin)
            let expected = reference.coverage
            var matched = false
            limited.enqueue(glyph: glyph(0x4D), in: font, at: origin, style: .heaviest) { pixels in
                matched = pixels.elementsEqual(expected)
            }
            limited.flushBatch()
            check("oversized batch tiles retain the scalar raster", matched && limited.batchDrawCount == 0)
        } else {
            check("oversized tile fixture allocates", false)
        }

        if let clusterRaster = GlyphRasterizer(width: 160, height: 80) {
            func shapedLine(_ text: String, in textFont: CTFont? = nil) -> CTLine {
                CTLineCreateWithAttributedString(
                    NSAttributedString(
                        string: text,
                        attributes: [
                            NSAttributedString.Key(kCTFontAttributeName as String): textFont ?? font,
                            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
                        ]
                    )
                )
            }
            func hasOutsideInk(_ pixels: [UInt8], left: CGFloat, width: CGFloat) -> Bool {
                let first = Int(left.rounded(.down))
                let end = Int((left + width).rounded(.up))
                return pixels.enumerated()
                    .contains { index, coverage in
                        coverage != 0 && (index % 160 < first || index % 160 >= end)
                    }
            }
            let nativeCellAdvance = CGFloat(CTLineGetTypographicBounds(shapedLine("M"), nil, nil, nil))
            for text in ["क्‍ष", "का", "कि", "कााा"] {
                let points = text.unicodeScalars.map(\.value)
                let fitMode = points.withUnsafeBufferPointer { GlyphRasterizer.clusterFitMode(for: $0.span) }
                check("narrow marked groups fit advance overflow", fitMode == .fitAdvanceOverflow, text)
                let line = shapedLine(text)
                check(
                    "the Indic fixture advances beyond one native cell",
                    CTLineGetTypographicBounds(line, nil, nil, nil) > Double(nativeCellAdvance),
                    text
                )
                for cellWidth in [nativeCellAdvance / 2, nativeCellAdvance] {
                    for phase in [CGFloat(0), CGFloat(0.375)] {
                        let pen = CGPoint(x: 20 + phase, y: 20)
                        var bounds = Ubiquitty.Rendering.ClusterRasterBounds()
                        bounds.left = Double(pen.x)
                        bounds.width = Double(cellWidth)
                        let inked = clusterRaster.rasterise(
                            line: line,
                            at: pen,
                            fittingIn: fitMode == .fitAdvanceOverflow ? bounds : nil
                        )
                        check("a fitted marked group retains ink", inked, "\(text), width=\(cellWidth)")
                        check(
                            "a marked group stays inside its allocated cells",
                            !hasOutsideInk(clusterRaster.coverage, left: pen.x, width: cellWidth),
                            "\(text), width=\(cellWidth), phase=\(phase)"
                        )
                        clusterRaster.rasterise(
                            line: line,
                            at: pen,
                            boostCappedTo: 1.1,
                            sizedBy: glyph(0x4D),
                            in: font,
                            fittingIn: fitMode == .fitAdvanceOverflow ? bounds : nil
                        )
                        check("a fitted grown group retains ink", clusterRaster.coverage.contains { $0 != 0 })
                        check(
                            "optical growth keeps a marked group inside its cells",
                            !hasOutsideInk(clusterRaster.coverage, left: pen.x, width: cellWidth)
                        )
                    }
                }
            }
            let preservedClusters: [(String, CGFloat, GlyphRasterizer.ClusterFitMode)] = [
                ("漢\u{0301}", 2, .preserveNativeAdvance),
                ("語\u{20DD}", 2, .preserveNativeAdvance),
                ("👩‍👩‍👧‍👧", 2, .preserveNativeAdvance),
                ("Z\u{0335}\u{034C}\u{035D}\u{030E}\u{0321}\u{0320}\u{032B}", 1, .preserveNativeAdvance),
            ]
            for (text, columns, expectedMode) in preservedClusters {
                let points = text.unicodeScalars.map(\.value)
                let fitMode = points.withUnsafeBufferPointer { GlyphRasterizer.clusterFitMode(for: $0.span) }
                check("the cluster retains its native sizing policy", fitMode == expectedMode, text)
                let line = shapedLine(text)
                let pen = CGPoint(x: 20, y: 20)
                var bounds = Ubiquitty.Rendering.ClusterRasterBounds()
                bounds.left = Double(pen.x)
                bounds.width = Double(nativeCellAdvance * columns)
                clusterRaster.rasterise(line: line, at: pen)
                let natural = clusterRaster.coverage
                check("the natural cluster retains ink", natural.contains { $0 != 0 }, text)
                if columns == 1 {
                    check("the marked Latin advance fits its cell", CTLineGetTypographicBounds(line, nil, nil, nil) <= bounds.width)
                    check("the fitting advance carries native ink overhang", hasOutsideInk(natural, left: pen.x, width: nativeCellAdvance))
                }
                let allocation = fitMode == .fitAdvanceOverflow ? bounds : nil
                clusterRaster.rasterise(line: line, at: pen, fittingIn: allocation)
                check("natural sizing and diacritic overhang are preserved", clusterRaster.coverage == natural, text)
                clusterRaster.rasterise(line: line, at: pen, boostCappedTo: 1.1, sizedBy: glyph(0x4D), in: font)
                let grown = clusterRaster.coverage
                clusterRaster.rasterise(
                    line: line,
                    at: pen,
                    boostCappedTo: 1.1,
                    sizedBy: glyph(0x4D),
                    in: font,
                    fittingIn: allocation
                )
                check("natural optical growth is preserved", clusterRaster.coverage == grown, text)
            }
            for text in ["a\u{0301}", "α\u{0301}", "س\u{064E}\u{0651}", "ש\u{05B8}\u{05C1}"] {
                let points = text.unicodeScalars.map(\.value)
                let fitMode = points.withUnsafeBufferPointer { GlyphRasterizer.clusterFitMode(for: $0.span) }
                check("other scripts preserve native advance", fitMode == .preserveNativeAdvance, text)
                let line = shapedLine(text)
                let pen = CGPoint(x: 20, y: 20)
                var bounds = Ubiquitty.Rendering.ClusterRasterBounds()
                bounds.left = Double(pen.x)
                let advance = CTLineGetTypographicBounds(line, nil, nil, nil)
                bounds.width = advance / 2
                check("the preserve fixture exceeds its allocation", advance > bounds.width && bounds.width > 0, text)
                clusterRaster.rasterise(line: line, at: pen)
                let natural = clusterRaster.coverage
                check("the preserve fixture retains ink", natural.contains { $0 != 0 }, text)
                let allocation = fitMode == .fitAdvanceOverflow ? bounds : nil
                clusterRaster.rasterise(line: line, at: pen, fittingIn: allocation)
                check("other-script overflow retains native coverage", clusterRaster.coverage == natural, text)
                clusterRaster.rasterise(line: line, at: pen, boostCappedTo: 1.1, sizedBy: glyph(0x4D), in: font)
                let grown = clusterRaster.coverage
                clusterRaster.rasterise(
                    line: line,
                    at: pen,
                    boostCappedTo: 1.1,
                    sizedBy: glyph(0x4D),
                    in: font,
                    fittingIn: allocation
                )
                check("other-script overflow retains native optical growth", clusterRaster.coverage == grown, text)
            }
            for text in ["กิ", "កិ"] {
                let points = text.unicodeScalars.map(\.value)
                let fitMode = points.withUnsafeBufferPointer { GlyphRasterizer.clusterFitMode(for: $0.span) }
                check("related syllabic scripts fit advance overflow", fitMode == .fitAdvanceOverflow, text)
                let line = shapedLine(text)
                let pen = CGPoint(x: 20.375, y: 20)
                var bounds = Ubiquitty.Rendering.ClusterRasterBounds()
                bounds.left = Double(pen.x)
                bounds.width = CTLineGetTypographicBounds(line, nil, nil, nil) / 2
                check("the related-script fixture advances beyond its cells", bounds.width > 0, text)
                clusterRaster.rasterise(
                    line: line,
                    at: pen,
                    fittingIn: fitMode == .fitAdvanceOverflow ? bounds : nil
                )
                check("a related-script fitted cluster retains ink", clusterRaster.coverage.contains { $0 != 0 }, text)
                check(
                    "a related-script cluster stays inside its cells",
                    !hasOutsideInk(clusterRaster.coverage, left: pen.x, width: CGFloat(bounds.width)),
                    text
                )
            }
            let fittingLine = shapedLine("e\u{0301}")
            let pen = CGPoint(x: 20, y: 20)
            clusterRaster.rasterise(line: fittingLine, at: pen)
            let natural = clusterRaster.coverage
            var roomyBounds = Ubiquitty.Rendering.ClusterRasterBounds()
            roomyBounds.left = Double(pen.x)
            roomyBounds.width = 100
            clusterRaster.rasterise(line: fittingLine, at: pen, fittingIn: roomyBounds)
            check("an already fitting cluster retains its natural coverage", clusterRaster.coverage == natural)
            let italic = faces[Ubiquitty.Rendering.FontFace.Italic]
            var italicCharacter: UInt16 = 0x66
            var italicGlyph: CGGlyph = 0
            CTFontGetGlyphsForCharacters(italic, &italicCharacter, &italicGlyph, 1)
            clusterRaster.rasterise(glyph: italicGlyph, in: italic, at: pen)
            let naturalItalic = clusterRaster.coverage
            roomyBounds.width = 8
            clusterRaster.rasterise(line: fittingLine, at: pen, fittingIn: roomyBounds)
            clusterRaster.rasterise(glyph: italicGlyph, in: italic, at: pen)
            check("cluster fitting leaves ordinary italic glyphs unchanged", clusterRaster.coverage == naturalItalic)
            for text in ["f\u{FE0E}", "f\u{200D}", "f\u{FE0E}\u{200D}"] {
                let points = text.unicodeScalars.map(\.value)
                let fitMode = points.withUnsafeBufferPointer { GlyphRasterizer.clusterFitMode(for: $0.span) }
                check("invisible suffixes preserve native advance", fitMode == .preserveNativeAdvance, text)
                let line = shapedLine(text, in: italic)
                clusterRaster.rasterise(line: line, at: pen)
                let nativeItalicCoverage = clusterRaster.coverage
                clusterRaster.rasterise(
                    line: line,
                    at: pen,
                    boostCappedTo: 1.1,
                    sizedBy: italicGlyph,
                    in: italic
                )
                let nativeWideItalicCoverage = clusterRaster.coverage
                let bounds = fitMode == .fitAdvanceOverflow ? roomyBounds : nil
                clusterRaster.rasterise(line: line, at: pen, fittingIn: bounds)
                check("invisible suffixes preserve native italic coverage", clusterRaster.coverage == nativeItalicCoverage, text)
                clusterRaster.rasterise(
                    line: line,
                    at: pen,
                    boostCappedTo: 1.1,
                    sizedBy: italicGlyph,
                    in: italic,
                    fittingIn: bounds
                )
                check("invisible suffixes preserve native wide italic coverage", clusterRaster.coverage == nativeWideItalicCoverage, text)
            }
            clusterRaster.rasterise(line: shapedLine(" "), at: pen, fittingIn: roomyBounds)
            check("a fitted blank clears its predecessor", clusterRaster.coverage.allSatisfy { $0 == 0 })
        } else {
            check("the cluster fitting plane allocates", false)
        }

        let variableURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("MonaspaceNeonVar.ttf")
        var registrationError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(variableURL as CFURL, .process, &registrationError) {
            defer { CTFontManagerUnregisterFontsForURL(variableURL as CFURL, .process, nil) }
            let weightTag = UInt32(Ubiquitty.Rendering.variationAxisTagWeight)
            func weightCoordinate(_ font: CTFont) -> Double? {
                if let coordinate = (CTFontCopyVariation(font) as? [UInt32: Double])?[weightTag] {
                    return coordinate
                }
                let axis = (CTFontCopyVariationAxes(font) as? [[String: Any]] ?? [])
                    .first {
                        $0[kCTFontVariationAxisIdentifierKey as String] as? UInt32 == weightTag
                    }
                return axis?[kCTFontVariationAxisDefaultValueKey as String] as? Double
            }
            for (bodyWeight, boldWeight, expectedBold) in [(800, 0, 800), (250, 0, 700), (800, 600, 600)] {
                guard
                    let varied = FontFaces(
                        family: "Monaspace Neon Var",
                        size: 32,
                        pixelsPerPoint: 1,
                        weight: 900,
                        boldWeight: boldWeight,
                        variationSpec: "wght=\(bodyWeight)"
                    )
                else {
                    check("the variable family resolves its configured faces", false)
                    continue
                }
                check("the body variation overrides font.weight", weightCoordinate(varied[.Regular]) == Double(bodyWeight))
                check("bold uses the effective body floor or explicit weight", weightCoordinate(varied[.Bold]) == Double(expectedBold))
                if bodyWeight == expectedBold {
                    func coverage(_ face: Ubiquitty.Rendering.FontFace) -> [UInt8] {
                        var character: UInt16 = 0x7C
                        var glyph: CGGlyph = 0
                        let font = varied[face]
                        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0,
                            raster.rasterise(glyph: glyph, in: font, at: CGPoint(x: 2, y: 8))
                        else { return [] }
                        return raster.coverage
                    }
                    let regularCoverage = coverage(.Regular)
                    check(
                        "heavy body and default bold draw the same ink",
                        regularCoverage.contains(where: { $0 != 0 }) && regularCoverage == coverage(.Bold)
                    )
                }
            }
        } else {
            check("the bundled variable fixture registers", false, String(describing: registrationError?.takeRetainedValue()))
        }
        check("the static control has no variation axes", (CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []).isEmpty)
        if let plain = FontFaces(family: "Menlo", size: 32, pixelsPerPoint: 1, weight: 400),
            let varied = FontFaces(family: "Menlo", size: 32, pixelsPerPoint: 1, weight: 400, variationSpec: "wght=800")
        {
            for face in [Ubiquitty.Rendering.FontFace.Regular, .Bold] {
                check(
                    "an unsupported axis leaves the static member unchanged",
                    CTFontCopyPostScriptName(plain[face]) == CTFontCopyPostScriptName(varied[face])
                )
            }
        } else {
            check("the static control resolves its faces", false)
        }

        // A grown two-cell glyph keyed in its own pen grid's buckets is drawn as
        // CoreText draws it at the true pen, for every pen: the raster for the
        // bucket a pen floors into equals the raster at the pen itself. Keyed
        // at the page's count instead, a glyph that grows less than the cap —
        // or not at all — lands in a neighbouring bucket on part of the pens,
        // wherever its own grid and the page's differ.
        var differingGlyphs = 0
        var pageMismatches = 0
        var ownMismatches = 0
        let wideCap: CGFloat = 1.1
        for size in [11.0, 16.0, 32.0] {
            guard let primary = FontFaces(family: "Menlo", size: size, pixelsPerPoint: 1)?[Ubiquitty.Rendering.FontFace.Regular] else {
                check("the wide oracle's primary resolves", false, "\(size)")
                continue
            }
            var em: UInt16 = 0x4D
            var emGlyph: CGGlyph = 0
            CTFontGetGlyphsForCharacters(primary, &em, &emGlyph, 1)
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(primary, .horizontal, &emGlyph, &advance, 1)
            let margin = (size / 4).rounded(.up)
            let width = Int(2 * advance.width.rounded(.up) + 2 * margin)
            let height = Int((CTFontGetAscent(primary) + CTFontGetDescent(primary)).rounded(.up) + 2 * margin)
            guard let plane = GlyphRasterizer(width: width, height: height) else {
                check("the wide oracle's plane builds", false, "\(size)")
                continue
            }
            let pageCount = Int(Ubiquitty.Rendering.nativeSubpixelPhaseCount(Double(wideCap) * size))
            let penY = margin + CTFontGetDescent(primary)
            for codePoint: UInt16 in [0xFF5C, 0xFF3F, 0x3013, 0x4E00, 0x6771, 0xFF5B] {
                var character = codePoint
                let text = String(utf16CodeUnits: &character, count: 1) as CFString
                let font = CTFontCreateForString(primary, text, CFRangeMake(0, 1))
                var glyph: CGGlyph = 0
                guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 else { continue }
                let ownCount = plane.penGridPhaseCount(sizedBy: glyph, in: font, cappedTo: wideCap)
                if ownCount != pageCount { differingGlyphs += 1 }
                func coverage(atFraction fraction: CGFloat) -> [UInt8] {
                    plane.rasterise(glyph: glyph, in: font, at: CGPoint(x: margin + fraction, y: penY), boostCappedTo: wideCap)
                    return plane.coverage
                }
                for step in 0..<64 {
                    let fraction = CGFloat(step) / 64
                    let atPen = coverage(atFraction: fraction)
                    let ownBucket = (fraction * CGFloat(ownCount)).rounded(.down) / CGFloat(ownCount)
                    let pageBucket = (fraction * CGFloat(pageCount)).rounded(.down) / CGFloat(pageCount)
                    if coverage(atFraction: ownBucket) != atPen { ownMismatches += 1 }
                    if coverage(atFraction: pageBucket) != atPen { pageMismatches += 1 }
                }
            }
        }
        check(
            "the wide oracle reaches a glyph drawn on another grid than the page's",
            differingGlyphs > 0 && pageMismatches > 0,
            "\(differingGlyphs) glyph(s), \(pageMismatches) pen(s) off at the page's count"
        )
        check(
            "a two-cell glyph keyed at its own pen grid draws as CoreText does at every pen",
            ownMismatches == 0,
            "\(ownMismatches) pen(s) off"
        )

        print(
            failures == 0
                ? "drive-glyph-rasterizer: ok (\(checks) claim(s))"
                : "drive-glyph-rasterizer: FAILED \(failures) of \(checks)"
        )
        exit(failures == 0 ? 0 : 1)
    }
}
