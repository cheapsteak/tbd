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

    /// The fixture's last two lines document the queued shape: an `enqueue`
    /// bookkeeping row that must render nothing, followed by the
    /// `queued_command` attachment that IS the delivery record.
    @Test func parses_queued_prompt_from_fixture() throws {
        let items = TranscriptParser.parse(filePath: fixturePath)
        let queued = items.filter {
            if case .userPrompt(let id, _, _) = $0 { return id == "queued-1" }
            return false
        }
        #expect(queued.count == 1, "the fixture's queued prompt must render exactly once")
        if case .userPrompt(_, let text, _)? = queued.first {
            #expect(text == "Also check the retry path while you are in there.")
        }
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
        if case .systemReminder(_, let kind, _, _, _, _) = items[0] {
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
        if case .systemReminder(_, let kind, let text, _, _, _) = items[0] {
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
            if case .systemReminder(_, let kind, let text, _, _, _) = item { return (kind, text) }
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
        case .systemReminder(let id, let kind, let t, _, _, _): return "systemReminder|\(id)|\(kind)|\(t)"
        case .toolCall(let id, let name, _, _, let result, _, _, _):
            return "toolCall|\(id)|\(name)|\(result?.text ?? "<nil>")"
        case .slashCommand(let id, let name, let args, _):
            return "slashCommand|\(id)|\(name)|\(args ?? "")"
        case .peerMessage(let id, let sender, let t, let payload, _):
            // The delivered payload is part of the signature: a tail parse that
            // recovered the clean body but dropped the original would otherwise
            // compare equal to a full parse that kept both.
            return "peerMessage|\(id)|\(sender.from)|\(sender.verified)|\(t)|\(payload ?? "<nil>")"
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

    // MARK: - attachments (hook- and CLAUDE.md-injected context)
    //
    // Tier 1. Fixture rows mirror the real shapes observed in a live Claude
    // Code session JSONL (an `attachment` row per flavor); paths and hook
    // payloads are rewritten to acme placeholders and shortened, except where
    // a test needs to cross the 2000-char truncation cap.

    /// Builds one `type:"attachment"` JSONL line from an attachment dict.
    private func attachmentLine(uuid: String, _ attachment: [String: Any]) throws -> String {
        let row: [String: Any] = [
            "type": "attachment",
            "uuid": uuid,
            "timestamp": "2026-07-24T10:00:00.000Z",
            "attachment": attachment
        ]
        let data = try JSONSerialization.data(withJSONObject: row)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    private func reminders(_ items: [TranscriptItem]) -> [(id: String, kind: SystemKind, text: String, source: String?, truncatedTo: Int?)] {
        items.compactMap {
            if case .systemReminder(let id, let kind, let text, _, let source, let truncatedTo) = $0 {
                return (id, kind, text, source, truncatedTo)
            }
            return nil
        }
    }

    @Test func attachment_nestedMemory_unwraps_nested_content_dict() throws {
        // `attachment.content` is an OBJECT here; the CLAUDE.md body sits at
        // `content.content`. A naive `content as? String` drops it entirely.
        let line = try attachmentLine(uuid: "att-mem", [
            "type": "nested_memory",
            "displayPath": ".github/CLAUDE.md",
            "path": "/Users/dev/acme-prod/.github/CLAUDE.md",
            "content": ["path": "/Users/dev/acme-prod/.github/CLAUDE.md",
                        "type": "nested_memory",
                        "content": "# acme-prod workflow rules"]
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let found = reminders(TranscriptParser.parse(filePath: tmp))
        #expect(found.count == 1)
        let row = try #require(found.first)
        #expect(row.id == "att-mem")
        #expect(row.kind == .nestedMemory)
        #expect(row.text == "# acme-prod workflow rules")
        #expect(row.source == ".github/CLAUDE.md")
        #expect(row.truncatedTo == nil)
    }

    @Test func attachment_nestedMemory_long_body_records_original_length() throws {
        let body = String(repeating: "acme rule line\n", count: 400)  // > 2000 chars, > 20 lines
        let line = try attachmentLine(uuid: "att-big", [
            "type": "nested_memory",
            "displayPath": "CLAUDE.md",
            "content": ["content": body]
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let row = try #require(reminders(TranscriptParser.parse(filePath: tmp)).first)
        #expect(row.text.count < body.count, "body must be truncated for the collapsed row")
        #expect(row.truncatedTo == body.count, "truncatedTo carries the ORIGINAL character count")

        // The click-to-open overlay must be able to recover the whole thing —
        // attachment rows carry no `message`, so this needs its own branch.
        #expect(TranscriptParser.lookupFullBody(filePath: tmp, itemID: "att-big") == body)
    }

    @Test func attachment_file_unwraps_dict_in_dict_body() throws {
        // An @-mentioned file: `attachment.content` is an object whose `file`
        // sub-object holds the body — one level deeper than `nested_memory`.
        let line = try attachmentLine(uuid: "att-file", [
            "type": "file",
            "displayPath": "src/acme/deploy.swift",
            "filename": "deploy.swift",
            "content": ["type": "text",
                        "file": ["filePath": "/Users/dev/acme-prod/src/acme/deploy.swift",
                                 "content": "func deployAcme() {}\n"]]
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let found = reminders(TranscriptParser.parse(filePath: tmp))
        #expect(found.count == 1)
        let row = try #require(found.first)
        #expect(row.id == "att-file")
        #expect(row.kind == .nestedMemory)
        #expect(row.text == "func deployAcme() {}\n")
        #expect(row.source == "src/acme/deploy.swift")
    }

    @Test func attachment_hookAdditionalContext_unwraps_string_array_and_suffixes_ids() throws {
        // `attachment.content` is an ARRAY of strings — one item per element.
        let line = try attachmentLine(uuid: "att-hac", [
            "type": "hook_additional_context",
            "hookName": "SessionStart",
            "content": ["first injected block", "second injected block"]
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let found = reminders(TranscriptParser.parse(filePath: tmp))
        #expect(found.map(\.id) == ["att-hac#0", "att-hac#1"])
        #expect(found.map(\.text) == ["first injected block", "second injected block"])
        #expect(found.allSatisfy { $0.kind == .hookOutput && $0.source == "SessionStart" })

        #expect(TranscriptParser.lookupFullBody(filePath: tmp, itemID: "att-hac#1") == "second injected block")
    }

    @Test func attachment_hookSuccess_ignores_additionalContext_in_stdout() throws {
        // A hook's stdout is what it EMITTED; `hook_additional_context` is what
        // was actually INJECTED. Measured across 120+ real sessions, the latter
        // covers 100% of the former — so the stdout path is pure redundancy and
        // emits nothing. The hac twin is the row that renders.
        let injected = "acme ADR applies here"
        let stdout = #"{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"\#(injected)"}}"#
        let lines = [
            try attachmentLine(uuid: "att-hs", [
                "type": "hook_success",
                "hookName": "PostToolUse:Read",
                "content": "",
                "stdout": stdout
            ]),
            try attachmentLine(uuid: "att-hac", [
                "type": "hook_additional_context",
                "hookName": "PostToolUse:Read",
                "content": [injected]
            ])
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let found = reminders(TranscriptParser.parse(filePath: tmp))
        #expect(found.count == 1, "hook_success stdout must contribute nothing")
        let row = try #require(found.first)
        #expect(row.id == "att-hac")
        #expect(row.kind == .hookOutput)
        #expect(row.source == "PostToolUse:Read")
        #expect(row.text == injected)
    }

    @Test func attachment_buildItems_is_window_independent_for_hookSuccess_pair() throws {
        // `parseTail` hands `buildItems` only the lines inside its byte window.
        // Any cross-row state (a dedup set, say) would make the same row parse
        // differently depending on what preceded it — breaking parseTail's
        // identical-bottom guarantee. Parse the pair, then parse the second row
        // alone, and require the item to be identical.
        let injected = "acme ADR applies here"
        let stdout = #"{"hookSpecificOutput":{"additionalContext":"\#(injected)"}}"#
        let hsLine = try attachmentLine(uuid: "att-hs", [
            "type": "hook_success", "hookName": "SessionStart", "content": "", "stdout": stdout
        ])
        let hacLine = try attachmentLine(uuid: "att-hac", [
            "type": "hook_additional_context", "hookName": "SessionStart", "content": [injected]
        ])

        let both = try writeTempJSONL([hsLine, hacLine].joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(atPath: both) }
        let windowOnly = try writeTempJSONL(hacLine)
        defer { try? FileManager.default.removeItem(atPath: windowOnly) }

        let fullTail = try #require(TranscriptParser.parse(filePath: both).last)
        let windowed = try #require(TranscriptParser.parse(filePath: windowOnly).last)
        #expect(fullTail == windowed)
    }

    @Test func attachment_hookSuccess_plain_content_emits_once() throws {
        // The plain-text branch survives — `hook_success.content` is never
        // mirrored in a hook_additional_context row (221/221 unique across the
        // corpus), so dropping it would lose the text entirely. `stdout` never
        // contributes, JSON or not, so exactly one item comes out.
        let line = try attachmentLine(uuid: "att-plain", [
            "type": "hook_success",
            "hookName": "SessionStart:startup",
            "content": "Cleared: /tmp/acme-work-claimed",
            "stdout": #"{"hookSpecificOutput":{"additionalContext":"something else entirely"}}"#
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let found = reminders(TranscriptParser.parse(filePath: tmp))
        #expect(found.count == 1)
        #expect(found.first?.text == "Cleared: /tmp/acme-work-claimed")
        #expect(found.first?.source == "SessionStart:startup")
    }

    @Test func attachment_hookSuccess_empty_stdout_object_emits_nothing() throws {
        // The overwhelmingly common case: `stdout` is literally "{}\n".
        let line = try attachmentLine(uuid: "att-empty", [
            "type": "hook_success", "hookName": "PostToolUse:Bash", "content": "", "stdout": "{}\n"
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect(TranscriptParser.parse(filePath: tmp).isEmpty)
    }

    @Test func attachment_injected_context_comes_only_from_additionalContext_row() throws {
        // The hook EMITS a payload (hook_success stdout), and what actually
        // entered the context window lands in the hook_additional_context row —
        // sometimes verbatim, sometimes as the `<persisted-output>` notice that
        // REPLACED an oversized payload. Only the hac row renders; every item
        // stays addressable by `lookupFullBody`.
        let emitted = "acme skill rules apply"
        let stdout = try String(
            decoding: JSONSerialization.data(
                withJSONObject: ["hookSpecificOutput": ["additionalContext": emitted]]),
            as: UTF8.self)
        let lines = [
            try attachmentLine(uuid: "hs-1", [
                "type": "hook_success", "hookName": "SessionStart", "content": "", "stdout": stdout
            ]),
            try attachmentLine(uuid: "hac-1", [
                "type": "hook_additional_context",
                "hookName": "SessionStart",
                "content": [emitted, "<persisted-output>\nOutput too large (22.2KB).\n</persisted-output>"]
            ])
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let found = reminders(TranscriptParser.parse(filePath: tmp))
        #expect(found.map(\.text) == [emitted, "<persisted-output>\nOutput too large (22.2KB).\n</persisted-output>"])
        #expect(found.map(\.id) == ["hac-1#0", "hac-1#1"])
        #expect(TranscriptParser.lookupFullBody(filePath: tmp, itemID: "hac-1#1")?.hasPrefix("<persisted-output>") == true)
    }

    @Test func attachment_skillListing_emits_hookOutput_named_skills() throws {
        let line = try attachmentLine(uuid: "att-skills", [
            "type": "skill_listing", "skillCount": 2, "content": "acme-deploy, acme-review"
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let row = try #require(reminders(TranscriptParser.parse(filePath: tmp)).first)
        #expect(row.kind == .hookOutput)
        #expect(row.source == "skills")
        #expect(row.text == "acme-deploy, acme-review")
    }

    /// Flavors that carry no injected *prose* context. `queued_command` is
    /// deliberately absent: it carries the user's own prompt and renders as a
    /// chat bubble — see the queued-prompt tests below.
    @Test func attachment_payloadless_flavors_emit_nothing() throws {
        let lines = [
            try attachmentLine(uuid: "att-tr", ["type": "task_reminder", "content": [], "itemCount": 0]),
            try attachmentLine(uuid: "att-cp", ["type": "command_permissions", "allowedTools": ["Bash"]]),
            try attachmentLine(uuid: "att-dd", ["type": "deferred_tools_delta", "addedNames": ["X"]])
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect(TranscriptParser.parse(filePath: tmp).isEmpty)
    }

    // MARK: - injected path normalization
    //
    // Tier 1. Claude Code writes `displayPath` relative to the cwd, so a file
    // outside the repo arrives as `../../../../../../private/tmp/…` — useless
    // once the row middle-truncates it.

    @Test func injectedPath_in_repo_displayPath_is_used_verbatim() throws {
        // The nicest form already: no `../`, no home prefix. Must not change.
        let line = try attachmentLine(uuid: "att-inrepo", [
            "type": "nested_memory",
            "displayPath": ".github/CLAUDE.md",
            "path": "\(NSHomeDirectory())/acme-prod/.github/CLAUDE.md",
            "content": ["type": "Project", "content": "# acme rules"]
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect(reminders(TranscriptParser.parse(filePath: tmp)).first?.source == ".github/CLAUDE.md")
    }

    @Test func injectedPath_escaping_displayPath_falls_back_to_tilde_absolute() throws {
        let absolute = "\(NSHomeDirectory())/scratch/acme/iam-pr-body.md"
        let line = try attachmentLine(uuid: "att-escape", [
            "type": "file",
            "displayPath": "../../../../../../scratch/acme/iam-pr-body.md",
            "filename": "iam-pr-body.md",
            "content": ["type": "text", "file": ["filePath": absolute, "content": "body"]]
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let source = try #require(reminders(TranscriptParser.parse(filePath: tmp)).first?.source)
        #expect(source == "~/scratch/acme/iam-pr-body.md")
        #expect(!source.hasPrefix("../"), "an escaping relative path must never reach the row")
    }

    @Test func injectedPath_missing_displayPath_uses_absolute_path() throws {
        // No `displayPath` at all: `attachment.path` is the only absolute form.
        let line = try attachmentLine(uuid: "att-nodp", [
            "type": "nested_memory",
            "path": "/opt/acme/CLAUDE.md",
            "content": ["type": "Project", "content": "# acme rules"]
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        // Outside $HOME, so no tilde to collapse — the absolute path stands.
        #expect(reminders(TranscriptParser.parse(filePath: tmp)).first?.source == "/opt/acme/CLAUDE.md")
    }

    @Test func injectedPath_escaping_with_no_absolute_falls_back_to_filename() throws {
        let line = try attachmentLine(uuid: "att-fname", [
            "type": "file",
            "displayPath": "../../../tmp/acme/notes.md",
            "filename": "notes.md",
            "content": ["type": "text", "file": ["content": "body"]]
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect(reminders(TranscriptParser.parse(filePath: tmp)).first?.source == "notes.md")
    }

    // The `~` abbreviation must match whole path components. A substring
    // replace of `NSHomeDirectory()` mangled sibling and nested paths.
    @Test func injectedPath_tilde_abbreviation_is_component_boundary_aware() {
        let home = NSHomeDirectory()
        let leaf = (home as NSString).lastPathComponent
        let parent = (home as NSString).deletingLastPathComponent

        // A genuine home-prefixed path abbreviates.
        #expect(TranscriptParser.injectedPathSource(
            displayPath: nil, absolutePath: "\(home)/acme-prod/CLAUDE.md", filename: nil)
            == "~/acme-prod/CLAUDE.md")

        // A *sibling* directory whose name merely starts with the home leaf is
        // a different directory and must be left alone.
        let sibling = "\(parent)/\(leaf)log-archive/CLAUDE.md"
        #expect(TranscriptParser.injectedPathSource(
            displayPath: nil, absolutePath: sibling, filename: nil) == sibling)

        // Home appearing mid-path (an external volume) must not be spliced.
        let onVolume = "/Volumes/T7\(home)/notes.md"
        #expect(TranscriptParser.injectedPathSource(
            displayPath: nil, absolutePath: onVolume, filename: nil) == onVolume)
    }

    @Test func injectedPath_last_resort_is_the_display_paths_last_component() {
        // Neither an absolute path nor a filename: strip the escape prefix
        // rather than rendering `../../..`.
        #expect(TranscriptParser.injectedPathSource(
            displayPath: "../../../tmp/acme/notes.md", absolutePath: nil, filename: nil) == "notes.md")
        #expect(TranscriptParser.injectedPathSource(
            displayPath: nil, absolutePath: nil, filename: nil) == nil)
    }

    // MARK: - injection metadata (overlay round-trip payload)
    //
    // Tier 1. Metadata rides `lookupDetail` — the same round-trip the overlay
    // already makes for a full body — so nothing is added to `TranscriptItem`.

    /// One assistant line carrying a single `tool_use` block.
    private func toolUseLine(uuid: String, id: String, name: String, input: [String: Any]) throws -> String {
        let row: [String: Any] = [
            "type": "assistant",
            "uuid": uuid,
            "timestamp": "2026-07-24T09:59:59.000Z",
            "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": id, "name": name, "input": input]
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: row)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test func metadata_hookSuccess_carries_hook_command_exit_duration_stderr() throws {
        let line = try attachmentLine(uuid: "att-hs", [
            "type": "hook_success",
            "hookName": "PostToolUse:Read",
            "hookEvent": "PostToolUse",
            "command": #"python3 "${CLAUDE_PLUGIN_ROOT}/hooks/posttooluse.py""#,
            "exitCode": 0,
            "durationMs": 142,
            "stderr": "acme: cache miss",
            "content": "Injected acme guidance"
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let detail = TranscriptParser.lookupDetail(filePath: tmp, itemID: "att-hs")
        #expect(detail.text == "Injected acme guidance")
        let m = try #require(detail.attachment)
        #expect(m.hookName == "PostToolUse:Read")
        #expect(m.hookEvent == "PostToolUse")
        #expect(m.command == #"python3 "${CLAUDE_PLUGIN_ROOT}/hooks/posttooluse.py""#)
        #expect(m.exitCode == 0)
        #expect(m.durationMs == 142)
        #expect(m.stderr == "acme: cache miss")
        #expect(m.memoryType == nil, "memory tier is meaningless for a hook row")
    }

    @Test func metadata_omits_blank_and_absent_fields() throws {
        // Empty strings must read as absent so the overlay can omit the line
        // instead of rendering an empty value.
        let line = try attachmentLine(uuid: "att-blank", [
            "type": "hook_additional_context",
            "hookName": "SessionStart:compact",
            "stderr": "   ",
            "content": ["injected"]
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let m = try #require(TranscriptParser.lookupDetail(filePath: tmp, itemID: "att-blank").attachment)
        #expect(m.hookName == "SessionStart:compact")
        #expect(m.stderr == nil)
        #expect(m.command == nil)
        #expect(m.exitCode == nil)
        #expect(m.path == nil)
    }

    @Test func metadata_nestedMemory_carries_tier_and_absolute_path() throws {
        let absolute = "\(NSHomeDirectory())/acme-prod/.github/CLAUDE.md"
        let line = try attachmentLine(uuid: "att-mem", [
            "type": "nested_memory",
            "displayPath": ".github/CLAUDE.md",
            "path": absolute,
            "content": ["path": absolute, "type": "Project", "content": "# acme rules"]
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let m = try #require(TranscriptParser.lookupDetail(filePath: tmp, itemID: "att-mem").attachment)
        #expect(m.memoryType == "Project")
        // The FULL absolute path — the overlay abbreviates for display and
        // copies this verbatim.
        #expect(m.path == absolute)
        #expect(m.hookName == nil)
    }

    @Test func metadata_file_carries_path_but_no_memory_tier() throws {
        let line = try attachmentLine(uuid: "att-file", [
            "type": "file",
            "displayPath": "src/acme/deploy.swift",
            "filename": "deploy.swift",
            "content": ["type": "text",
                        "file": ["filePath": "/srv/acme-prod/src/acme/deploy.swift", "content": "func deployAcme() {}"]]
        ])
        let tmp = try writeTempJSONL(line)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let m = try #require(TranscriptParser.lookupDetail(filePath: tmp, itemID: "att-file").attachment)
        #expect(m.path == "/srv/acme-prod/src/acme/deploy.swift")
        #expect(m.memoryType == nil, "a file row's inner type is just \"text\", not a memory tier")
    }

    @Test func metadata_is_nil_for_non_attachment_rows() throws {
        let lines = [
            try toolUseLine(uuid: "a1", id: "toolu_1", name: "Read",
                            input: ["file_path": "/srv/acme-prod/.github/workflows/ai-review-gate.yml"]),
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"file body"}]}}"#
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let detail = TranscriptParser.lookupDetail(filePath: tmp, itemID: "toolu_1")
        #expect(detail.text == "file body")
        #expect(detail.attachment == nil)
    }

    // MARK: - hook attribution (attachment.toolUseID → triggering tool call)

    @Test func attribution_resolves_toolUseID_to_tool_name_and_input_summary() throws {
        let lines = [
            try toolUseLine(uuid: "a1", id: "toolu_1", name: "Read",
                            input: ["file_path": "/srv/acme-prod/.github/workflows/ai-review-gate.yml"]),
            try attachmentLine(uuid: "att-hac", [
                "type": "hook_additional_context",
                "hookName": "PostToolUse:Read",
                "toolUseID": "toolu_1",
                "content": ["acme review gate applies"]
            ])
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let m = try #require(TranscriptParser.lookupDetail(filePath: tmp, itemID: "att-hac").attachment)
        #expect(m.triggeredBy == "Read ai-review-gate.yml")
    }

    @Test func attribution_omitted_when_toolUseID_resolves_to_nothing() throws {
        // ~3% of real hook rows name a tool_use that isn't in the file. Omit
        // the line entirely — never "unknown", never a guess.
        let lines = [
            try toolUseLine(uuid: "a1", id: "toolu_1", name: "Read", input: ["file_path": "/srv/acme-prod/main.swift"]),
            try attachmentLine(uuid: "att-orphan", [
                "type": "hook_additional_context",
                "hookName": "PostToolUse:Read",
                "toolUseID": "toolu_missing",
                "content": ["acme guidance"]
            ])
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let m = try #require(TranscriptParser.lookupDetail(filePath: tmp, itemID: "att-orphan").attachment)
        #expect(m.triggeredBy == nil)
        #expect(m.hookName == "PostToolUse:Read", "the rest of the metadata still lands")
    }

    @Test func attribution_absent_for_nestedMemory_and_file_rows() throws {
        // Neither flavor carries a `toolUseID`, and NOTHING in the JSONL links a
        // CLAUDE.md load to the Read that touched its directory. Inferring one
        // from row position would be positional guesswork — attribution is
        // simply absent, even with a tool_use sitting immediately above.
        let lines = [
            try toolUseLine(uuid: "a1", id: "toolu_1", name: "Read",
                            input: ["file_path": "/srv/acme-prod/.github/deploy.yml"]),
            try attachmentLine(uuid: "att-mem", [
                "type": "nested_memory",
                "displayPath": ".github/CLAUDE.md",
                "path": "/srv/acme-prod/.github/CLAUDE.md",
                "content": ["type": "Project", "content": "# acme rules"]
            ]),
            try attachmentLine(uuid: "att-file", [
                "type": "file",
                "displayPath": "src/acme/deploy.swift",
                "content": ["type": "text", "file": ["filePath": "/srv/acme-prod/src/acme/deploy.swift",
                                                     "content": "func deployAcme() {}"]]
            ])
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        for itemID in ["att-mem", "att-file"] {
            let m = try #require(TranscriptParser.lookupDetail(filePath: tmp, itemID: itemID).attachment)
            #expect(m.triggeredBy == nil, "\(itemID) must carry no attribution")
        }
    }

    @Test func attribution_summary_shapes_per_tool() {
        #expect(TranscriptParser.toolInputSummary(
            name: "Read", input: ["file_path": "/srv/acme-prod/Sources/Deploy.swift"]) == "Read Deploy.swift")
        #expect(TranscriptParser.toolInputSummary(
            name: "Bash", input: ["command": "swift build", "description": "Build acme"]) == "Bash Build acme")
        #expect(TranscriptParser.toolInputSummary(
            name: "Bash", input: ["command": "swift build"]) == "Bash swift build")
        #expect(TranscriptParser.toolInputSummary(
            name: "Grep", input: ["pattern": "TODO", "path": "Sources"]) == "Grep TODO")
        #expect(TranscriptParser.toolInputSummary(name: "TodoWrite", input: [:]) == "TodoWrite")
        // Long inputs are clipped, one line, with an ellipsis.
        let summary = TranscriptParser.toolInputSummary(
            name: "Bash", input: ["command": String(repeating: "acme ", count: 40)])
        #expect(summary.count <= "Bash ".count + 41)
        #expect(summary.hasSuffix("…"))
    }

    // MARK: - queued prompts
    //
    // A prompt typed while the agent is mid-turn is QUEUED, and Claude Code
    // never writes a `type:"user"` line for it — the delivery is recorded only
    // as a `queued_command` attachment. Measured over 120 recent session files,
    // 92 of them carried such rows and only 3 of 1331 were mirrored by a user
    // line, so every one of these prompts used to vanish from the transcript.

    /// Builds one `type:"attachment"` queued-prompt row. `prompt` is `Any` so a
    /// test can pass the array-of-content-blocks form a multimodal paste uses.
    private func queuedLine(uuid: String, prompt: Any, commandMode: String = "prompt") throws -> String {
        try attachmentLine(uuid: uuid, [
            "type": "queued_command",
            "prompt": prompt,
            "commandMode": commandMode,
            "origin": ["kind": "human"]
        ])
    }

    private func userPrompts(_ items: [TranscriptItem]) -> [(id: String, text: String)] {
        items.compactMap {
            if case .userPrompt(let id, let text, _) = $0 { return (id, text) }
            return nil
        }
    }

    @Test func queued_typed_prompt_renders_as_a_user_bubble() throws {
        let tmp = try writeTempJSONL(
            try queuedLine(uuid: "q1", prompt: "is the sonnet subagent what the codex subagent does?"))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1, "a queued prompt must render, not vanish")
        let prompts = userPrompts(items)
        #expect(prompts.count == 1)
        #expect(prompts.first?.id == "q1", "the row uses the line's own uuid")
        #expect(prompts.first?.text == "is the sonnet subagent what the codex subagent does?")
    }

    @Test func queued_cross_session_message_renders_as_a_user_bubble() throws {
        // Agent-to-agent traffic arrives queued and is real conversation, not
        // harness noise — it renders exactly as a typed prompt does.
        let text = #"<cross-session-message from-name="acme-worker">[note] standing down</cross-session-message>"#
        let tmp = try writeTempJSONL(try queuedLine(uuid: "q1", prompt: text))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect(userPrompts(TranscriptParser.parse(filePath: tmp)).first?.text == text)
    }

    @Test func queued_task_notification_is_a_system_row_not_a_user_bubble() throws {
        let text = "<task-notification>\n<task-id>bpzi7e9op</task-id>\n</task-notification>"
        let tmp = try writeTempJSONL(
            try queuedLine(uuid: "q1", prompt: text, commandMode: "task-notification"))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1)
        #expect(userPrompts(items).isEmpty, "a task notification is not something the user said")
        guard case .systemReminder(let id, let kind, let rowText, _, _, _) = items[0] else {
            Issue.record("expected .systemReminder"); return
        }
        #expect(id == "q1")
        #expect(kind == .taskNotification)
        #expect(rowText == text)
    }

    @Test func queued_slash_envelope_flattens_to_the_command_line() throws {
        let text = "<command-name>commit</command-name><command-args>--amend</command-args>"
        let tmp = try writeTempJSONL(try queuedLine(uuid: "q1", prompt: text))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1)
        #expect(userPrompts(items).first?.text == "/commit --amend",
                "a queued slash command flattens exactly like a typed one")
    }

    @Test func queued_prompt_as_content_blocks_joins_every_text_block() throws {
        // Multimodal paste: `prompt` is an array of content blocks. Every text
        // block joins, mirroring the `type:"user"` content-array rule.
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "first line"],
            ["type": "image", "source": ["type": "base64"]],
            ["type": "text", "text": "second line"]
        ]
        let tmp = try writeTempJSONL(try queuedLine(uuid: "q1", prompt: blocks))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let items = TranscriptParser.parse(filePath: tmp)
        #expect(items.count == 1)
        #expect(userPrompts(items).first?.text == "first line\nsecond line")
    }

    @Test func queued_prompt_full_body_is_recoverable_by_line_uuid() throws {
        let text = "the queued question in full"
        let tmp = try writeTempJSONL(try queuedLine(uuid: "q1", prompt: text))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect(TranscriptParser.lookupFullBody(filePath: tmp, itemID: "q1") == text)
    }

    /// Every degenerate `prompt` shape must leave the row exactly where it was
    /// before the queued branch existed: matched by no payload extractor, and
    /// therefore rendering nothing. An empty bubble is worse than no bubble,
    /// and `as? [[String: Any]]` is element-wise — an array of bare strings
    /// fails the cast rather than yielding a partial join.
    @Test func queued_prompt_with_no_usable_text_renders_nothing() throws {
        let lines = try [
            attachmentLine(uuid: "q-absent", ["type": "queued_command", "commandMode": "prompt"]),
            attachmentLine(uuid: "q-empty", ["type": "queued_command", "prompt": ""]),
            attachmentLine(uuid: "q-emptyArray", ["type": "queued_command", "prompt": [] as [Any]]),
            attachmentLine(uuid: "q-noTextBlock", ["type": "queued_command",
                "prompt": [["type": "image", "source": ["type": "base64"]]] as [[String: Any]]]),
            attachmentLine(uuid: "q-blankBlocks", ["type": "queued_command",
                "prompt": [["type": "text", "text": ""]] as [[String: Any]]]),
            attachmentLine(uuid: "q-number", ["type": "queued_command", "prompt": 42]),
            attachmentLine(uuid: "q-object", ["type": "queued_command", "prompt": ["text": "not a block array"]]),
            attachmentLine(uuid: "q-stringArray", ["type": "queued_command", "prompt": ["a", "b"] as [Any]])
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect(TranscriptParser.parse(filePath: tmp).isEmpty)
        for uuid in ["q-absent", "q-empty", "q-emptyArray", "q-noTextBlock",
                     "q-blankBlocks", "q-number", "q-object", "q-stringArray"] {
            #expect(TranscriptParser.lookupFullBody(filePath: tmp, itemID: uuid) == nil,
                    "\(uuid) has no recoverable body")
        }
    }

    /// The queued branch returns early from `lookupDetail`, before the general
    /// `attachmentPayloads` extraction. Injected-context rows in the same file
    /// must still resolve their body AND their injection metadata — the early
    /// return is keyed on the row, not on the file.
    @Test func lookupDetail_still_resolves_injected_rows_alongside_a_queued_row() throws {
        let absolute = "\(NSHomeDirectory())/acme-prod/CLAUDE.md"
        let lines = try [
            queuedLine(uuid: "q1", prompt: "queued while busy"),
            attachmentLine(uuid: "att-mem", [
                "type": "nested_memory",
                "displayPath": "CLAUDE.md",
                "path": absolute,
                "content": ["path": absolute, "type": "Project", "content": "# acme rules"]
            ])
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let queued = TranscriptParser.lookupDetail(filePath: tmp, itemID: "q1")
        #expect(queued.text == "queued while busy")
        #expect(queued.attachment == nil, "a queued prompt is the user's own input, not injected context")

        let injected = TranscriptParser.lookupDetail(filePath: tmp, itemID: "att-mem")
        #expect(injected.text == "# acme rules")
        #expect(injected.attachment?.memoryType == "Project")
    }

    @Test func queue_operation_rows_render_nothing() throws {
        // `enqueue`/`remove`/`dequeue` are queue bookkeeping, not the delivery
        // record. If they rendered, one queued prompt would appear several times.
        let lines = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-08-19T21:13:08.194Z","content":"do the thing"}"#,
            #"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-08-19T21:13:09.194Z","content":"do the thing"}"#,
            #"{"type":"queue-operation","operation":"remove","timestamp":"2026-08-19T21:13:10.194Z","content":"do the thing"}"#,
        ].joined(separator: "\n")
        let tmp = try writeTempJSONL(lines)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        #expect(TranscriptParser.parse(filePath: tmp).isEmpty)
    }

    @Test func parseTail_window_with_a_queued_row_matches_the_full_parse() throws {
        // The purity contract: `buildItems` sees only the lines in the tail's
        // byte window, so a queued row must be derivable from itself alone —
        // no cross-row dedup against a user line that may sit outside the window.
        var lines: [String] = []
        for i in 0..<20 {
            let ts = "2026-05-05T10:00:\(String(format: "%02d", i))Z"
            lines.append(
                "{\"type\":\"assistant\",\"uuid\":\"a\(i)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"reply \(i)\"}]}}")
        }
        lines.append(#"{"type":"queue-operation","operation":"enqueue","content":"queued near the end"}"#)
        lines.append(try queuedLine(uuid: "qtail", prompt: "queued near the end"))
        lines.append(
            #"{"type":"assistant","uuid":"alast","timestamp":"2026-05-05T10:00:59Z","message":{"role":"assistant","content":[{"type":"text","text":"on it"}]}}"#)

        let tmp = try writeTempJSONL(lines.joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let full = TranscriptParser.parse(filePath: tmp)
        #expect(full.contains { if case .userPrompt(let id, _, _) = $0 { return id == "qtail" }; return false },
                "the queued row must be in the full parse for the comparison to mean anything")

        let tail = TranscriptParser.parseTail(filePath: tmp, limit: 5)
        #expect(tail.count == 5)
        #expect(full.suffix(5).map(signature) == tail.map(signature),
                "a tail window containing a queued row must equal the bottom of the full parse")
    }

    // MARK: - peer messages
    //
    // Tier 1. The committed six-row fixture: four peer rows (two verified-rich,
    // one asserted, one older-verified) followed by two ordinary typed prompts.

    private var peerFixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/peer-messages.jsonl")
            .path
    }

    @Test func peer_rows_emit_peerMessage_items_in_order() throws {
        let items = TranscriptParser.parse(filePath: peerFixturePath)
        let peers = items.compactMap { item -> PeerSender? in
            if case .peerMessage(_, let sender, _, _, _) = item { return sender }
            return nil
        }
        #expect(peers.count == 4, "the fixture's four peer rows must each render as a peer message")

        #expect(peers.map(\.from) == [
            "uds:/tmp/cc-socks/26152.sock",
            "uds:/tmp/cc-socks/4300.sock",
            "acme-bot",
            "uds:/tmp/cc-socks/20202.sock",
        ], "peer messages must keep the transcript's row order")
        #expect(peers.map(\.verified) == [true, true, false, false])
        #expect(peers.map(\.name) == ["🛠 Acme Deploy Watch", "📝 Acme Release Notes", nil, nil])
        #expect(peers.map(\.pid) == [26152, 4300, nil, nil])
    }

    @Test func peer_rows_carry_clean_text_and_the_untouched_payload() throws {
        let items = TranscriptParser.parse(filePath: peerFixturePath)
        let peers = items.compactMap { item -> (text: String, payload: String?)? in
            if case .peerMessage(_, _, let text, let payload, _) = item { return (text, payload) }
            return nil
        }
        #expect(peers.count == 4)

        for peer in peers {
            #expect(!peer.text.hasPrefix("\n"), "no peer body may start with a blank line")
            #expect(!peer.text.contains("<cross-session-message"),
                    "the envelope's open tag must not survive into the rendered body")
            #expect(!peer.text.contains("Another Claude session sent a message:"))
            #expect(!peer.text.contains("This came from another Claude session"))
        }

        // The overlay reads the original delivery verbatim, so it must be kept
        // whenever cleaning changed anything — which, for every fixture row,
        // it did.
        for peer in peers {
            let payload = try #require(peer.payload, "a cleaned body must retain its delivered payload")
            #expect(payload.hasPrefix("Another Claude session sent a message:"))
            #expect(payload != peer.text)
        }
    }

    @Test func non_peer_rows_still_render_as_user_prompts() throws {
        let items = TranscriptParser.parse(filePath: peerFixturePath)
        let prompts = items.compactMap { item -> String? in
            if case .userPrompt(_, let text, _) = item { return text }
            return nil
        }
        #expect(prompts == ["please rebase this onto main", "and run the tests"],
                "the human-origin row and the origin-less row stay ordinary prompts")
    }

    @Test func no_user_prompt_carries_the_peer_delivery_framing() throws {
        let items = TranscriptParser.parse(filePath: peerFixturePath)
        for item in items {
            if case .userPrompt(let id, let text, _) = item {
                #expect(!text.hasPrefix("Another Claude session sent a message:"),
                        "row \(id) rendered a peer delivery as a typed prompt")
            }
        }
    }

    @Test func parseTail_window_with_peer_rows_matches_the_full_parse() throws {
        // The purity contract: `buildItems` sees only the lines inside the
        // tail's byte window, and a peer row must be derivable from itself
        // alone. The signature includes the delivered payload, so a tail that
        // recovered the clean body but dropped the original goes red here.
        let full = TranscriptParser.parse(filePath: peerFixturePath)
        #expect(full.count == 6, "the fixture must produce one item per row")

        let tail = TranscriptParser.parseTail(filePath: peerFixturePath, limit: 4)
        #expect(tail.count == 4)
        #expect(tail.contains { if case .peerMessage = $0 { return true }; return false },
                "the tail window must contain a peer row for this comparison to mean anything")
        #expect(full.suffix(4).map(signature) == tail.map(signature),
                "a tail window containing peer rows must equal the bottom of the full parse")
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
