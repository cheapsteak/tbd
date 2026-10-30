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
/// "Removed"). The absence of every prompt-answer event is pinned by the full
/// hook list in
/// `ClaudeHookOverlayTests.registersNotificationHookWithoutAMatcherAndLeavesTheOthersUntouched`.
@Suite struct ClaudeHookOverlayPromptAnswerTests {

    /// With nothing per-session to carry, a spawn shares the global overlay.
    @Test func plainSpawnKeepsTheSharedOverlay() {
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: UUID().uuidString)
        #expect(path == ClaudeHookOverlay.overlayPath)
    }
}
}
