import Foundation
import Testing
import TBDShared

@testable import TBDDaemonLib

@Suite("TranscriptParser")
struct TranscriptParserTests {
    private var fixturePath: String {
        // Same fixture used by ClaudeSessionScannerTests.
        let p = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample-session.jsonl")
            .path
        return p
    }

    @Test func parses_user_prompt() throws {
        let items = TranscriptParser.parse(filePath: fixturePath)
        let userPrompts = items.compactMap { item -> String? in
            if case .userPrompt(_, let t, _) = item { return t }
            return nil
        }
        #expect(!userPrompts.isEmpty, "expected at least one user prompt in fixture")
    }

    @Test func parses_assistant_text() throws {
        let items = TranscriptParser.parse(filePath: fixturePath)
        let assistantTexts = items.compactMap { item -> String? in
            if case .assistantText(_, let t, _) = item { return t }
            return nil
        }
        #expect(!assistantTexts.isEmpty)
    }

    @Test func multi_block_assistant_emits_multiple_items_in_order() throws {
        let line = """
        {"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Let me read."},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/x"}}]}}
        """
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 3)
        if case .thinking = items[0] {} else { Issue.record("expected .thinking at index 0") }
        if case .assistantText = items[1] {} else { Issue.record("expected .assistantText at index 1") }
        if case .toolCall = items[2] {} else { Issue.record("expected .toolCall at index 2") }
    }

    @Test func tool_use_paired_with_tool_result_by_id() throws {
        let lines = [
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/x"}}]}}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-05-05T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file contents"}]}}"#,
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1, "tool_result should fold into the tool_use, not be its own item")
        if case .toolCall(_, _, _, let r, _, _) = items[0] {
            #expect(r?.text == "file contents")
            #expect(r?.isError == false)
        } else {
            Issue.record("expected .toolCall")
        }
    }

    @Test func tool_use_without_result_is_in_flight() throws {
        let line = #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo hi"}}]}}"#
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1)
        if case .toolCall(_, _, _, let r, _, _) = items[0] {
            #expect(r == nil, "in-flight tool call should have nil result")
        } else {
            Issue.record("expected .toolCall")
        }
    }

    @Test func system_reminder_classified_to_typed_kind() throws {
        let line = #"{"type":"user","uuid":"u1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}"#
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1)
        if case .systemReminder(_, let kind, _, _) = items[0] {
            #expect(kind == .toolReminder)
        } else {
            Issue.record("expected .systemReminder")
        }
    }

    // MARK: - helpers

    private func writeTempJSONL(_ contents: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-parser-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("session.jsonl").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}
