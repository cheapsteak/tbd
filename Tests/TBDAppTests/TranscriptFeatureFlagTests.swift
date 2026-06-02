import Foundation
import Testing
@testable import TBDApp

/// Tests for the `enableTranscript` UserDefaults helper that gates the
/// experimental live transcript pane. The live transcript feature can freeze
/// the app UI on very large transcripts, so it is opt-in and fails closed.
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
        let suiteName = "TBDAppTests.Transcript.\(UUID().uuidString)"
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
            #expect(AppState.transcriptFeatureEnabled(defaults: defaults) == true)
        }
    }

    @Test("returns false when toggle is off — the gated-off branch")
    func disabledWhenOff() {
        withIsolatedDefaults(seed: false) { defaults in
            #expect(AppState.transcriptFeatureEnabled(defaults: defaults) == false)
        }
    }

    @Test("defaults to false when the user has never touched the toggle — fail-closed")
    func defaultsToFalseWhenUnset() {
        withIsolatedDefaults(seed: nil) { defaults in
            #expect(AppState.transcriptFeatureEnabled(defaults: defaults) == false)
        }
    }
}
