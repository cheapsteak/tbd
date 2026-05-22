import Testing
import Foundation
@testable import TBDApp
import TBDShared

@Suite("AppState.claudeEnvOverrides")
struct ClaudeEnvOverridesTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "ClaudeEnvOverridesTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("untouched settings produce no overrides")
    func emptyByDefault() {
        let d = freshDefaults()
        #expect(AppState.claudeEnvOverrides(defaults: d).isEmpty)
    }

    @Test("a value equal to the registry default produces no override")
    func defaultValueNotAnOverride() {
        let d = freshDefaults()
        d.set(true, forKey: AppState.claudeEnvKey("fullscreenRendering"))
        #expect(AppState.claudeEnvOverrides(defaults: d).isEmpty)
    }

    @Test("a value differing from the default is an override")
    func changedValueIsOverride() {
        let d = freshDefaults()
        d.set(false, forKey: AppState.claudeEnvKey("fullscreenRendering"))
        #expect(AppState.claudeEnvOverrides(defaults: d)["fullscreenRendering"] == .bool(false))
    }
}
