import Foundation
import Testing
@testable import TBDApp

/// Tests for the `nightwatchExperimentalEnabled` UserDefaults helper that gates
/// the experimental Nightwatch / Daywatch feature. The sidebar mode control is
/// hidden unless this opt-in is on, so the gate must fail closed.
///
/// Isolation matters: TBDApp ships as an unbundled SPM executable, so its
/// `UserDefaults.standard` domain is the developer's live `TBDApp.plist`. Each
/// test drives the helper through a per-test `UserDefaults(suiteName:)` so
/// `.standard` is never touched (see AutoSuspendPreferenceTests for the full
/// rationale).
@MainActor
@Suite("Nightwatch experimental gate")
struct NightwatchExperimentalGateTests {
    private let key = AppState.nightwatchExperimentalKey

    private func withIsolatedDefaults(
        seed: Bool?,
        _ body: (UserDefaults) -> Void
    ) {
        let suiteName = "TBDAppTests.NightwatchExperimental.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        if let seed {
            defaults.set(seed, forKey: key)
        }
        body(defaults)
    }

    @Test("enabled when the opt-in toggle is on")
    func enabledWhenOn() {
        withIsolatedDefaults(seed: true) { defaults in
            #expect(AppState.nightwatchExperimentalEnabled(defaults: defaults) == true)
        }
    }

    @Test("disabled when the toggle is explicitly off")
    func disabledWhenOff() {
        withIsolatedDefaults(seed: false) { defaults in
            #expect(AppState.nightwatchExperimentalEnabled(defaults: defaults) == false)
        }
    }

    @Test("defaults to false when never set — fail-closed, control stays hidden")
    func defaultsToFalseWhenUnset() {
        withIsolatedDefaults(seed: nil) { defaults in
            #expect(AppState.nightwatchExperimentalEnabled(defaults: defaults) == false)
        }
    }
}
