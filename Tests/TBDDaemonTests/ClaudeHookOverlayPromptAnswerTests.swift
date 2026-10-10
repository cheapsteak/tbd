import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

// Nested under TBDHomeSerialized: the per-session overlay tests mutate the
// process-global `TBD_HOME` env var. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite struct ClaudeHookOverlayPromptAnswerTests {

    private func hooks(_ data: Data) throws -> [String: Any] {
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(parsed["hooks"] as? [String: Any])
    }

    private func entries(_ hooks: [String: Any], _ key: String) -> [[String: Any]] {
        hooks[key] as? [[String: Any]] ?? []
    }

    private func command(_ entry: [String: Any]) -> String? {
        (entry["hooks"] as? [[String: Any]])?.first?["command"] as? String
    }

    @Test func flagOffBodyIsUnchanged() throws {
        let plain = try ClaudeHookOverlay.generateBody()
        let off = try ClaudeHookOverlay.generateBody(promptAnswerHooks: false)
        #expect(plain == off)
        let h = try hooks(off)
        #expect(h["PermissionRequest"] == nil)
        #expect(h["PostToolUseFailure"] == nil)
        #expect(entries(h, "PreToolUse").count == 1)
        #expect(entries(h, "PostToolUse").count == 2)
    }

    @Test func flagOnAddsNoteAndWaitHooks() throws {
        let h = try hooks(try ClaudeHookOverlay.generateBody(promptAnswerHooks: true))

        let wait = entries(h, "PermissionRequest")
        #expect(wait.count == 1)
        #expect(wait[0]["matcher"] == nil)
        #expect(command(wait[0]) == ClaudeHookOverlay.promptWaitCommand)
        let waitHook = (wait[0]["hooks"] as? [[String: Any]])?.first
        #expect(waitHook?["timeout"] as? Int == 86400)

        let pre = entries(h, "PreToolUse")
        #expect(pre.count == 2)
        #expect(pre[0]["matcher"] as? String == "AskUserQuestion")
        #expect(pre[1]["matcher"] == nil)
        #expect(command(pre[1]) == "tbd prompt note --phase pre 2>/dev/null || true")
        #expect(((pre[1]["hooks"] as? [[String: Any]])?.first?["timeout"]) as? Int == 3)

        let post = entries(h, "PostToolUse")
        #expect(post.count == 3)
        #expect(post[0]["matcher"] as? String == "AskUserQuestion")
        #expect(post[1]["matcher"] as? String == "Bash")
        #expect(post[2]["matcher"] == nil)
        #expect(command(post[2]) == "tbd prompt note --phase post 2>/dev/null || true")
        #expect(((post[2]["hooks"] as? [[String: Any]])?.first?["timeout"]) as? Int == 3)

        let failure = entries(h, "PostToolUseFailure")
        #expect(failure.count == 1)
        #expect(failure[0]["matcher"] == nil)
        #expect(command(failure[0]) == "tbd prompt note --phase post 2>/dev/null || true")
    }

    @Test func flagOnLeavesEveryOtherHookUntouched() throws {
        let off = try hooks(try ClaudeHookOverlay.generateBody())
        let on = try hooks(try ClaudeHookOverlay.generateBody(promptAnswerHooks: true))
        for key in ["SessionStart", "Stop", "StopFailure", "SessionEnd", "UserPromptSubmit", "Notification"] {
            #expect(
                NSDictionary(dictionary: [key: off[key] as Any])
                    .isEqual(to: [key: on[key] as Any]),
                "\(key) must be identical with the flag on")
        }
    }

    @Test func flagOnForcesAPerSessionOverlay() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-overlay-test-\(UUID().uuidString)")
        let prior = setTBDHome(tmp.path)
        defer {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: tmp)
        }
        let key = UUID().uuidString
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: key, promptAnswerHooks: true)
        #expect(path == ClaudeHookOverlay.perSessionOverlayPath(sessionKey: key))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(try hooks(data)["PermissionRequest"] != nil)
    }

    @Test func flagOffKeepsTheSharedOverlay() {
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: UUID().uuidString, promptAnswerHooks: false)
        #expect(path == ClaudeHookOverlay.overlayPath)
    }
}
}
