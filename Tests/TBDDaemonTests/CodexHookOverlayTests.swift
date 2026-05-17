import Foundation
import Testing
@testable import TBDDaemonLib

@Suite struct CodexHookOverlayTests {

    @Test func generateBodyHasExpectedShape() throws {
        let data = try CodexHookOverlay.generateBody()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        #expect(hooks != nil)

        let sessionStart = hooks?["SessionStart"] as? [[String: Any]]
        #expect(sessionStart?.first?["matcher"] as? String == "startup|resume|clear")
        let sessionHooks = sessionStart?.first?["hooks"] as? [[String: Any]]
        let sessionCommand = sessionHooks?.first?["command"] as? String
        #expect(sessionCommand?.contains("tbd session-event") == true)

        let stop = hooks?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 1)
        let stopHooks = stop?.first?["hooks"] as? [[String: Any]]
        let stopCommand = stopHooks?.first?["command"] as? String
        #expect(stopCommand?.contains("tbd notify --type response_complete") == true)
        #expect(stopCommand?.contains("last_assistant_message") == true)
    }

    @Test func roundtripsAsValidJSON() throws {
        let data = try CodexHookOverlay.generateBody()
        _ = try JSONSerialization.jsonObject(with: data, options: [])
    }

    @Test func writeOverlayCreatesHooksJSONInCodexHome() throws {
        let codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-codex-hooks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codexHome) }

        #expect(CodexHookOverlay.writeOverlay(in: codexHome))

        let path = codexHome.appendingPathComponent("hooks.json")
        let data = try Data(contentsOf: path)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = parsed?["hooks"] as? [String: Any]
        #expect(hooks?["SessionStart"] != nil)
        #expect(hooks?["Stop"] != nil)
    }
}
