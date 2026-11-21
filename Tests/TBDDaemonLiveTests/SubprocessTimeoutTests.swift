import Darwin
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib

/// The kill path of `runBoundedProcess` when the child's streams are a
/// pseudo-terminal. The pipe-mode deadline, drain and grandchild cases are
/// `GitManagerTimeoutTests`, which drives the same runner through `GitManager`;
/// `SubprocessTimeoutStarvationTests` covers the production
/// `SubprocessWatchdog` on a real clock.
///
/// **Tier 3** — spawns a real child and drives the real SIGTERM→SIGKILL path.
/// Only the *deadline* is virtual.
///
/// An explicit `.timeLimit(.minutes(1))` rather than `.clockDriven`: this is
/// tier 3, which CI runs as `--filter '^TBDDaemonLiveTests\.' --no-parallel`
/// on an otherwise-idle machine, so real arming latency is milliseconds and
/// the five-minute budget `.clockDriven` carries for the fast parallel pass is
/// not needed. `requireSleeperArmed`'s default is 45 s, so the test waits on
/// one handshake only; two would trip the limit.
@Suite("Subprocess timeout / kill path", .timeLimit(.minutes(1)))
struct SubprocessTimeoutTests {

    /// Far enough out that the real watchdog cannot reach it inside the suite's
    /// one-minute hang limit, so only the `EventDrivenTestClock` can fire the deadline.
    private static let unreachableTimeout: Duration = .seconds(600)

    /// How long `pseudoTerminalRunTimesOutAndKillsTheChild` waits to observe
    /// the child disappear. Kept small enough that one `requireAdvanceWhenArmed`
    /// guard (45 s) plus this budget still fits the suite's 60 s limit.
    private static let killObservationBudget: Duration = .seconds(10)

    /// The deadline and the kill must still work when the child's streams are a
    /// pseudo-terminal rather than pipes — the mode replaces the pipe pair with
    /// one `openpty(3)` descriptor, and the deadline path snapshots and CLOSES
    /// that descriptor before it signals. A pty primary is a character device,
    /// so nothing about closing it terminates the child; only the SIGTERM does.
    ///
    /// The kill is asserted, not assumed, and the observation is deliberately
    /// argv-based rather than pid-file-based. Under an `EventDrivenTestClock` the deadline
    /// is armed BEFORE `Process.run()` and fires the instant the test advances,
    /// so the child is killed on arrival — it may never execute a single line,
    /// and anything it was asked to write down would race. Its argv, by
    /// contrast, is set by the kernel at spawn, so a per-run marker embedded in
    /// the `-c` string identifies it whether or not it ever ran. The leading
    /// `:;` matters: `/bin/sh -c "<one simple command>"` exec-optimizes into
    /// the command itself and the marker would be lost with the shell's argv.
    ///
    /// The assertion is not vacuous, because `.timedOut` can only be reached
    /// after `Process.run()` succeeded — so a marked process definitely existed,
    /// and "no live marked process remains" is a real claim about the
    /// SIGTERM→SIGKILL path. Mutation-checked: neutering BOTH signals turns this
    /// red (`still live: [<pid> S /bin/sh -c :; sleep 60 # tbd-pty-timeout-…]`).
    /// Deleting only the SIGTERM
    /// does NOT redden it — the 500 ms SIGKILL escalation covers that on its
    /// own, which is the escalation working as designed, not a weak assertion.
    ///
    /// Worth recording for anyone reasoning about this mode: closing the pty
    /// primary does **not** by itself terminate the child. `Process` does not
    /// `setsid`, so the child never acquires the pty as its CONTROLLING
    /// terminal and no SIGHUP is delivered when the last primary descriptor
    /// closes — measured directly, a child survived the close indefinitely.
    /// The signals are the only thing that ends it.
    ///
    /// The `sleep 60` grandchild is NOT killed and may linger for its full
    /// minute — tolerated orphanage, as in `GitManagerTimeoutTests`' grandchild
    /// tests.
    @Test func pseudoTerminalRunTimesOutAndKillsTheChild() async throws {
        let marker = "tbd-pty-timeout-\(UUID().uuidString)"

        let clock = EventDrivenTestClock()
        let call = Task {
            try await runBoundedProcess(
                executable: "/bin/sh",
                arguments: ["-c", ":; sleep 60 # \(marker)"],
                currentDirectory: nil,
                timeout: Self.unreachableTimeout,
                stdio: .pseudoTerminal,
                clock: clock
            )
        }
        try await clock.requireAdvanceWhenArmed(by: Self.unreachableTimeout)
        let outcome = try await call.value
        guard case .timedOut = outcome else {
            Issue.record("expected .timedOut under .pseudoTerminal, got \(outcome)")
            return
        }

        // Bounded poll (assertion-hygiene rule 3): the runner escalates
        // SIGTERM → SIGKILL after 500ms of REAL time and Foundation reaps the
        // child asynchronously, so "gone" is observable but not instant. A
        // reaped-but-unwaited zombie still appears in `ps`, hence the `Z` filter.
        var survivors: [String] = []
        let deadline = ContinuousClock.now + Self.killObservationBudget
        while ContinuousClock.now < deadline {
            survivors = try await liveProcessLines(matching: marker)
            if survivors.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if !survivors.isEmpty {
            Issue.record(PTYChildSurvivedDeadline(
                survivors: survivors, waited: Self.killObservationBudget))
        }
    }

    /// `ps` lines for non-zombie processes whose argv contains `marker`.
    private func liveProcessLines(matching marker: String) async throws -> [String] {
        let outcome = try await runBoundedProcess(
            executable: "/bin/ps",
            arguments: ["-Ao", "pid=,stat=,command="],
            currentDirectory: nil,
            timeout: .seconds(15)
        )
        guard case .completed(_, let stdout, _) = outcome else { return [] }
        return (String(data: stdout, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(marker) && !$0.contains(" Z") }
    }
}

/// Timeout diagnostic for `pseudoTerminalRunTimesOutAndKillsTheChild`. A thrown
/// `Error` rather than an `#expect` message so the OBSERVED state reaches the
/// primary failure line, and therefore the CI summary (`Tests/CLAUDE.md`,
/// assertion-hygiene rule 4).
private struct PTYChildSurvivedDeadline: Error, CustomStringConvertible {
    let survivors: [String]
    let waited: Duration
    var description: String {
        "the pty child outlived its deadline by \(waited) — the SIGTERM→SIGKILL "
            + "path did not reach it; still live: \(survivors)"
    }
}
