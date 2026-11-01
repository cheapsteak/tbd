import DaemonTestSupport
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

    /// A child that dies of an uncaught signal has no exit status, and the
    /// runner says so rather than reporting the signal number as an exit code.
    @Test func aChildKilledBySignalIsSignaledNotCompleted() async throws {
        let outcome = try await runBoundedProcess(
            executable: "/bin/sh",
            arguments: ["-c", "echo before; kill -9 $$"],
            currentDirectory: nil,
            timeout: .seconds(10)
        )
        guard case .signaled(let signal, let stdout, _) = outcome else {
            Issue.record("expected .signaled, got \(outcome)")
            return
        }
        #expect(signal == SIGKILL)
        #expect(String(data: stdout, encoding: .utf8) == "before\n")
    }

    /// A plain non-zero exit stays `.completed`: only a signal is `.signaled`.
    @Test func aNonZeroExitIsStillCompleted() async throws {
        let outcome = try await runBoundedProcess(
            executable: "/bin/sh",
            arguments: ["-c", "exit 9"],
            currentDirectory: nil,
            timeout: .seconds(10)
        )
        guard case .completed(let status, _, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == 9)
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

    // MARK: - A failed spawn must not outlive the call

    /// A spawn that fails must release its `Process` and every pipe descriptor
    /// it created. The termination handler reaches the `Process` through the
    /// deadline, and Foundation clears a termination handler only after it
    /// fires — which a throwing `run()` never does — so an unbroken cycle keeps
    /// the `Process` and its pipes' write ends alive forever. A daemon polling
    /// git in deleted worktree folders leaked two descriptors per poll that way
    /// until pipe(2) hit EMFILE and every spawn in the process failed.
    ///
    /// The hook records a weak reference to the `Process` and the identity
    /// (device, inode) of each descriptor, and holds every pipe open with a
    /// duplicate so that identity cannot be handed to another pipe meanwhile —
    /// see `SpawnProbe` for why an unpinned identity proves nothing.
    @Test func aFailedSpawnDoesNotOutliveTheCall() async throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = SpawnProbe()
        await #expect(throws: (any Error).self) {
            _ = try await runBoundedProcess(
                executable: "/bin/echo", arguments: [],
                currentDirectory: dir.appendingPathComponent("gone").path,
                timeout: .seconds(10), didCreateProcess: probe.record)
        }
        await Self.expectReleased(probe)
    }

    /// The same, with a stdin payload: the stdin pipe is created too, and the
    /// child never received either of its ends.
    @Test func aFailedSpawnWithStdinDoesNotOutliveTheCall() async throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = SpawnProbe()
        await #expect(throws: (any Error).self) {
            _ = try await runBoundedProcess(
                executable: "/bin/echo", arguments: [],
                currentDirectory: dir.appendingPathComponent("gone").path,
                stdin: Data("x".utf8),
                timeout: .seconds(10), didCreateProcess: probe.record)
        }
        #expect(probe.descriptorCount == 6, "expected both ends of stdout, stderr and stdin")
        await Self.expectReleased(probe)
    }

    @Test func aFailedSpawnOfAMissingExecutableDoesNotOutliveTheCall() async throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = SpawnProbe()
        await #expect(throws: (any Error).self) {
            _ = try await runBoundedProcess(
                executable: dir.appendingPathComponent("no-such-tool").path, arguments: [],
                currentDirectory: nil,
                timeout: .seconds(10), didCreateProcess: probe.record)
        }
        await Self.expectReleased(probe)
    }

    /// A failed spawn leaves nothing behind that breaks the next one.
    @Test func aSpawnAfterAFailedSpawnSucceeds() async throws {
        let dir = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) {
            _ = try await runBoundedProcess(
                executable: "/bin/echo", arguments: [],
                currentDirectory: dir.appendingPathComponent("gone").path,
                timeout: .seconds(10))
        }
        let outcome = try await runBoundedProcess(
            executable: "/bin/echo", arguments: ["hi"],
            currentDirectory: nil, timeout: .seconds(10))
        guard case .completed(let status, let stdout, _) = outcome else {
            Issue.record("expected .completed, got \(outcome)")
            return
        }
        #expect(status == 0)
        #expect(String(data: stdout, encoding: .utf8) == "hi\n")
    }

    /// The check that refuses the nil-backed `Pipe` Foundation returns when
    /// pipe(2) fails. Exercised directly: exhausting the descriptor table to
    /// reach the real failure would break every test sharing this process.
    @Test func isPipeDescriptorAcceptsOnlyAnOpenPipe() throws {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        #expect(isPipeDescriptor(ends[0]))
        #expect(isPipeDescriptor(ends[1]))
        // A high number no concurrent open(2) or pipe(2) will be handed, so it
        // stays closed between the close and the check.
        let high = fcntl(ends[0], F_DUPFD_CLOEXEC, 3000)
        close(ends[0])
        close(ends[1])
        try #require(high >= 3000)
        close(high)
        #expect(!isPipeDescriptor(high), "a closed descriptor is not a pipe")
        #expect(!isPipeDescriptor(-1))

        let devNull = open("/dev/null", O_RDONLY)
        try #require(devNull >= 0)
        #expect(!isPipeDescriptor(devNull))
        close(devNull)
    }

    // MARK: - The deadline path must not block the shared watchdog

    /// A child that IGNORES SIGTERM must still be gone when the call returns,
    /// which can only happen if the SIGKILL escalation ran.
    ///
    /// The escalation is queued on the `SubprocessWatchdog` thread whichever
    /// armer fires the deadline, so it can only fire while that thread is free.
    /// That is why the snapshot no longer runs there: it acquires the
    /// accumulator lock, a drain worker can hold that lock across a blocking
    /// read on a pipe the child still owns, and a deadline action that waits
    /// there on the watchdog waits for the escalation it queued behind itself —
    /// a deadlock that would take every other bounded deadline in the daemon
    /// down with it. That a deadline action run *on* the watchdog leaves it free
    /// is pinned by `aSecondDeadlineIsServedWhileAnotherCallsSnapshotIsWedged`
    /// below; this test pins that the escalation runs at all, and that the call
    /// does not wait its child out.
    ///
    /// `trap '' TERM` before `exec` is what makes the child TERM-proof and keeps
    /// it a single process: `SIG_IGN` survives `exec`, so the sleeping process
    /// itself ignores SIGTERM, holds the stdout pipe, and strands no grandchild.
    ///
    /// **The test fires the deadline itself, once the child has recorded its
    /// pid.** The call takes an `EventDrivenTestClock`, and the test advances it
    /// only after the child has written its pid file, which the script does
    /// after its `trap`. The child then provably ignores the deadline's SIGTERM,
    /// and only the escalation's SIGKILL can end it. A deadline that raced the
    /// child's startup could end `/bin/sh` with that SIGTERM before its `trap`,
    /// because the runner measures a deadline from before `Process.run()` and a
    /// spawn alone has taken about a second in a loaded pass; a child ended that
    /// way proves nothing.
    ///
    /// **The reap `waitFor` is the check that proves the escalation ran.** The
    /// child ignores SIGTERM and sleeps for `Self.childLifetimeSeconds`, longer
    /// than every wait here, so a child that is gone inside that wait was
    /// killed, and only the escalation's SIGKILL kills it. The wait runs before
    /// the test awaits the call, so a call that waited its child out instead
    /// fails it too: nobody has killed the child by then. The check is read
    /// off the child, not off a stopwatch, so a slow runner cannot redden it.
    ///
    /// The *wedged-snapshot* property — that a blocking snapshot cannot cost
    /// another call its deadline — is pinned deterministically by
    /// `aSecondDeadlineIsServedWhileAnotherCallsSnapshotIsWedged` below, which
    /// holds the snapshot through a seam instead of racing a clock.
    @Test func aTermIgnoringChildIsKilledByTheEscalationAtItsDeadline() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pidFile = scratch.appendingPathComponent("pid")
        // Diagnostics only: what the parent saw, if the child never records
        // its pid.
        let probe = SpawnProbe(keepsProcess: true)
        // On every exit path, and only while the pid still names the child:
        // the escalation under test normally kills and reaps it first. The
        // child writes its file before anything can signal it, and a process
        // that reuses the pid starts after the child died, so after the write.
        defer { RecordedChild.killIfStartedBeforeWriting(pidFile: pidFile.path) }

        let clock = EventDrivenTestClock()
        async let outcome = runBoundedProcess(
            executable: "/bin/sh",
            arguments: ["-c", Self.termIgnoringScript(pidFile: pidFile)],
            currentDirectory: nil,
            timeout: Self.testFiredDeadline,
            stdio: .pipes,
            clock: clock,
            didCreateProcess: probe.record)
        guard let pid = try await Self.waitForRecordedPid(of: "the child", pidFile: pidFile, probe: probe)
        else { return }
        try await clock.requireAdvanceWhenArmed(by: Self.testFiredDeadline, timeout: TestDeadlines.saturatedPass)

        let reaped = try await waitFor(
            "the TERM-ignoring child to be reaped",
            observed: { Self.isAlive(pid) ? "pid \(pid) still alive" : "pid \(pid) gone" }
        ) { !Self.isAlive(pid) }
        // On a failure, return at once: leaving the call unawaited cancels it,
        // which fires its deadline if nothing has, so the exit does not wait
        // out the child.
        guard reaped else { return }
        let result = try await outcome
        guard case .timedOut = result else {
            Issue.record("expected .timedOut, got \(result)")
            return
        }
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
    /// the snapshot inline would be fatal. Its child is a plain sleeper and its
    /// deadline is short: the first call only has to reach its deadline on the
    /// watchdog and park there, whatever its child makes of the SIGTERM.
    ///
    /// **The second call's deadline is fired by the test, through a virtual
    /// clock it advances once the hold is in place.** The clock armer runs the
    /// same deadline action as the watchdog: it sends the SIGTERM itself and
    /// queues the SIGKILL escalation on the watchdog. Firing it this way leaves
    /// the watchdog the only thing that can deliver the SIGKILL, and the test
    /// advances only after the second child has written its pid file, which the
    /// script does after its `trap`, so the child provably ignores the SIGTERM.
    /// A reaped second child is therefore proof the watchdog was free. A
    /// deadline that raced the child's startup could instead end `/bin/sh` with
    /// SIGTERM before its `trap`, since the runner measures a deadline from
    /// before `Process.run()` and a spawn alone has taken about a second in a
    /// loaded pass, and a child ended that way proves nothing about the
    /// watchdog (runs 41354244199 and 41334860240 went red on a child ended
    /// that way).
    ///
    /// The decisive observation, the second child gone, completes before the
    /// release, and `firstReturned` records that the first call really was
    /// still wedged while it was made. The second call's `.timedOut` is read
    /// after the release, so that nothing which waits on the call can hold the
    /// first call parked.
    ///
    /// It does not check that the first call's own escalation completes once
    /// the hold is released. That would need a TERM-proof first child behind
    /// its short, watchdog-only deadline, which is exactly the race between a
    /// deadline and a child's startup that this test is built to avoid.
    ///
    /// The mutation this guards against: running the deposited work inline in
    /// the deadline action (`beforeDeadlineSnapshot?(); _ = snapshot()` in place
    /// of the `deferredSnapshot.deposit`, which is exactly the pre-fix
    /// structure) wedges the watchdog on the hold, so the second child, which
    /// ignores its SIGTERM, is still alive when the bounded wait gives up: its
    /// SIGKILL is queued behind the wedge.
    @Test func aSecondDeadlineIsServedWhileAnotherCallsSnapshotIsWedged() async throws {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let secondPidFile = scratch.appendingPathComponent("second")
        let firstProbe = SpawnProbe(keepsProcess: true)
        // Diagnostics only: what the parent saw, if the second child never
        // records its pid.
        let secondProbe = SpawnProbe(keepsProcess: true)
        // On every exit path, the early ones included, and only while each pid
        // still names its child; the deadlines under test normally end both
        // children first. The second child writes its pid file before anything
        // can signal it, and a process that reuses the pid starts after the
        // child died, so after the write. The first child writes no file, so it
        // is reclaimed by its parent's view, which `killChild()` reads then.
        defer {
            RecordedChild.killIfStartedBeforeWriting(pidFile: secondPidFile.path)
            firstProbe.killChild()
        }

        // The observer, started first, so that its child's startup and its
        // clock's arming are both awaited before the hold rather than inside it.
        let secondClock = EventDrivenTestClock()
        async let secondOutcome = runBoundedProcess(
            executable: "/bin/sh",
            arguments: ["-c", Self.termIgnoringScript(pidFile: secondPidFile)],
            currentDirectory: nil,
            timeout: Self.testFiredDeadline,
            stdio: .pipes,
            clock: secondClock,
            didCreateProcess: secondProbe.record)
        guard let secondPid = try await Self.waitForRecordedPid(
            of: "the second child", pidFile: secondPidFile, probe: secondProbe)
        else { return }
        try await secondClock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)

        // The seam announces its entry with a flag the test polls, so nothing
        // on the observing side ever blocks a thread; the hold itself is a
        // semaphore, because the seam is a synchronous closure and blocking it
        // IS the condition under test.
        let snapshotEntered = Flag()
        let releaseSnapshot = DispatchSemaphore(value: 0)
        let firstReturned = Flag()

        // `gateHoldingTask`, not `Task`: this task blocks a thread for the whole
        // observation below, and a cooperative-pool thread is exactly what the
        // rest of the pass needs. See Tests/TestSupport/BoundedGateSupport.swift.
        let first = gateHoldingTask { () -> BoundedProcessOutcome? in
            let outcome = try? await runBoundedProcess(
                executable: "/bin/sleep",
                arguments: ["\(Self.childLifetimeSeconds)"],
                currentDirectory: nil,
                timeout: .milliseconds(200),
                stdio: .pipes,
                clock: EventDrivenTestClock(),
                beforeDeadlineSnapshot: {
                    snapshotEntered.set()
                    releaseSnapshot.waitForGate("the first call's deadline snapshot")
                },
                didCreateProcess: firstProbe.record)
            firstReturned.set()
            return outcome
        }

        // Bounded, and its two ways to end are told apart: the first call
        // reaching its snapshot, or returning without ever reaching it.
        let settled = try await waitFor(
            "the first call to reach its deadline snapshot or return",
            observed: { "entered: \(snapshotEntered.value), returned: \(firstReturned.value)" }
        ) { snapshotEntered.value || firstReturned.value }
        guard snapshotEntered.value else {
            // Nothing is held. Open the gate anyway, so an entry that comes
            // after all passes straight through instead of parking; the first
            // child is reclaimed by the `defer` above either way.
            releaseSnapshot.signal()
            if settled {
                let unheld = await first.value
                Issue.record(
                    "the first call returned without reaching its deadline snapshot: \(String(describing: unheld))")
            }
            return
        }

        // Everything in this block happens with the first call's snapshot
        // held, and nothing in it waits on the second call: the release runs
        // as soon as the reap wait ends, either way, and on a thrown error too,
        // so a failure here cannot leave the first call parked until its gate
        // gives up. On the failure path the hold is the reap wait — one
        // `saturatedPass` — plus the scheduling hops around it: the poll that
        // saw the entry and the wait's last poll. That is the shape
        // `TestGate.deadline` is sized for, one `saturatedPass` wait inside a
        // 150 s gate, and its 30 s margin covers those hops at the single
        // stalls of at most about 8 s measured in fast passes 1a and 1b (runs
        // 41346745036, 41348358505, 41350081888).
        let returnedEarly: Bool
        do {
            defer { releaseSnapshot.signal() }
            await secondClock.advance(by: Self.testFiredDeadline)
            try await waitFor(
                "the second call's TERM-ignoring child to be reaped while a snapshot is wedged",
                observed: { Self.isAlive(secondPid) ? "pid \(secondPid) still alive" : "pid \(secondPid) gone" }
            ) { !Self.isAlive(secondPid) }
            returnedEarly = firstReturned.value
        }
        #expect(!returnedEarly,
                """
                the first call returned before the hold was released — it was never wedged, \
                so nothing above was observed under the condition this test exists for
                """)

        let secondResult = try await secondOutcome
        guard case .timedOut = secondResult else {
            Issue.record("expected the second call to time out, got \(secondResult)")
            return
        }
        let firstOutcome = await first.value
        guard case .timedOut = firstOutcome else {
            Issue.record("expected the first call to time out, got \(String(describing: firstOutcome))")
            return
        }
    }

    // MARK: - Fixtures

    /// A one-way flag: whether the held call has returned yet, so "observed
    /// while wedged" is asserted rather than assumed, and whether the seam has
    /// been entered. A locked class rather than an actor because the seam is a
    /// synchronous closure that must set it without awaiting, and the reader
    /// is a poll on the cooperative pool.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = false
        var value: Bool { lock.withLock { isSet } }
        func set() { lock.withLock { isSet = true } }
    }

    /// The run timeout of a call whose deadline the test fires itself, by
    /// advancing the call's `EventDrivenTestClock`.
    ///
    /// The runner also arms the same timeout on the watchdog in real time, and
    /// that armer must never beat the advance. The advance comes after at most
    /// three `TestDeadlines.saturatedPass` waits (the child's pid file, the
    /// clock's arming and, in the wedged-snapshot test, the first call's
    /// entry), so four budgets keep it out of reach. `childLifetimeSeconds`
    /// stays above it.
    private static let testFiredDeadline = TestDeadlines.saturatedPass * 4

    /// Waits for `child` to write its pid file, which it does after
    /// `trap '' TERM`, so a pid here means the child ignores SIGTERM from now
    /// on. Returns that pid, or nil once the wait has recorded its failure; the
    /// failure says what the parent saw of the child instead. The pid is the
    /// one the poll parsed, kept in a box, rather than a second read.
    private static func waitForRecordedPid(
        of child: String, pidFile: URL, probe: SpawnProbe,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> pid_t? {
        let found = PidBox()
        let recorded = try await waitFor(
            "\(child) to record its pid after its trap",
            observed: {
                let file = FileManager.default.fileExists(atPath: pidFile.path)
                    ? "exists but holds no pid" : "does not exist"
                return "pid file \(file); its parent saw \(probe.describeChild())"
            },
            sourceLocation: sourceLocation
        ) {
            guard let pid = Self.readPid(from: pidFile) else { return false }
            found.set(pid)
            return true
        }
        return recorded ? found.value : nil
    }

    /// The pid `waitForRecordedPid` parsed, handed from its `@Sendable` poll
    /// back to the caller.
    private final class PidBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        var value: pid_t? { lock.withLock { pid } }
        func set(_ newValue: pid_t) { lock.withLock { pid = newValue } }
    }

    /// How long the sleepers live.
    ///
    /// It must dominate everything a child lives through while its test relies
    /// on it being alive — up to three `TestDeadlines.saturatedPass` waits
    /// before the test fires its deadline (see `testFiredDeadline`) and the
    /// reap wait after, 480 s in all — so a child that is gone is a child
    /// something KILLED, never one that finished its sleep inside the wait.
    /// Each such child is signalled by the escalation under test and, failing
    /// that, by its test's own `defer`.
    ///
    /// It is `TestDeadlines.outlivingChildSeconds`, so it moves with
    /// `saturatedPass` and stays above every wait in the suite.
    private static let childLifetimeSeconds = TestDeadlines.outlivingChildSeconds

    /// A `sh -c` body that ignores SIGTERM, records its own pid, then becomes a
    /// long-lived sleeper. `SIG_IGN` is inherited across `exec`, so the
    /// surviving process is the shell's own pid and nothing is left behind for a
    /// sweep. The record follows the `trap`, so a child that wrote it was
    /// already ignoring SIGTERM when the deadline's SIGTERM arrived; one that
    /// was not would have died before writing. The tests fire a deadline on
    /// such a child only once the record exists.
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

    /// Expects every descriptor the runner closes synchronously to be closed
    /// already, then waits for the probed `Process` to deallocate and every
    /// recorded descriptor to be released.
    ///
    /// The write ends and stdin's read end are checked at once because the
    /// runner closes them before it resumes the caller; were any left to the
    /// `Process`'s deallocation, the wait below would pass by releasing them
    /// late. The stdout and stderr read ends are left to the wait: each had a
    /// `readabilityHandler`, and Foundation defers the `close(2)` of such a
    /// handle to its dispatch source's cancellation handler, which runs
    /// asynchronously after `close()` returns — measured on Darwin 25, 199 of
    /// 200 such handles were still open straight after `close()` and none 20 ms
    /// later. The `Process` is polled because the deadline's clock armer is a
    /// cancelled `Task` that drops its capture only once it next runs.
    private static func expectReleased(
        _ probe: SpawnProbe, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        defer { probe.closeDuplicates() }
        #expect(probe.failures.isEmpty, "the hook could not watch: \(probe.failures)",
                sourceLocation: sourceLocation)
        #expect(probe.descriptorCount >= 2, "the hook recorded no pipe descriptors",
                sourceLocation: sourceLocation)
        // These ends are closed before the call resumes its caller, so they
        // must already be gone; only the `Process` and the drained read ends,
        // whose close Foundation defers, may linger.
        let heldOnReturn = probe.heldDescriptors(closedOnReturnOnly: true)
        #expect(heldOnReturn.isEmpty, "a failed spawn returned still holding \(heldOnReturn)",
                sourceLocation: sourceLocation)
        let outcome = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(20)
        ) { probe.processIsGone && probe.heldDescriptors().isEmpty }
        if outcome == .timedOut {
            let alive = !probe.processIsGone
            let held = probe.heldDescriptors()
            Issue.record(
                "failed spawn outlived the call: process alive=\(alive), still-open descriptors=\(held)",
                sourceLocation: sourceLocation)
        }
    }
}

/// What `didCreateProcess` saw: a weak reference to the `Process` and the
/// identity of every pipe descriptor it was configured with, each pipe held
/// open by a duplicate so that identity stays meaningful.
///
/// An unpinned identity proves nothing. The suite runs in parallel, so a
/// sibling test may already have been handed the closed descriptor's number,
/// and on macOS a pipe's `st_dev` is 0 and its `st_ino` is derived from the
/// kernel pipe's address, which the allocator hands to the next pipe at once:
/// in a pipe()/close() loop, 9,999 of 9,999 new pipes came back with both the
/// closed descriptor's number and its inode, so a sibling's fresh pipe was
/// indistinguishable from ours.
///
/// The probe therefore keeps a close-on-exec duplicate of each pipe's read end.
/// While any end of a pipe is open the kernel cannot free it, so no other pipe
/// can be given either end's inode, and "this number still names the inode it
/// was recorded with" means exactly "the runner still holds this end". With the
/// pipe pinned, no reuse was observed across 10,000 new pipes.
///
/// The question is asked of this process's descriptor table only. Watching
/// the other end for EOF (or EPIPE) instead would also count every copy a
/// sibling test's child inherited: `Pipe()` descriptors are not close-on-exec,
/// and `Process` closes nothing that lacks `FD_CLOEXEC` (see
/// `HolderDescriptorInheritanceTests`), so an unrelated long-running child
/// could fake a leak.
///
/// The deadline tests use it for something else: the child as its parent sees
/// it, for cleanup and for diagnosing a child that never recorded its own pid.
/// A probe made with `keepsProcess` holds the `Process` for its own lifetime,
/// because the weak reference alone could lose it the moment the runner lets
/// go. The pins are inert there: nothing reads them, and they close with the
/// probe.
private final class SpawnProbe: @unchecked Sendable {
    private struct Descriptor {
        let role: String
        /// Whether the runner closes this end before it resumes the caller.
        /// False for a read end it drained with a `readabilityHandler`, whose
        /// close Foundation completes asynchronously (see `expectReleased`).
        let closedOnReturn: Bool
        let fd: Int32
        let device: dev_t
        let inode: ino_t
    }

    private let lock = NSLock()
    private weak var process: Process?
    /// Set only when `keepsProcess`; a probe asked whether the `Process`
    /// outlives the call must not be what keeps it alive.
    private var keptProcess: Process?
    private let keepsProcess: Bool
    private var descriptors: [Descriptor] = []
    private var pins: [Int32] = []
    private var pinFailures: [String] = []

    init(keepsProcess: Bool = false) {
        self.keepsProcess = keepsProcess
    }

    deinit { closeDuplicates() }

    var record: @Sendable (Process) -> Void {
        { [self] process in
            var found: [Descriptor] = []
            var newPins: [Int32] = []
            var failures: [String] = []
            func watch(_ role: String, _ handle: FileHandle, closedOnReturn: Bool = true) {
                var info = stat()
                guard fstat(handle.fileDescriptor, &info) == 0 else {
                    failures.append("\(role): fstat errno \(errno)")
                    return
                }
                found.append(Descriptor(
                    role: role, closedOnReturn: closedOnReturn, fd: handle.fileDescriptor,
                    device: info.st_dev, inode: info.st_ino))
            }
            let pipes: [(String, Any?)] = [
                ("stdout", process.standardOutput),
                ("stderr", process.standardError),
                ("stdin", process.standardInput)
            ]
            for case let (name, pipe as Pipe) in pipes {
                let pin = fcntl(pipe.fileHandleForReading.fileDescriptor, F_DUPFD_CLOEXEC, 0)
                guard pin >= 0 else {
                    failures.append("\(name): dup errno \(errno)")
                    continue
                }
                newPins.append(pin)
                // A failed spawn leaves the runner owning both ends of every
                // pipe: the child never received its end, and the snapshot
                // closes the stdout and stderr read ends — the two it drained,
                // so their close completes only after the call returns.
                watch("\(name) write end", pipe.fileHandleForWriting)
                watch("\(name) read end", pipe.fileHandleForReading, closedOnReturn: name == "stdin")
            }
            lock.withLock {
                self.process = process
                if keepsProcess { keptProcess = process }
                descriptors = found
                pins = newPins
                pinFailures = failures
            }
        }
    }

    /// SIGKILLs the child while `Process` still reports it running, for a child
    /// that writes no pid file of its own. A child that does write one is
    /// better reclaimed by `RecordedChild.killIfStartedBeforeWriting`, whose
    /// check leaves no window.
    ///
    /// The moment is taken first and `isRunning` read after it, and
    /// `RecordedChild`'s check then kills only a process that started no later
    /// than that moment. That is not airtight. Foundation reaps the child with
    /// `waitpid` an instant before it clears `isRunning`, so the pid is free
    /// for reuse during that microsecond window, and a process created in it
    /// would pass. It would need the kernel to hand out this same pid at once,
    /// which its sequential allocation does only after wrapping all the way
    /// round. A child reported not running is left alone. Nothing here depends
    /// on where the test resumes or on the call returning: it reads the
    /// `Process` when it is called.
    func killChild() {
        let moment = Date()
        let pid: pid_t? = lock.withLock {
            guard let child = keptProcess ?? process, child.isRunning else { return nil }
            return child.processIdentifier
        }
        guard let pid else { return }
        RecordedChild.killIfStarted(pid, noLaterThan: moment)
    }

    /// The child as `Process` reports it, for a failure message: its pid and
    /// `isRunning`, the two properties that are safe to read in any state.
    /// `terminationReason` and `terminationStatus` are left out on purpose:
    /// they raise an Objective-C exception, which Swift cannot catch and which
    /// would abort the whole test process, whenever `Process` has not finished
    /// its termination bookkeeping.
    func describeChild() -> String {
        lock.withLock {
            guard let child = keptProcess ?? process else { return "no Process" }
            let pid = child.processIdentifier
            guard pid > 0 else { return "no pid yet, so run() had not returned one" }
            return "pid \(pid), isRunning \(child.isRunning)"
        }
    }

    var descriptorCount: Int { lock.withLock { descriptors.count } }
    var processIsGone: Bool { lock.withLock { process == nil } }
    /// Pipes the hook could not pin or stat, with the errno; empty when all
    /// were watched.
    var failures: [String] { lock.withLock { pinFailures } }

    /// Recorded descriptors the runner still holds, as "role (fd N)", limited
    /// to those it closes before returning when `closedOnReturnOnly` is set.
    /// Sound only while the pins are open, so call it before `closeDuplicates()`.
    func heldDescriptors(closedOnReturnOnly: Bool = false) -> [String] {
        lock.withLock {
            // Unpinned, a match proves nothing: fail closed rather than pass.
            guard !pins.isEmpty || descriptors.isEmpty else { return ["probe read after its pins closed"] }
            return descriptors.filter { recorded in
                if closedOnReturnOnly && !recorded.closedOnReturn { return false }
                var info = stat()
                guard fstat(recorded.fd, &info) == 0 else { return false }
                return info.st_dev == recorded.device && info.st_ino == recorded.inode
            }.map { "\($0.role) (fd \($0.fd))" }
        }
    }

    /// Closes the pins. Idempotent.
    func closeDuplicates() {
        lock.withLock {
            for pin in pins { close(pin) }
            pins = []
        }
    }
}
