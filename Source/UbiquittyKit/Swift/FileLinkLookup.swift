// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Coalesces one surface's file checks without holding its main actor on I/O.
@MainActor
internal final class FileLinkLookup {
    private final class Interest: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false

        var isWanted: Bool { lock.withLock { !isCancelled } }
        func cancel() { lock.withLock { isCancelled = true } }
    }

    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "org.ubiquitty.file-link-lookup"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private struct Reading {
        let path: String
        let isPresent: Bool
        let time: TimeInterval
    }

    private let exists: @Sendable (String) -> Bool
    private var reading: Reading?
    private var inFlightPath: String?
    private var requestedPath: String?
    private var completion: (@MainActor @Sendable () -> Void)?
    private var interest: Interest?

    /// Creates an asynchronous lookup with an injectable filesystem reader.
    ///
    /// - Parameter exists: The check performed only on the bounded worker pool.
    internal init(exists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.exists = exists
    }

    deinit { interest?.cancel() }

    /// Returns the last reading and schedules only the latest needed check.
    ///
    /// One check may be in flight and one latest path may wait behind it.
    /// A cached answer survives revalidation so continuous pointer motion does
    /// not blink the affordance while a filesystem lookup finishes.
    ///
    /// - Parameters:
    ///   - path: The local path to inspect.
    ///   - completion: Called on the main actor only if this remains the wanted path.
    /// - Returns: The last answer for this path, or nil until its first check finishes.
    internal func value(for path: String, completion: @escaping @MainActor @Sendable () -> Void) -> Bool? {
        if let inFlightPath, inFlightPath != path { interest?.cancel() }
        requestedPath = path
        self.completion = completion
        let cached = reading.flatMap { $0.path == path ? $0 : nil }
        let isFresh =
            cached.map { reading in
                let age = ProcessInfo.processInfo.systemUptime - reading.time
                return age >= 0 && age < 1
            } ?? false
        if inFlightPath == nil, !isFresh {
            begin(path)
        }
        return cached?.isPresent
    }

    /// Drops pending interest without waiting for an operating-system lookup.
    internal func cancel() {
        interest?.cancel()
        requestedPath = nil
        completion = nil
    }

    private func begin(_ path: String) {
        inFlightPath = path
        let check = exists
        let interest = Interest()
        self.interest = interest
        Self.workers.addOperation { [weak self] in
            let result = interest.isWanted ? check(path) : nil
            Task { @MainActor [weak self] in self?.finish(path, exists: result) }
        }
    }

    private func finish(_ path: String, exists: Bool?) {
        inFlightPath = nil
        interest = nil
        if let exists {
            reading = Reading(path: path, isPresent: exists, time: ProcessInfo.processInfo.systemUptime)
            if requestedPath == path { completion?() }
        }
        if inFlightPath == nil, let requestedPath, requestedPath != path || exists == nil { begin(requestedPath) }
    }
}
