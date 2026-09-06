import Darwin
import Dispatch
import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib

// Tier 2: spawns short-lived local processes (/usr/bin/env, /bin/cat) it fully
// controls, no ~/tbd access, no setenv, bounded waits only.
@Suite("BoundedProcessRunner")
struct BoundedProcessRunnerTests {
    @Test func environmentReplacesRatherThanMerges() async throws {
        let outcome = try await runBoundedProcess(
            executable: "/usr/bin/env",
            arguments: [],
            currentDirectory: nil,
            environment: ["FOO": "bar"],
            timeout: .seconds(10)
        )
        guard case .completed(let status, let stdout, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == 0)
        let text = String(data: stdout, encoding: .utf8) ?? ""
        #expect(text.contains("FOO=bar"))
        // A parent-set variable omitted from the dict must NOT survive — proves
        // `environment` is assigned directly, not merged with the parent's.
        #expect(!text.contains("PATH="))
    }

    @Test func nilEnvironmentInheritsParent() async throws {
        let outcome = try await runBoundedProcess(
            executable: "/usr/bin/env",
            arguments: [],
            currentDirectory: nil,
            timeout: .seconds(10)
        )
        guard case .completed(let status, let stdout, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == 0)
        let text = String(data: stdout, encoding: .utf8) ?? ""
        #expect(text.contains("PATH="))
    }

    @Test func stdinIsDeliveredVerbatim() async throws {
        let payload = Data("hello bounded process".utf8)
        let outcome = try await runBoundedProcess(
            executable: "/bin/cat",
            arguments: [],
            currentDirectory: nil,
            stdin: payload,
            timeout: .seconds(10)
        )
        guard case .completed(let status, let stdout, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == 0)
        #expect(stdout == payload)
    }

    /// `cat` reads to EOF before exiting. If the runner failed to close the
    /// stdin pipe's write end after writing, `cat` would block forever
    /// waiting for more input and this test would hang until the 10s
    /// deadline and report `.timedOut` instead of `.completed`.
    @Test func stdinWriteEndIsClosedSoChildTerminates() async throws {
        let outcome = try await runBoundedProcess(
            executable: "/bin/cat",
            arguments: [],
            currentDirectory: nil,
            stdin: Data("closes promptly".utf8),
            timeout: .seconds(10)
        )
        guard case .completed(let status, _, _) = outcome else {
            Issue.record("expected .completed (child hung on unclosed stdin?), got \(outcome)")
            return
        }
        #expect(status == 0)
    }

    /// Regression for the final pre-merge review's item 1: a child that
    /// exits before reading (or ever draining) its stdin must fail the
    /// WRITE, not the whole daemon process. `/bin/sh -c "exit 7"` never
    /// touches its stdin and exits immediately; the payload here (well past
    /// darwin's ~64KB pipe buffer) forces `write(contentsOf:)` to actually
    /// hit the broken pipe rather than have the whole thing land in the
    /// kernel buffer before the child's fd closes — with a small payload
    /// this test would pass by accident (the write never blocks long enough
    /// to observe EPIPE) regardless of which overload production code uses.
    ///
    /// This is deterministic BECAUSE of that sizing, not in spite of it: the
    /// child exits near-instantly and a >64KB write cannot complete without
    /// the reader (the child) draining it, so the write is guaranteed to
    /// observe the closed read end — no timing race with the child's exit.
    /// `signal(SIGPIPE, SIG_IGN)` mirrors `main.swift`'s process-wide stance
    /// (see `PaneFanoutFlowControlTests.routeHardErrorCountsDroppedRemainder`
    /// for the same pattern) — without it, the raw SIGPIPE would kill this
    /// TEST process before the write even has a chance to return an error.
    ///
    /// Before the fix, `stdinPipe.fileHandleForWriting.write(stdin)` (the
    /// non-throwing overload) raised an uncatchable
    /// `NSFileHandleOperationException` on this exact EPIPE, which would
    /// have aborted the whole test process rather than merely failing an
    /// assertion — so a green run of this test is itself part of the proof.
    @Test func childExitingBeforeReadingLargeStdinFailsTheCallNotTheProcess() async throws {
        signal(SIGPIPE, SIG_IGN)
        let oversizedPayload = Data(repeating: 0x41, count: 200_000)
        let outcome = try await runBoundedProcess(
            executable: "/bin/sh",
            arguments: ["-c", "exit 7"],
            currentDirectory: nil,
            stdin: oversizedPayload,
            timeout: .seconds(10)
        )
        guard case .completed(let status, _, _) = outcome else {
            Issue.record("expected .completed with the child's exit status, got \(outcome)")
            return
        }
        #expect(status == 7)
    }

    /// Every other `.pseudoTerminal` test in this file drives a child that
    /// exits 0, so none of them can tell a correctly-read exit status from one
    /// hardcoded to zero. `childExitingBeforeReadingLargeStdinFailsTheCallNotTheProcess`
    /// above proves status 7 survives under `.pipes`; this is its `.pseudoTerminal`
    /// twin, closing the one gap that shape leaves — a status-reading bug
    /// (e.g. reading the wrong process, or a stray `status == 0` fallback)
    /// specific to the pty branch would pass every existing pty test here and
    /// only show up on a nonzero exit.
    @Test func pseudoTerminalModePreservesTheChildsNonzeroExitStatus() async throws {
        let outcome = try await runBoundedProcess(
            executable: "/bin/sh", arguments: ["-c", "echo hello; exit 7"],
            currentDirectory: nil, timeout: .seconds(10), stdio: .pseudoTerminal)
        guard case .completed(let status, let stdout, let stderr) = outcome else {
            Issue.record("expected .completed under .pseudoTerminal, got \(outcome)")
            return
        }
        #expect(status == 7)
        #expect((String(data: stdout, encoding: .utf8) ?? "").contains("hello"))
        #expect(stderr.isEmpty)
    }

    /// The whole point of the mode. The vendor CLI refuses `--cloud` creation
    /// when stdout is not a terminal, so a probe that reports what it sees is
    /// the only assertion that proves the child got one. Both arms run the SAME
    /// probe, so the test discriminates rather than merely passing.
    @Test func pseudoTerminalModeGivesTheChildATty() async throws {
        let probe = "if [ -t 1 ]; then echo tty; else echo pipe; fi"

        let pty = try await runBoundedProcess(
            executable: "/bin/sh", arguments: ["-c", probe],
            currentDirectory: nil, timeout: .seconds(10), stdio: .pseudoTerminal)
        guard case .completed(let ptyStatus, let ptyOut, let ptyErr) = pty else {
            Issue.record("expected .completed under .pseudoTerminal, got \(pty)")
            return
        }
        #expect(ptyStatus == 0)
        #expect((String(data: ptyOut, encoding: .utf8) ?? "").contains("tty"))
        // One file descriptor: everything the child wrote is on stdout.
        #expect(ptyErr.isEmpty)

        let piped = try await runBoundedProcess(
            executable: "/bin/sh", arguments: ["-c", probe],
            currentDirectory: nil, timeout: .seconds(10))
        guard case .completed(let pipeStatus, let pipeOut, _) = piped else {
            Issue.record("expected .completed under the default .pipes, got \(piped)")
            return
        }
        #expect(pipeStatus == 0)
        #expect((String(data: pipeOut, encoding: .utf8) ?? "").contains("pipe"))
    }

    /// A pty has a small kernel buffer, so the incremental drain matters here
    /// at least as much as it does for a pipe: a child that outruns it would
    /// otherwise block on write while the parent waits for exit.
    @Test func pseudoTerminalModeDrainsMoreThanOneBufferful() async throws {
        let outcome = try await runBoundedProcess(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' 'x'"],
            currentDirectory: nil, timeout: .seconds(20), stdio: .pseudoTerminal)
        guard case .completed(let status, let stdout, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == 0)
        // Raw mode, so no CR is inserted and the byte count is exact.
        #expect(stdout.count == 200_000)
    }

    /// The replica is the child's stdin AND its stdout on one descriptor, so
    /// there is no write end to close and a child waiting for EOF would hang
    /// forever. Refusing loudly beats hanging quietly; `create` passes no stdin.
    @Test func pseudoTerminalModeRefusesAStdinPayload() async {
        await #expect(throws: BoundedProcessRunnerError.stdinUnsupportedOnPseudoTerminal) {
            _ = try await runBoundedProcess(
                executable: "/bin/cat", arguments: [],
                currentDirectory: nil, stdin: Data("hi".utf8),
                timeout: .seconds(10), stdio: .pseudoTerminal)
        }
    }

    /// The reported terminal geometry is wide ON PURPOSE and a comment alone
    /// cannot stop someone "restoring" it to the 24x80 that
    /// `TmuxControlConnection` uses. A pty never wraps by itself — `winsize` is
    /// advisory metadata — but a child that reads `TIOCGWINSZ` formats to it and
    /// inserts REAL newlines at the wrap, which then corrupt the captured bytes.
    /// At 80 columns the headroom over a realistic output line was six
    /// characters. `stty size` is what the child sees, so this pins the actual
    /// contract rather than the constant's spelling.
    @Test func pseudoTerminalReportsAWideGeometryToTheChild() async throws {
        let outcome = try await runBoundedProcess(
            executable: "/bin/sh", arguments: ["-c", "stty size"],
            currentDirectory: nil, timeout: .seconds(10), stdio: .pseudoTerminal)
        guard case .completed(let status, let stdout, _) = outcome else {
            Issue.record("expected .completed under .pseudoTerminal, got \(outcome)")
            return
        }
        #expect(status == 0)
        let reported = (String(data: stdout, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(reported == "200 400", "child saw rows/cols \(reported.debugDescription), wanted \"200 400\"")
    }

    /// The merge itself, asserted directly rather than inferred from an empty
    /// `stderr`. `pseudoTerminalModeGivesTheChildATty` checks only that the
    /// reported stderr is empty, and emptiness is the WRONG witness: deleting
    /// `process.standardError = replicaHandle` leaves it empty too — the
    /// child's stderr would simply escape to the daemon's own stderr, where the
    /// CLI's error text vanishes unlogged and a nonzero status arrives with
    /// nothing to diagnose from. Requiring BOTH streams to appear in `stdout`
    /// is the contract; the empty `stderr` is only its consequence.
    ///
    /// Its `.pipes` twin is `defaultStdioIsStillPipes` below, which runs the
    /// same probe and requires the two streams to stay SEPARATE — so between
    /// them the merge is pinned in both directions.
    @Test func pseudoTerminalModeMergesStderrIntoStdout() async throws {
        let outcome = try await runBoundedProcess(
            executable: "/bin/sh", arguments: ["-c", "echo out; echo err 1>&2"],
            currentDirectory: nil, timeout: .seconds(10), stdio: .pseudoTerminal)
        guard case .completed(let status, let stdout, let stderr) = outcome else {
            Issue.record("expected .completed under .pseudoTerminal, got \(outcome)")
            return
        }
        #expect(status == 0)
        let merged = String(data: stdout, encoding: .utf8) ?? ""
        #expect(merged.contains("out"), "child's stdout missing from the merged capture: \(merged.debugDescription)")
        #expect(merged.contains("err"), "child's stderr missing from the merged capture: \(merged.debugDescription)")
        // One descriptor, so there is nothing left to report separately.
        #expect(stderr.isEmpty)
    }

    /// The default is unchanged, which is what keeps every existing call site
    /// on pipes without being revisited.
    @Test func defaultStdioIsStillPipes() async throws {
        let outcome = try await runBoundedProcess(
            executable: "/bin/sh", arguments: ["-c", "echo out; echo err 1>&2"],
            currentDirectory: nil, timeout: .seconds(10))
        guard case .completed(_, let stdout, let stderr) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect((String(data: stdout, encoding: .utf8) ?? "").contains("out"))
        #expect((String(data: stderr, encoding: .utf8) ?? "").contains("err"))
    }

    // MARK: - The deadline path must not block the shared watchdog

    /// A child that IGNORES SIGTERM must still be gone when the call returns,
    /// which can only happen if the SIGKILL escalation ran.
    ///
    /// The escalation is queued on the same `SubprocessWatchdog` thread that
    /// just ran the deadline action, so it can only fire if that action left the
    /// thread free. That is why the snapshot no longer runs there: it acquires
    /// the accumulator lock, a drain worker can hold that lock across a blocking
    /// read on a pipe the child still owns, and an action that waits there waits
    /// for the escalation it queued behind itself — a deadlock that would take
    /// every other bounded deadline in the daemon down with it.
    ///
    /// `trap '' TERM` before `exec` is what makes the child TERM-proof and keeps
    /// it a single process: `SIG_IGN` survives `exec`, so the sleeping process
    /// itself ignores SIGTERM, holds the stdout pipe, and strands no grandchild.
    ///
    /// **What discriminates here is the child, and the fixture is sized so that
    /// stays true.** The sleeper outlives `TestDeadlines.saturatedPass` several
    /// times over (`Self.childLifetimeSeconds`), so "the escalation ran" and
    /// "the call waited its child out" can never produce the same observation:
    /// a call that waits its child out cannot return inside the bound, and a
    /// child nobody killed cannot be gone inside it either. A 30 s sleeper —
    /// what this fixture used to be — collapsed that distinction, because
    /// natural exit beat the bound.
    ///
    /// Both bounds are therefore `TestDeadlines.saturatedPass` rather than a
    /// snappier number. A wall-clock ceiling tuned to the healthy path (~1.2 s)
    /// measures the runner instead of the code: fast pass 1 runs ~1800 tests in
    /// parallel on a loaded macOS runner whose per-test latency has a p50 near
    /// 65 s, and the 20 s ceiling this used to carry went red at 31.3 s on green
    /// code.
    ///
    /// The *wedged-snapshot* property — that a blocking snapshot cannot cost
    /// another call its deadline — is pinned deterministically by
    /// `aSecondDeadlineIsServedWhileAnotherCallsSnapshotIsWedged` below, which
    /// holds the snapshot through a seam instead of racing a clock.
    @Test func aTermIgnoringChildIsKilledByTheEscalationAtItsDeadline() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pidFile = scratch.appendingPathComponent("pid")

        let started = ContinuousClock.now
        let outcome = try await runBoundedProcess(
            executable: "/bin/sh",
            arguments: ["-c", Self.termIgnoringScript(pidFile: pidFile)],
            currentDirectory: nil,
            timeout: .milliseconds(300),
            stdio: .pipes)
        let elapsed = ContinuousClock.now - started

        guard case .timedOut = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            return
        }
        #expect(elapsed < TestDeadlines.saturatedPass,
                "a 300 ms deadline resolved after \(elapsed) — the call waited its child out")

        let recorded = Self.readPid(from: pidFile)
        defer { if let recorded { kill(recorded, SIGKILL) } }
        let pid = try #require(recorded, "the child never recorded its pid")
        try await waitFor(
            "the TERM-ignoring child to be reaped",
            observed: { Self.isAlive(pid) ? "pid \(pid) still alive" : "pid \(pid) gone" }
        ) { !Self.isAlive(pid) }
    }

    /// A second bounded call's deadline AND its SIGKILL escalation must both be
    /// served while a first call's deadline-path snapshot is wedged.
    ///
    /// This is the property the deferred snapshot exists to provide, and it is
    /// asserted here **without comparing any elapsed time**. The earlier version
    /// of this test raced two real deadlines and bounded the pair by a wall
    /// clock; on a saturated CI pass that ceiling measured the runner (40.6 s
    /// against a 20 s bound, on green code) rather than the code under test.
    ///
    /// The seam is `beforeDeadlineSnapshot`, which runs immediately before the
    /// deadline path's snapshot *wherever that snapshot runs*. Holding it is
    /// therefore an exact model of the hazard: with the fix it holds the first
    /// call's own task and nothing else; without it, it holds the one watchdog
    /// thread every bounded deadline in the daemon shares.
    ///
    /// **The first call is given a virtual clock nobody ever advances, and that
    /// is what makes the hold land where the hazard is.** `runBoundedProcess`
    /// arms its deadline twice — once on the watchdog thread, once on the
    /// injected clock — and under a real clock those two race to the same
    /// instant. A hold on whichever won would be a coin flip: the clock armer
    /// fires the action from the calling task, where blocking costs nothing that
    /// this test can see. An `EventDrivenTestClock` left at its start instant
    /// never fires, so armer 1 is the only armer, the action runs on the
    /// watchdog thread, and the seam is reached from the one place where running
    /// the snapshot inline would be fatal. The second call keeps the real clock:
    /// it is the observer, and nothing about it should be virtual.
    ///
    /// While the hold is in place, the second call must report `.timedOut` and
    /// its TERM-ignoring child must be gone. Only the watchdog can deliver that
    /// SIGKILL — the clock armer can resume a continuation but signals nothing —
    /// so a reaped second child is proof the watchdog was free. Both
    /// observations complete before the release, and `firstReturned` records
    /// that the first call really was still wedged while they were made.
    ///
    /// Verified by mutation: running the deposited work inline in the deadline
    /// action (`beforeDeadlineSnapshot?(); _ = snapshot()` in place of the
    /// `deferredSnapshot.deposit`, which is exactly the pre-fix structure) wedges
    /// the watchdog on the hold, and the second call's child is still alive when
    /// the bounded wait gives up.
    @Test func aSecondDeadlineIsServedWhileAnotherCallsSnapshotIsWedged() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let firstPidFile = scratch.appendingPathComponent("first")
        let secondPidFile = scratch.appendingPathComponent("second")

        // Entry is announced asynchronously (nothing on the observing side ever
        // blocks a thread); the hold itself is a semaphore, because the seam is
        // a synchronous closure and blocking it IS the condition under test.
        let (snapshotEntered, snapshotDidEnter) = AsyncStream<Void>.makeStream()
        let releaseSnapshot = DispatchSemaphore(value: 0)
        let firstReturned = Flag()

        // `gateHoldingTask`, not `Task`: this task blocks a thread for the whole
        // observation below, and a cooperative-pool thread is exactly what the
        // rest of the pass needs. See Tests/TestSupport/BoundedGateSupport.swift.
        let first = gateHoldingTask { () -> BoundedProcessOutcome? in
            let outcome = try? await runBoundedProcess(
                executable: "/bin/sh",
                arguments: ["-c", Self.termIgnoringScript(pidFile: firstPidFile)],
                currentDirectory: nil,
                timeout: .milliseconds(200),
                stdio: .pipes,
                clock: EventDrivenTestClock(),
                beforeDeadlineSnapshot: {
                    snapshotDidEnter.yield()
                    releaseSnapshot.waitForGate("the first call's deadline snapshot")
                })
            await firstReturned.set()
            return outcome
        }
        var entries = snapshotEntered.makeAsyncIterator()
        _ = await entries.next()

        // Everything from here to `releaseSnapshot.signal()` happens with the
        // first call's snapshot held.
        let secondOutcome = try await runBoundedProcess(
            executable: "/bin/sh",
            arguments: ["-c", Self.termIgnoringScript(pidFile: secondPidFile)],
            currentDirectory: nil,
            timeout: .milliseconds(200),
            stdio: .pipes)
        guard case .timedOut = secondOutcome else {
            Issue.record("expected the second call to time out, got \(secondOutcome)")
            releaseSnapshot.signal()
            return
        }

        let recordedSecond = Self.readPid(from: secondPidFile)
        defer { if let recordedSecond { kill(recordedSecond, SIGKILL) } }
        let secondPid = try #require(recordedSecond, "the second child never recorded its pid")
        try await waitFor(
            "the second call's TERM-ignoring child to be reaped while a snapshot is wedged",
            observed: { Self.isAlive(secondPid) ? "pid \(secondPid) still alive" : "pid \(secondPid) gone" }
        ) { !Self.isAlive(secondPid) }

        let returnedEarly = await firstReturned.value
        #expect(!returnedEarly,
                """
                the first call returned before the hold was released — it was never wedged, \
                so nothing above was observed under the condition this test exists for
                """)

        releaseSnapshot.signal()
        let firstOutcome = await first.value
        guard case .timedOut = firstOutcome else {
            Issue.record("expected the first call to time out, got \(String(describing: firstOutcome))")
            return
        }
        let recordedFirst = Self.readPid(from: firstPidFile)
        defer { if let recordedFirst { kill(recordedFirst, SIGKILL) } }
        let firstPid = try #require(recordedFirst, "the first child never recorded its pid")
        try await waitFor(
            "the first call's TERM-ignoring child to be reaped",
            observed: { Self.isAlive(firstPid) ? "pid \(firstPid) still alive" : "pid \(firstPid) gone" }
        ) { !Self.isAlive(firstPid) }
    }

    // MARK: - Fixtures

    /// Records whether the held call has returned yet, so "observed while
    /// wedged" is asserted rather than assumed. An actor because the setter runs
    /// on the gate executor and the reader on the cooperative pool.
    private actor Flag {
        private(set) var value = false
        func set() { value = true }
    }

    /// How long the TERM-ignoring sleeper lives. It must dominate every bound in
    /// this suite — all of which are `TestDeadlines.saturatedPass` (90 s) — so a
    /// child that is gone is a child something KILLED, never one that finished
    /// its sleep inside the wait. Each such child is signalled by the escalation
    /// under test and, failing that, by its test's own `defer`.
    private static let childLifetimeSeconds = 300

    /// A `sh -c` body that records its own pid, then becomes a long-lived sleeper
    /// that ignores SIGTERM. `SIG_IGN` is inherited across `exec`, so the
    /// surviving process is the shell's own pid and nothing is left behind for a
    /// sweep.
    private static func termIgnoringScript(pidFile: URL) -> String {
        "trap '' TERM; echo $$ > '\(pidFile.path)'; exec /bin/sleep \(childLifetimeSeconds)"
    }

    private static func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-runner-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func readPid(from file: URL) -> pid_t? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Whether a pid is still signallable. A reaped child is `ESRCH`; anything
    /// else (including `EPERM`, which this test can never see for its own
    /// children) counts as alive so the wait reports rather than passing blind.
    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }
}
