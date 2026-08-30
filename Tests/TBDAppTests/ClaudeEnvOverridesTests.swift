import Testing
import Foundation
import TestSupport
@testable import TBDApp
import TBDShared

@Suite("AppState.claudeEnvOverrides")
struct ClaudeEnvOverridesTests {
    private func freshSuite() -> TestDefaultsSuite {
        TestDefaultsSuite("ClaudeEnvOverrides")
    }

    @Test("untouched settings produce no overrides")
    func emptyByDefault() {
        let suite = freshSuite()
        defer { suite.tearDown() }
        let d = suite.defaults
        #expect(AppState.claudeEnvOverrides(defaults: d).isEmpty)
    }

    @Test("a value equal to the registry default produces no override")
    func defaultValueNotAnOverride() {
        let suite = freshSuite()
        defer { suite.tearDown() }
        let d = suite.defaults
        d.set(true, forKey: AppState.claudeEnvKey("fullscreenRendering"))
        #expect(AppState.claudeEnvOverrides(defaults: d).isEmpty)
    }

    @Test("a value differing from the default is an override")
    func changedValueIsOverride() {
        let suite = freshSuite()
        defer { suite.tearDown() }
        let d = suite.defaults
        d.set(false, forKey: AppState.claudeEnvKey("fullscreenRendering"))
        #expect(AppState.claudeEnvOverrides(defaults: d)["fullscreenRendering"] == .bool(false))
    }
}
