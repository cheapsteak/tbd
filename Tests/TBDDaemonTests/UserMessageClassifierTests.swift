import Testing
import Foundation
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
