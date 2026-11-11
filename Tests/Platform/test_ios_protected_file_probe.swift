// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

//
// Tests/Platform/test_ios_protected_file_probe.swift — the one question
// test_ios_protected_file.cpp cannot ask in C++: which data-protection class a
// file carries. That is a Foundation resource value, so it is read here and
// handed to the C++ suite behind a C symbol, the way the creator under test
// (Source/UbiquittyKit/Swift/ProtectedFile.swift) is.
//

import Foundation

/// Whether the file at `path` carries Complete protection.
///
/// - Parameter path: A NUL-terminated file-system path.
/// - Returns: Whether its `fileProtection` resource value is `.complete`;
///   false when the value cannot be read.
@_cdecl("ubiquittyTestHasCompleteProtection")
func hasCompleteProtection(_ path: UnsafePointer<CChar>) -> Bool {
    let url = URL(fileURLWithFileSystemRepresentation: path, isDirectory: false, relativeTo: nil)
    guard let values = try? url.resourceValues(forKeys: [.fileProtectionKey]) else {
        return false
    }
    return values.fileProtection == .complete
}

/// Whether a file written with Complete protection, then set to it again,
/// reads back as Complete on this device: the suite's premise, which every
/// creator case depends on. Prints the class it read, or what refused it.
///
/// - Returns: Whether the class read back is Complete.
@_cdecl("ubiquittyTestCompleteProtectionApplies")
func completeProtectionApplies() -> Bool {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ubq-protection-probe-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("probe", isDirectory: false)
    var report: String
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data().write(to: url, options: [.withoutOverwriting, .completeFileProtection])
        let reference = url as NSURL
        try reference.setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
        reference.removeAllCachedResourceValues()
        var protection: AnyObject?
        try reference.getResourceValue(&protection, forKey: .fileProtectionKey)
        report = (protection as? URLFileProtection)?.rawValue ?? (protection as? String) ?? "no protection value"
    } catch {
        report = "refused: \(error)"
    }
    try? FileManager.default.removeItem(at: directory)
    print("probe: a file written with Complete protection reads back \(report)")
    return report == URLFileProtection.complete.rawValue
}
