import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("CodexContinuationPacketBuilder")
struct CodexContinuationPacketBuilderTests {
    private enum StubError: Error {
        case failed
    }

    private struct StubGitStatusProvider: CodexContinuationGitStatusProviding {
        let result: Result<String, StubError>

        init(status: String) {
            result = .success(status)
        }

        init(error: StubError) {
            result = .failure(error)
        }

        func status(worktreePath: String) async throws -> String {
            try result.get()
        }
    }

    private final class Fixture: @unchecked Sendable {
        let directory: URL
        let rollout: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "codex-continuation-\(UUID().uuidString)", isDirectory: true)
            rollout = directory.appendingPathComponent("rollout.jsonl")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }

        func write(_ records: [[String: Any]], terminateLast: Bool = true) throws {
            var data = Data()
            for (index, record) in records.enumerated() {
                data.append(try JSONSerialization.data(
                    withJSONObject: record, options: [.sortedKeys]))
                if index < records.count - 1 || terminateLast {
                    data.append(0x0A)
                }
            }
            try data.write(to: rollout)
        }
    }

    @Test("stable input and status produce identical, attributed packets")
    func deterministicPacket() async throws {
        let fixture = try Fixture()
        try fixture.write([
            envelope("session_meta", [
                "id": "thread-123",
                "timestamp": "2026-09-16T01:02:03Z",
                "cwd": fixture.directory.path,
                "originator": "codex_cli_rs",
                "cli_version": "1.2.3",
                "model": "example-model",
                "model_provider": "example-provider",
                "instructions": "must-not-appear",
                "environment": ["PRIVATE_VALUE": "must-not-appear"],
            ]),
            responseMessage(role: "user", text: "Implement the requested change."),
            responseMessage(role: "assistant", text: "The implementation is ready."),
        ])
        let builder = CodexContinuationPacketBuilder(
            gitStatusProvider: StubGitStatusProvider(status: "## topic\n M Sources/Feature.swift\n"))

        let first = try await builder.build(
            rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)
        let second = try await builder.build(
            rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)

        #expect(first == second)
        #expect(first.utf8.count <= CodexContinuationPacketBuilder.promptByteLimit)
        #expect(first.contains("without a model call"))
        #expect(first.contains("not a Claude-native resume"))
        #expect(first.contains("Complete immutable Codex rollout: \(fixture.rollout.path)"))
        #expect(first.contains("Source thread ID: thread-123"))
        #expect(first.contains("Codex version: 1.2.3"))
        #expect(first.contains("## topic"))
        #expect(first.contains("### User\nImplement the requested change."))
        #expect(first.contains("### Codex\nThe implementation is ready."))
        #expect(first.contains("Authorship: TBD generated this packet mechanically"))
        #expect(!first.contains("must-not-appear"))
    }

    @Test("history keeps the initial task and newest whole turns within 64 KiB")
    func boundedHistorySelection() async throws {
        let fixture = try Fixture()
        var records = [
            responseMessage(
                role: "user", text: "INITIAL TASK — keep this even when history is long 🧭"),
            turnContext("initial"),
        ]
        for index in 0..<80 {
            records.append(responseMessage(
                role: "user", text: "follow-up-\(index)"))
            records.append(turnContext("turn-\(index)"))
            records.append(responseMessage(
                role: "assistant",
                text: "conclusion-\(index)-" + String(repeating: "é", count: 900)))
        }
        try fixture.write(records)
        let builder = CodexContinuationPacketBuilder(
            gitStatusProvider: StubGitStatusProvider(status: "## topic\n"))

        let packet = try await builder.build(
            rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)

        #expect(packet.utf8.count <= 65_536)
        #expect(String(data: Data(packet.utf8), encoding: .utf8) == packet)
        #expect(packet.contains("INITIAL TASK"))
        #expect(packet.contains("conclusion-79-"))
        #expect(!packet.contains("conclusion-1-"))
        #expect(integer(after: "- Middle history units: ", in: packet) > 0)
        let seventyEight = try #require(packet.range(of: "conclusion-78-"))
        let seventyNine = try #require(packet.range(of: "conclusion-79-"))
        #expect(seventyEight.lowerBound < seventyNine.lowerBound)
    }

    @Test("history cap never emits a partial turn bundle")
    func completeTurnSelectionAtCap() async throws {
        let fixture = try Fixture()
        try fixture.write([
            responseMessage(role: "user", text: "INITIAL-TASK"),
            turnContext("initial"),
            responseMessage(
                role: "user",
                text: "MIDDLE-USER-" + String(repeating: "u", count: 19_000)),
            turnContext("middle"),
            responseMessage(
                role: "assistant",
                text: "MIDDLE-ASSISTANT-" + String(repeating: "a", count: 19_000)),
            responseMessage(
                role: "user",
                text: "NEWEST-USER-" + String(repeating: "n", count: 6_000)),
            turnContext("newest"),
            responseMessage(
                role: "assistant",
                text: "NEWEST-ASSISTANT-" + String(repeating: "z", count: 6_000)),
        ])
        let builder = CodexContinuationPacketBuilder(
            gitStatusProvider: StubGitStatusProvider(status: "## topic\n"))

        let packet = try await builder.build(
            rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)

        #expect(packet.contains("INITIAL-TASK"))
        #expect(packet.contains("NEWEST-USER-"))
        #expect(packet.contains("NEWEST-ASSISTANT-"))
        #expect(!packet.contains("MIDDLE-USER-"))
        #expect(!packet.contains("MIDDLE-ASSISTANT-"))
        #expect(integer(after: "- Middle history units: ", in: packet) > 0)
    }

    @Test("mandatory envelope survives maximal metadata and git status")
    func boundedEnvelope() async throws {
        let fixture = try Fixture()
        let huge = String(repeating: "metadata-🧭", count: 400)
        try fixture.write([
            envelope("session_meta", [
                "id": huge, "timestamp": huge, "cwd": huge,
                "originator": huge, "cli_version": huge,
                "model": huge, "model_provider": huge,
            ]),
            responseMessage(role: "user", text: "Keep the envelope."),
        ])
        let status = (0..<200).map {
            " M file-\($0)-" + String(repeating: "x", count: 1_000)
        }.joined(separator: "\n")
        let builder = CodexContinuationPacketBuilder(
            gitStatusProvider: StubGitStatusProvider(status: status))

        let packet = try await builder.build(
            rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)
        let historyStart = try #require(packet.range(of: "## Selected history"))
        let envelope = String(packet[..<historyStart.lowerBound])

        #expect(envelope.utf8.count <= CodexContinuationPacketBuilder.envelopeByteLimit)
        #expect(packet.utf8.count <= CodexContinuationPacketBuilder.promptByteLimit)
        #expect(envelope.contains("Complete immutable Codex rollout:"))
        #expect(envelope.contains("Current git status"))
        #expect(envelope.contains("git-status line(s) omitted"))
        #expect(envelope.contains("Inspect the repository and the complete rollout"))
        #expect(envelope.contains("Authorship:"))
        #expect(packet.contains("Keep the envelope."))
    }

    @Test("oversized and unterminated JSONL records are discarded without losing valid content")
    func boundedJSONLRecords() async throws {
        let fixture = try Fixture()
        var data = try JSONSerialization.data(
            withJSONObject: responseMessage(role: "user", text: "Valid task"),
            options: [.sortedKeys])
        data.append(0x0A)
        data.append(Data(repeating: 0x78, count: CodexContinuationPacketBuilder.recordByteLimit + 1))
        data.append(0x0A)
        data.append(Data(#"{"type":"response_item""#.utf8))
        try data.write(to: fixture.rollout)
        let builder = CodexContinuationPacketBuilder(
            gitStatusProvider: StubGitStatusProvider(status: "## topic\n"))

        let packet = try await builder.build(
            rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)

        #expect(packet.contains("Valid task"))
        #expect(packet.contains("- Oversized JSONL records: 1"))
        #expect(packet.contains("- Malformed or unterminated records: 1"))
    }

    @Test("oversized semantic units become typed stubs")
    func oversizedUnitStub() async throws {
        let fixture = try Fixture()
        try fixture.write([
            responseMessage(role: "user", text: String(repeating: "🧭", count: 20_000)),
            responseMessage(role: "assistant", text: "newest conclusion"),
        ])
        let builder = CodexContinuationPacketBuilder(
            gitStatusProvider: StubGitStatusProvider(status: ""))

        let packet = try await builder.build(
            rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)

        #expect(packet.contains("### User\n[Oversized unit omitted"))
        #expect(packet.contains("newest conclusion"))
        #expect(packet.contains("- Oversized history units: 1"))
    }

    @Test("response items win over duplicate event-message fallbacks")
    func eventFallbackDeduplication() async throws {
        let fixture = try Fixture()
        try fixture.write([
            envelope("event_msg", ["type": "user_message", "message": "Same task"]),
            responseMessage(role: "user", text: "Same   task"),
            envelope("event_msg", ["type": "agent_message", "message": "Only in event"]),
            responseMessage(role: "assistant", text: "Canonical conclusion"),
        ])
        let builder = CodexContinuationPacketBuilder(
            gitStatusProvider: StubGitStatusProvider(status: ""))

        let packet = try await builder.build(
            rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)

        #expect(occurrences(of: "### User", in: packet) == 1)
        #expect(packet.contains("Same   task"))
        #expect(packet.contains("Only in event"))
        #expect(packet.contains("Canonical conclusion"))
    }

    @Test("free-text redaction covers JSON-quoted keys and leaves ordinary prose alone")
    func redactionCoversQuotedJSONKeys() async throws {
        let fixture = try Fixture()
        try fixture.write([
            responseMessage(
                role: "user",
                text: """
                pasted {"password": "hunter2"} and {"api_key":"quoted-key-value","user":"someone"}
                also {'token': 'single-quoted-value'} and {"client_secret": 12345678}
                The password reset flow uses a token bucket; see the secret santa list.
                plain {"name": "widget", "count": 3}
                """),
            responseMessage(role: "assistant", text: "Finished safely."),
        ])
        let builder = CodexContinuationPacketBuilder(
            gitStatusProvider: StubGitStatusProvider(status: ""))

        let packet = try await builder.build(
            rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)

        #expect(!packet.contains("hunter2"))
        #expect(!packet.contains("quoted-key-value"))
        #expect(!packet.contains("single-quoted-value"))
        #expect(!packet.contains("12345678"))
        #expect(packet.contains("[REDACTED]"))
        #expect(packet.contains(#""user":"someone""#))
        #expect(packet.contains("The password reset flow uses a token bucket; see the secret santa list."))
        #expect(packet.contains(#"plain {"name": "widget", "count": 3}"#))
    }

    @Test("tool summaries keep only path arguments and all retained strings are redacted")
    func redactionAndToolAllowlist() async throws {
        let fixture = try Fixture()
        let privateKey = """
        -----BEGIN PRIVATE KEY-----
        very-secret-material
        -----END PRIVATE KEY-----
        """
        try fixture.write([
            responseMessage(
                role: "user",
                text: """
                token=abcd1234 Authorization: Bearer bearer-secret
                GITHUB_TOKEN=github-ordinary-value
                ANTHROPIC_API_KEY=anthropic-ordinary-value
                AWS_SECRET_ACCESS_KEY=aws-ordinary-value
                CLAUDE_CODE_OAUTH_TOKEN=claude-ordinary-value
                URL https://person:pass@example.test/path key \(privateKey)
                service ghp_abcdefghijk
                """),
            envelope("response_item", [
                "type": "function_call",
                "name": "exec_command",
                "arguments": jsonString([
                    "cwd": "/tmp/acme",
                    "files": ["Sources/A.swift", "Sources/B.swift"],
                    "nested": ["target": "docs/design.md"],
                    "command": "curl https://person:pass@example.test",
                    "prompt": "password=hunter2",
                    "headers": ["Authorization": "Bearer hidden-value"],
                    "api_key": "sk-abcdefghi",
                ]),
            ]),
            envelope("response_item", [
                "type": "function_call_output",
                "output": "TOOL-RESULT-MUST-NOT-APPEAR",
            ]),
            envelope("response_item", [
                "type": "reasoning", "summary": "REASONING-MUST-NOT-APPEAR",
            ]),
            responseMessage(role: "assistant", text: "Finished safely."),
        ])
        let builder = CodexContinuationPacketBuilder(
            gitStatusProvider: StubGitStatusProvider(
                status: "## topic\n M credential.txt token=status-secret\n"))

        let packet = try await builder.build(
            rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)

        #expect(packet.contains("### Tool call: exec_command"))
        #expect(packet.contains("- cwd: /tmp/acme"))
        #expect(packet.contains("- files: Sources/A.swift"))
        #expect(packet.contains("- target: docs/design.md"))
        #expect(packet.contains("[REDACTED]"))
        #expect(!packet.contains("abcd1234"))
        #expect(!packet.contains("bearer-secret"))
        #expect(!packet.contains("github-ordinary-value"))
        #expect(!packet.contains("anthropic-ordinary-value"))
        #expect(!packet.contains("aws-ordinary-value"))
        #expect(!packet.contains("claude-ordinary-value"))
        #expect(packet.contains("GITHUB_TOKEN=[REDACTED]"))
        #expect(packet.contains("ANTHROPIC_API_KEY=[REDACTED]"))
        #expect(packet.contains("AWS_SECRET_ACCESS_KEY=[REDACTED]"))
        #expect(packet.contains("CLAUDE_CODE_OAUTH_TOKEN=[REDACTED]"))
        #expect(!packet.contains("person:pass"))
        #expect(!packet.contains("very-secret-material"))
        #expect(!packet.contains("ghp_abcdefghijk"))
        #expect(!packet.contains("status-secret"))
        #expect(!packet.contains("curl https"))
        #expect(!packet.contains("hunter2"))
        #expect(!packet.contains("hidden-value"))
        #expect(!packet.contains("sk-abcdefghi"))
        #expect(!packet.contains("TOOL-RESULT-MUST-NOT-APPEAR"))
        #expect(!packet.contains("REASONING-MUST-NOT-APPEAR"))
    }

    @Test("malformed or content-free rollouts fail preparation")
    func rejectsContentFreeRollout() async throws {
        let fixture = try Fixture()
        try fixture.write([
            envelope("session_meta", ["id": "thread-empty"]),
            envelope("response_item", ["type": "reasoning", "text": "hidden"]),
        ])
        let builder = CodexContinuationPacketBuilder(
            gitStatusProvider: StubGitStatusProvider(status: ""))

        await #expect(throws: CodexContinuationPacketError.contentFreeRollout) {
            try await builder.build(
                rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)
        }
    }

    @Test("git status failure is a preparation failure")
    func gitStatusFailure() async throws {
        let fixture = try Fixture()
        try fixture.write([responseMessage(role: "user", text: "A valid task")])
        let builder = CodexContinuationPacketBuilder(
            gitStatusProvider: StubGitStatusProvider(error: .failed))

        await #expect(throws: CodexContinuationPacketError.gitStatusFailed) {
            try await builder.build(
                rolloutPath: fixture.rollout.path, worktreePath: fixture.directory.path)
        }
    }

    private func envelope(_ type: String, _ payload: [String: Any]) -> [String: Any] {
        ["type": type, "payload": payload]
    }

    private func responseMessage(role: String, text: String) -> [String: Any] {
        envelope("response_item", [
            "type": "message",
            "role": role,
            "content": [[
                "type": role == "user" ? "input_text" : "output_text",
                "text": text,
            ]],
        ])
    }

    private func turnContext(_ id: String) -> [String: Any] {
        envelope("turn_context", ["turn_id": id])
    }

    private func jsonString(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func integer(after prefix: String, in text: String) -> Int {
        guard let range = text.range(of: prefix) else { return -1 }
        let tail = text[range.upperBound...]
        let digits = tail.prefix(while: \.isNumber)
        return Int(digits) ?? -1
    }
}
