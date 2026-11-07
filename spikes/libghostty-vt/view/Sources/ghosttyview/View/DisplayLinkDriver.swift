// Adapted from tkzmux c961533 Sources/TkzTerminalView/DisplayLinkDriver.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// DisplayLinkDriver — the parked-unless-there-is-work frame clock (M1.6).
//
// The whole point of tkzmux's renderer is that an idle terminal costs nothing: the renderer's skip
// path returns *before* `nextDrawable()`, so as long as the display link itself is paused when
// there is no work, an idle window holds no drawable and burns no CPU.
//
// "Is there work?" is therefore the single most important decision in the view layer, so it is
// factored out of AppKit entirely: `DisplayLinkPolicy` is a pure function of `DisplayLinkDemand`
// and unit-tests without a window, a screen or a run loop. `DisplayLinkDriver` is the thin AppKit
// half: it owns the `CADisplayLink`, applies the policy's verdict, and logs every transition.
//
// A driver with no adopted link is fully functional (it just has nothing to pause), which is what
// lets the headless tests drive the exact same decision code the app runs.

import AppKit
import Foundation
import QuartzCore
import os

// MARK: - Demand

/// Everything that can justify running the display link. A pure value.
///
/// Note what is *not* here: "the cursor is blinking". A blink is an **event** (the blink timer flips
/// `TerminalSurface.cursorBlinkOn`, which marks the surface dirty and sets `needsUpdate`), not a
/// state — modelling it as a state would hold the link at 120 Hz forever and idle CPU with it.
public struct DisplayLinkDemand: Sendable, Hashable {
    /// The surface has unrendered changes (pty output, blink flip, focus change, selection…).
    public var needsUpdate: Bool = false
    /// A mouse drag (selection or autoscroll) is in progress.
    public var isDragging: Bool = false
    /// DEC 2026 (synchronized output) is held: frames are being skipped, but the watchdog deadline
    /// must still be evaluated every tick, so the link keeps running.
    public var hasSyncDeadline: Bool = false
    /// A live resize is in progress. Frames go out transactionally from `setFrameSize`, but the link
    /// stays up so the surface keeps up with anything the child writes meanwhile.
    public var isLiveResizing: Bool = false
    /// The window is fully occluded (or miniaturized). Nothing on screen can change.
    public var isOccluded: Bool = false
    /// A session is attached to the surface. With nothing attached there is nothing to draw.
    public var hasVisibleSession: Bool = false

    public init() {}
}

// MARK: - Policy

/// The pause/resume decision, as a pure value. Injected into `DisplayLinkDriver` so the app and the
/// tests run the identical code.
public struct DisplayLinkPolicy: Sendable, Hashable {
    public init() {}

    /// True when the link must be running.
    public func shouldRun(_ demand: DisplayLinkDemand) -> Bool {
        // Occlusion and "nothing attached" veto everything: an occluded window cannot show a frame
        // and a detached surface renders as "skipped" anyway.
        guard demand.hasVisibleSession, !demand.isOccluded else { return false }
        // A live resize *pauses* the link rather than running it. During a drag `setFrameSize`
        // renders synchronously under `presentsWithTransaction`, so a ticking link is not just
        // redundant, it is harmful: both paths call `nextDrawable()`, the layer only has a few
        // drawables, and a synchronous present that finds the pool empty blocks for up to a second.
        // Measured on a real drag (2026-09-08): with the link running, a multi-second drag produced
        // only two size updates. The drag owns the surface while it lasts.
        guard !demand.isLiveResizing else { return false }
        return demand.needsUpdate || demand.isDragging || demand.hasSyncDeadline
    }

    public enum Transition: Sendable, Hashable {
        case unchanged
        case pause
        case resume
    }

    /// What to do to a link that is currently `isPaused`, given `demand`.
    public func transition(isPaused: Bool, demand: DisplayLinkDemand) -> Transition {
        switch (shouldRun(demand), isPaused) {
        case (true, true): return .resume
        case (false, false): return .pause
        default: return .unchanged
        }
    }
}

// MARK: - Driver

/// Owns a `CADisplayLink` and keeps it paused unless `DisplayLinkPolicy` says otherwise.
///
/// The link itself is created by the view (`NSView.displayLink(target:selector:)`, macOS 14+, which
/// already stops itself when the view leaves the screen) and handed over with `adopt(_:)`. The
/// driver never creates one, which is exactly why it works headlessly.
@MainActor
public final class DisplayLinkDriver {
    /// One recorded pause/resume. Kept in memory (bounded) as well as logged, so the dev build can
    /// print the transition history and the tests can assert on it.
    public struct TransitionRecord: Sendable, Hashable {
        public let isPaused: Bool
        public let demand: DisplayLinkDemand
    }

    public var policy = DisplayLinkPolicy()

    public private(set) var demand = DisplayLinkDemand()
    /// The link's pause state. A driver with no link still tracks it.
    public private(set) var isPaused: Bool = true
    public private(set) var pauseCount: Int = 0
    public private(set) var resumeCount: Int = 0
    /// Bounded ring of the most recent transitions (newest last).
    public private(set) var transitions: [TransitionRecord] = []

    private var link: CADisplayLink?
    private let logger = Logger(subsystem: "ghosttyview", category: "displaylink")
    private static let maxTransitions = 256

    public init() {}

    /// The frame rate range every adopted link is configured with: never below 60 Hz, up to the
    /// 120 Hz a ProMotion display offers.
    public static let frameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)

    /// Takes ownership of `link` (invalidating any previous one) and immediately applies the policy.
    /// Pass `nil` when the view leaves its window.
    public func adopt(_ link: CADisplayLink?) {
        if let existing = self.link, existing !== link { existing.invalidate() }
        self.link = link
        link?.preferredFrameRateRange = DisplayLinkDriver.frameRateRange
        // A fresh CADisplayLink starts unpaused; mirror our own state onto it rather than guessing.
        link?.isPaused = isPaused
        apply()
    }

    /// Whether a real link is attached. False in tests and between windows.
    public var hasLink: Bool { link != nil }

    /// Mutates the demand and applies the policy. The only way to change the demand.
    public func update(_ mutate: (inout DisplayLinkDemand) -> Void) {
        var next = demand
        mutate(&next)
        guard next != demand else { return }
        demand = next
        apply()
    }

    /// "Something changed, draw a frame." The seam a session's render signal, a focus change and
    /// the cursor blink timer all funnel through.
    public func requestFrame() {
        update { $0.needsUpdate = true }
    }

    private func apply() {
        switch policy.transition(isPaused: isPaused, demand: demand) {
        case .unchanged:
            return
        case .pause:
            isPaused = true
            pauseCount += 1
        case .resume:
            isPaused = false
            resumeCount += 1
        }
        link?.isPaused = isPaused
        record()
    }

    private func record() {
        transitions.append(TransitionRecord(isPaused: isPaused, demand: demand))
        if transitions.count > DisplayLinkDriver.maxTransitions { transitions.removeFirst() }
        logger.debug("""
            display link \(self.isPaused ? "paused" : "resumed", privacy: .public) \
            (needsUpdate=\(self.demand.needsUpdate, privacy: .public) \
            drag=\(self.demand.isDragging, privacy: .public) \
            sync=\(self.demand.hasSyncDeadline, privacy: .public) \
            liveResize=\(self.demand.isLiveResizing, privacy: .public) \
            occluded=\(self.demand.isOccluded, privacy: .public) \
            session=\(self.demand.hasVisibleSession, privacy: .public))
            """)
    }

    /// A one-line summary of the transition history, for the dev-window dump.
    public var transitionSummary: String {
        """
        pauses=\(pauseCount) resumes=\(resumeCount) currentlyPaused=\(isPaused) \
        needsUpdate=\(demand.needsUpdate) occluded=\(demand.isOccluded) session=\(demand.hasVisibleSession)
        """
    }
}
