import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct ClaudeHookOverlayTests {

    @Test func generateBodyHasExpectedShape() throws {
        let data = try ClaudeHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        #expect(hooks != nil)
        // SessionStart entry registers `tbd session-event` with a `*` matcher.
        let sessionStart = hooks?["SessionStart"] as? [[String: Any]]
        let matcher0 = sessionStart?.first?["matcher"] as? String
        #expect(matcher0 == "*")
        let inner = sessionStart?.first?["hooks"] as? [[String: Any]]
        let cmd0 = inner?.first?["command"] as? String
        #expect(cmd0?.contains("tbd session-event") == true)

        // Stop entry registers `tbd notify` as the first matcher and
        // `tbd hooks stop-rename-check` as a sibling matcher.
        let stop = hooks?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 2)
        let stopHooks = stop?.first?["hooks"] as? [[String: Any]]
        let stopCmd = stopHooks?.first?["command"] as? String
        #expect(stopCmd?.contains("tbd notify") == true)
        let allStopCommands: [String] = (stop ?? []).flatMap { entry -> [String] in
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            return inner.compactMap { $0["command"] as? String }
        }
        #expect(allStopCommands.contains(where: { $0.contains("stop-rename-check") }))
    }

    @Test func registersStopFailureNotifyHook() throws {
        let data = try ClaudeHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]

        // StopFailure fires when a turn dies on an API error (rate limit,
        // server error, etc.). It must shell out to `tbd notify --type error`
        // so the dead thread surfaces instead of dying silently.
        let stopFailure = hooks?["StopFailure"] as? [[String: Any]]
        #expect(stopFailure?.count == 1)
        let inner = stopFailure?.first?["hooks"] as? [[String: Any]]
        let cmd = inner?.first?["command"] as? String
        #expect(cmd?.contains("tbd notify --type error") == true)
        // Surfaces the error_type so the message is actionable.
        #expect(cmd?.contains("error_type") == true)
    }

    @Test func roundtripsAsValidJSON() throws {
        let data = try ClaudeHookOverlay.generateBody()
        // Must round-trip — a malformed overlay file would crash Claude
        // Code's settings loader. JSONSerialization throws on invalid JSON.
        _ = try JSONSerialization.jsonObject(with: data, options: [])
    }
}
