import Darwin
import Testing
import Foundation
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
}
