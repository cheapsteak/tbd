import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite("claude.setSpawnPreferences data path")
struct ClaudeSpawnPreferencesHandlerTests {
    @Test("decoding params then persisting yields the override")
    func decodeAndPersist() async throws {
        let db = try TBDDatabase(inMemory: true)
        let prefs = ClaudeSpawnPreferences(
            settingOverrides: ["fullscreenRendering": .bool(false)])
        let data = try JSONEncoder().encode(prefs)

        let decoded = try JSONDecoder().decode(ClaudeSpawnPreferences.self, from: data)
        try await db.config.setEnvSettingOverrides(decoded.settingOverrides ?? [:])

        let cfg = try await db.config.get()
        #expect(cfg.envSettingOverrides["fullscreenRendering"] == .bool(false))
    }
}
