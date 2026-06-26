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

    @Test func task_notification_emits_system_reminder_with_full_text() throws {
        // A real user prompt, then a background-task notification injected into
        // the user role, then an assistant reply. The task-notification must
        // produce a single .systemReminder(kind: .taskNotification) item whose
        // text preserves the original <task-notification> content (for the
        // detail overlay).
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-05-05T10:00:00Z","message":{"role":"user","content":"Please run the build."}}"#,
            #"{"type":"user","uuid":"u2","timestamp":"2026-05-05T10:00:01Z","message":{"role":"user","content":"<task-notification>\n<status>completed</status>\n<summary>Build finished</summary>\n</task-notification>"}}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-05-05T10:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"Build started."}]}}"#,
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 3, "task-notification line must produce a system reminder item")

        let userPrompts = items.compactMap { item -> String? in
            if case .userPrompt(_, let t, _) = item { return t }
            return nil
        }
        #expect(userPrompts == ["Please run the build."])

        let assistantTexts = items.compactMap { item -> String? in
            if case .assistantText(_, let t, _, _) = item { return t }
            return nil
        }
        #expect(assistantTexts == ["Build started."])

        // Exactly one .systemReminder with kind .taskNotification preserving the
        // full original notification text.
        let reminders = items.compactMap { item -> (SystemKind, String)? in
            if case .systemReminder(_, let kind, let text, _) = item { return (kind, text) }
            return nil
        }
        #expect(reminders.count == 1)
        #expect(reminders.first?.0 == .taskNotification)
        #expect(reminders.first?.1.contains("<task-notification>") == true)
        #expect(reminders.first?.1.contains("Build finished") == true)
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

    // MARK: - parseTail

    /// Maps an item to a comparable signature (id + discriminator + key text)
    /// so tail items can be asserted byte-identical to the full parse's bottom.
    private func signature(_ item: TranscriptItem) -> String {
        switch item {
        case .userPrompt(let id, let t, _): return "userPrompt|\(id)|\(t)"
        case .assistantText(let id, let t, _, _): return "assistantText|\(id)|\(t)"
        case .thinking(let id, let t, _): return "thinking|\(id)|\(t)"
        case .systemReminder(let id, let kind, let t, _): return "systemReminder|\(id)|\(kind)|\(t)"
        case .toolCall(let id, let name, _, _, let result, _, _, _):
            return "toolCall|\(id)|\(name)|\(result?.text ?? "<nil>")"
        case .slashCommand(let id, let name, let args, _):
            return "slashCommand|\(id)|\(name)|\(args ?? "")"
        }
    }

    @Test func parseTail_returns_same_last_N_items_as_full_parse() throws {
        // Build a synthetic session with > N visible items, including a
        // tool_use+tool_result pair INSIDE the tail window so the
        // window-only toolResultsByID still folds the result in.
        var lines: [String] = []
        for i in 0..<30 {
            let ts = "2026-05-05T10:00:\(String(format: "%02d", i))Z"
            if i % 2 == 0 {
                lines.append(
                    "{\"type\":\"user\",\"uuid\":\"u\(i)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"user\",\"content\":\"hello \(i)\"}}")
            } else {
                lines.append(
                    "{\"type\":\"assistant\",\"uuid\":\"a\(i)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"reply \(i)\"}]}}")
            }
        }
        // A tool_use immediately followed by its tool_result, near the end so
        // both fall inside a limit=10 window.
        lines.append(
            #"{"type":"assistant","uuid":"atool","timestamp":"2026-05-05T10:00:30Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_tail","name":"Read","input":{"file_path":"/x"}}]}}"#)
        lines.append(
            #"{"type":"user","uuid":"utool","timestamp":"2026-05-05T10:00:31Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_tail","content":"tail file contents"}]}}"#)

        let tmp = try writeTempJSONL(lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let full = TranscriptParser.parse(filePath: tmp)
        #expect(full.count > 10, "fixture must produce more than N visible items")

        let tail = TranscriptParser.parseTail(filePath: tmp, limit: 10)
        #expect(tail.count == min(10, full.count))

        // The tail's tool_use must have folded in its result (window-local
        // toolResultsByID), proving the in-window pairing works.
        let toolItem = tail.first { item in
            if case .toolCall = item { return true }
            return false
        }
        if case .toolCall(_, _, _, _, let r, _, _, _)? = toolItem {
            #expect(r?.text == "tail file contents")
        } else {
            Issue.record("expected a folded tool_use in the tail window")
        }

        // ids AND content must match exactly between full.suffix(10) and tail.
        let fullSigs = full.suffix(10).map(signature)
        let tailSigs = tail.map(signature)
        #expect(fullSigs == tailSigs, "tail must be byte-identical to the bottom of the full parse")
    }

    @Test func parseTail_seeks_mid_line_in_large_file_and_matches_full_tail() throws {
        // Build a file LARGER than the 1MB tail chunk so parseTail's seek lands
        // mid-line, exercising the partial-first-line discard. We pad each
        // assistant line's text with filler bytes to inflate the file past the
        // chunk threshold without inflating the visible-item count.
        let filler = String(repeating: "x", count: 4000)
        var lines: [String] = []
        // ~400 lines * ~4KB filler each ≈ 1.6MB > 1MB chunk.
        for i in 0..<400 {
            let ts = "2026-05-05T10:00:\(String(format: "%02d", i % 60))Z"
            if i % 2 == 0 {
                lines.append(
                    "{\"type\":\"user\",\"uuid\":\"u\(i)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"user\",\"content\":\"hello \(i) \(filler)\"}}")
            } else {
                lines.append(
                    "{\"type\":\"assistant\",\"uuid\":\"a\(i)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"reply \(i) \(filler)\"}]}}")
            }
        }

        let tmp = try writeTempJSONL(lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Confirm the fixture actually exceeds the 1MB tail chunk so the seek
        // is guaranteed to start mid-line (else the test wouldn't prove the
        // partial-line discard).
        let size = try FileManager.default.attributesOfItem(atPath: tmp)[.size] as? Int ?? 0
        #expect(size > (1 << 20), "fixture must exceed the 1MB tail chunk to force a mid-line seek")

        let full = TranscriptParser.parse(filePath: tmp)
        let tail = TranscriptParser.parseTail(filePath: tmp, limit: 10)
        #expect(tail.count == 10)

        // Despite the seek landing mid-line, the discarded partial prefix must
        // not corrupt the bottom: tail == full.suffix(10), exactly.
        let fullSigs = full.suffix(10).map(signature)
        let tailSigs = tail.map(signature)
        #expect(fullSigs == tailSigs, "tail from a mid-line seek must equal the bottom of the full parse")
    }

    @Test func parseTail_grows_chunk_when_items_exceed_window() throws {
        // A handful of HUGE items: each line is far larger than typical, so a
        // small initial window might underflow `limit` and force a grow. Even
        // with the 1MB default this stays correct; the assertion is that the
        // grow-on-underflow path still returns the full parse's exact bottom.
        let huge = String(repeating: "y", count: 200_000)
        var lines: [String] = []
        for i in 0..<8 {
            let ts = "2026-05-05T10:00:0\(i)Z"
            lines.append(
                "{\"type\":\"assistant\",\"uuid\":\"a\(i)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(huge) \(i)\"}]}}")
        }
        let tmp = try writeTempJSONL(lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let full = TranscriptParser.parse(filePath: tmp)
        let tail = TranscriptParser.parseTail(filePath: tmp, limit: 5)
        #expect(tail.count == 5)
        #expect(full.suffix(5).map(signature) == tail.map(signature))
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
