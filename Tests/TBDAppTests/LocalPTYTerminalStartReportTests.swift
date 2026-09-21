import AppKit
import Darwin
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp

// Types the suite uses, kept at file scope rather than nested: the suite is
// `@MainActor`, and a nested `CustomStringConvertible` would raise the question
// of whether its `description` satisfies a nonisolated requirement. These
// answer it by not being nested.

/// Catches the reported date. A class rather than a captured `var` so the
/// closure's capture is unambiguous, and unlocked rather than thread-safe
/// because `start` is `@MainActor` and calls `onStarted` synchronously — the
/// write happens on the same thread, inside the same statement, as the call
/// that triggers it.
private final class StartReport {
    var date: Date?
}

/// Everything one attempt observed, all of it read before that attempt's
/// coordinator was torn down.
private struct StartAttempt {
    let shellPid: pid_t
    let childfd: Int32
    let cols: Int
    let rows: Int
    let reported: Date?
    let before: Date
    let after: Date
}

/// Named diagnostic for "the machine would not give us a pty", carrying the
/// state that decides between the plausible causes. Thrown rather than
/// `#expect`ed for the reason assertion-hygiene rule 4 in `Tests/CLAUDE.md`
/// gives: only `Issue.record(_: some Error)` puts this text on the primary
/// failure line, and an `#expect` message is demoted to a `↳` line that CI
/// summaries drop.
private struct ForkptyProducedNoChild: Error, CustomStringConvertible {
    let observedPIDs: [pid_t]
    let ttyDeviceCount: Int
    let openFileDescriptors: Int?

    var description: String {
        let fds = openFileDescriptors.map(String.init) ?? "unavailable"
        let pids = observedPIDs.map(String.init).joined(separator: ", ")
        return "LocalPTYTerminalRepresentable.Coordinator.start produced no child in "
            + "\(observedPIDs.count) attempts — PseudoTerminalHelpers.fork returned nil and "
            + "LocalProcess.startProcess surfaces neither an error nor an errno of its own. "
            + "Observed shellPids: \(pids). errno is not legible from here, because start() "
            + "runs several more statements after the fork. /dev/ttys* entries: "
            + "\(ttyDeviceCount); open fds in this process (via /dev/fd, includes this probe's "
            + "own): \(fds). Nothing here says the start report is broken — it says no pty was "
            + "available to report a start for."
    }
}

/// The failure this suite exists to produce.
private struct StartWentUnreported: Error, CustomStringConvertible {
    let shellPid: pid_t
    let childfd: Int32

    var description: String {
        "start() forked a child (shellPid \(shellPid), master fd \(childfd)) and never called "
            + "onStarted. That report is the only thing that dates an attach child for "
            + "AppState.restartRemoteAttachChildren(startedBefore:), so without it every attach "
            + "pane reads as 'not yet spawned', a network change restarts nothing, and the "
            + "#884 tests all stay green — they inject the date through markRemoteAttachStarted "
            + "rather than producing it here."
    }
}

/// Tier 2: drives the real
/// `LocalPTYTerminalRepresentable.Coordinator.start(terminalView:argv:environment:)`
/// through a real `forkpty` and a real child — no tmux server, no daemon, no
/// `~/tbd`. Sibling in spirit to `TerminalTeardownReapTests`, which drives the
/// same coordinator's `cleanup()` the same way; this one drives the spawn side.
///
/// **What this pins that nothing else does.** `onStarted?(Date())` in `start`
/// is the *only* producer of the instant that dates an attach child for
/// `AppState.restartRemoteAttachChildren(startedBefore:)` — the pane hands it
/// to `AppState.markRemoteAttachStarted` from `RemoteAttachPager`. Every other
/// test of the network-recovery feature (#884) calls `markRemoteAttachStarted`
/// directly with a date it made up, so none of them touches that statement.
/// Remove the call, or move the `process.childfd >= 0` guard to before the
/// fork so it reads the `-1` a fresh `LocalProcess` carries, and every attach
/// pane reads as "not yet spawned": a network change finds nothing to restart,
/// the whole feature silently does nothing, and the rest of the suite stays
/// green. This test is the one that goes red.
///
/// **Why it builds the view itself instead of going through `makeNSView`.**
/// Two reasons, both hard. `makeNSView` calls
/// `AppState.metalTerminalRendererEnabled()`, which resolves
/// `UserDefaults.standard` — on this unbundled executable that is the
/// developer's real `TBDApp.plist` (root `CLAUDE.md`, "Tests must not touch
/// ~/tbd"). And it starts nothing itself: the spawn is deferred to
/// `TBDTerminalView.onReady`, which fires from a real layout pass with
/// non-zero bounds that a view in no window never gets. So the fixture builds
/// the same `TBDTerminalView` `makeNSView` builds, with the same frame and the
/// same appearance source, and calls the same `start` that `onReady` calls —
/// with `argv` and `environment` passed verbatim, as the representable passes
/// them.
///
/// **The negative branch is deliberately untested.** `childfd < 0` needs a
/// `forkpty` that fails, which cannot be induced from inside the process
/// without exhausting the machine's ptys — and doing that would take every
/// concurrently running suite down with it. The guard is covered only in the
/// direction that has an observable: a child exists, therefore a start is
/// reported.
///
/// **`@MainActor` on the whole suite, unlike `TerminalTeardownReapTests`.**
/// That suite avoids it because its tests re-acquire main at each of ~200 poll
/// resumptions; this one contains no poll, no wait and no suspension point at
/// all — every statement is synchronous main-isolated work — so the suite-wide
/// annotation costs exactly the one main acquisition a `MainActor.run` would.
/// For the same reason it carries no time limit: there is no wait here for a
/// hang guard to bound.
@MainActor
@Suite("Local PTY start report")
struct LocalPTYTerminalStartReportTests {

    /// How many times a spawn that produced no child is attempted again.
    /// Three, for the reason `TerminalTeardownReapTests.forkptyAttempts` gives:
    /// the pty race it covers is one revoke wide. Only a fork that produced
    /// **nothing** is retried — a failed fork leaves no child, so a healthy run
    /// and an unhealthy one both spawn at most one — and `shellPid` is
    /// `LocalProcess` state that no change to the start report can influence,
    /// so this can neither re-run nor mask the assertion under test.
    private static let forkptyAttempts = 3

    /// Long enough that the child is certainly still running when `cleanup()`
    /// SIGTERMs it a few microseconds later, which is the production-faithful
    /// path for this coordinator; short enough that a teardown which somehow
    /// failed to kill it still leaves nothing behind.
    private static let childLifetime = "0.4"

    /// The same view `makeNSView` builds, minus the two things that would reach
    /// outside this test (see the suite comment). Isolated defaults:
    /// `AppearanceSettings` must never read or write the developer's real
    /// `TBDApp.plist` — same idiom as `TerminalLockedAccessTests`.
    private func makeTerminalView() -> TBDTerminalView {
        let suiteName = "TBDAppTests.LocalPTYStartReport.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults))
    }

    /// Runs one real `start` and tears its coordinator down again, returning
    /// what it observed.
    ///
    /// The teardown happens here, before anything can throw: a `defer`
    /// registered after a throwing `#require` never runs at all, so a child
    /// this fixture spawned has to be disposed of before the first assertion
    /// rather than after it. `cleanup()` is the production disposal —
    /// `terminate()` plus `ChildReaper.reap` — and `TerminalTeardownReapTests`
    /// is what pins that it works; this suite only has to call it.
    private func runStart(on view: TBDTerminalView) -> StartAttempt {
        let coordinator = LocalPTYTerminalRepresentable.Coordinator()
        coordinator.terminalView = view
        let report = StartReport()
        coordinator.onStarted = { report.date = $0 }

        // Bracketed rather than compared against a freshness window —
        // assertion hygiene rule 2 in `Tests/CLAUDE.md`.
        let before = Date()
        coordinator.start(
            terminalView: view,
            argv: ["/bin/sleep", Self.childLifetime],
            environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"])
        let after = Date()

        // Read `LocalProcess` state BEFORE cleanup() releases it — it is the
        // only thing that knows the pid and the master fd.
        let shellPid = coordinator.localProcess?.shellPid ?? 0
        let childfd = coordinator.localProcess?.childfd ?? -1
        let dims = view.terminalDimensions
        coordinator.cleanup()

        return StartAttempt(
            shellPid: shellPid, childfd: childfd, cols: dims.cols, rows: dims.rows,
            reported: report.date, before: before, after: after)
    }

    /// How many `/dev/ttys*` slave devices exist right now — the direct read on
    /// "the machine ran out of ptys". Failure path only.
    private static func ttyDeviceCount() -> Int {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries.filter { $0.hasPrefix("ttys") }.count
    }

    /// Open descriptors in this process, counted through `/dev/fd`, which
    /// darwin populates per-process. Nil when the directory cannot be read.
    private static func openFileDescriptorCount() -> Int? {
        try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    @Test("start reports the spawn instant once a real child exists")
    func startReportsTheSpawnInstant() throws {
        let view = makeTerminalView()

        var observedPIDs: [pid_t] = []
        var landed: StartAttempt?
        for attempt in 1...Self.forkptyAttempts {
            let result = runStart(on: view)
            observedPIDs.append(result.shellPid)
            if result.shellPid > 0 {
                landed = result
                break
            }
            // A real sleep, on the failure path only: this is synchronous
            // `@MainActor` code with no suspension point to yield at, and the
            // pty revoke it waits out is a kernel-side transition nothing in
            // scheduling can hurry. Same shape and same 10 ms as
            // `TerminalTeardownReapTests.startChild`.
            if attempt < Self.forkptyAttempts { usleep(10_000) }
        }

        guard let attempt = landed else {
            throw ForkptyProducedNoChild(
                observedPIDs: observedPIDs,
                ttyDeviceCount: Self.ttyDeviceCount(),
                openFileDescriptors: Self.openFileDescriptorCount())
        }

        // The fixture has to be the one production builds, or the guard under
        // test is not the guard being exercised: `childfd` is what start()
        // reads to decide a child exists, and non-zero dimensions are what put
        // the TIOCSWINSZ leg beside it on the same evidence.
        #expect(attempt.childfd >= 0, "a forked child must carry a pty master fd")
        #expect(attempt.cols > 0, "the view must report real columns, not placeholders")
        #expect(attempt.rows > 0, "the view must report real rows, not placeholders")

        guard let reported = attempt.reported else {
            throw StartWentUnreported(shellPid: attempt.shellPid, childfd: attempt.childfd)
        }
        #expect(
            reported >= attempt.before && reported <= attempt.after,
            "the reported instant must be the spawn's own, not one taken elsewhere")
    }
}
