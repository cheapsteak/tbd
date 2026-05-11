import Testing
import Foundation
@testable import TBDDaemonLib

@Suite struct ClaudeHookOverlayAskUserQuestionTests {
    private func decode(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(obj)
    }

    @Test func preToolUseAskUserQuestionEntryIsPresent() throws {
        let data = try ClaudeHookOverlay.generateBody()
        let obj = try decode(data)
        let hooks = try #require(obj["hooks"] as? [String: Any])
        let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 1)
        #expect(pre[0]["matcher"] as? String == "AskUserQuestion")
        let commands = try #require(pre[0]["hooks"] as? [[String: Any]])
        #expect(commands.count == 1)
        #expect(commands[0]["type"] as? String == "command")
        let cmd = try #require(commands[0]["command"] as? String)
        #expect(cmd.contains("tbd ask-user-question pre"), "got: \(cmd)")
    }

    @Test func postToolUseAskUserQuestionEntryIsPresent() throws {
        let data = try ClaudeHookOverlay.generateBody()
        let obj = try decode(data)
        let hooks = try #require(obj["hooks"] as? [String: Any])
        let post = try #require(hooks["PostToolUse"] as? [[String: Any]])
        #expect(post.count == 1)
        #expect(post[0]["matcher"] as? String == "AskUserQuestion")
        let commands = try #require(post[0]["hooks"] as? [[String: Any]])
        let cmd = try #require(commands[0]["command"] as? String)
        #expect(cmd.contains("tbd ask-user-question post"), "got: \(cmd)")
    }

    @Test func existingSessionStartAndStopHooksUnchanged() throws {
        let data = try ClaudeHookOverlay.generateBody()
        let obj = try decode(data)
        let hooks = try #require(obj["hooks"] as? [String: Any])
        #expect(hooks["SessionStart"] != nil, "SessionStart hook regressed")
        #expect(hooks["Stop"] != nil, "Stop hook regressed")
    }
}
