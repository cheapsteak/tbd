import Testing
import Foundation
import TBDShared

@Suite("UserMessageClassifier")
struct UserMessageClassifierTests {

    private func line(_ type: String, role: String, content: Any) -> [String: Any] {
        ["type": type, "message": ["role": role, "content": content]]
    }

    @Test("passes real string message")
    func realStringMessage() {
        let l = line("user", role: "user", content: "Hello, can you help?")
        #expect(UserMessageClassifier.isRealUserMessage(l) == true)
        #expect(UserMessageClassifier.extractText(l) == "Hello, can you help?")
    }

    @Test("passes real array message")
    func realArrayMessage() {
        let l = line("user", role: "user", content: [["type": "text", "text": "Now add unit tests."]])
        #expect(UserMessageClassifier.isRealUserMessage(l) == true)
        #expect(UserMessageClassifier.extractText(l) == "Now add unit tests.")
    }

    /// A multi-image paste records one text block PER image, so extraction must
    /// keep them all. Taking only the first silently dropped every attachment
    /// after the first, and the transcript could then never show them.
    @Test("joins every text block, not just the first")
    func joinsAllTextBlocks() {
        let l = line("user", role: "user", content: [
            ["type": "text", "text": "[Image: source: /tmp/cache/2.png]"],
            ["type": "text", "text": "[Image: source: /tmp/cache/3.png]"]
        ])
        #expect(UserMessageClassifier.isRealUserMessage(l) == true)
        #expect(UserMessageClassifier.extractText(l)
            == "[Image: source: /tmp/cache/2.png]\n[Image: source: /tmp/cache/3.png]")
    }

    /// A typed prompt with a pasted image is `[text, image]` — the base64 block
    /// carries no path, so only the text block contributes.
    @Test("ignores non-text blocks when joining")
    func ignoresNonTextBlocks() {
        let l = line("user", role: "user", content: [
            ["type": "text", "text": "looks good [Image #1]"],
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "iVBOR"]]
        ])
        #expect(UserMessageClassifier.extractText(l) == "looks good [Image #1]")
    }

    @Test("filters system-reminder string")
    func filtersSystemReminder() {
        let l = line("user", role: "user", content: "<system-reminder>You are Claude.</system-reminder>")
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("filters tool_result string")
    func filtersToolResultString() {
        let l = line("user", role: "user", content: "<tool_result>output</tool_result>")
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("filters all-tool_result array")
    func filtersToolResultArray() {
        let l = line("user", role: "user", content: [
            ["type": "tool_result", "tool_use_id": "t1", "content": "result"]
        ])
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("slash commands (command- prefix) are filtered out")
    func filtersCommandPrefix() {
        let l = line("user", role: "user", content: [
            ["type": "text", "text": "<command-name>commit</command-name>"]
        ])
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("rejects non-user type")
    func rejectsAssistantType() {
        let l = line("assistant", role: "assistant", content: "Some response")
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("extracts text from array content")
    func extractsArrayText() {
        let l = line("user", role: "user", content: [
            ["type": "text", "text": "What does this error mean?"]
        ])
        #expect(UserMessageClassifier.extractText(l) == "What does this error mean?")
    }

    @Test("filters local-command prefix")
    func filtersLocalCommandPrefix() {
        let l = line("user", role: "user", content: "<local-command-stdout>output</local-command-stdout>")
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("empty string content: isRealUserMessage true, extractText nil")
    func emptyStringContent() {
        let l = line("user", role: "user", content: "")
        #expect(UserMessageClassifier.isRealUserMessage(l) == true)
        #expect(UserMessageClassifier.extractText(l) == nil)
    }

    @Test("task-notification string is not a real user message")
    func filtersTaskNotificationString() {
        let l = line("user", role: "user", content: "<task-notification>\n<task-id>abc</task-id>\n</task-notification>")
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("SYSTEM NOTIFICATION preamble string is not a real user message")
    func filtersSystemNotificationPreambleString() {
        let l = line("user", role: "user", content: "[SYSTEM NOTIFICATION - NOT USER INPUT]\nThis is an automated background-task event.\n<task-notification>\n<task-id>abc</task-id>\n</task-notification>")
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }

    @Test("task-notification array content is not a real user message")
    func filtersTaskNotificationArray() {
        let l = line("user", role: "user", content: [
            ["type": "text", "text": "<task-notification>\n<task-id>abc</task-id>\n</task-notification>"]
        ])
        #expect(UserMessageClassifier.isRealUserMessage(l) == false)
    }
}

@Suite("UserMessageClassifier.classify")
struct UserMessageClassifierClassifyTests {
    private func userLine(_ text: String) -> [String: Any] {
        return [
            "type": "user",
            "message": ["role": "user", "content": text],
        ]
    }

    @Test func real_user_message_returns_nil() {
        let line = userLine("Hi Claude, please help.")
        #expect(UserMessageClassifier.classify(line) == nil)
    }

    @Test func system_reminder_returns_toolReminder() {
        let line = userLine("<system-reminder>The task tools haven't been used recently...</system-reminder>")
        #expect(UserMessageClassifier.classify(line) == .toolReminder)
    }

    @Test func command_envelope_returns_slashEnvelope() {
        let line = userLine("<command-name>/rebase</command-name>")
        #expect(UserMessageClassifier.classify(line) == .slashEnvelope)
    }

    @Test func environment_details_returns_environmentDetails() {
        let line = userLine("<environment_details>cwd: /Users/x</environment_details>")
        #expect(UserMessageClassifier.classify(line) == .environmentDetails)
    }

    @Test func local_command_output_returns_hookOutput() {
        let line = userLine("<local-command-stdout>hello</local-command-stdout>")
        #expect(UserMessageClassifier.classify(line) == .hookOutput)
    }

    @Test func unknown_tag_prefix_returns_nil() {
        // Previously this returned .other via a speculative tag-shape
        // heuristic. We now bias toward user-typed XML: if a line passes
        // isRealUserMessage (i.e. its text doesn't match a known system
        // prefix), it's treated as a real prompt. Future unknown injections
        // degrade to plain user prompts rather than being hidden as system
        // noise — see user_typed_xml_prompt_returns_nil.
        let line = userLine("<diagnostics>some payload</diagnostics>")
        #expect(UserMessageClassifier.classify(line) == nil)
    }

    @Test func git_repository_context_returns_environmentDetails() {
        let line = userLine("# Git repository context\nbranch: main")
        #expect(UserMessageClassifier.classify(line) == .environmentDetails)
    }

    @Test func pure_tool_result_array_returns_nil() {
        let line: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]
                ] as [[String: Any]],
            ],
        ]
        #expect(UserMessageClassifier.classify(line) == nil)
    }

    @Test func digit_led_pseudo_tag_does_not_match_other() {
        // "<3 hearts" — looks tag-shaped but body "3" isn't a letter; must NOT match.
        let line = userLine("<3 hearts to you")
        #expect(UserMessageClassifier.classify(line) == nil)
    }

    @Test func skill_body_returns_skillBody() {
        let line = userLine("Base directory for this skill: /Users/me/.claude/skills/pr\n\n# Commit, Push, and Open a PR\n\n## Step 1: …")
        #expect(UserMessageClassifier.classify(line) == .skillBody)
    }

    @Test func user_typed_xml_prompt_returns_nil() {
        // A user typing `<html>...` is a real prompt, not a system injection.
        let line = userLine("<html>my page</html> please review")
        #expect(UserMessageClassifier.classify(line) == nil)
    }

    @Test func user_typed_data_tag_prompt_returns_nil() {
        let line = userLine("<data>some xml</data>")
        #expect(UserMessageClassifier.classify(line) == nil)
    }

    @Test func task_notification_returns_task_notification_kind() {
        let line = userLine("<task-notification>\n<task-id>abc</task-id>\n</task-notification>")
        #expect(UserMessageClassifier.classify(line) == .taskNotification)
        #expect(UserMessageClassifier.isRealUserMessage(line) == false)
    }

    @Test func system_notification_preamble_returns_task_notification_kind() {
        let line = userLine("[SYSTEM NOTIFICATION - NOT USER INPUT]\nThis is an automated background-task event.\n<task-notification>\n<task-id>abc</task-id>\n</task-notification>")
        #expect(UserMessageClassifier.classify(line) == .taskNotification)
        #expect(UserMessageClassifier.isRealUserMessage(line) == false)
    }

    // MARK: - text entry points
    //
    // A prompt queued while the agent was busy is recorded ONLY as a
    // `queued_command` attachment — it has no `type:"user"` line and no
    // `message` dict — so the classification rules must be reachable from the
    // raw text. The dictionary-shaped entry points above delegate to these, so
    // a queued prompt and a typed one can never be classified differently.

    @Test func text_and_line_entry_points_agree() {
        let bodies = [
            "plain typed prompt",
            "<cross-session-message from-name=\"acme-worker\">[note] done</cross-session-message>",
            "<task-notification>\n<task-id>abc</task-id>\n</task-notification>",
            "[SYSTEM NOTIFICATION - NOT USER INPUT]\nbackground event",
            "<command-name>commit</command-name>",
            "<system-reminder>x</system-reminder>",
            "<local-command-stdout>ok</local-command-stdout>",
            "<environment_details>cwd</environment_details>",
            "Base directory for this skill: /skills/pr",
            "# Git repository context\nbranch: main",
            "<unknown-tag>future injection</unknown-tag>",
            "<html>my page</html> please review",
            "<3 hearts to you",
        ]
        for body in bodies {
            let l = userLine(body)
            #expect(UserMessageClassifier.classify(text: body) == UserMessageClassifier.classify(l),
                    "classification diverged for: \(body)")
            #expect(UserMessageClassifier.isRealUserMessage(text: body)
                    == UserMessageClassifier.isRealUserMessage(l),
                    "real-message verdict diverged for: \(body)")
        }
    }

    @Test func text_classification_matches_the_documented_kinds() {
        #expect(UserMessageClassifier.classify(text: "just asking a question") == nil)
        #expect(UserMessageClassifier.isRealUserMessage(text: "just asking a question") == true)
        #expect(UserMessageClassifier.classify(text: "<task-notification>x</task-notification>") == .taskNotification)
        #expect(UserMessageClassifier.classify(text: "<command-name>pr</command-name>") == .slashEnvelope)
        #expect(UserMessageClassifier.classify(text: "<system-reminder>x</system-reminder>") == .toolReminder)
        #expect(UserMessageClassifier.isRealUserMessage(text: "<task-notification>x") == false)
    }

    // MARK: - compaction summary
    //
    // When Claude Code compacts a conversation it writes the summary into the
    // user role and marks the line `isCompactSummary`. The flag decides, never
    // the text: the summary's body is ordinary prose.

    private static let compactSummaryText = "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.\n\nSummary:\n1. Primary Request and Intent: refactor the acme widget loader."

    /// A user-role line shaped like Claude Code's compaction line. Pass `nil`
    /// for `isCompactSummary` to leave the key out entirely.
    private func compactLine(content: Any, isCompactSummary: Any? = true) -> [String: Any] {
        let message: [String: Any] = ["role": "user", "content": content]
        var line: [String: Any] = [
            "type": "user",
            "message": message,
            "isVisibleInTranscriptOnly": true,
        ]
        if let isCompactSummary { line["isCompactSummary"] = isCompactSummary }
        return line
    }

    @Test func compact_summary_line_is_compactSummary_and_not_a_real_message() {
        let line = compactLine(content: Self.compactSummaryText)
        #expect(UserMessageClassifier.classify(line) == .compactSummary)
        #expect(UserMessageClassifier.isRealUserMessage(line) == false)
    }

    @Test func compact_summary_with_text_block_content_is_compactSummary() {
        let blocks: [[String: Any]] = [["type": "text", "text": Self.compactSummaryText]]
        let line = compactLine(content: blocks)
        #expect(UserMessageClassifier.classify(line) == .compactSummary)
        #expect(UserMessageClassifier.isRealUserMessage(line) == false)
    }

    /// The other branch: the same text on a line without the flag is a prompt
    /// someone typed (or pasted), and stays one.
    @Test func the_same_text_without_the_flag_is_still_a_real_message() {
        // Absent, explicitly false, and JSON `null` (which real lines carry).
        let flags: [Any?] = [nil, false, NSNull()]
        for flag in flags {
            let line = compactLine(content: Self.compactSummaryText, isCompactSummary: flag)
            #expect(UserMessageClassifier.classify(line) == nil,
                    "isCompactSummary=\(String(describing: flag)) must not classify as a summary")
            #expect(UserMessageClassifier.isRealUserMessage(line) == true,
                    "isCompactSummary=\(String(describing: flag)) must stay a real message")
            #expect(UserMessageClassifier.extractText(line) == Self.compactSummaryText)
        }
    }

    /// The flag is checked before the text rules, so it wins even over text
    /// that one of them would otherwise claim.
    @Test func the_flag_wins_over_the_text_rules() {
        let line = compactLine(content: "<system-reminder>summary body</system-reminder>")
        #expect(UserMessageClassifier.classify(line) == .compactSummary)
    }

    /// The multi-text-block join is the same rule for a `type:"user"` content
    /// array and a queued prompt's content-block array.
    @Test func joinTextBlocks_joins_text_and_skips_everything_else() {
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "first"],
            ["type": "image", "source": ["type": "base64"]],
            ["type": "text", "text": "second"],
        ]
        #expect(UserMessageClassifier.joinTextBlocks(blocks) == "first\nsecond")
        #expect(UserMessageClassifier.joinTextBlocks([["type": "image"]]) == nil)
        #expect(UserMessageClassifier.joinTextBlocks([]) == nil)
    }

    @Test func untypedMarkers() {
        #expect(UserMessageClassifier.isUntypedPromptMarker("[Image: source: /tmp/a/1.png]"))
        #expect(UserMessageClassifier.isUntypedPromptMarker("[Image: source: /tmp/a/1.png]\n[Image: source: /tmp/a/2.png]"))
        #expect(UserMessageClassifier.isUntypedPromptMarker("[Request interrupted by user]"))
        #expect(UserMessageClassifier.isUntypedPromptMarker("[Request interrupted by user for tool use]"))
        #expect(UserMessageClassifier.isUntypedPromptMarker(
            "This session is being continued from a previous conversation that ran out of context. …"))
        #expect(UserMessageClassifier.isUntypedPromptMarker("  \n "))
    }

    @Test func typedPromptsThatMentionMarkers() {
        #expect(!UserMessageClassifier.isUntypedPromptMarker("why did I see [Request interrupted by user] there?"))
        #expect(!UserMessageClassifier.isUntypedPromptMarker("[Image #1] what is this?"))
        #expect(!UserMessageClassifier.isUntypedPromptMarker("look: [Image: source: /tmp/a/1.png] and fix it"))
        #expect(!UserMessageClassifier.isUntypedPromptMarker("/review 1174"))
    }
}
