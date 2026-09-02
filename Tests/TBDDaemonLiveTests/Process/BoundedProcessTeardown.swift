import Darwin
import Foundation

@testable import TBDDaemonLib

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
///   kernel thought of the pid at that moment.
/// - **There is no injected clock, deliberately.** This is a synchronous helper
///   called from `defer`, where `Task.sleep` is unavailable and the repo's
///   `Clock` seam — which is async — cannot be used. The deadline is a plain
///   parameter instead, so a caller that needs a different bound states it.
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
        _ process: any ExitObservableProcess, within seconds: Double = 10
    ) -> Outcome {
        let pid = process.processIdentifier
        if process.isRunning && pid > 0 { kill(pid, SIGKILL) }
        return awaitExit(process, within: seconds)
    }

    /// Polls `isRunning` every 20 ms until it flips or `seconds` elapse. Never
    /// signals anything, so it is safe on a process the caller must leave alive.
    @discardableResult
    static func awaitExit(
        _ process: any ExitObservableProcess, within seconds: Double = 10
    ) -> Outcome {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            // Checked before the deadline and before any sleep, so a child that
            // has already exited costs nothing.
            if !process.isRunning { return .exited }
            if Date() >= deadline { break }
            usleep(20_000)
        }
        let pid = process.processIdentifier
        return .unobserved(pid: pid, diagnostic: diagnose(pid, after: seconds))
    }

    /// One `waitpid(…, WNOHANG)` plus one `ps -o stat=`, to say which of the
    /// several very different situations the bound just fired on.
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
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        // Captured immediately: `stat` below spawns `ps`, which overwrites errno.
        let probeErrno = errno

        let finding: String
        if reaped == pid {
            finding = "zombie collected by the teardown diagnostic; Foundation never observed the exit"
        } else if reaped == 0 {
            finding = "still running \(seconds)s after the signal"
        } else if reaped == -1 && probeErrno == ECHILD {
            finding = "already collected by another waiter (sole-waiter violation)"
        } else {
            finding = "waitpid errno \(probeErrno)"
        }

        let psStat = ProductionProcessSignaller().stat(pid)
        return "pid \(pid): \(finding) (ps stat: '\(psStat ?? "nil")')"
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
