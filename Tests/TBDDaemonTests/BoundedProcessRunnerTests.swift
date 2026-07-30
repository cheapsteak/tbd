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
}
