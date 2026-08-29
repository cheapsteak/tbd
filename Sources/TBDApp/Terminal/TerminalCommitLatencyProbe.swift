import AppKit
import Foundation
import QuartzCore
import SwiftTerm
import os

/// Measures the one leg of the terminal render path nothing else instruments:
/// **app finishes drawing → the render server has committed that frame.**
///
/// ## What this is a lower bound on
///
/// This is NOT time-to-glass. `CATransaction`'s completion block fires once
/// the render server has committed the transaction; everything after that —
/// `WindowServer` compositing the layer tree, the display's own scanout — is
/// invisible here. Every number this probe emits is therefore a **lower
/// bound** on what a user perceives, and a future reader must not quote it as
/// a keystroke-to-pixel figure.
///
/// ## Why this leg
///
/// The lag investigation closed off everything upstream with numbers: TBD's
/// client parity with other emulators (#750), a main thread measured 83% idle
/// during a confirmed lag episode, idle SwiftTerm IO threads, and tmux at
/// 0.1–0.4% CPU. `sample` could follow the trail as far as
/// `CA::Transaction::commit` and then lost it at the process boundary, with
/// `WindowServer` at 57–66% CPU. The remaining hypothesis is that TBD's deep
/// SwiftUI-hosted layer tree degrades under a loaded compositor where
/// iTerm2's single flat layer does not. This probe puts a number on the first
/// half of that gap.
///
/// ## The two seams
///
/// SwiftTerm's `TerminalView.draw(_:)` is `public`, not `open`, so a subclass
/// outside that module cannot override it and bracket the draw directly. The
/// two ends are therefore stamped from the two hooks that ARE reachable:
///
/// - **`viewWillDraw()`** (`open` on `NSView`, `open override` on
///   `TerminalView`) — the start. AppKit sends it to each view it is about to
///   draw, on the main thread, inside the display cycle's transaction, which
///   is what makes the completion-block registration land on the right
///   transaction.
/// - **`TerminalView.onFramePresented`** — the end of the app's drawing.
///   SwiftTerm's fork provides it as a diagnostics hook and calls it at the
///   end of `draw` on the main thread (the Core Graphics path; TBD does not
///   use the Metal renderer). TBD uses it nowhere else, so the probe takes
///   sole ownership of it while the diagnostic is on.
///
/// AppKit sends `viewWillDraw` to a whole subtree before drawing any of it, so
/// the two hooks cannot be paired per view. `drawms` is therefore the *span* —
/// first terminal view about to draw → last terminal draw returned — not a sum
/// of per-view draw bodies. The span is the more useful of the two anyway: it
/// includes whatever AppKit does between the terminal draws.
///
/// ## Per-transaction, not per-view
///
/// Several terminal views can draw in one display cycle, and they all land in
/// the same `CATransaction`. The probe therefore keys its state on the
/// *cycle*, not the view: `t0` is stamped at the first terminal draw of a
/// cycle, later draws only add to the count, and exactly one line is logged
/// when the completion block fires. Registering a block per view would
/// overwrite the previous one (see `defaultRegisterCommitCompletion`) and
/// measure nonsense.
///
/// ## Reading the output
///
/// One `.info` line per instrumented display cycle, on subsystem
/// `com.tbd.app`, category `commitlatency`:
///
///     commit draws=<n> drawms=<f> commitms=<f> vis=<0|1>
///
/// - `draws` — terminal views that drew in this transaction
/// - `drawms` — first terminal view about to draw → last terminal draw
///   returned (the app-side paint span)
/// - `commitms` — first draw's start → render server committed (the missing leg)
/// - `vis` — 1 if at least one of those views was genuinely on screen
///
/// Plus, when a cycle is abandoned (see `staleCycleSeconds`):
///
///     commitdrop cycles=<cumulative count>
///
/// `scripts/diag/commit-latency-report.py` parses both.
///
/// ## Gating
///
/// Default OFF behind `AppState.enableCommitLatencyDiagnosticKey`. Per-frame
/// `.info` logging is far too heavy to ship on, and this registers a
/// completion block on a transaction it does not own — neither is acceptable
/// outside a measurement session.
@MainActor
final class TerminalCommitLatencyProbe {
    /// Where a finished line goes. Injected so tests can capture without a
    /// log-store round trip.
    typealias Emit = @MainActor (String) -> Void

    /// Registers a block to run once the render server has committed the
    /// transaction currently in flight.
    typealias RegisterCommitCompletion = @MainActor (@escaping @Sendable () -> Void) -> Void

    nonisolated static let logger = Logger(subsystem: "com.tbd.app", category: "commitlatency")

    /// A cycle whose completion block has not fired this long after its first
    /// draw is assumed lost and abandoned, so one swallowed block cannot wedge
    /// the instrument for the rest of the session. A block is lost whenever
    /// AppKit or SwiftUI sets its own completion block on the same transaction
    /// after we set ours — `setCompletionBlock` replaces, it does not chain.
    nonisolated static let staleCycleSeconds: Double = 0.5

    /// Monotonic seconds. `Duration` is behaviour, `Date` is data, and this is
    /// behaviour — so uptime, not wall clock, and never a `Date` difference.
    private let now: @MainActor () -> Double
    private let registerCommitCompletion: RegisterCommitCompletion
    private let emit: Emit

    private struct Cycle {
        let id: UInt64
        let startedAt: Double
        var draws: Int
        /// When the last terminal draw in this cycle returned. Nil until the
        /// first `onFramePresented`; a cycle can in principle be invalidated
        /// without any view actually drawing, and then `drawms` is 0.
        var lastPresentedAt: Double?
        var anyOnScreen: Bool
    }

    private var cycle: Cycle?
    private var nextCycleID: UInt64 = 0
    private var droppedCycles = 0

    init(
        now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
        registerCommitCompletion: @escaping RegisterCommitCompletion
            = TerminalCommitLatencyProbe.defaultRegisterCommitCompletion,
        emit: @escaping Emit = { line in
            TerminalCommitLatencyProbe.logger.info("\(line, privacy: .public)")
        }
    ) {
        self.now = now
        self.registerCommitCompletion = registerCommitCompletion
        self.emit = emit
    }

    /// The probe's own clock, so the call site stamps both ends of a draw off
    /// the same source the completion block will use.
    func timestamp() -> Double { now() }

    // MARK: - Recording

    /// Called from `TBDTerminalView.viewWillDraw()`, which AppKit sends on the
    /// main thread inside the transaction it is building for this display
    /// cycle — that is what makes the completion-block registration land on
    /// the right transaction.
    func recordDrawWillBegin(at startedAt: Double, isOnScreen: Bool) {
        if var open = cycle {
            if startedAt - open.startedAt > Self.staleCycleSeconds {
                // The completion block for that cycle never arrived. Drop it
                // and start fresh rather than counting draws into a cycle that
                // will never be reported.
                droppedCycles += 1
                emit("commitdrop cycles=\(droppedCycles)")
                cycle = nil
            } else {
                open.draws += 1
                open.anyOnScreen = open.anyOnScreen || isOnScreen
                cycle = open
                return
            }
        }

        nextCycleID += 1
        let id = nextCycleID
        cycle = Cycle(
            id: id,
            startedAt: startedAt,
            draws: 1,
            lastPresentedAt: nil,
            anyOnScreen: isOnScreen
        )
        registerCommitCompletion { [weak self] in
            // CoreAnimation runs the completion block on the thread that
            // committed the transaction, which for an AppKit display cycle is
            // the main thread. Hopping via `DispatchQueue.main.async` instead
            // would fold an unrelated dispatch latency into `commitms`.
            MainActor.assumeIsolated {
                self?.completeCycle(id: id)
            }
        }
    }

    /// Called from `TerminalView.onFramePresented` at the end of a terminal
    /// draw. Only moves the end of the app-side paint span; a frame presented
    /// with no cycle open (nothing of ours drew) is ignored.
    func recordFramePresented(at presentedAt: Double) {
        guard cycle != nil else { return }
        cycle?.lastPresentedAt = presentedAt
    }

    private func completeCycle(id: UInt64) {
        // A block from an already-abandoned cycle must not close the current
        // one; the id makes stale blocks inert.
        guard let open = cycle, open.id == id else { return }
        let committedAt = now()
        cycle = nil
        let drawSeconds = (open.lastPresentedAt ?? open.startedAt) - open.startedAt
        emit(
            "commit draws=\(open.draws)"
                + " drawms=\(Self.millis(drawSeconds))"
                + " commitms=\(Self.millis(committedAt - open.startedAt))"
                + " vis=\(open.anyOnScreen ? 1 : 0)"
        )
    }

    nonisolated private static func millis(_ seconds: Double) -> String {
        String(format: "%.3f", seconds * 1000)
    }

    // MARK: - CoreAnimation seam

    /// Registers `block` on the `CATransaction` currently in flight.
    ///
    /// **`CATransaction.setCompletionBlock` has no getter and unconditionally
    /// replaces any block already set on this transaction.** There is no way
    /// to read the incumbent and chain to it. Two consequences we accept
    /// because this is a default-off diagnostic and for no other reason:
    /// a block someone else set earlier in this cycle is discarded by us, and
    /// a block someone else sets later discards ours (that cycle then reports
    /// nothing and is eventually counted by the stale-cycle drop). Setting one
    /// per view instead of one per cycle would make the second case the common
    /// case.
    static func defaultRegisterCommitCompletion(_ block: @escaping @Sendable () -> Void) {
        CATransaction.setCompletionBlock(block)
    }

    /// Points SwiftTerm's frame-presented diagnostics hook at this probe.
    ///
    /// The hook is a process-wide static with a single slot, so installing
    /// takes sole ownership of it. That is safe here only because TBD uses it
    /// nowhere else; a second user would need a real fan-out in the fork. Only
    /// `shared` installs, so a probe built by `make(defaults:)` in a test
    /// never touches process-global state.
    func installFramePresentedHook() {
        TerminalView.onFramePresented = { [weak self] in
            // SwiftTerm calls this on the main thread from the Core Graphics
            // `draw` path, and off-main only from the Metal renderer — which
            // TBD does not use. Ignoring a non-main call keeps that assumption
            // from turning into a crash if it ever stops holding, and hopping
            // to main instead would fold dispatch latency into the span.
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordFramePresented(at: self.now())
            }
        }
    }

    // MARK: - Visibility

    /// Whether AppKit would actually put this view's pixels on screen.
    ///
    /// TBD keeps terminals for unselected worktrees alive and fed inside a
    /// visible window, so the window-level checks alone are not enough:
    /// `window.occlusionState` reports the *window*, and admits views that
    /// AppKit correctly never draws because they are clipped entirely out of
    /// their scroll/pager container. The non-empty `visibleRect` is what
    /// separates those.
    static func isOnScreen(_ view: NSView) -> Bool {
        guard let window = view.window, window.isVisible else { return false }
        guard window.occlusionState.contains(.visible) else { return false }
        return !view.visibleRect.isEmpty
    }

    // MARK: - Gate

    private static var didResolveShared = false
    private static var sharedStorage: TerminalCommitLatencyProbe?

    /// The process-wide probe, or `nil` when the diagnostic is off — which is
    /// the default. `nil` is the whole gate: the draw call site's `guard let`
    /// falls straight through to `super.draw`, so nothing is timed, nothing is
    /// logged, and no completion block is registered.
    ///
    /// Resolved once, on the first terminal draw. Flipping the flag takes
    /// effect on the next launch; a measurement session starts with a relaunch
    /// anyway.
    static var shared: TerminalCommitLatencyProbe? {
        if !didResolveShared {
            didResolveShared = true
            sharedStorage = make(defaults: .standard)
            sharedStorage?.installFramePresentedHook()
        }
        return sharedStorage
    }

    /// Builds a probe if the flag in `defaults` is on, `nil` otherwise. The
    /// injectable half of `shared`, so both branches of the gate are testable
    /// without touching `UserDefaults.standard` — which on this unbundled
    /// executable is the developer's live `TBDApp.plist`.
    static func make(defaults: UserDefaults) -> TerminalCommitLatencyProbe? {
        guard AppState.commitLatencyDiagnosticEnabled(defaults: defaults) else { return nil }
        return TerminalCommitLatencyProbe()
    }
}
