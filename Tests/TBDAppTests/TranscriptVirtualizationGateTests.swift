import Foundation
import Testing
@testable import TBDApp

/// Tests the virtualized-transcript gate (issue #129). The live-transcript pane
/// renders the AppKit `VirtualizedTranscriptList` instead of the production
/// `LazyVStack { ForEach }` when EITHER the `TBD_VIRT_TRANSCRIPT=1` env override
/// is set OR the user opts in via the Settings → Experimental toggle
/// (`AppState.useVirtualizedTranscriptKey`). Per CLAUDE.md "test each branch of
/// a gated conditional": assert the off-by-default branches AND the on branch,
/// for both inputs. The AppKit view itself is not exercised headlessly — only
/// the gate decision.
@MainActor
@Suite("Transcript virtualization gate")
struct TranscriptVirtualizationGateTests {

    // MARK: Env override branch

    @Test("env override off when TBD_VIRT_TRANSCRIPT is absent")
    func envOffWhenAbsent() {
        #expect(TranscriptItemsView.virtualizedTranscriptEnvOverride([:]) == false)
    }

    @Test("env override off when TBD_VIRT_TRANSCRIPT is empty")
    func envOffWhenEmpty() {
        #expect(TranscriptItemsView.virtualizedTranscriptEnvOverride(["TBD_VIRT_TRANSCRIPT": ""]) == false)
    }

    @Test("env override off when TBD_VIRT_TRANSCRIPT is a non-1 value")
    func envOffWhenNotOne() {
        #expect(TranscriptItemsView.virtualizedTranscriptEnvOverride(["TBD_VIRT_TRANSCRIPT": "0"]) == false)
        #expect(TranscriptItemsView.virtualizedTranscriptEnvOverride(["TBD_VIRT_TRANSCRIPT": "true"]) == false)
    }

    @Test("env override on when TBD_VIRT_TRANSCRIPT == 1")
    func envOnWhenOne() {
        #expect(TranscriptItemsView.virtualizedTranscriptEnvOverride(["TBD_VIRT_TRANSCRIPT": "1"]) == true)
    }

    // MARK: Settings (UserDefaults) branch
    //
    // Uses an injected `UserDefaults(suiteName:)` so the test never touches the
    // developer's real `TBDApp.plist` (`.standard`); torn down with
    // `removePersistentDomain(forName:)` per CLAUDE.md.

    @Test("setting defaults ON (true) when the toggle is untouched")
    func settingDefaultsTrueWhenUnset() {
        let suite = "TranscriptVirtualizationGateTests.unset"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppState.virtualizedTranscriptEnabled(defaults: defaults) == true)
    }

    @Test("setting true when the toggle is on")
    func settingTrueWhenSet() {
        let suite = "TranscriptVirtualizationGateTests.on"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: AppState.useVirtualizedTranscriptKey)
        #expect(AppState.virtualizedTranscriptEnabled(defaults: defaults) == true)
    }

    @Test("setting false when the toggle is explicitly off")
    func settingFalseWhenSetFalse() {
        let suite = "TranscriptVirtualizationGateTests.off"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: AppState.useVirtualizedTranscriptKey)
        #expect(AppState.virtualizedTranscriptEnabled(defaults: defaults) == false)
    }
}
