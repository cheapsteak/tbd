import AppKit
import Foundation
import QuartzCore
import SwiftTerm
import os

/// Measures a leg of the terminal render path nothing else instruments:
/// **app starts drawing → the app has finished committing that frame.**
///
/// ## What it actually measures — read this before quoting a number
///
/// `commitms` is: first terminal `viewWillDraw` of a transaction → the
/// `CATransaction` completion block for that transaction runs.
///
/// **That is app-side only. It does NOT cross into the render server, and it
/// is nowhere near time-to-glass.** Measured on this machine with a real
/// on-screen window and real committed layer changes, the completion block
/// runs **12–99 microseconds after `CATransaction.commit()` returns**, on the
/// same runloop turn. Nothing makes a round trip to `WindowServer` in 20µs.
/// Apple's contract for `setCompletionBlock` says only that the block runs
/// "as soon as all animations subsequent to this transaction group have
/// completed", and that with no animations it "will be invoked immediately" —
/// the render server is not mentioned, because it is not involved.
///
/// So this instrument covers the app's own cost of assembling and committing
/// the frame — `CA::Transaction::commit` on the main thread, the last thing
/// `sample` could see before the trail left the process. **The render-server
/// leg remains uninstrumented.** No public API exposes it for a
/// CoreGraphics-drawn `NSView`; `CAMetalDrawable.addPresentedHandler` would,
/// but TBD does not use the Metal renderer.
///
/// A small `commitms` therefore licenses NO conclusion about the compositor.
/// It says the app hands the frame over quickly, which was already the
/// direction the evidence pointed. Do not read it as "the render server is
/// fine".
///
/// ## The distortion that will bite you: animations
///
/// Because the block waits for *animations*, not for a commit, any animation
/// added inside a transaction the probe marked redefines `commitms` for that
/// cycle. Measured here:
///
/// - A finite 0.6s animation → the block fired **675ms** after commit. That
///   sample reports the animation's duration and lands straight in p90/p99,
///   looking exactly like the compositor stall this instrument was built to
///   look for.
/// - An infinite animation → the block **never fired**. The cycle is lost and
///   surfaces as a `commitdrop`.
///
/// TBD's terminal has both shapes in it: SwiftTerm's caret blink is
/// `repeatCount = .infinity` (`MacCaretView`), and the overlay scroller fades
/// over 0.25s — during scrolling, which is the lag repro. These are added on
/// state changes rather than per frame, so the effect is episodic, not
/// constant.
///
/// **`sync` is the discriminator.** The probe schedules a marker for the end
/// of the current runloop turn. `sync=1` means the completion block beat it —
/// same turn, no animation wait, the number means what it says. `sync=0` means
/// the block arrived later, so the sample is an animation wait, a commit that
/// spanned turns, or both, and the two cannot be told apart from inside the
/// process. Report `sync=1` and `sync=0` separately; never pool them.
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
///   `Package.swift` carries a standing warning from the #750 bump that a frame
///   loop not running on the main thread may never call `viewWillDraw()`, so
///   TBD's terminal diagnostics can go quiet. It does not bite here: SwiftTerm
///   takes the render-loop path only when the Metal layer surface is enabled,
///   TBD never enables it, and `frameTick` therefore falls through to
///   `setNeedsDisplay` and an ordinary AppKit display pass. **If this
///   instrument ever logs nothing at all, suspect that assumption before
///   concluding there is no lag** — silence here is indistinguishable from a
///   fast frame.
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
/// ## Per-transaction, not per-view — and the boundary is exact
///
/// Several terminal views can draw in one display cycle and they all land in
/// the same `CATransaction`. The probe therefore keys its state on the
/// *transaction*: `t0` is stamped at the first terminal draw in a transaction,
/// later draws in the same one fold into it — raising `draws`, and `vis` if
/// any of them was on screen — and exactly one line is
/// logged when the completion block fires. Registering a block per view would
/// overwrite the previous one (see `TransactionSeam`) and measure nonsense.
///
/// **Transaction identity comes from the transaction itself, not from a
/// stopwatch.** `CATransaction.setValue(_:forKey:)` is a per-transaction store
/// with a getter, so the probe stamps its cycle id there and reads it back on
/// the next draw: same mark means same transaction, no mark means a new one.
/// One edge the mark does not cover: a nested transaction inherits its
/// parent's mark on read and discards its own writes at its commit (measured),
/// so a terminal draw *joining* an existing cycle is safe. But a cycle's
/// FIRST draw landing while a nested transaction is current would mark and
/// register on the nested one, which commits early — `commitms` would measure
/// that nested commit and later draws in the display cycle would read no mark
/// and emit a spurious drop. TBD has one nested transaction, in
/// `TypingDotsView.layout()`; interleaving it with a terminal draw is
/// unlikely, and this is recorded rather than defended against.
///
/// An elapsed-time heuristic cannot do this job — AppKit's cadence is ~16.67ms,
/// so any window wide enough to tolerate a slow commit is also wide enough to
/// swallow the following cycle whole. That failure would grow with exactly the
/// latency this instrument exists to characterize, silently merging frames and
/// leaving later transactions with no completion block at all.
///
/// ## Reading the output
///
/// One `.info` line per instrumented display cycle, on subsystem
/// `com.tbd.app`, category `commitlatency`:
///
///     commit draws=<n> paints=<n> drawms=<f> commitms=<f> vis=<0|1> sync=<0|1>
///
/// - `draws` — terminal views that drew in this transaction
/// - `paints` — terminal draws that actually reached the end of `draw`. Less
///   than `draws` means a view bailed before painting, and `drawms` is
///   meaningless for that cycle; `paints=0` makes a `drawms=0.000` that means
///   "nothing painted" distinguishable from one that means "painted instantly".
/// - `drawms` — first terminal view about to draw → last terminal draw
///   returned (the app-side paint span)
/// - `commitms` — first draw's start → the transaction's completion block ran
/// - `vis` — 1 if at least one of those views was genuinely on screen
/// - `sync` — 1 if the completion block ran in the same runloop turn as the
///   draw. Only `sync=1` samples are comparable; see above.
///
/// Plus, one line per cycle whose completion block never fired:
///
///     commitdrop draws=<n> vis=<0|1>
///
/// One line per lost cycle rather than a running total, so a reader working
/// over a time window counts the drops in that window rather than inheriting a
/// process-lifetime counter. A cycle is declared lost the moment a draw arrives
/// in a different transaction — promptly and exactly, not on a timer. The one
/// loss that goes uncounted is a final cycle at the end of a session with no
/// draw after it.
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

    /// The per-transaction seam: reads back the mark the probe left on the
    /// `CATransaction` currently in flight, and stamps a new one together with
    /// the completion block that closes it. Injected so tests can open and
    /// commit transactions by hand.
    struct TransactionSeam {
        /// The cycle id the probe stamped on the transaction currently in
        /// flight, or nil if it has not marked this one — which is exactly how
        /// "a new transaction has begun" is detected.
        var mark: @MainActor () -> UInt64?

        /// Stamps `cycleID` on the transaction currently in flight and
        /// registers `onCommitted` to run when CoreAnimation completes it —
        /// which, absent animations, is microseconds later on the same
        /// runloop turn. See the type header: this is not a render-server ack.
        var begin: @MainActor (_ cycleID: UInt64, _ onCommitted: @escaping @Sendable () -> Void) -> Void

        /// Key for the probe's per-transaction mark. Namespaced because the
        /// transaction's value store is shared with everything else drawing
        /// in this process.
        static let markKey = "com.tbd.app.commitLatency.cycle"

        /// The real seam.
        ///
        /// **`CATransaction.setCompletionBlock` has no getter and
        /// unconditionally replaces any block already set on this
        /// transaction.** There is no way to read the incumbent and chain to
        /// it. Two consequences we accept because this is a default-off
        /// diagnostic and for no other reason: a block someone else set
        /// earlier in this cycle is discarded by us, and a block someone else
        /// sets later discards ours — that cycle then reports nothing and is
        /// counted by the drop line at the next transaction. Setting one per
        /// view instead of one per transaction would make the second case the
        /// common case.
        static let coreAnimation = TransactionSeam(
            mark: { (CATransaction.value(forKey: markKey) as? NSNumber)?.uint64Value },
            begin: { cycleID, onCommitted in
                CATransaction.setValue(NSNumber(value: cycleID), forKey: markKey)
                CATransaction.setCompletionBlock(onCommitted)
            }
        )
    }

    /// Runs `body` once the current runloop turn's work has drained. Used
    /// only to date-stamp the turn boundary for `sync`; injected so tests can
    /// fire it deterministically.
    typealias AfterCurrentTurn = @MainActor (@escaping @MainActor () -> Void) -> Void

    nonisolated static let logger = Logger(subsystem: "com.tbd.app", category: "commitlatency")

    /// Monotonic seconds. `Duration` is behaviour, `Date` is data, and this is
    /// behaviour — so uptime, not wall clock, and never a `Date` difference.
    private let now: @MainActor () -> Double
    private let transaction: TransactionSeam
    private let afterCurrentTurn: AfterCurrentTurn
    private let emit: Emit

    private struct Cycle {
        let id: UInt64
        let startedAt: Double
        var draws: Int
        /// Terminal draws in this cycle that reached the end of `draw`.
        var paints: Int
        /// When the last terminal draw in this cycle returned. Nil while
        /// `paints` is 0 — SwiftTerm's `draw` has early returns before its
        /// frame-presented hook, so a view can be asked to draw and paint
        /// nothing.
        var lastPresentedAt: Double?
        var anyOnScreen: Bool
        /// False once the current runloop turn has drained with this cycle
        /// still open — i.e. the completion block did not run in the same
        /// turn as the draw, so an animation (or a commit spanning turns)
        /// is folded into `commitms`.
        var sameTurn: Bool
    }

    private var cycle: Cycle?
    private var nextCycleID: UInt64 = 0

    init(
        now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
        transaction: TransactionSeam = .coreAnimation,
        afterCurrentTurn: @escaping AfterCurrentTurn = { body in
            DispatchQueue.main.async { body() }
        },
        emit: @escaping Emit = { line in
            TerminalCommitLatencyProbe.logger.info("\(line, privacy: .public)")
        }
    ) {
        self.now = now
        self.transaction = transaction
        self.afterCurrentTurn = afterCurrentTurn
        self.emit = emit
    }

    /// The probe's own clock, so the call site stamps both ends of a draw off
    /// the same source the completion block will use.
    func timestamp() -> Double { now() }

    // MARK: - Recording

    /// Called from `TBDTerminalView.viewWillDraw()`, which AppKit sends on the
    /// main thread inside the transaction it is building for this display
    /// cycle — that is what makes the mark and the completion block land on
    /// the right transaction.
    func recordDrawWillBegin(at startedAt: Double, isOnScreen: Bool) {
        let mark = transaction.mark()

        if var open = cycle {
            if mark == open.id {
                open.draws += 1
                open.anyOnScreen = open.anyOnScreen || isOnScreen
                cycle = open
                return
            }
            // A different transaction is in flight while our cycle is still
            // open, so that cycle's completion block has not run. Two causes,
            // and from inside the process they are indistinguishable: somebody
            // replaced our block on that transaction, or an animation in it is
            // still running and CoreAnimation is still holding the block. Do
            // not claim which. Report the cycle lost, with the draws and the
            // visibility that went with it — drops cluster on animated frames
            // rather than falling randomly, so a reader needs to know whether
            // the lost ones were on screen.
            emit("commitdrop draws=\(open.draws) vis=\(open.anyOnScreen ? 1 : 0)")
            cycle = nil
        }

        nextCycleID += 1
        let id = nextCycleID
        cycle = Cycle(
            id: id,
            startedAt: startedAt,
            draws: 1,
            paints: 0,
            lastPresentedAt: nil,
            anyOnScreen: isOnScreen,
            sameTurn: true
        )
        afterCurrentTurn { [weak self] in
            self?.markTurnEnded(id: id)
        }
        transaction.begin(id) { [weak self] in
            // CoreAnimation runs the completion block on the thread that
            // committed the transaction, which for an AppKit display cycle is
            // the main thread. Hopping via `DispatchQueue.main.async` instead
            // would fold an unrelated dispatch latency into `commitms`. The
            // guard matches `installFramePresentedHook`: if that assumption
            // ever stops holding, this diagnostic goes quiet rather than
            // crashing the app.
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                self?.completeCycle(id: id)
            }
        }
    }

    /// Called from `TerminalView.onFramePresented` at the end of a terminal
    /// draw. Only moves the end of the app-side paint span; a frame presented
    /// with no cycle open (nothing of ours drew) is ignored.
    func recordFramePresented(at presentedAt: Double) {
        guard var open = cycle else { return }
        open.paints += 1
        open.lastPresentedAt = presentedAt
        cycle = open
    }

    /// The current runloop turn has drained. If the cycle is still open its
    /// completion block did not run in the same turn as the draw, so whatever
    /// `commitms` ends up being is not a clean app-side commit.
    private func markTurnEnded(id: UInt64) {
        guard var open = cycle, open.id == id else { return }
        open.sameTurn = false
        cycle = open
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
                + " paints=\(open.paints)"
                + " drawms=\(Self.millis(drawSeconds))"
                + " commitms=\(Self.millis(committedAt - open.startedAt))"
                + " vis=\(open.anyOnScreen ? 1 : 0)"
                + " sync=\(open.sameTurn ? 1 : 0)"
        )
    }

    nonisolated private static func millis(_ seconds: Double) -> String {
        String(format: "%.3f", seconds * 1000)
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
    /// the default. `nil` is the whole gate: `TBDTerminalView.viewWillDraw()`
    /// returns right after its `super.viewWillDraw()` call, so nothing is
    /// timed, nothing is logged, no transaction is marked, and no completion
    /// block is registered.
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
