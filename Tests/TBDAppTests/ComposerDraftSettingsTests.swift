import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// The Settings toggle for `composer_draft_enabled`: the setter writes
/// through the injected closure and reads the daemon back, and a failed write
/// is surfaced rather than followed by a refresh.
///
/// Every `AppState` here runs over its own throwaway `UserDefaults` suite —
/// `.standard` on this unbundled executable is the developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("Composer draft settings")
struct ComposerDraftSettingsTests {
    private func withAppState(_ body: (AppState) async -> Void) async {
        let suite = TestDefaultsSuite("tbd-composer-draft-settings")
        let defaults = suite.defaults
        await body(AppState(userDefaults: defaults))
        suite.tearDown()
    }

    private static func capabilities(composerDraft: Bool) -> DaemonCapabilitiesResult {
        var result = DaemonCapabilitiesResult(controlModeEnabled: false)
        result.composerDraftEnabled = composerDraft
        return result
    }

    @Test func setterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.composerDraftFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return Self.capabilities(composerDraft: true)
            }

            await state.setComposerDraftEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(state.daemonCapabilities?.composerDraftEnabled == true)
        }
    }

    @Test func setterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.composerDraftFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                Self.capabilities(composerDraft: false)
            }

            await state.setComposerDraftEnabled(false)

            #expect(written == [false])
            #expect(state.daemonCapabilities?.composerDraftEnabled == false)
        }
    }

    @Test func setterSurfacesAFailureAndLeavesCapabilitiesAlone() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.composerDraftFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setComposerDraftEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.daemonCapabilities == nil)
            #expect(state.alertMessage != nil)
        }
    }

    /// While automatic parking holds the feature on, the daemon reports it,
    /// and Settings greys the toggle with this caption. The flag follows the
    /// daemon, false until capabilities arrive.
    @Test func requiredByAutoParkFollowsCapabilities() async {
        await withAppState { state in
            #expect(state.composerDraftRequiredByAutoPark == false)
            var held = Self.capabilities(composerDraft: true)
            held.composerDraftRequiredByAutoPark = true
            state.daemonCapabilities = held
            #expect(state.composerDraftRequiredByAutoPark == true)
            #expect(state.composerDraftEnabled == true)
            state.daemonCapabilities = Self.capabilities(composerDraft: false)
            #expect(state.composerDraftRequiredByAutoPark == false)
        }
    }

    @Test func theCaptionSaysWhatHoldsTheToggle() {
        #expect(AppState.composerDraftRequiredByAutoParkCaption == "On while auto-hibernation is on")
    }

    @Test func computedFlagFollowsCapabilities() async {
        await withAppState { state in
            #expect(state.daemonCapabilities == nil)
            #expect(state.composerDraftEnabled == false)
            state.daemonCapabilities = Self.capabilities(composerDraft: true)
            #expect(state.composerDraftEnabled == true)
            state.daemonCapabilities = Self.capabilities(composerDraft: false)
            #expect(state.composerDraftEnabled == false)
        }
    }
}
