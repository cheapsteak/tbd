import Foundation
import TestSupport
import Testing
@testable import TBDApp

/// Tests for the `enableTranscript` UserDefaults helper that gates the live
/// transcript pane. The pane is on by default; the toggle only exists so a
/// user can turn it off.
///
/// Isolation matters: TBDApp ships as an unbundled SPM executable, so its
/// `UserDefaults.standard` domain is `TBDApp.plist` in the developer's home
/// — the SAME domain a running production TBDApp reads via `@AppStorage`.
/// Every test below drives the helper through a per-test `UserDefaults(suiteName:)`
/// so `.standard` is never touched.

@MainActor
@Suite("Transcript feature flag preference")
struct TranscriptFeatureFlagTests {
    private let key = AppState.enableTranscriptKey

    /// Build an isolated UserDefaults domain, run the body with it, and tear
    /// the domain down afterwards so nothing persists across tests.
    private func withIsolatedDefaults(
        seed: Bool?,
        _ body: (UserDefaults) -> Void
    ) {
        let suite = TestDefaultsSuite("Transcript")
        defer { suite.tearDown() }
        let defaults = suite.defaults
        if let seed {
            defaults.set(seed, forKey: key)
        }
        body(defaults)
    }

    @Test("returns true when toggle is on")
    func enabledWhenOn() {
        withIsolatedDefaults(seed: true) { defaults in
            #expect(AppState.transcriptFeatureEnabled(defaults: defaults) == true)
        }
    }

    @Test("returns false when toggle is off — the gated-off branch")
    func disabledWhenOff() {
        withIsolatedDefaults(seed: false) { defaults in
            #expect(AppState.transcriptFeatureEnabled(defaults: defaults) == false)
        }
    }

    @Test("defaults to true when the user has never touched the toggle")
    func defaultsToTrueWhenUnset() {
        withIsolatedDefaults(seed: nil) { defaults in
            #expect(AppState.transcriptFeatureEnabled(defaults: defaults) == true)
        }
    }
}
