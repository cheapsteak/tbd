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
/// Serialization note, stated precisely because the two call sites differ.
/// The *writer* side is the same for both: `LocalProcess.init` defaults its
/// `dispatchQueue` to `DispatchQueue.main`, neither TBD call site passes one,
/// and the `DispatchSourceProcess` is created with `queue: dispatchQueue`, so
/// the monitor handler and the delegate callback that calls `record()` run on
/// the main queue. The *reader* side is where the guarantee weakens:
/// `TerminalPanelRepresentable.Coordinator.cleanup()` is `@MainActor`, so the
/// compiler enforces it; `LocalPTYTerminalRepresentable.Coordinator.cleanup()`
/// carries no isolation annotation, and its main-thread execution rests only
/// on its sole caller being SwiftUI's `dismantleNSView` — a convention, not a
/// type-system guarantee.
///
/// So the lock is not decorative. It is real protection if that convention is
/// ever violated (a coordinator torn down off the main thread), and it is
/// load-bearing regardless of any of the above, because `ChildReaper.reap`
/// re-reads this flag from its own background queue.
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
/// **Sole-waiter invariant.** Never reap a pid that something else may also be
/// waiting on: whoever wins frees the pid, and the OS may recycle it for
/// another child of this process, so the loser's `waitpid` can steal an
/// unrelated child's exit status. Two things establish it at the call sites.
/// Each releases its `LocalProcess` inside `cleanup()`, so `deinit` runs there
/// and cancels `childMonitor` at a known moment rather than whenever ARC gets
/// round to it. And `ChildExitObservation` covers the case where the monitor
/// had *already* fired, since that path has reaped the child itself.
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
    static func reap(pid: pid_t, unless observation: ChildExitObservation) {
        guard shouldReap(pid: pid, alreadyObserved: observation.wasObserved) else { return }
        queue.async {
            // Re-checked here, not just at the call site: an unbounded amount
            // of time can pass between that decision and this block running,
            // and reaping a pid the monitor has since claimed is exactly the
            // pid-reuse hazard the sole-waiter invariant exists to prevent.
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
