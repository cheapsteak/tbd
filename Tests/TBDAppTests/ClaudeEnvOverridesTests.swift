import Testing
import Foundation
@testable import TBDApp
import TBDShared
import TestSupport

@Suite("AppState.claudeEnvOverrides")
struct ClaudeEnvOverridesTests {
    @Test("untouched settings produce no overrides")
    func emptyByDefault() {
        withTestDefaults("ClaudeEnvOverridesTests") { d in
            #expect(AppState.claudeEnvOverrides(defaults: d).isEmpty)
        }
    }

    @Test("a value equal to the registry default produces no override")
    func defaultValueNotAnOverride() {
        withTestDefaults("ClaudeEnvOverridesTests") { d in
            d.set(true, forKey: AppState.claudeEnvKey("fullscreenRendering"))
            #expect(AppState.claudeEnvOverrides(defaults: d).isEmpty)
        }
    }

    @Test("a value differing from the default is an override")
    func changedValueIsOverride() {
        withTestDefaults("ClaudeEnvOverridesTests") { d in
            d.set(false, forKey: AppState.claudeEnvKey("fullscreenRendering"))
            #expect(AppState.claudeEnvOverrides(defaults: d)["fullscreenRendering"] == .bool(false))
        }
    }
}
