import Clocks
import Foundation
import os
import TestSupport
import Testing
@testable import TBDDaemonLib

@Suite("CodexSessionImporter", .clockDriven)
struct CodexSessionImporterTests {
    private final class FakeConnection: CodexAppServerConnection,
        @unchecked Sendable {
        private struct State {
            var responses: [Result<Data, any Error>]
            var sent: [Data] = []
            var waiter: CheckedContinuation<Data, any Error>?
            var closed = false
        }

        private let lock: NSLock
        private var state: State

        init(responses: [Data]) {
            lock = NSLock()
            state = State(responses: responses.map(Result.success))
        }

        func send(_ line: Data) throws {
            lock.lock()
            state.sent.append(line)
            lock.unlock()
        }

        func receive() async throws -> Data {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !state.responses.isEmpty {
                    let response = state.responses.removeFirst()
                    lock.unlock()
                    continuation.resume(with: response)
                } else if state.closed {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    state.waiter = continuation
                    lock.unlock()
                }
            }
        }

        func close() {
            lock.lock()
            state.closed = true
            let waiter = state.waiter
            state.waiter = nil
            lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }

        var sentLines: [Data] {
            lock.lock()
            defer { lock.unlock() }
            return state.sent
        }

        var isClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return state.closed
        }
    }

    private final class FakeTransport: CodexAppServerTransport, @unchecked Sendable {
        let connection: FakeConnection
        // Written once by `connect` and read only after `importSession` has
        // fully awaited, so no lock is needed across the async boundary
        // (NSLock.lock() is unavailable from async contexts under Swift 6).
        private let recorder = OSAllocatedUnfairLock<URL?>(initialState: nil)

        init(connection: FakeConnection) {
            self.connection = connection
        }

        func connect(executablePath: String, codexHome: URL, workingDirectory: URL)
            async throws -> any CodexAppServerConnection {
            recorder.withLock { $0 = workingDirectory }
            return connection
        }

        var workingDirectory: URL? {
            recorder.withLock { $0 }
        }
    }

    @Test("emits exactly one SESSIONS item and captures its target")
    func importsExactlyOneSession() async throws {
        let connection = FakeConnection(responses: [
            json(["jsonrpc": "2.0", "id": 1, "result": [:]]),
            json([
                "jsonrpc": "2.0", "id": 2,
                "result": ["importId": "import-1"],
            ]),
            json([
                "jsonrpc": "2.0",
                "method": "externalAgentConfig/import/completed",
                "params": [
                    "importId": "import-1",
                    "itemTypeResults": [[
                        "itemType": "SESSIONS",
                        "successes": [[
                            "source": "/tmp/source.jsonl",
                            "target": "thread-123",
                        ]],
                        "failures": [],
                    ]],
                ],
            ]),
        ])
        let transport = FakeTransport(connection: connection)
        let importer = CodexSessionImporter(
            executablePath: "/opt/bin/codex",
            codexHome: URL(fileURLWithPath: "/tmp/codex-home"),
            transport: transport)

        let target = try await importer.importSession(
            transcriptPath: "/tmp/source.jsonl",
            cwd: "/tmp/worktree",
            title: "Session title")

        #expect(target == "thread-123")
        #expect(connection.isClosed)
        // The child must run in the session worktree, not the daemon's cwd.
        #expect(transport.workingDirectory?.path == "/tmp/worktree")
        #expect(connection.sentLines.count == 3)
        let methods = try connection.sentLines.map(method(from:))
        #expect(methods == [
            "initialize", "initialized", "externalAgentConfig/import",
        ])
        #expect(!methods.contains("externalAgentConfig/detect"))

        let request = try object(from: connection.sentLines[2])
        let params = try #require(request["params"] as? [String: Any])
        let items = try #require(params["migrationItems"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items[0]["itemType"] as? String == "SESSIONS")
        let details = try #require(items[0]["details"] as? [String: Any])
        let sessions = try #require(details["sessions"] as? [[String: Any]])
        #expect(sessions.count == 1)
        #expect(sessions[0]["path"] as? String == "/tmp/source.jsonl")
        #expect(sessions[0]["cwd"] as? String == "/tmp/worktree")
        #expect(sessions[0]["title"] as? String == "Session title")
        #expect(Set(details.keys) == ["sessions"])
    }

    @Test("a SESSIONS failure becomes an actionable error")
    func surfacesSessionFailure() async {
        let connection = FakeConnection(responses: [
            json(["jsonrpc": "2.0", "id": 1, "result": [:]]),
            json([
                "jsonrpc": "2.0", "id": 2,
                "result": ["importId": "import-2"],
            ]),
            json([
                "jsonrpc": "2.0",
                "method": "externalAgentConfig/import/completed",
                "params": [
                    "importId": "import-2",
                    "itemTypeResults": [[
                        "itemType": "SESSIONS",
                        "successes": [],
                        "failures": [[
                            "itemType": "SESSIONS",
                            "failureStage": "conversion",
                            "message": "source transcript is unreadable",
                        ]],
                    ]],
                ],
            ]),
        ])
        let importer = CodexSessionImporter(
            executablePath: "/opt/bin/codex",
            codexHome: URL(fileURLWithPath: "/tmp/codex-home"),
            transport: FakeTransport(connection: connection))

        await #expect(throws: CodexSessionImportError.appServer(
            "source transcript is unreadable")) {
            try await importer.importSession(
                transcriptPath: "/tmp/source.jsonl",
                cwd: "/tmp/worktree")
        }
        #expect(connection.isClosed)
    }

    @Test("a silent app-server times out on the injected clock")
    func timeoutUsesInjectedClock() async {
        let clock = TestClock<Duration>()
        let connection = FakeConnection(responses: [])
        let importer = CodexSessionImporter(
            executablePath: "/opt/bin/codex",
            codexHome: URL(fileURLWithPath: "/tmp/codex-home"),
            transport: FakeTransport(connection: connection),
            timeout: .seconds(5),
            clock: clock)
        let task = Task {
            try await importer.importSession(
                transcriptPath: "/tmp/source.jsonl",
                cwd: "/tmp/worktree")
        }

        await clock.advanceWhenSuspended(by: .seconds(5))

        await #expect(throws: CodexSessionImportError.timedOut) {
            try await task.value
        }
        #expect(connection.isClosed)
    }

    @Test("a nonzero exit surfaces the child's stderr tail")
    func processExitedIncludesStderrTail() {
        let error = CodexSessionImportError.processExited(
            status: 1,
            stderr: """
            some earlier noise
            Error: error loading default config after config error: \
            No such file or directory (os error 2)
            """)
        let message = try! #require(error.errorDescription)
        #expect(message.contains("status 1"))
        #expect(message.contains("error loading default config"))
        #expect(message.contains("No such file or directory"))
    }

    @Test("an empty stderr leaves the exit message unadorned")
    func processExitedWithoutStderrStaysClean() {
        let error = CodexSessionImportError.processExited(status: 2, stderr: "   \n\n")
        let message = try! #require(error.errorDescription)
        #expect(message.contains("status 2"))
        #expect(!message.contains("Codex reported:"))
    }

    @Test("stderr tail keeps the last lines within the cap")
    func stderrTailKeepsRecentLinesWithinCap() {
        let tail = CodexSessionImportError.stderrTail(
            "line-1\nline-2\nline-3\nline-4\nline-5")
        #expect(tail == "line-3 line-4 line-5")
        let long = String(repeating: "x", count: 900)
        #expect(CodexSessionImportError.stderrTail(long).count == 500)
    }

    private func json(_ object: [String: Any]) -> Data {
        // Test fixture is static and valid by construction.
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func object(from data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func method(from data: Data) throws -> String {
        let value = try object(from: data)["method"] as? String
        return try #require(value)
    }
}
