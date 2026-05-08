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

        // Stop entry registers `tbd notify`.
        let stop = hooks?["Stop"] as? [[String: Any]]
        let stopHooks = stop?.first?["hooks"] as? [[String: Any]]
        let stopCmd = stopHooks?.first?["command"] as? String
        #expect(stopCmd?.contains("tbd notify") == true)
    }

    @Test func roundtripsAsValidJSON() throws {
        let data = try ClaudeHookOverlay.generateBody()
        // Must round-trip — a malformed overlay file would crash Claude
        // Code's settings loader. JSONSerialization throws on invalid JSON.
        _ = try JSONSerialization.jsonObject(with: data, options: [])
    }
}
