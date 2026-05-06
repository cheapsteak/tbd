import Foundation
import Testing
import TBDShared

@Suite("TranscriptItem Codable")
struct TranscriptItemTests {
    @Test func roundtrip_userPrompt() throws {
        let original: TranscriptItem = .userPrompt(id: "u1", text: "hello", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .userPrompt(let id, let text, _) = decoded else {
            Issue.record("expected .userPrompt"); return
        }
        #expect(id == "u1")
        #expect(text == "hello")
    }

    @Test func roundtrip_assistantText() throws {
        let original: TranscriptItem = .assistantText(id: "a1", text: "ok", timestamp: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .assistantText(let id, let text, _) = decoded else {
            Issue.record("expected .assistantText"); return
        }
        #expect(id == "a1")
        #expect(text == "ok")
    }

    @Test func roundtrip_toolCall_no_subagent() throws {
        let result = ToolResult(text: "stdout", truncatedTo: nil, isError: false)
        let original: TranscriptItem = .toolCall(
            id: "toolu_1", name: "Read", inputJSON: "{\"file_path\":\"/x\"}",
            inputTruncatedTo: nil,
            result: result, subagent: nil, timestamp: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .toolCall(let id, let name, let inputJSON, _, let r, let sub, _) = decoded else {
            Issue.record("expected .toolCall"); return
        }
        #expect(id == "toolu_1")
        #expect(name == "Read")
        #expect(inputJSON == "{\"file_path\":\"/x\"}")
        #expect(r?.text == "stdout")
        #expect(sub == nil)
    }

    @Test func roundtrip_toolCall_with_subagent_with_nested_toolcall() throws {
        let inner: TranscriptItem = .toolCall(
            id: "toolu_inner", name: "Bash", inputJSON: "{}",
            inputTruncatedTo: nil,
            result: ToolResult(text: "ok", truncatedTo: nil, isError: false),
            subagent: nil, timestamp: nil
        )
        let sub = Subagent(agentID: "agent_x", agentType: "feature-dev:code-explorer", items: [inner])
        let outer: TranscriptItem = .toolCall(
            id: "toolu_outer", name: "Task", inputJSON: "{}",
            inputTruncatedTo: nil,
            result: ToolResult(text: "done", truncatedTo: nil, isError: false),
            subagent: sub, timestamp: nil
        )
        let data = try JSONEncoder().encode(outer)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .toolCall(_, _, _, _, _, let s, _) = decoded else {
            Issue.record("expected .toolCall"); return
        }
        #expect(s?.agentID == "agent_x")
        #expect(s?.items.count == 1)
    }

    @Test func roundtrip_thinking() throws {
        let original: TranscriptItem = .thinking(id: "t1", text: "musing", timestamp: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .thinking(_, let text, _) = decoded else {
            Issue.record("expected .thinking"); return
        }
        #expect(text == "musing")
    }

    @Test func roundtrip_systemReminder() throws {
        let original: TranscriptItem = .systemReminder(id: "s1", kind: .toolReminder, text: "hi", timestamp: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .systemReminder(_, let kind, _, _) = decoded else {
            Issue.record("expected .systemReminder"); return
        }
        #expect(kind == .toolReminder)
    }

    @Test func roundtrip_slashCommand() throws {
        let original: TranscriptItem = .slashCommand(id: "sc1", name: "rebase", args: "main", timestamp: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptItem.self, from: data)
        guard case .slashCommand(_, let name, let args, _) = decoded else {
            Issue.record("expected .slashCommand"); return
        }
        #expect(name == "rebase")
        #expect(args == "main")
    }

    @Test func toolResult_truncated_field_decodes() throws {
        let original = ToolResult(text: "first 2KB", truncatedTo: 50_000, isError: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded.truncatedTo == 50_000)
        #expect(decoded.isError == false)
    }
}
