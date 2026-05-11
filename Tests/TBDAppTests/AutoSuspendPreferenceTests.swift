import Foundation
import Testing
@testable import TBDApp

/// Tests for the `autoSuspendClaude` UserDefaults helper that the
/// daemon-reconnect path in `AppState.connectAndLoadInitialState()` reads to
/// build the `worktree.selectionChanged` RPC params. Regression coverage for
/// a bug where the reconnect path ignored the toggle and always sent
/// `suspendEnabled=true`, causing real Claude sessions to receive `/exit`.
///
/// Isolation matters: TBDApp ships as an unbundled SPM executable, so its
/// `UserDefaults.standard` domain is `TBDApp.plist` in the developer's home
/// — the SAME domain a running production TBDApp reads via `@AppStorage`.
/// An earlier version of these tests mutated `.standard`, which clobbered the
/// live app's preferences mid-test and triggered a real Claude `/exit`. Every
/// test below now drives the helper through a per-test `UserDefaults(suiteName:)`
/// so `.standard` is never touched.

@MainActor
@Suite("Auto-suspend Claude preference")
struct AutoSuspendPreferenceTests {
    private let key = AppState.autoSuspendClaudeKey

    /// Build an isolated UserDefaults domain, run the body with it, and tear
    /// the domain down afterwards so nothing persists across tests.
    private func withIsolatedDefaults(
        seed: Bool?,
        _ body: (UserDefaults) -> Void
    ) {
        let suiteName = "TBDAppTests.AutoSuspend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        if let seed {
            defaults.set(seed, forKey: key)
        }
        body(defaults)
    }

    @Test("returns true when toggle is on")
    func enabledWhenOn() {
        withIsolatedDefaults(seed: true) { defaults in
            #expect(AppState.autoSuspendClaudeEnabled(defaults: defaults) == true)
        }
    }

    @Test("returns false when toggle is off — the regressed branch")
    func disabledWhenOff() {
        withIsolatedDefaults(seed: false) { defaults in
            #expect(AppState.autoSuspendClaudeEnabled(defaults: defaults) == false)
        }
    }

    @Test("defaults to true when the user has never touched the toggle")
    func defaultsToTrueWhenUnset() {
        withIsolatedDefaults(seed: nil) { defaults in
            #expect(AppState.autoSuspendClaudeEnabled(defaults: defaults) == true)
        }
    }
}
