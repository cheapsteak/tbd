import Testing
import Foundation
@testable import TBDShared

@Suite("ClaudeSpawnPreferences")
struct ClaudeSpawnPreferencesTests {
    @Test("round-trips with overrides")
    func roundTrip() throws {
        let prefs = ClaudeSpawnPreferences(
            settingOverrides: ["fullscreenRendering": .bool(false)])
        let data = try JSONEncoder().encode(prefs)
        let back = try JSONDecoder().decode(ClaudeSpawnPreferences.self, from: data)
        #expect(back.settingOverrides?["fullscreenRendering"] == .bool(false))
    }

    @Test("decodes when settingOverrides field is absent")
    func decodesMissingField() throws {
        let data = Data("{}".utf8)
        let back = try JSONDecoder().decode(ClaudeSpawnPreferences.self, from: data)
        #expect(back.settingOverrides == nil)
    }

    @Test("method constant is stable")
    func methodConstant() {
        #expect(RPCMethod.claudeSetSpawnPreferences == "claude.setSpawnPreferences")
    }
}
