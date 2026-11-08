// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Foundation
import UbiquittyCore

/// Holds one real ingest reply under Core's model lock for the draw-entry smoke.
///
/// A DSR response is tapped after its stream write, before the drain publishes
/// its frame and unlocks. The context is borrowed: its main-thread owner must
/// release the gate, stop and join ingest, then uninstall the tap before dropping it.
package final class ModelContentionProbe {
    private let condition = NSCondition()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var isArmed = true
    private var isHeld = false
    private var didEnter = false
    private var didExpire = false

    package init() {}

    /// Installs the one-shot reply tap before ingest starts.
    package func install(on session: Ubiquitty.Runtime.TerminalSession) {
        session.setOutboundByteTap(
            { context, bytes in
                guard let context, bytes.size() == 4, let base = bytes.__dataUnsafe(),
                    base[0] == 0x1B, base[1] == 0x5B, base[2] == 0x30, base[3] == 0x6E
                else { return }
                Unmanaged<ModelContentionProbe>.fromOpaque(context).takeUnretainedValue().holdReply()
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Waits for the worker's positive under-lock acknowledgement.
    package func waitUntilHeld() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 2)
        while !didEnter, Date() < deadline {
            _ = condition.wait(until: deadline)
        }
        return didEnter && isHeld && !didExpire
    }

    /// Whether the worker still holds its callback, without reading the model.
    package var isWorkerHeld: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isHeld && !didExpire
    }

    /// Releases this one-shot gate, including when setup failed before its reply.
    package func release() {
        condition.lock()
        isArmed = false
        condition.unlock()
        releaseSignal.signal()
    }

    private func holdReply() {
        condition.lock()
        guard isArmed else {
            condition.unlock()
            return
        }
        isArmed = false
        didEnter = true
        isHeld = true
        condition.broadcast()
        condition.unlock()

        // The old blocking capture must return too. Its fallback cannot pass:
        // this worker clears the acknowledgement before returning to unlock.
        let outcome = releaseSignal.wait(timeout: .now() + 1)
        condition.lock()
        didExpire = outcome == .timedOut
        isHeld = false
        condition.broadcast()
        condition.unlock()
    }
}
