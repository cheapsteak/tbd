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

    @Test func subagent_attached_when_file_exists() throws {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parser-sub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let sessionID = "SESSION1"
        let parentPath = projectDir.appendingPathComponent("\(sessionID).jsonl").path
        let subDir = projectDir.appendingPathComponent(sessionID).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let subPath = subDir.appendingPathComponent("agent-AGENTX.jsonl").path

        let parent = [
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_task","name":"Task","input":{"description":"explore"}}]}}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-05-05T10:00:30Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_task","content":"agent done"}]},"toolUseResult":{"agentId":"AGENTX","agentType":"feature-dev:code-explorer"}}"#,
        ].joined(separator: "\n")
        try parent.write(toFile: parentPath, atomically: true, encoding: .utf8)

        let sub = [
            #"{"type":"user","isSidechain":true,"uuid":"sub-u1","timestamp":"2026-05-05T10:00:05Z","message":{"role":"user","content":"go explore"}}"#,
            #"{"type":"assistant","isSidechain":true,"uuid":"sub-a1","timestamp":"2026-05-05T10:00:10Z","message":{"role":"assistant","content":[{"type":"text","text":"on it"}]}}"#,
        ].joined(separator: "\n")
        try sub.write(toFile: subPath, atomically: true, encoding: .utf8)

        let items = TranscriptParser.parse(filePath: parentPath)
        #expect(items.count == 1)
        guard case .toolCall(_, let name, _, _, let subagent, _) = items[0] else {
            Issue.record("expected .toolCall"); return
        }
        #expect(name == "Task")
        #expect(subagent?.agentID == "AGENTX")
        #expect(subagent?.items.count == 2, "subagent should have its own user prompt + assistant text")
    }

    @Test func subagent_meta_provides_agent_type() throws {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parser-sub-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let sessionID = "SM"
        let parentPath = projectDir.appendingPathComponent("\(sessionID).jsonl").path
        let subDir = projectDir.appendingPathComponent(sessionID).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        try [
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_task","name":"Task","input":{}}]}}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-05-05T10:00:30Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_task","content":"done"}]},"toolUseResult":{"agentId":"AM"}}"#,
        ].joined(separator: "\n").write(toFile: parentPath, atomically: true, encoding: .utf8)

        try #"{"type":"user","isSidechain":true,"uuid":"s1","timestamp":"2026-05-05T10:00:10Z","message":{"role":"user","content":"hi"}}"#
            .write(toFile: subDir.appendingPathComponent("agent-AM.jsonl").path, atomically: true, encoding: .utf8)
        try #"{"agentType":"feature-dev:code-reviewer"}"#
            .write(toFile: subDir.appendingPathComponent("agent-AM.meta.json").path, atomically: true, encoding: .utf8)

        let items = TranscriptParser.parse(filePath: parentPath)
        guard case .toolCall(_, _, _, _, let subagent, _) = items[0] else {
            Issue.record("expected .toolCall"); return
        }
        #expect(subagent?.agentType == "feature-dev:code-reviewer")
    }

    @Test func subagent_missing_file_yields_nil_subagent() throws {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parser-sub-missing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let parentPath = projectDir.appendingPathComponent("S.jsonl").path
        let parent = [
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_task","name":"Task","input":{}}]}}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-05-05T10:00:30Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_task","content":"done"}]},"toolUseResult":{"agentId":"NOTHERE"}}"#,
        ].joined(separator: "\n")
        try parent.write(toFile: parentPath, atomically: true, encoding: .utf8)

        let items = TranscriptParser.parse(filePath: parentPath)
        guard case .toolCall(_, _, _, _, let subagent, _) = items[0] else {
            Issue.record("expected .toolCall"); return
        }
        #expect(subagent == nil, "missing subagent file → nil subagent, parent still renders")
    }

    @Test func subagent_recursion_two_levels() throws {
        let projectDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parser-sub-deep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDir) }

        let sessionID = "S2"
        let parentPath = projectDir.appendingPathComponent("\(sessionID).jsonl").path
        let subDir = projectDir.appendingPathComponent(sessionID).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        try [
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_outer","name":"Task","input":{}}]}}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-05-05T10:01:00Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_outer","content":"outer done"}]},"toolUseResult":{"agentId":"AOUTER"}}"#,
        ].joined(separator: "\n").write(toFile: parentPath, atomically: true, encoding: .utf8)

        try [
            #"{"type":"user","isSidechain":true,"uuid":"o-u1","timestamp":"2026-05-05T10:00:10Z","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","isSidechain":true,"uuid":"o-a1","timestamp":"2026-05-05T10:00:20Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_inner","name":"Task","input":{}}]}}"#,
            #"{"type":"user","isSidechain":true,"uuid":"o-u2","timestamp":"2026-05-05T10:00:50Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_inner","content":"inner done"}]},"toolUseResult":{"agentId":"AINNER"}}"#,
        ].joined(separator: "\n").write(toFile: subDir.appendingPathComponent("agent-AOUTER.jsonl").path, atomically: true, encoding: .utf8)

        try [
            #"{"type":"user","isSidechain":true,"uuid":"i-u1","timestamp":"2026-05-05T10:00:30Z","message":{"role":"user","content":"deep"}}"#,
            #"{"type":"assistant","isSidechain":true,"uuid":"i-a1","timestamp":"2026-05-05T10:00:40Z","message":{"role":"assistant","content":[{"type":"text","text":"deep done"}]}}"#,
        ].joined(separator: "\n").write(toFile: subDir.appendingPathComponent("agent-AINNER.jsonl").path, atomically: true, encoding: .utf8)

        let items = TranscriptParser.parse(filePath: parentPath)
        guard case .toolCall(_, _, _, _, let outer, _) = items[0],
              let outerItems = outer?.items, outerItems.count >= 2,
              case .toolCall(_, _, _, _, let inner, _) = outerItems[1] else {
            Issue.record("recursive structure mismatched"); return
        }
        #expect(inner?.agentID == "AINNER")
        #expect(inner?.items.count == 2)
    }

    @Test func tool_result_truncated_when_over_char_cap() throws {
        let bigText = String(repeating: "x", count: 5000)
        let lines = [
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo big"}}]}}"#,
            "{\"type\":\"user\",\"uuid\":\"u1\",\"timestamp\":\"2026-05-05T10:00:01Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"\(bigText)\"}]}}",
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        guard case .toolCall(_, _, _, let r, _, _) = items[0] else {
            Issue.record("expected .toolCall"); return
        }
        #expect(r?.text.count == 2000)
        #expect(r?.truncatedTo == 5000)
    }

    @Test func tool_result_truncated_when_over_line_cap() throws {
        // 60 short lines joined with \n inside a JSON string literal.
        let bigLines = (0..<60).map { "line \($0)" }.joined(separator: "\\n")
        let lines = [
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}]}}"#,
            "{\"type\":\"user\",\"uuid\":\"u1\",\"timestamp\":\"2026-05-05T10:00:01Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"\(bigLines)\"}]}}",
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        guard case .toolCall(_, _, _, let r, _, _) = items[0] else {
            Issue.record("expected .toolCall"); return
        }
        #expect(r?.text.split(separator: "\n").count == 20)
        #expect(r?.truncatedTo != nil)
    }

    @Test func tool_result_under_cap_is_not_truncated() throws {
        let lines = [
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-05-05T10:00:01Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"short"}]}}"#,
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        guard case .toolCall(_, _, _, let r, _, _) = items[0] else {
            Issue.record("expected .toolCall"); return
        }
        #expect(r?.text == "short")
        #expect(r?.truncatedTo == nil)
    }

    @Test func parses_iso8601_with_fractional_seconds() throws {
        let line = #"{"type":"user","uuid":"u1","timestamp":"2026-05-05T03:06:16.813Z","message":{"role":"user","content":"hi"}}"#
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let items = TranscriptParser.parse(filePath: tmp)
        guard case .userPrompt(_, _, let ts) = items[0] else {
            Issue.record("expected .userPrompt"); return
        }
        #expect(ts != nil, "timestamp with fractional seconds should parse")
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
