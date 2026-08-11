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
/// Serialization note. The *writer* side: `LocalProcess.init` defaults its
/// `dispatchQueue` to `DispatchQueue.main`, neither TBD call site passes one,
/// and the `DispatchSourceProcess` is created with `queue: dispatchQueue`, so
/// the monitor handler and the delegate callback that calls `record()` run on
/// the main queue. The *reader* side: both `cleanup()` implementations are
/// `@MainActor`, so the compiler enforces it — this is a guarantee, not the
/// `dismantleNSView` convention it used to rest on.
///
/// The lock is still not decorative, on two independent grounds. It is what
/// makes the flag safe to read from `ChildReaper`'s own background queue, which
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
/// - `terminate()` closes the fd, sends `SIGTERM`, then cancels the monitor via
///   `childStopped()`; signal delivery and process teardown are asynchronous.
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
    /// Concurrent on purpose: each reap parks a thread until its child exits,
    /// and a child that ignores `SIGHUP` would block every later reap behind it
    /// on a serial queue. Utility QoS — nothing waits on the result.
    private static let queue = DispatchQueue(
        label: "com.tbd.app.child-reaper", qos: .utility, attributes: .concurrent)

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
        // ever reaches — it keeps teardown from enqueuing a pointless block.
        guard shouldReap(pid: pid, alreadyObserved: observation.wasObserved) else { return }
        queue.async {
            // Re-checked here because an unbounded amount of time can pass
            // before this block runs, and the check costs one lock acquisition.
            guard shouldReap(pid: pid, alreadyObserved: observation.wasObserved) else { return }
            reapBlocking(pid: pid)
        }
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
