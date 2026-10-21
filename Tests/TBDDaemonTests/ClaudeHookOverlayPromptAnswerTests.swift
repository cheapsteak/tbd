import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

// Nested under TBDHomeSerialized: `resolveOverlayPath` reads paths derived
// from the process-global `TBD_HOME`. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
/// The overlay carries no prompt-answer hooks: the session mod answers
/// prompts (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`,
/// "Removed").
@Suite struct ClaudeHookOverlayPromptAnswerTests {

    private func hooks(_ data: Data) throws -> [String: Any] {
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(parsed["hooks"] as? [String: Any])
    }

    private func entries(_ hooks: [String: Any], _ key: String) -> [[String: Any]] {
        hooks[key] as? [[String: Any]] ?? []
    }

    @Test func overlayHasNoPromptAnswerHooks() throws {
        let body = try ClaudeHookOverlay.generateBody()
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(!text.contains("PermissionRequest"))
        // Neither removed `tbd prompt` subcommand (note, wait) is invoked.
        #expect(!text.contains("tbd prompt "))

        let h = try hooks(body)
        #expect(h["PostToolUseFailure"] == nil)
        #expect(entries(h, "PreToolUse").map { $0["matcher"] as? String } == ["AskUserQuestion"])
        #expect(entries(h, "PostToolUse").map { $0["matcher"] as? String } == ["AskUserQuestion", "Bash"])
    }

    /// With nothing per-session to carry, a spawn shares the global overlay.
    @Test func plainSpawnKeepsTheSharedOverlay() {
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: UUID().uuidString)
        #expect(path == ClaudeHookOverlay.overlayPath)
    }
}
}
