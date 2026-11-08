// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#if canImport(AppKit)
import AppKit
import Metal
import QuartzCore

/// Drives visible output at the surface's display cadence.
@MainActor
internal final class SurfaceFrameLink: NSObject, @preconcurrency CAMetalDisplayLinkDelegate {
    #if UBIQUITTY_UI_TESTS
    private enum TestFrameLatency: String {
        case oneFrame = "1"
        case twoFrames = "2"

        var frames: Float { self == .oneFrame ? 1 : 2 }
    }

    private let testFrameLatency: TestFrameLatency? = {
        guard let value = ProcessInfo.processInfo.environment["UBIQUITTY_FRAME_LATENCY_FOR_TESTING"] else { return nil }
        guard let latency = TestFrameLatency(rawValue: value) else {
            preconditionFailure("UBIQUITTY_FRAME_LATENCY_FOR_TESTING must be 1 or 2")
        }
        return latency
    }()
    #endif
    private let onTick: () -> Void
    private var displayLink: CAMetalDisplayLink?
    private weak var layer: SurfaceMetalLayer?
    private weak var view: NSView?
    private var viewLink: CADisplayLink?
    internal private(set) var currentDrawable: CAMetalDrawable?
    internal var diagnosticSnapshot: (() -> String)?
    private let tracesCadence = ProcessInfo.processInfo.environment["UBIQUITTY_TRACE_FRAME_LINK"] == "1"
    private var traceStart: CFTimeInterval = 0
    private var traceTicks = 0
    private var traceWork: CFTimeInterval = 0
    private var traceLongestWork: CFTimeInterval = 0
    private var traceMetalTicks = 0
    private var traceTargetLead: CFTimeInterval = 0
    private var tracePresentationLead: CFTimeInterval = 0
    private var tracePreferredLatency: Double = 0
    private var traceCallbackPastTarget = 0
    private var requestedRate = 0

    internal init(layer: SurfaceMetalLayer, view: NSView, onTick: @escaping () -> Void) {
        self.layer = layer
        self.view = view
        self.onTick = onTick
        super.init()
    }

    internal var isRunning: Bool { displayLink != nil || viewLink != nil }
    internal var ownsDrawableDelivery: Bool { displayLink != nil }

    /// Uses ordinary display ticks while resize steps present inside AppKit transactions.
    internal func synchronizePresentationMode() {
        if isRunning { start(framesPerSecond: requestedRate) }
    }

    internal private(set) var startCount = 0

    /// Starts the display link or updates its requested rate without resetting its phase.
    ///
    /// A layer presenting with a transaction, or one a `nextDrawable()` call
    /// on another thread is waiting on, takes no drawable-delivering link: the
    /// view's display link ticks instead, and each tick asks the layer for its
    /// drawable. A later start attaches the delivering link once the layer
    /// takes one.
    internal func start(framesPerSecond: Int) {
        guard framesPerSecond > 0, let layer else { return }
        requestedRate = framesPerSecond
        let rate = Float(framesPerSecond)
        let range = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        if layer.presentsWithTransaction, let view {
            invalidateDisplayLink()
            startViewLink(on: view, range: range)
            return
        }
        if let displayLink {
            displayLink.preferredFrameRateRange = range
            return
        }
        guard let link = layer.makeDisplayLink() else {
            if let view {
                startViewLink(on: view, range: range)
            }
            return
        }
        viewLink?.invalidate()
        viewLink = nil
        traceStart = 0
        traceTicks = 0
        traceWork = 0
        traceLongestWork = 0
        traceMetalTicks = 0
        traceTargetLead = 0
        tracePresentationLead = 0
        tracePreferredLatency = 0
        traceCallbackPastTarget = 0
        link.delegate = self
        link.preferredFrameRateRange = range
        #if UBIQUITTY_UI_TESTS
        if let testFrameLatency { link.preferredFrameLatency = testFrameLatency.frames }
        if tracesCadence || testFrameLatency != nil {
            NSLog(
                "frame-link created path=metal testLatency=%@ actualLatency=%.1f",
                testFrameLatency?.rawValue ?? "unset",
                Double(link.preferredFrameLatency)
            )
        }
        #else
        if tracesCadence {
            NSLog("frame-link created path=metal actualLatency=%.1f", Double(link.preferredFrameLatency))
        }
        #endif
        displayLink = link
        startCount += 1
        // Tracking modes must keep presenting during window resizing and menu tracking.
        link.add(to: .main, forMode: .common)
    }

    /// Ticks at the view's display cadence without taking the layer's drawables.
    ///
    /// - Parameters:
    ///   - view: The view whose display the link follows.
    ///   - range: The frame rate to request.
    private func startViewLink(on view: NSView, range: CAFrameRateRange) {
        if let viewLink {
            viewLink.preferredFrameRateRange = range
            return
        }
        let link = view.displayLink(target: self, selector: #selector(viewLinkFired))
        link.preferredFrameRateRange = range
        #if UBIQUITTY_UI_TESTS
        if tracesCadence || testFrameLatency != nil {
            NSLog("frame-link created path=view testLatency=%@ actualLatency=unavailable", testFrameLatency?.rawValue ?? "unset")
        }
        #else
        if tracesCadence { NSLog("frame-link created path=view actualLatency=unavailable") }
        #endif
        viewLink = link
        startCount += 1
        link.add(to: .main, forMode: .common)
    }

    /// Invalidates continuous delivery so the layer can supply on-demand drawables.
    internal func stop() {
        invalidateDisplayLink()
        viewLink?.invalidate()
        viewLink = nil
        if tracesCadence {
            NSLog("frame-link stopped %@", diagnosticSnapshot?() ?? "")
        }
    }

    /// Detaches the drawable-delivering link, handing the layer's drawables
    /// back to `nextDrawable()`.
    private func invalidateDisplayLink() {
        guard let displayLink else { return }
        if let layer {
            layer.invalidate(displayLink)
        } else {
            displayLink.invalidate()
        }
        self.displayLink = nil
    }

    internal func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        currentDrawable = update.drawable
        defer { currentDrawable = nil }
        performTick(update: update, preferredFrameLatency: tracesCadence ? link.preferredFrameLatency : nil)
    }

    @objc
    private func viewLinkFired() {
        performTick()
    }

    private func performTick(update: CAMetalDisplayLink.Update? = nil, preferredFrameLatency: Float? = nil) {
        guard tracesCadence else {
            onTick()
            return
        }
        let start = CACurrentMediaTime()
        if traceStart == 0 { traceStart = start }
        onTick()
        let finishedAt = CACurrentMediaTime()
        let work = finishedAt - start
        if let update, let preferredFrameLatency {
            traceMetalTicks += 1
            traceTargetLead += update.targetTimestamp - start
            tracePresentationLead += update.targetPresentationTimestamp - start
            tracePreferredLatency += Double(preferredFrameLatency)
            // CPU callback completion, including ticks that drew nothing;
            // this is neither GPU completion nor an actual presentation miss.
            if finishedAt > update.targetTimestamp { traceCallbackPastTarget += 1 }
        }
        traceWork += work
        traceLongestWork = max(traceLongestWork, work)
        traceTicks += 1
        let elapsed = start - traceStart
        if elapsed >= 1 {
            NSLog(
                "frame-link requested=%d callbacks=%.2f workMeanMs=%.3f workMaxMs=%.3f",
                requestedRate,
                Double(traceTicks - 1) / elapsed,
                traceWork * 1000 / Double(traceTicks),
                traceLongestWork * 1000
            )
            if traceMetalTicks > 0 {
                NSLog(
                    "frame-link schedule latencyMean=%.1f targetLeadMeanMs=%.3f presentationLeadMeanMs=%.3f callbackPastTarget=%d/%d",
                    tracePreferredLatency / Double(traceMetalTicks),
                    traceTargetLead * 1000 / Double(traceMetalTicks),
                    tracePresentationLead * 1000 / Double(traceMetalTicks),
                    traceCallbackPastTarget,
                    traceMetalTicks
                )
            }
            if let diagnosticSnapshot { NSLog("frame-delivery %@", diagnosticSnapshot()) }
            traceStart = start
            traceTicks = 1
            traceWork = work
            traceLongestWork = work
            traceMetalTicks = 0
            traceTargetLead = 0
            tracePresentationLead = 0
            tracePreferredLatency = 0
            traceCallbackPastTarget = 0
        }
    }
}
#endif
