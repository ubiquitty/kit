// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

private final class ReadTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var didReadOnMainThread = false
    private var didTimeOut = false

    func record(_ path: String, waitingFor release: DispatchSemaphore?) -> Bool {
        lock.withLock {
            recorded.append(path)
            didReadOnMainThread = didReadOnMainThread || Thread.isMainThread
        }
        if let release, release.wait(timeout: .now() + 5) != .success {
            lock.withLock { didTimeOut = true }
        }
        return !path.contains("missing")
    }

    var paths: [String] { lock.withLock { recorded } }
    var isValid: Bool { lock.withLock { !didReadOnMainThread && !didTimeOut } }
}

@MainActor
private final class Answers {
    var paths: [String] = []
}

@MainActor
private func expect(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("file-link-lookup: FAIL — \(message)\n".utf8))
        exit(1)
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
    expect(condition(), "the admitted lookup did not complete")
}

@main
private struct FileLinkLookupTests {
    @MainActor
    static func main() async {
        let trace = ReadTrace()
        let release = DispatchSemaphore(value: 0)
        let answers = Answers()
        let lookup = FileLinkLookup { path in
            trace.record(path, waitingFor: path == "blocked" ? release : nil)
        }
        expect(lookup.value(for: "blocked") { answers.paths.append("stale") } == nil, "first lookup must be asynchronous")
        await waitUntil { trace.paths == ["blocked"] }

        // Main-actor work still runs while the filesystem reader is held.
        let canary = Answers()
        Task { @MainActor in canary.paths.append("responsive") }
        await waitUntil { !canary.paths.isEmpty }
        for number in 0..<1000 {
            _ = lookup.value(for: "superseded-\(number)") { answers.paths.append("superseded") }
        }
        _ = lookup.value(for: "latest") { answers.paths.append("latest") }
        expect(trace.paths == ["blocked"], "motion must not create more in-flight reads")
        release.signal()
        await waitUntil { answers.paths == ["latest"] }
        expect(trace.paths == ["blocked", "latest"], "only the latest waiting path may reach the filesystem")
        expect(trace.isValid, "reader ran on main or waited for a main-thread release")
        expect(lookup.value(for: "latest") { answers.paths.append("cached") } == true, "fresh result was not cached")
        expect(trace.paths.count == 2, "cache hit started another read")

        let cancelTrace = ReadTrace()
        let cancelRelease = DispatchSemaphore(value: 0)
        let cancelled = FileLinkLookup { path in
            cancelTrace.record(path, waitingFor: path == "old" ? cancelRelease : nil)
        }
        let cancelledAnswers = Answers()
        _ = cancelled.value(for: "old") { cancelledAnswers.paths.append("old") }
        await waitUntil { cancelTrace.paths == ["old"] }
        cancelled.cancel()
        _ = cancelled.value(for: "replacement") { cancelledAnswers.paths.append("replacement") }
        cancelRelease.signal()
        await waitUntil { cancelledAnswers.paths == ["replacement"] }
        expect(cancelTrace.paths == ["old", "replacement"] && cancelTrace.isValid, "cancel lost replacement or performed main-thread I/O")

        // A missing path is a cached negative answer, not a repeated read storm.
        let missingTrace = ReadTrace()
        let missing = FileLinkLookup { missingTrace.record($0, waitingFor: nil) }
        let missingAnswers = Answers()
        _ = missing.value(for: "missing") { missingAnswers.paths.append("missing") }
        await waitUntil { !missingAnswers.paths.isEmpty }
        expect(missing.value(for: "missing") {} == false, "missing file must resolve false")
        expect(missingTrace.paths == ["missing"] && missingTrace.isValid, "negative answer did not cache")

        // The shared pool remains bounded even when different panes all wait.
        let poolTrace = ReadTrace()
        let poolRelease = DispatchSemaphore(value: 0)
        let poolAnswers = Answers()
        let checks = (0..<3)
            .map { _ in
                FileLinkLookup { path in
                    poolTrace.record(path, waitingFor: poolRelease)
                }
            }
        for index in checks.indices {
            _ = checks[index].value(for: "pane-\(index)") { poolAnswers.paths.append("done") }
        }
        await waitUntil { poolTrace.paths.count == 2 }
        expect(poolTrace.paths.count == 2, "a third filesystem worker escaped the pool bound")
        guard let queued = (0..<3).first(where: { !poolTrace.paths.contains("pane-\($0)") }) else {
            expect(false, "there was no queued pane despite the two-worker bound")
            return
        }
        checks[queued].cancel()
        _ = checks[queued].value(for: "replacement-pane") { poolAnswers.paths.append("done") }
        for _ in 0..<3 { poolRelease.signal() }
        await waitUntil { poolAnswers.paths.count == 3 }
        expect(!poolTrace.paths.contains("pane-\(queued)"), "cancelled queued lookup still performed filesystem I/O")
        expect(poolTrace.paths.count == 3 && poolTrace.isValid, "pool did not drain all admitted panes")
        print("file-link-lookup: PASS — off-main reads, latest-only admission, cache, cancellation and bounded workers")
    }
}
