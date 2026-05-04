import Foundation
import Testing
@testable import TBDApp

/// Tests for the `autoSuspendClaude` UserDefaults helper that the
/// daemon-reconnect path in `AppState.connectAndLoadInitialState()` reads to
/// build the `worktree.selectionChanged` RPC params. Regression coverage for
/// a bug where the reconnect path ignored the toggle and always sent
/// `suspendEnabled=true`, causing real Claude sessions to receive `/exit`.

@MainActor
@Suite("Auto-suspend Claude preference")
struct AutoSuspendPreferenceTests {
    private let key = AppState.autoSuspendClaudeKey

    private func withPreference(_ value: Bool?, _ body: () throws -> Void) rethrows {
        let prior = UserDefaults.standard.object(forKey: key)
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        defer {
            if let prior {
                UserDefaults.standard.set(prior, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try body()
    }

    @Test("returns true when toggle is on")
    func enabledWhenOn() throws {
        try withPreference(true) {
            #expect(AppState.autoSuspendClaudeEnabled == true)
        }
    }

    @Test("returns false when toggle is off — the regressed branch")
    func disabledWhenOff() throws {
        try withPreference(false) {
            #expect(AppState.autoSuspendClaudeEnabled == false)
        }
    }

    @Test("defaults to true when the user has never touched the toggle")
    func defaultsToTrueWhenUnset() throws {
        try withPreference(nil) {
            #expect(AppState.autoSuspendClaudeEnabled == true)
        }
    }
}
