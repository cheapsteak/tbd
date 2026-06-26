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
            if case .assistantText(_, let t, _, _) = item { return t }
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
        if case .toolCall(_, _, _, _, let r, _, _, _) = items[0] {
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
        if case .toolCall(_, _, _, _, let r, _, _, _) = items[0] {
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

    @Test func task_tool_renders_as_plain_card_without_subagent() throws {
        // A Task tool call with an existing subagent JSONL on disk: the parser
        // must NOT open the subagent file. The tool call renders as an ordinary
        // card (name + result) with a nil subagent payload.
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

        // Subagent file exists on disk but must be ignored.
        let sub = [
            #"{"type":"user","isSidechain":true,"uuid":"sub-u1","timestamp":"2026-05-05T10:00:05Z","message":{"role":"user","content":"go explore"}}"#,
            #"{"type":"assistant","isSidechain":true,"uuid":"sub-a1","timestamp":"2026-05-05T10:00:10Z","message":{"role":"assistant","content":[{"type":"text","text":"on it"}]}}"#,
        ].joined(separator: "\n")
        try sub.write(toFile: subPath, atomically: true, encoding: .utf8)

        let items = TranscriptParser.parse(filePath: parentPath)
        #expect(items.count == 1)
        guard case .toolCall(_, let name, _, _, let result, let subagent, _, _) = items[0] else {
            Issue.record("expected .toolCall"); return
        }
        #expect(name == "Task")
        #expect(subagent == nil, "subagent file must NOT be opened — payload is always nil")
        #expect(result?.text == "agent done", "parent tool_result still renders")
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
        guard case .toolCall(_, _, _, _, let r, _, _, _) = items[0] else {
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
        guard case .toolCall(_, _, _, _, let r, _, _, _) = items[0] else {
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
        guard case .toolCall(_, _, _, _, let r, _, _, _) = items[0] else {
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

    @Test func skill_body_emits_systemReminder_with_skillBody_kind() throws {
        let body = "Base directory for this skill: /Users/chang/.claude/skills/pr\n\n# Commit, Push, and Open a PR\n\n## Step 1: ..."
        let escaped = body.replacingOccurrences(of: "\n", with: "\\n")
        let line = "{\"type\":\"user\",\"uuid\":\"u1\",\"timestamp\":\"2026-05-05T10:00:00Z\",\"message\":{\"role\":\"user\",\"content\":\"\(escaped)\"}}"
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1)
        if case .systemReminder(_, let kind, let text, _) = items[0] {
            #expect(kind == .skillBody)
            #expect(text.hasPrefix("Base directory for this skill:"))
        } else {
            Issue.record("expected .systemReminder(.skillBody)")
        }
    }

    @Test func slash_envelope_emits_user_prompt_with_command_text() throws {
        let line = #"{"type":"user","uuid":"u1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"user","content":"<command-name>/pr</command-name><command-message>pr</command-message><command-args></command-args>"}}"#
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1)
        if case .userPrompt(_, let text, _) = items[0] {
            #expect(text == "/pr")
        } else {
            Issue.record("expected .userPrompt with slash command text")
        }
    }

    @Test func inputTruncatesLargeStringField() throws {
        let big = String(repeating: "a", count: 3000)
        let line = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"timestamp\":\"2026-05-05T10:00:00Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Write\",\"input\":{\"file_path\":\"/x.swift\",\"content\":\"\(big)\"}}]}}"
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        guard case .toolCall(_, _, let inputJSON, let inputTruncatedTo, _, _, _, _) = items[0] else {
            Issue.record("expected .toolCall"); return
        }
        #expect(inputTruncatedTo != nil, "large input field should set inputTruncatedTo")
        #expect(inputJSON.count < 3000, "truncated inputJSON should be smaller than original payload")
        // The recorded original JSON length should match the count we report.
        if let trunc = inputTruncatedTo {
            #expect(trunc > inputJSON.count, "inputTruncatedTo should be the original full-JSON char count")
        }
    }

    @Test func inputNotTruncatedWhenSmall() throws {
        let line = #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Write","input":{"file_path":"x.swift","content":"ok"}}]}}"#
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        guard case .toolCall(_, _, _, let inputTruncatedTo, _, _, _, _) = items[0] else {
            Issue.record("expected .toolCall"); return
        }
        #expect(inputTruncatedTo == nil, "small inputs should not set inputTruncatedTo")
    }

    @Test func multiEditNestedStringIsTruncated() throws {
        let big = String(repeating: "a", count: 3000)
        let line = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"timestamp\":\"2026-05-05T10:00:00Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"MultiEdit\",\"input\":{\"file_path\":\"/x.swift\",\"edits\":[{\"old_string\":\"foo\",\"new_string\":\"\(big)\"}]}}]}}"
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        guard case .toolCall(_, _, let inputJSON, let inputTruncatedTo, _, _, _, _) = items[0] else {
            Issue.record("expected .toolCall"); return
        }
        #expect(inputTruncatedTo != nil, "nested oversized string should trigger truncation")
        let needle = String(repeating: "a", count: 2500)
        #expect(!inputJSON.contains(needle), "the nested array element's string should have been truncated below 2500 chars")
    }

    @Test func lookupFullBodyWithInputSuffix() throws {
        let big = String(repeating: "a", count: 3000)
        let line = "{\"type\":\"assistant\",\"uuid\":\"a1\",\"timestamp\":\"2026-05-05T10:00:00Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_xyz\",\"name\":\"Write\",\"input\":{\"file_path\":\"/x.swift\",\"content\":\"\(big)\"}}]}}"
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let hit = TranscriptParser.lookupFullBody(filePath: tmp, itemID: "toolu_xyz#input")
        #expect(hit != nil, "lookupFullBody with #input suffix should resolve")
        guard let hit else { return }
        #expect(hit.count > 2000, "result should include the full un-truncated content (\(hit.count) chars)")
        #expect(hit.contains(big), "result should contain the full original 3000-char content string")
        // Sanity-check the result is JSON (parses to a dict).
        let data = hit.data(using: .utf8) ?? Data()
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed != nil, "result should be valid JSON")
    }

    @Test func extracts_usage_from_assistant_line() throws {
        let line = """
        {"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":5,"cache_creation_input_tokens":1000,"cache_read_input_tokens":40000,"output_tokens":7}}}
        """
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1)
        let usage = items[0].usage
        #expect(usage?.inputTokens == 5)
        #expect(usage?.cacheCreationTokens == 1000)
        #expect(usage?.cacheReadTokens == 40000)
        #expect(usage?.contextTotal == 41005)
    }

    @Test func usage_stamped_on_every_item_from_same_assistant_line() throws {
        let line = """
        {"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"calling a tool"},{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/x"}}],"usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}
        """
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 2)
        #expect(items[0].usage?.contextTotal == 6)
        #expect(items[1].usage?.contextTotal == 6)
    }

    @Test func usage_nil_when_absent() throws {
        let line = #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1)
        #expect(items[0].usage == nil)
    }

    @Test func usage_extracted_when_only_input_tokens_present() throws {
        // Users without prompt caching emit `usage` blocks that omit the
        // cache fields. Those sessions must still surface a token count.
        let line = #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":42,"output_tokens":7}}}"#
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1)
        let usage = items[0].usage
        #expect(usage?.inputTokens == 42)
        #expect(usage?.cacheCreationTokens == 0)
        #expect(usage?.cacheReadTokens == 0)
        #expect(usage?.contextTotal == 42)
    }

    @Test func sidechain_lines_drop_at_top_level_regression_guard() throws {
        // Locks in the existing TranscriptParser behavior that top-level
        // sidechain lines are dropped — the latest-usage badge logic relies
        // on the top-level items array being sidechain-free by construction.
        let lines = [
            #"{"type":"assistant","uuid":"a1","isSidechain":true,"timestamp":"2026-05-05T10:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"sidechain"}],"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-05-05T10:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"main"}],"usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#,
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1, "sidechain line must not produce a top-level item")
        if case .assistantText(_, let text, _, _) = items[0] {
            #expect(text == "main")
        } else {
            Issue.record("expected only the main assistant text item")
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
