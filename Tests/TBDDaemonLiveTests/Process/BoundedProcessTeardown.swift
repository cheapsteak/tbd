import Darwin
import Foundation

/// What teardown needs to know about a child — and nothing that can block.
///
/// `Process.waitUntilExit()` is deliberately absent from this protocol, so a
/// helper written against it cannot reach the call. On macOS 26.1 that call can
/// spin forever (62.5 ms run-loop polls, 0% CPU) with `isRunning` already
/// `false`, and the mechanism is structural rather than a narrow race:
/// `Process.run()` appends the task's pointer to a **per-thread** CFArray (CF
/// thread-specific-data slot 30) created with NULL callbacks, and nothing prunes
/// that array when a task is freed — so it accumulates dangling pointers of dead
/// tasks. `waitUntilExit()` then reads "my pointer is in *this* thread's array"
/// as "this thread launched me", and in that case keeps running the run loop
/// until a termination block has run — a block the exit handler
/// `CFRunLoopPerformBlock`s onto the **launching** thread's run loop. When the
/// pointer matched only a stale entry, because the allocator handed a dead
/// task's address to a live one, that block belongs to a different thread and
/// the loop never ends.
///
/// A test suite is the ideal incubator for the stale entry: async tests resume
/// on arbitrary cooperative-pool threads that live for the whole run, and the
/// suite churns hundreds of short-lived `Process` objects on them — every `ps`
/// call in `ProductionProcessSignaller` is one. Same-thread launch-and-wait is
/// not exposed, which is why `runPS` and the shell helpers are left alone; a
/// `defer` that runs after an `await` is the shape that is.
/// `scripts/diag/nstask-waituntilexit-stale-entry.swift` reproduces the hang
/// deterministically by planting the stale entry by hand.
protocol ExitObservableProcess: AnyObject {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
}

extension Process: ExitObservableProcess {}

/// Bounded replacement for `Process.waitUntilExit()` in test teardown.
///
/// Three properties are load-bearing.
///
/// - **`isRunning == false` is a reap proof, not merely an exit proof.**
///   Foundation's exit handler clears that flag only *after* its own blocking
///   `waitpid` has collected the corpse, so a child observed not-running has
///   been reaped and is not a zombie. Teardown therefore needs no `waitpid` of
///   its own, and Foundation stays the sole waiter for the pids it owns.
/// - **The bound exists because a hung teardown is worse than a red test.** The
///   live target runs `--no-parallel` on one machine; a `defer` that never
///   returns burns the whole step's budget and reports nothing, while a bound
///   that fires reds exactly one test and carries a diagnostic saying what the
///   kernel thought of the pid at that moment. The 5-second default is sized
///   against what the wait costs while it runs: it parks the calling thread —
///   a cooperative-pool thread, when it is reached from a `defer` in an async
///   test — so it is sized to how long a SIGKILLed child's exit handler takes
///   under CI load, which is milliseconds, leaving orders of magnitude of
///   headroom. It is not sized to the unbounded wait it replaces.
/// - **There is no injected clock, deliberately.** This is a synchronous helper
///   called from `defer`, where `Task.sleep` is unavailable and the repo's
///   `Clock` seam — which is async — cannot be used. The deadline is a plain
///   parameter instead, so a caller that needs a different bound states it. It
///   is measured monotonically on purpose: a wall-clock step backwards, which
///   an NTP correction on a shared box produces, would push a `Date()` deadline
///   further into the future and re-open the unbounded wait this helper exists
///   to close.
enum BoundedProcessTeardown {
    enum Outcome: Equatable {
        /// Foundation observed the exit. Its handler clears `isRunning` only
        /// after its own `waitpid` collected the corpse, so this also means
        /// "reaped, not a zombie".
        case exited
        /// The deadline passed with `isRunning` still true. `diagnostic` says
        /// what the kernel thought of the pid at that moment.
        case unobserved(pid: Int32, diagnostic: String)
    }

    /// SIGKILL if the child is still running, then `awaitExit`.
    ///
    /// The signal is pid-exact and guarded on `pid > 0`: `kill(0, …)` signals
    /// the caller's entire process group, which in a test process is the test
    /// runner itself.
    @discardableResult
    static func killAndReap(
        _ process: any ExitObservableProcess, within seconds: Double = 5
    ) -> Outcome {
        let pid = process.processIdentifier
        if process.isRunning && pid > 0 { kill(pid, SIGKILL) }
        return awaitExit(process, within: seconds)
    }

    /// Polls `isRunning` every 20 ms until it flips or `seconds` elapse. Never
    /// signals, so it is safe on a process that must keep running. It is not
    /// observe-only on expiry: the diagnostic's `waitpid` collects the corpse of
    /// a child that has exited, so after a fired bound the child is gone from
    /// Foundation's view as well as the kernel's.
    @discardableResult
    static func awaitExit(
        _ process: any ExitObservableProcess, within seconds: Double = 5
    ) -> Outcome {
        // `ContinuousClock`, not `Date()`: the bound must not be extendable by a
        // wall-clock correction landing mid-wait.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while true {
            // Checked before the deadline and before any sleep, so a child that
            // has already exited costs nothing.
            if !process.isRunning { return .exited }
            if clock.now >= deadline { break }
            usleep(20_000)
        }
        let pid = process.processIdentifier
        return .unobserved(pid: pid, diagnostic: diagnose(pid, after: seconds))
    }

    /// One `kill(pid, 0)` reading plus one `waitpid(…, WNOHANG)`, to say which of
    /// the several very different situations the bound just fired on.
    ///
    /// **It spawns nothing, and that is not fastidiousness.** A `Process`
    /// launched here would be one more entry in this thread's per-thread task
    /// list — the precondition of the hazard this helper exists for — and `ps` is
    /// reached through a `waitUntilExit()`, so asking `ps` would put an unbounded
    /// wait into the one path that runs only when a wait has already failed.
    /// `kill(pid, 0)` answers the same question with a syscall.
    ///
    /// **The WNOHANG probe is acceptable here and only here.** Foundation owns
    /// the corpse of every child it launched, and racing its handler for one is
    /// how a sole waiter stops being sole. After the bound has already fired,
    /// though, "the handler is merely late" is not a live possibility worth
    /// protecting: the flag it would have cleared has not moved for the whole
    /// deadline. And losing the race is survivable in the direction that matters
    /// — Foundation's handler treats `ECHILD` as status −1 and still clears
    /// `isRunning`, verified against the running implementation — so the probe
    /// cannot wedge the process it is diagnosing.
    private static func diagnose(_ pid: Int32, after seconds: Double) -> String {
        // Guarded on `pid > 0` for the same reason the kill above is:
        // `waitpid(0, …)` collects any child in the caller's process group and
        // `waitpid(-1, …)` any child at all, so a non-positive pid would reap a
        // corpse this helper was never asked about.
        guard pid > 0 else { return "pid \(pid): no pid to probe (never launched?)" }

        // Read BEFORE the probe, deliberately: a WNOHANG that collects a zombie
        // frees the number, and the kernel may hand it to somebody else
        // immediately after — so a reading taken afterwards could describe a
        // stranger.
        let kernelBeforeProbe = kernelView(of: pid)

        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        let probeErrno = errno

        let finding: String
        if reaped == pid {
            finding = "zombie collected by the teardown diagnostic; Foundation never observed the exit"
        } else if reaped == 0 {
            finding = "still running \(seconds)s into the bound"
        } else if reaped == -1 && probeErrno == ECHILD {
            finding = "already collected by another waiter (sole-waiter violation)"
        } else {
            finding = "waitpid errno \(probeErrno)"
        }

        return "pid \(pid): \(finding) (kill(pid, 0) before the probe: \(kernelBeforeProbe))"
    }

    /// What `kill(pid, 0)` says about a pid, in one word. `"alive"` covers a
    /// zombie too — an uncollected corpse answers with success — which is why it
    /// is reported alongside the `waitpid` finding rather than instead of it.
    private static func kernelView(of pid: Int32) -> String {
        if kill(pid, 0) == 0 { return "alive" }
        switch errno {
        case ESRCH: return "ESRCH"
        case EPERM: return "EPERM"
        default: return "errno \(errno)"
        }
    }
}

/// The bound fired. Thrown-`Error` shape on purpose: only
/// `Issue.record(_: some Error)` puts the text on the primary failure line that
/// CI summaries keep, while `Issue.record(String)` and `#expect(cond, "…")`
/// demote it to a trailing `↳` line that those summaries drop
/// (`Tests/CLAUDE.md`, "Assertion hygiene" rule 4).
///
/// It lives beside the helper rather than in one suite so every teardown that
/// adopts the bound reports it the same way. Foundation-only by design — the
/// recording is done by the suite, which already imports `Testing`.
struct TeardownBoundExpired: Error, CustomStringConvertible {
    let pid: Int32
    let diagnostic: String

    var description: String {
        "teardown: pid \(pid) was not reaped within the bound — \(diagnostic)"
    }
}
