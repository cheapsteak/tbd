import Foundation
import Testing
@testable import TBDShared

@Suite("CodexTranscriptParser")
struct CodexTranscriptParserTests {
    private var fixture: URL {
        Bundle.module.url(forResource: "codex-rollout", withExtension: "jsonl")!
    }

    @Test("canonical messages replace duplicate events while unknown and malformed rows preserve later items")
    func canonicalMessagesAndStableIDs() throws {
        let items = CodexTranscriptParser.parse(filePath: fixture.path)
        #expect(items.count == 7)
        #expect(items == CodexTranscriptParser.parse(filePath: fixture.path))
        #expect(items[0] == .userPrompt(id: "user-1", text: "Inspect the sample", timestamp: Date(timeIntervalSince1970: 1_767_225_600)))
        #expect(items[1] == .thinking(id: "reason-1", text: "Check the inputs", timestamp: Date(timeIntervalSince1970: 1_767_225_601.125)))
        #expect(items[4] == .assistantText(id: "answer-1", text: "Inspection complete", timestamp: Date(timeIntervalSince1970: 1_767_225_604)))
        #expect(items[5] == .userPrompt(id: "event-only", text: "One more check", timestamp: Date(timeIntervalSince1970: 1_767_225_605)))
        let bytes = try Data(contentsOf: fixture)
        let marker = Data(#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Later valid row"}]}}"#.utf8)
        let offset = try #require(bytes.range(of: marker)?.lowerBound)
        #expect(items[6].id == "codex-byte-\(offset)")
        #expect(items[6] == .assistantText(id: "codex-byte-\(offset)", text: "Later valid row", timestamp: nil))
    }

    @Test("function and custom tool outputs correlate by call ID with error and truncation metadata")
    func toolResultsAndCaps() throws {
        let items = CodexTranscriptParser.parse(filePath: fixture.path)
        guard case let .toolCall(id, name, input, inputSize, result, subagent, _, _) = items[2] else {
            Issue.record("Expected function tool"); return
        }
        #expect(id == "call-1")
        #expect(name == "exec_command")
        #expect(input.contains("printf"))
        #expect(inputSize == nil)
        #expect(result == ToolResult(text: "exit code 1", truncatedTo: nil, isError: true))
        #expect(subagent == nil)
        guard case let .toolCall(customID, customName, customInput, customSize, customResult, _, _, _) = items[3] else {
            Issue.record("Expected custom tool"); return
        }
        #expect(customID == "call-2")
        #expect(customName == "apply_patch")
        #expect(customInput.count < 25_000)
        #expect(customSize != nil)
        #expect(customResult?.text.count == 2_000)
        #expect(customResult?.truncatedTo == 25_000)
        #expect(customResult?.isError == false)
    }

    @Test("tail is the exact full suffix including correlated results and byte-based IDs", arguments: [0, 1, 3, 7, 30])
    func tailMatchesFull(limit: Int) {
        let full = CodexTranscriptParser.parse(filePath: fixture.path)
        #expect(CodexTranscriptParser.parseTail(filePath: fixture.path, limit: limit) == Array(full.suffix(limit)))
    }

    @Test("stream boundaries and invalid UTF-8 cannot hide later complete records")
    func chunkBoundaries() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let text = String(repeating: "é", count: 40_000)
        var data = Data([0xFF, 0x0A])
        data.append(try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]]))
        data.append(0x0A)
        let offset = data.count
        data.append(Data(#"{"type":"event_msg","payload":{"type":"agent_message","message":"complete"}}"#.utf8))
        data.append(0x0A)
        // A valid JSON value without the newline is still an unfinished JSONL append.
        data.append(Data(#"{"type":"event_msg","payload":{"type":"agent_message","message":"partial"}}"#.utf8))
        try data.write(to: file)
        let items = CodexTranscriptParser.parse(filePath: file.path)
        #expect(items.count == 2)
        #expect(items[0] == .userPrompt(id: "codex-byte-2", text: text, timestamp: nil))
        #expect(items[1] == .assistantText(id: "codex-byte-\(offset)", text: "complete", timestamp: nil))
        #expect(CodexTranscriptParser.parseTail(filePath: file.path, limit: 1) == [items[1]])
    }

    @Test("equivalent text in another turn cannot consume an event-only fallback")
    func independentTurns() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"one"}}
        {"type":"event_msg","payload":{"type":"agent_message","id":"event-one","message":"Repeated answer"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"two"}}
        {"type":"event_msg","payload":{"type":"agent_message","id":"event-two","message":"Repeated answer"}}
        {"type":"response_item","payload":{"type":"message","id":"canonical-two","role":"assistant","content":[{"type":"output_text","text":"Repeated answer"}]}}

        """.write(to: file, atomically: true, encoding: .utf8)
        let items = CodexTranscriptParser.parse(filePath: file.path)
        #expect(items.map(\.id) == ["event-one", "canonical-two"])
        #expect(CodexTranscriptParser.parseTail(filePath: file.path, limit: 1) == Array(items.suffix(1)))
    }

    @Test("structured tool output metadata reports nonzero exit status", arguments: [false, true])
    func structuredToolError(encodedOutput: Bool) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let output: [String: Any] = ["output": "Command failed", "metadata": ["exit_code": 2]]
        let value: Any = encodedOutput ? String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8)! : output
        let records: [[String: Any]] = [
            ["type": "response_item", "payload": ["type": "function_call", "call_id": "failed-call", "name": "shell", "arguments": "{}"]],
            ["type": "response_item", "payload": ["type": "function_call_output", "call_id": "failed-call", "output": value]]
        ]
        var bytes = Data()
        for record in records {
            bytes.append(try JSONSerialization.data(withJSONObject: record))
            bytes.append(0x0A)
        }
        try bytes.write(to: file)
        let items = CodexTranscriptParser.parse(filePath: file.path)
        guard case let .toolCall(_, _, _, _, result, _, _, _) = items.first else {
            Issue.record("Expected correlated tool result"); return
        }
        #expect(result == ToolResult(text: "Command failed", truncatedTo: nil, isError: true))
    }

    @Test("provider identity and legacy summary and params decoding remain compatible")
    func legacyContracts() throws {
        let legacy = Data(#"{"sessionId":"same","filePath":"/acme/session.jsonl","modifiedAt":0,"lastMessageAt":0,"fileSize":0,"lineCount":0}"#.utf8)
        let summary = try JSONDecoder().decode(SessionSummary.self, from: legacy)
        #expect(summary.agentKind == nil)
        #expect(summary.transcriptAvailable)
        #expect(summary.identity == AgentSessionIdentity(agentKind: .claude, sessionID: "same"))
        let codex = SessionSummary(sessionId: "same", filePath: "", modifiedAt: .distantPast, fileSize: 0,
                                   lineCount: 0, firstUserMessage: nil, lastUserMessage: nil, cwd: nil,
                                   gitBranch: nil, agentKind: .codex, transcriptAvailable: false)
        #expect(codex.id != summary.id)
        let oldParams = try JSONDecoder().decode(SessionMessagesParams.self, from: Data(#"{"filePath":"/acme/session.jsonl"}"#.utf8))
        #expect(oldParams.filePath == "/acme/session.jsonl")
        #expect(oldParams.identity == nil)
        #expect(oldParams.worktreeID == nil)
        #expect(oldParams.tailLimit == nil)
    }
}
