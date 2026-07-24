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
}
