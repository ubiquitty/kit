// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// RichTextFaces.swift — the faces rich text blocks are measured and drawn in,
// on both Apple shells (Docs/rich-text.md, "The measurement model").
//
// One derivation for both halves of the contract: the typography table Core
// lays a block out by is measured from exactly the faces the block is later
// drawn in, so a glyph lands where Core put it, the highlight sits on it and a
// click names it. A face is measured once at 2048 points, where an advance in
// points is an advance in 1/2048 em, the table's unit.

import CoreText
import UbiquittyCore

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// One process-wide inventory. Its lock protects publication, never font discovery.
package final class RichTextFontCatalogCache: @unchecked Sendable {
    package static let shared = RichTextFontCatalogCache()
    package static let readyNotification = Notification.Name("UbiquittyRichTextFontCatalogReady")

    private let lock = NSLock()
    private var snapshot: RichTextFontCatalog?
    private var isBuilding = false
    private var revision: UInt64 = 0
    private var publishedGeneration: UInt64 = 0
    private let build: @Sendable () -> RichTextFontCatalog
    private var registeredFontsObserver: NSObjectProtocol?

    package init(
        build: @escaping @Sendable () -> RichTextFontCatalog = {
            let bundled = Ubiquitty.Rendering.bundledFontFamilies()
                .compactMap {
                    FontFaces.shippedStyles(family: String($0), size: 12)
                }
            return RichTextFontCatalog(additionalFamilies: bundled)
        }
    ) {
        self.build = build
        registeredFontsObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit {
        if let registeredFontsObserver {
            NotificationCenter.default.removeObserver(registeredFontsObserver)
        }
    }

    /// Starts discovery on demand and returns the published snapshot immediately.
    package func catalog() -> RichTextFontCatalog? {
        lock.lock()
        if let snapshot {
            lock.unlock()
            return snapshot
        }
        if !isBuilding {
            isBuilding = true
            let requestedRevision = revision
            DispatchQueue.global(qos: .userInitiated)
                .async { [self] in
                    let built = build()
                    lock.lock()
                    guard revision == requestedRevision else {
                        lock.unlock()
                        return
                    }
                    snapshot = built
                    publishedGeneration &+= 1
                    isBuilding = false
                    lock.unlock()
                    NotificationCenter.default.post(name: Self.readyNotification, object: self)
                }
        }
        lock.unlock()
        return nil
    }

    /// Retires an inventory after CoreText's registered-font set changes.
    package func invalidate() {
        lock.lock()
        revision &+= 1
        snapshot = nil
        isBuilding = false
        lock.unlock()
    }

    package var hasBuiltSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot != nil
    }

    package var generation: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return publishedGeneration
    }

    /// The registered-font set the cached class-face measurements were made under.
    package var registrationGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }
}

/// The faces a rich text block is set in.
package struct RichTextFaces {
    /// The grid's own upright face.
    package let grid: CTFont
    /// The grid's four faces in FontFace order, which the monospace class's
    /// styles are: the grid's own bold and italics, never a family match that
    /// could answer with a copy of the family the machine has installed.
    private let gridStyles: [CTFont]
    private let sansStyles: [CTFont]
    private let serifStyles: [CTFont]
    private let namedClassStyles: [(family: String, styles: [CTFont])]
    /// The configured proportional family, or empty for the platform's UI face.
    package let proportionalFamilyName: String
    private let catalogCache: RichTextFontCatalogCache
    var catalog: RichTextFontCatalog? { catalogCache.catalog() }
    package var hasBuiltCatalog: Bool { catalogCache.hasBuiltSnapshot }

    package init(grid: FontFaces, proportionalFamilyName: String, catalogCache: RichTextFontCatalogCache = .shared) {
        self.grid = grid[Ubiquitty.Rendering.FontFace.Regular]
        self.gridStyles = [
            grid[Ubiquitty.Rendering.FontFace.Regular],
            grid[Ubiquitty.Rendering.FontFace.Bold],
            grid[Ubiquitty.Rendering.FontFace.Italic],
            grid[Ubiquitty.Rendering.FontFace.BoldItalic],
        ]
        self.proportionalFamilyName = proportionalFamilyName
        if let shipped = FontFaces.shippedStyles(family: proportionalFamilyName, size: 12) {
            sansStyles = shipped
        } else {
            let base =
                LigatureSheet.namedProportionalFace(proportionalFamilyName, pointSize: 12)
                ?? CTFontCreateUIFontForLanguage(.system, 12, nil)
                ?? CTFontCreateCopyWithAttributes(self.grid, 12, nil, nil)
            sansStyles = Self.classStyles(of: base)
        }
        serifStyles = Self.classStyles(of: Self.serifFace(size: 12))
        namedClassStyles = [gridStyles, sansStyles, serifStyles]
            .map {
                (CTFontCopyFamilyName($0[0]) as String, $0)
            }
        self.catalogCache = catalogCache
    }

    /// Begins the shared inventory when the first block reaches a frame.
    package func prepareCatalog() { _ = catalogCache.catalog() }

    /// Whether two tables measure the same immutable native class faces.
    ///
    /// - Parameter other: The faces behind a cached table.
    /// - Returns: Whether all twelve class faces are CoreText-equivalent.
    // swift-only: native CTFont identity stays within the Swift rendering modules
    package func hasSameClassFaces(as other: RichTextFaces) -> Bool {
        func matches(_ first: [CTFont], _ second: [CTFont]) -> Bool {
            first.count == second.count && zip(first, second).allSatisfy { CFEqual($0, $1) }
        }
        return matches(gridStyles, other.gridStyles) && matches(sansStyles, other.sansStyles) && matches(serifStyles, other.serifStyles)
    }

    /// The process inventory plus the exact class faces this renderer publishes.
    package func familyNames(in catalog: RichTextFontCatalog) -> [String] {
        let names = namedClassStyles.map(\.family).filter(RichTextFontCatalog.isRepresentable)
        return Array(Set(catalog.families).union(names)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// Resolves a source family in the same snapshot its font query enumerates.
    package func font(
        _ familyClass: Ubiquitty.RichText.FamilyClass,
        familyName: String,
        isBold: Bool,
        isItalic: Bool,
        size: CGFloat
    ) -> CTFont {
        if !familyName.isEmpty {
            if let styles = namedClassStyles.first(where: { $0.family == familyName })?.styles {
                let source = styles[(isBold ? 1 : 0) | (isItalic ? 2 : 0)]
                return CTFontCreateCopyWithAttributes(source, size, nil, nil)
            }
            if let named = catalog?.font(family: familyName, isBold: isBold, isItalic: isItalic, size: size) {
                return named
            }
        }
        return font(familyClass, isBold: isBold, isItalic: isItalic, size: size)
    }

    /// The face a class names in a style, at an em size.
    ///
    /// - Parameters:
    ///   - familyClass: The class.
    ///   - isBold: Whether the face is the bold one.
    ///   - isItalic: Whether the face is the italic one.
    ///   - size: The em size, in the units the caller draws in.
    /// - Returns: The face; the upright regular one when the family has no
    ///   face in the style asked for.
    package func font(_ familyClass: Ubiquitty.RichText.FamilyClass, isBold: Bool, isItalic: Bool, size: CGFloat) -> CTFont {
        let styles: [CTFont]
        switch familyClass {
        case .Monospace:
            styles = gridStyles
        case .Serif:
            styles = serifStyles
        default:
            styles = sansStyles
        }
        let source = styles[Int(Ubiquitty.Rendering.fontFace(isBold, isItalic).rawValue) & 0x3]
        if familyClass == .Monospace {
            var identity = CGAffineTransform.identity
            return CTFontCreateCopyWithAttributes(source, size, &identity, nil)
        }
        return CTFontCreateCopyWithAttributes(source, size, nil, nil)
    }

    /// Preserve each class's native style policy in immutable handles. Font
    /// matching and bundled-file reads occur only during renderer construction.
    private static func classStyles(of base: CTFont) -> [CTFont] {
        (0...3)
            .map { style in
                guard style != 0 else { return base }
                var traits = CTFontSymbolicTraits()
                if style & 1 != 0 { traits.insert(.boldTrait) }
                if style & 2 != 0 { traits.insert(.italicTrait) }
                var identity = CGAffineTransform.identity
                return CTFontCreateCopyWithSymbolicTraits(base, 12, &identity, traits, traits) ?? base
            }
    }

    /// The table Core lays rich text out by: the cell, and the three class
    /// faces in their four styles.
    ///
    /// - Parameters:
    ///   - cellWidthInPoints: The grid's cell width.
    ///   - cellHeightInPoints: The grid's cell height.
    ///   - baselineInPoints: The grid's baseline below the row top.
    ///   - proportionalSizeInPoints: The zoomed proportional em size.
    ///   - monospaceSizeInPoints: The zoomed grid font's em size.
    /// - Returns: The filled table.
    // swift-only: the generated C++ header drops this package helper, and only Swift callers build the table through it
    package func typographyFacts(
        cellWidthInPoints: Double,
        cellHeightInPoints: Double,
        baselineInPoints: Double,
        proportionalSizeInPoints: Double,
        monospaceSizeInPoints: Double
    ) -> Ubiquitty.RichText.TypographyFactsBuilder {
        var builder = Ubiquitty.RichText.TypographyFactsBuilder()
        builder.setCell(Self.inSixtyFourths(cellWidthInPoints), Self.inSixtyFourths(cellHeightInPoints))
        builder.setTerminalMetrics(
            Self.inSixtyFourths(baselineInPoints),
            Self.inSixtyFourths(proportionalSizeInPoints),
            Self.inSixtyFourths(monospaceSizeInPoints)
        )
        builder.setShaping(1)
        builder.setRendering(1)
        builder.setFontCatalogScope(Ubiquitty.RichText.FontCatalogScope.System.rawValue)
        let emSize = CGFloat(Ubiquitty.RichText.unitsPerEm)
        let classes: [Ubiquitty.RichText.FamilyClass] = [.SansSerif, .Serif, .Monospace]
        for familyClass in classes {
            for styles: UInt8 in 0...3 {
                let face = font(familyClass, isBold: styles & 1 != 0, isItalic: styles & 2 != 0, size: emSize)
                Self.measure(face, as: familyClass, styles: styles, into: &builder)
            }
        }
        return builder
    }

    /// The platform's serif text face: the system face's serif design, New
    /// York, whose vertical proportions are the sans-serif class face's, so a
    /// serif run at the primary em sets at the same cap height.
    ///
    /// The design is reached through the system descriptor because its family
    /// is published under a hidden, dot-prefixed name that a lookup by family
    /// never matches; such a lookup lands on Times New Roman, whose caps are 6%
    /// and lowercase 12% shorter at the same em.
    private static func serifFace(size: CGFloat) -> CTFont {
        #if canImport(AppKit)
        if let design = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif),
            let face = NSFont(descriptor: design, size: size)
        {
            return face as CTFont
        }
        #elseif canImport(UIKit)
        if let design = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: design, size: size) as CTFont
        }
        #endif
        for family in ["Times New Roman", "Times"] {
            if let face = LigatureSheet.namedProportionalFace(family, pointSize: size) {
                return face
            }
        }
        return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Times" as CFString, size, nil)
    }

    /// One face's metrics and the advances of the tabled range, in 1/2048 em.
    ///
    /// The measurement is the face's alone, made at the table's em, so it is
    /// kept across launches (``RichTextFaceMeasurementCache``): a code point a
    /// face lacks is measured in the face CoreText falls back to, and the first
    /// such lookup against a registered face builds the character set of every
    /// registered font, which is most of a launch's measuring.
    private static func measure(
        _ face: CTFont,
        as familyClass: Ubiquitty.RichText.FamilyClass,
        styles: UInt8,
        into builder: inout Ubiquitty.RichText.TypographyFactsBuilder
    ) {
        let measurement = RichTextFaceMeasurementCache.shared.measurement(of: face) { measureFace(face) }
        guard
            builder.addFace(
                familyClass,
                styles,
                measurement.ascent,
                measurement.descent,
                measurement.lineHeight,
                measurement.averageAdvance
            )
        else {
            return
        }
        let first = Ubiquitty.RichText.firstTabledCodePoint
        for (index, advance) in measurement.advances.enumerated() {
            builder.setAdvance(first + UInt32(index), advance)
        }
    }

    /// Measures one face at the table's em: its vertical metrics, and the
    /// advance of every tabled code point, from the face CoreText falls back
    /// to where the face lacks one.
    ///
    /// - Parameter face: The face, at the table's em.
    /// - Returns: The measurement.
    private static func measureFace(_ face: CTFont) -> RichTextFaceMeasurement {
        let ascent = CTFontGetAscent(face)
        let descent = CTFontGetDescent(face)
        let lineHeight = ascent + descent + CTFontGetLeading(face)
        let first = Ubiquitty.RichText.firstTabledCodePoint
        let last = Ubiquitty.RichText.lastTabledCodePoint
        var advances = [UInt16](repeating: 0, count: Int(last - first + 1))
        var characters = [UInt16](repeating: 0, count: advances.count)
        for index in 0..<characters.count {
            characters[index] = UInt16(first + UInt32(index))
        }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        _ = CTFontGetGlyphsForCharacters(face, characters, &glyphs, characters.count)
        var sizes = [CGSize](repeating: .zero, count: glyphs.count)
        _ = CTFontGetAdvancesForGlyphs(face, .horizontal, glyphs, &sizes, glyphs.count)
        for index in 0..<advances.count {
            var advance = sizes[index].width
            // A code point the face lacks is drawn from the face CoreText
            // falls back to, so it is measured there too.
            if glyphs[index] == 0, let scalar = Unicode.Scalar(characters[index]) {
                let fallback = CTFontCreateForString(face, String(Character(scalar)) as CFString, CFRange(location: 0, length: 1))
                var unit = characters[index]
                var glyph = CGGlyph(0)
                if CTFontGetGlyphsForCharacters(fallback, &unit, &glyph, 1) {
                    var fallbackSize = CGSize.zero
                    _ = CTFontGetAdvancesForGlyphs(fallback, .horizontal, &glyph, &fallbackSize, 1)
                    advance = fallbackSize.width
                }
            }
            advances[index] = clamped(advance)
        }
        // The printable ASCII advances' mean, which an estimate takes.
        let ascii = advances[0..<95]
        let average = UInt16(ascii.reduce(0) { $0 + Int($1) } / ascii.count)
        return RichTextFaceMeasurement(
            ascent: clamped(ascent),
            descent: clamped(descent),
            lineHeight: clamped(lineHeight),
            averageAdvance: average,
            advances: advances
        )
    }

    private static func clamped(_ value: CGFloat) -> UInt16 {
        UInt16(max(0, min(CGFloat(UInt16.max), value.rounded())))
    }

    private static func inSixtyFourths(_ points: Double) -> UInt16 {
        UInt16(max(1, min(Double(Ubiquitty.RichText.maxCellSize), (points * 64).rounded())))
    }
}

/// One class face's measurement at the typography table's em, in 1/2048 em.
struct RichTextFaceMeasurement: Equatable {
    /// The face's ascent.
    var ascent: UInt16
    /// The face's descent.
    var descent: UInt16
    /// The face's line height: ascent, descent and leading.
    var lineHeight: UInt16
    /// The printable ASCII advances' mean, which an estimate takes.
    var averageAdvance: UInt16
    /// The advance of every tabled code point, from the first on.
    var advances: [UInt16]
}

/// Class-face measurements kept across launches, in the user's cache directory.
///
/// A measurement depends on the face and on the faces CoreText falls back to
/// for the code points it lacks, so its key names everything those depend on:
/// the face's PostScript name, version, variation, matrix and size, its file's
/// path, size and date, every installed and registered font file's path, size
/// and date, the operating system's build, the preferred languages, and the
/// table's range. A font installed, updated or removed changes the key, so the
/// faces are measured again: an updated face by its own file, and every face
/// by the installed set, since a new font may be the one a missing code point
/// now falls back to. The installed set is read once a process and again when
/// CoreText reports the registered fonts changed. A launch whose faces were
/// measured before reads them instead of measuring, which a snapshot run, one
/// process a case, would otherwise pay for every case. The file holds its own
/// key, so a hash that collides reads as a miss, and the directory keeps the
/// newest measurements only, so the ones a font change retired go.
final class RichTextFaceMeasurementCache: @unchecked Sendable {
    /// The process-wide cache.
    static let shared = RichTextFaceMeasurementCache()

    private static let magic: UInt32 = 0x5542_5146 // "UBQF"
    private static let formatVersion: UInt32 = 1

    /// How many measurement files the directory keeps: a few font sets' worth
    /// of twelve class faces each.
    private static let keptFiles = 96

    private let lock = NSLock()
    private var memory: [String: RichTextFaceMeasurement] = [:]
    private var installedFonts: String?
    private let directory: URL?
    private var fontsChangedObserver: NSObjectProtocol?

    /// Creates a cache over a directory, or the user's cache directory.
    ///
    /// - Parameter directory: Where measurements are kept; nil keeps them in
    ///   memory only.
    init(directory: URL? = RichTextFaceMeasurementCache.defaultDirectory()) {
        self.directory = directory
        fontsChangedObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.fontsChanged()
        }
    }

    deinit {
        if let fontsChangedObserver {
            NotificationCenter.default.removeObserver(fontsChangedObserver)
        }
    }

    /// Forgets the installed set and the measurements made under it, so the
    /// next key reads the fonts afresh.
    private func fontsChanged() {
        lock.lock()
        installedFonts = nil
        memory.removeAll()
        lock.unlock()
    }

    /// The directory measurements are kept in by default.
    ///
    /// - Returns: The application's cache directory's measurement folder, or
    ///   nil where there is none.
    static func defaultDirectory() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Ubiquitty", isDirectory: true)
            .appendingPathComponent("RichTextFaceMeasurements", isDirectory: true)
    }

    /// Returns a face's measurement, measuring and keeping it on a miss.
    ///
    /// - Parameters:
    ///   - face: The face, at the table's em.
    ///   - measure: Measures the face when no measurement is kept.
    /// - Returns: The measurement.
    func measurement(of face: CTFont, measure: () -> RichTextFaceMeasurement) -> RichTextFaceMeasurement {
        let key = Self.key(of: face, installedFonts: installedFontsIdentity())
        lock.lock()
        if let kept = memory[key] {
            lock.unlock()
            return kept
        }
        lock.unlock()
        if let stored = read(key) {
            lock.lock()
            memory[key] = stored
            lock.unlock()
            return stored
        }
        let measured = measure()
        lock.lock()
        memory[key] = measured
        lock.unlock()
        write(measured, key: key)
        return measured
    }

    /// The installed and registered fonts' identity, read once until CoreText
    /// reports a change.
    private func installedFontsIdentity() -> String {
        lock.lock()
        if let installedFonts {
            lock.unlock()
            return installedFonts
        }
        lock.unlock()
        let identity = Self.readInstalledFontsIdentity()
        lock.lock()
        installedFonts = identity
        lock.unlock()
        return identity
    }

    /// Every installed font file's path, size and date, as a count and a hash.
    ///
    /// On macOS every font the process can use, the ones it registered among
    /// them. On iOS the fonts registered for the process and the ones a font
    /// app installed; the system's own change only with the build, which the
    /// key names.
    private static func readInstalledFontsIdentity() -> String {
        #if os(macOS)
        let urls = (CTFontManagerCopyAvailableFontURLs() as? [URL]) ?? []
        #else
        var urls: [URL] = []
        for scope in [CTFontManagerScope.process, CTFontManagerScope.persistent] {
            let descriptors = (CTFontManagerCopyRegisteredFontDescriptors(scope, true) as? [CTFontDescriptor]) ?? []
            urls += descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontURLAttribute) as? URL }
        }
        #endif
        let files = Set(urls.map(fileIdentity)).sorted()
        return "\(files.count):" + String(fnv1a(files.joined(separator: "\n")), radix: 16)
    }

    /// The key a face's measurement is kept under.
    ///
    /// - Parameters:
    ///   - face: The face.
    ///   - installedFonts: The installed and registered fonts' identity.
    /// - Returns: The key.
    static func key(of face: CTFont, installedFonts: String) -> String {
        var parts = ["rich-text-face-\(formatVersion)"]
        parts.append("range=\(Ubiquitty.RichText.firstTabledCodePoint)-\(Ubiquitty.RichText.lastTabledCodePoint)")
        parts.append("name=\(CTFontCopyPostScriptName(face) as String)")
        parts.append("version=\((CTFontCopyName(face, kCTFontVersionNameKey) as String?) ?? "")")
        if let variation = CTFontCopyVariation(face) as? [NSNumber: NSNumber] {
            parts.append("variation=" + variation.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","))
        }
        let matrix = CTFontGetMatrix(face)
        parts.append("size=\(CTFontGetSize(face)) matrix=\(matrix.a),\(matrix.b),\(matrix.c),\(matrix.d)")
        if let url = CTFontCopyAttribute(face, kCTFontURLAttribute) as? URL {
            parts.append("file=" + fileIdentity(url))
        }
        parts.append("installed=" + installedFonts)
        parts.append("os=" + ProcessInfo.processInfo.operatingSystemVersionString)
        parts.append("languages=" + Locale.preferredLanguages.joined(separator: ","))
        return parts.joined(separator: "\n")
    }

    /// A file's path, size and modification date.
    private static func fileIdentity(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)|\(size)|\(date)"
    }

    /// FNV-1a, 64-bit: a name for a key, not a check of it.
    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// The file a key's measurement is kept in; the file holds its key.
    private func fileURL(for key: String) -> URL? {
        directory?.appendingPathComponent(String(Self.fnv1a(key), radix: 16) + ".measurement")
    }

    /// Removes all but the newest measurement files.
    private func prune(_ directory: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)),
            files.count > Self.keptFiles
        else {
            return
        }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.keptFiles) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func read(_ key: String) -> RichTextFaceMeasurement? {
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url) else {
            return nil
        }
        var offset = 0
        func next32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            defer { offset += 4 }
            return data[offset..<offset + 4].reduce(UInt32(0)) { ($0 >> 8) | (UInt32($1) << 24) }
        }
        func next16() -> UInt16? {
            guard offset + 2 <= data.count else { return nil }
            defer { offset += 2 }
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        guard next32() == Self.magic, next32() == Self.formatVersion, let keyLength = next32().map(Int.init),
            offset + keyLength <= data.count,
            String(decoding: data[offset..<offset + keyLength], as: UTF8.self) == key
        else {
            return nil
        }
        offset += keyLength
        guard let count = next32().map(Int.init),
            let ascent = next16(), let descent = next16(), let lineHeight = next16(), let average = next16(),
            count == Int(Ubiquitty.RichText.lastTabledCodePoint - Ubiquitty.RichText.firstTabledCodePoint + 1)
        else {
            return nil
        }
        var advances: [UInt16] = []
        advances.reserveCapacity(count)
        for _ in 0..<count {
            guard let advance = next16() else { return nil }
            advances.append(advance)
        }
        return RichTextFaceMeasurement(
            ascent: ascent,
            descent: descent,
            lineHeight: lineHeight,
            averageAdvance: average,
            advances: advances
        )
    }

    private func write(_ measurement: RichTextFaceMeasurement, key: String) {
        guard let url = fileURL(for: key), let directory else {
            return
        }
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let keyBytes = Data(key.utf8)
        append32(Self.magic)
        append32(Self.formatVersion)
        append32(UInt32(keyBytes.count))
        data.append(keyBytes)
        append32(UInt32(measurement.advances.count))
        append16(measurement.ascent)
        append16(measurement.descent)
        append16(measurement.lineHeight)
        append16(measurement.averageAdvance)
        for advance in measurement.advances {
            append16(advance)
        }
        // A cache that cannot be written is a cache that measures again: the
        // table is right either way.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        prune(directory)
    }
}
