import Testing
import Foundation
import TBDShared
@testable import TBDDaemonLib

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

    @Test func unknown_tag_prefix_returns_other() {
        let line = userLine("<diagnostics>some payload</diagnostics>")
        #expect(UserMessageClassifier.classify(line) == .other)
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
}
