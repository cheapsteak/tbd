import Darwin
import Foundation
import os

private let reaperLogger = Logger(subsystem: "com.tbd.app", category: "childReaper")

/// Records whether SwiftTerm's own exit monitor already observed a child's exit
/// — and therefore already called `waitpid` on it.
///
/// One instance per terminal coordinator. `record()` is called from the
/// `LocalProcessDelegate.processTerminated` callback; `wasObserved` gates the
/// teardown reap, both on the main queue and again on the reaper thread.
///
/// Serialization note. The *writer* side runs on main for TWO independent
/// reasons, and both must be kept in mind. First: both TBD call sites pass
/// `dispatchQueue: .main` explicitly — keep it that way — and the
/// `DispatchSourceProcess` is created with `queue: dispatchQueue`
/// (`directDelivery` moves only data delivery onto the IO thread; it does not
/// affect the exit monitor's queue).
/// Second, since upstream `1c3f353`: `setEventHandler` is now armed BEFORE
/// `activate()`, and upstream documents that `activate()` can invoke the
/// handler SYNCHRONOUSLY for an already-exited child — on that path the handler
/// runs on the activating thread rather than being dispatched to
/// `dispatchQueue`. That is still main here, because both call sites start the
/// process from main-isolated code — `TerminalPanelRepresentable.Coordinator`'s
/// `startTmuxClient(terminalView:bridge:server:windowID:)` and
/// `LocalPTYTerminalRepresentable.Coordinator.start(terminalView:argv:environment:)`,
/// both `@MainActor` — so do not "simplify" either call site off the main
/// actor without revisiting this. (Both `Coordinator`s are nested in the
/// `NSViewRepresentable`, not in the `View`/file of the same name.) The *reader* side: both `cleanup()` implementations are
/// `@MainActor`, so the compiler enforces it — this is a guarantee, not the
/// `dismantleNSView` convention it used to rest on.
///
/// The lock is still not decorative, on two independent grounds. It is what
/// makes the flag safe to read from `ChildReaper`'s own reaper thread, which
/// happens on every reap. And a future call site that passed an explicit
/// `dispatchQueue:` would move the writer off main, where nothing above would
/// protect it.
final class ChildExitObservation: Sendable {
    private let observed = OSAllocatedUnfairLock<Bool>(initialState: false)

    var wasObserved: Bool { observed.withLock { $0 } }

    func record() { observed.withLock { $0 = true } }
}

/// Reaps forked PTY children that nothing else will `waitpid` for.
///
/// SwiftTerm's `LocalProcess` calls `waitpid` from exactly one place: the
/// `DispatchSourceProcess` (`.exit`) handler installed by
/// `startProcessWithForkpty`. Both of its teardown paths cancel that source
/// *before* the child has actually exited —
///
/// - `deinit` cancels the monitor, then closes the master fd; the child only
///   notices the resulting `SIGHUP` afterwards.
/// - `terminate()` cancels the monitor directly (`takeResourcesForShutdown()`
///   → `cancelMonitor()`), closes the write channel, and only then sends
///   `SIGTERM` — the monitor is already gone before the signal can land.
///
/// — so on both paths the `.exit` event never fires, `waitpid` is never called,
/// and the child stays a zombie under TBDApp for the life of the app. Observed
/// in the field as 67 permanently-`<defunct>` `tmux … attach` children.
///
/// The fix is to guarantee the `waitpid` ourselves at teardown, without
/// changing *how* the child is asked to die. A blocking `waitpid` is the
/// deterministic instrument for that: it reaps whether the child is still
/// running (it blocks until exit), already a zombie (returns immediately), or
/// already reaped (`ECHILD`, immediately). Registering a second
/// `DispatchSourceProcess` would not be — arming one against a pid that has
/// already exited is not guaranteed to deliver `NOTE_EXIT`, which is precisely
/// the failure being fixed.
///
/// **Each reap gets a thread of its own, and deliberately not a libdispatch
/// worker.** A reap parks for the child's whole remaining lifetime — which the
/// known limitation below says can be forever — and libdispatch's
/// non-overcommit worker pool, the one every `DispatchQueue.global()` block and
/// every private *concurrent* queue draws from, is capped per process at
/// `kern.wq_max_constrained_threads` (64 on a stock macOS install). That pool
/// is shared with everything else in the app that uses a global queue —
/// `FileWatcher`, the file viewer, transcript image actions — so a reap that
/// held one of its workers would be spending a scarce app-wide resource on
/// waiting, and enough stuck children would freeze all of it. The converse is
/// the failure that was actually measured: once other work has the pool full,
/// a reap queued on it never *starts*, and the zombie this type exists to
/// collect is left exactly where it was. A `Thread` is a plain pthread outside
/// that cap; it costs a stack and nothing else, and teardowns are rare.
///
/// **Sole-waiter discipline — what is guaranteed, and what is not.** Never
/// commit a `waitpid` for a pid another waiter may also claim: whoever wins
/// frees the pid, the OS may recycle it for a newly forked child, and the loser
/// can then steal that unrelated child's exit status. Two things narrow that to
/// a residual, and the residual is real.
///
/// - Each call site releases its `LocalProcess` inside `cleanup()`, so `deinit`
///   cancels `childMonitor` at a known moment rather than whenever ARC gets
///   round to it. No exit handler is scheduled after that.
/// - `ChildExitObservation` carries the monitor's claim to both of `reap`'s
///   checks, covering every case where the handler ran before teardown looked.
///
/// **The residual, stated rather than glossed: this is not airtight.**
/// Cancelling a dispatch source does *not* retroactively un-enqueue a handler
/// invocation that is already queued. So a child that exits in the narrow
/// window before `cleanup()` releases its `LocalProcess` can leave a handler
/// queued on main that runs after we have already committed a `waitpid`, and
/// then both of us have waited on one pid.
///
/// What that actually costs, so the risk is legible rather than alarming. The
/// loser's `waitpid` returns `ECHILD` and SwiftTerm reports `exitCode` 0, so
/// the terminal prints "[View detached — session is still running]" instead of
/// naming the real exit code: one wrong message, no lost state. The serious
/// outcome — reaping an unrelated child — additionally requires the pid to be
/// recycled into a *new* child of this process inside the microseconds between
/// the winner's `waitpid` and the loser's, which is a coincidence on top of a
/// race. Note the common teardown path does not even enter this window:
/// `TmuxBridge.cleanupSession` kills the tmux session from a *detached* task,
/// so the attach client normally exits after `cleanup()` has already cancelled
/// the monitor, leaving this reaper as the only waiter.
///
/// It is therefore a narrow race that is deliberately left open rather than
/// closed by making cleanup depend on the main queue — see `reap`.
///
/// **Known limitation, deliberately not handled here:** a child that ignores
/// `SIGHUP` (and `SIGTERM`, on the path that sends one) never exits, so its
/// reaper thread parks forever. Bounding that wait and escalating to `SIGKILL`
/// is a separate change — it needs an injected clock per `CLAUDE.md` and it
/// changes how the child is asked to die, which this fix deliberately does not.
enum ChildReaper {
    /// Which reaps are still parked, so `drainPendingReaps` can say when every
    /// reap started before a given moment has finished. Sequence numbers are
    /// handed out in `reap` order, so "everything started before this call"
    /// is "every in-flight sequence below the counter as it stood then".
    private struct Ledger {
        var nextSequence: UInt64 = 0
        var inFlight: Set<UInt64> = []
        var waiters: [(threshold: UInt64, done: @Sendable () -> Void)] = []

        /// Waiters whose reaps have all finished; removed from `waiters`.
        ///
        /// **`threshold <= lowestInFlight`, and the `=` is the whole
        /// decision.** A waiter's threshold is `nextSequence` as it stood when
        /// its drain was requested — one *past* the last reap that drain
        /// covers. So a reap whose sequence is exactly the threshold was
        /// registered after the drain, is none of its business, and must not
        /// hold it open.
        ///
        /// Tightening this to `<` is invisible to a sequential test: with
        /// nothing in flight the minimum is the `UInt64.max` of an empty set,
        /// which is above every threshold either way. Run one at a time against
        /// the mutation, `backgroundReapClearsTheZombie` and
        /// `reapsWhileTheConstrainedWorkerPoolIsExhausted` both still pass.
        /// What `<` breaks is a drain waiting while a *later* reap is parked on
        /// a child that has not exited — the drain then waits for a reap it
        /// does not cover — and
        /// `ChildReaperTests.drainIgnoresAReapRegisteredAfterIt` constructs
        /// exactly that and fails on it in isolation. (In the parallel pass the
        /// mutation reddens every drain-awaiting test, because some sibling's
        /// reap is usually in flight; that is overlap doing the work, not any
        /// of those tests asserting this.)
        ///
        /// This is the only comparison in the ledger, deliberately — see
        /// `drainPendingReaps`.
        mutating func takeSatisfiedWaiters() -> [@Sendable () -> Void] {
            let lowestInFlight = inFlight.min() ?? UInt64.max
            let satisfied = waiters.filter { $0.threshold <= lowestInFlight }
            waiters.removeAll { $0.threshold <= lowestInFlight }
            return satisfied.map(\.done)
        }
    }

    private static let ledger = OSAllocatedUnfairLock(initialState: Ledger())

    /// The teardown decision, pure so both branches are directly testable.
    ///
    /// `pid <= 0` is rejected because those are not pids to `waitpid`: `0`
    /// means the caller's whole process group and `-1` means any child, either
    /// of which would park on, and reap, unrelated processes. A control-mode
    /// panel has no `LocalProcess` at all and yields `0` here.
    static func shouldReap(pid: pid_t, alreadyObserved: Bool) -> Bool {
        pid > 0 && !alreadyObserved
    }

    /// Reap `pid` in the background unless `observation` says SwiftTerm's own
    /// monitor already did. Fire-and-forget; returns immediately.
    ///
    /// Deliberately not routed through the main queue. Hopping through main
    /// before committing would resolve the residual race above, by ordering
    /// this behind any exit handler already queued there — but it would make
    /// every reap wait on main-queue liveness, and main is the thread this app
    /// has a `HangWatchdog` for. Cleanup that stops working precisely when the
    /// app is unhealthy is the wrong trade for a race whose realistic outcome
    /// is one wrong exit code in one terminal message.
    static func reap(pid: pid_t, unless observation: ChildExitObservation) {
        // Cheap early-out, and the only check a control-mode panel (pid 0)
        // ever reaches — it keeps teardown from starting a pointless thread.
        guard shouldReap(pid: pid, alreadyObserved: observation.wasObserved) else { return }
        // Registered before the thread starts, so a drain requested the
        // instant `reap` returns already counts this one.
        let sequence = ledger.withLock { state in
            let sequence = state.nextSequence
            state.nextSequence += 1
            state.inFlight.insert(sequence)
            return sequence
        }
        let thread = Thread {
            defer { finish(sequence) }
            // Re-checked here because time can pass before this thread is
            // scheduled, and the check costs one lock acquisition.
            guard shouldReap(pid: pid, alreadyObserved: observation.wasObserved) else { return }
            reapBlocking(pid: pid)
        }
        thread.name = "com.tbd.app.child-reaper"
        // Nothing waits on the result; the same band the old queue ran at.
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func finish(_ sequence: UInt64) {
        let satisfied = ledger.withLock { state in
            state.inFlight.remove(sequence)
            return state.takeSatisfiedWaiters()
        }
        for done in satisfied { done() }
    }

    /// Test seam: runs `done` once every reap started *before this call* has
    /// finished. Never used by production code — nothing here waits on a
    /// reap, deliberately (see `reap`).
    ///
    /// Why this exists. `reap(pid:unless:)` registers its reap **synchronously**
    /// before it returns, so a drain requested after a teardown has returned
    /// covers every reap that teardown started. That turns "has the reap
    /// happened yet?" from a window a test must poll into an event it can await
    /// — and, unlike polling, it tells the two failures apart: once `done` runs,
    /// the reap has *finished*, so a child that still exists means the reap did
    /// not reap it, not that it had not been scheduled yet. Polling cannot make
    /// that distinction at all, which is why a polling test can only ever
    /// report "still there after N tries".
    ///
    /// `done` runs on the calling thread when nothing is in flight, and
    /// otherwise on the reaper thread whose completion satisfied the wait —
    /// never on a libdispatch worker, for the reason the type comment gives.
    ///
    /// **Caveat: the drain is process-wide, not per-pid.** It also waits on
    /// reaps started by any concurrently running test, and each reap parks
    /// until *its* child exits. That is bounded — every child in these suites
    /// exits within a second — but it is not free, and a caller that spawned a
    /// long-lived child elsewhere in the process pays for it here.
    static func drainPendingReaps(_ done: @escaping @Sendable () -> Void) {
        let alreadyDrained = ledger.withLock { state -> Bool in
            // No comparison here, on purpose. Every sequence ever handed out is
            // below `nextSequence`, so anything in flight is necessarily a reap
            // this drain covers: "nothing in flight" is exactly "everything
            // covered has already finished". Written as a threshold comparison
            // it would read as a second decision a reader has to check against
            // the one in `takeSatisfiedWaiters` — and as one no test could
            // distinguish, since the only value it can ever be compared with is
            // the `UInt64.max` of an empty set.
            if state.inFlight.isEmpty { return true }
            state.waiters.append((threshold: state.nextSequence, done: done))
            return false
        }
        if alreadyDrained { done() }
    }

    /// Blocking `waitpid` for `pid`. Returns `waitpid`'s result: the reaped pid,
    /// or `-1` when there was nothing to reap (`ECHILD`).
    ///
    /// Never call this on a thread you care about — it blocks until the child
    /// exits. `reap(pid:unless:)` is the ordinary entry point; this is exposed
    /// so the behavior can be tested without a scheduling handshake.
    @discardableResult
    static func reapBlocking(pid: pid_t) -> pid_t {
        guard pid > 0 else { return -1 }
        var status: Int32 = 0
        var result: pid_t = -1
        repeat {
            result = waitpid(pid, &status, 0)
        } while result == -1 && errno == EINTR
        if result == -1 {
            let code = errno
            // ECHILD is the expected benign case: someone else already reaped
            // it, or it was never our child.
            if code != ECHILD {
                reaperLogger.error(
                    "waitpid(\(pid, privacy: .public)) failed: errno \(code, privacy: .public)")
            }
        } else {
            reaperLogger.debug(
                "reaped child pid \(result, privacy: .public) status \(status, privacy: .public)")
        }
        return result
    }
}
