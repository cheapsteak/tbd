import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The Settings surface for the transcript-composer gate — the flag the whole
/// composer hangs off, and the only ordinary gesture that starts or ends its
/// soak.
///
/// Every test that constructs `AppState` does so against a unique throwaway
/// `UserDefaults` suite and tears it down — TBDApp ships as an unbundled SPM
/// executable, so `UserDefaults.standard` is the running developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("TranscriptComposerSettings")
struct TranscriptComposerSettingsTests {

    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-transcript-composer-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    @Test func setterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.transcriptComposerFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return DaemonCapabilitiesResult(
                    controlModeEnabled: false, transcriptComposerEnabled: true)
            }

            await state.setTranscriptComposerEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(state.daemonCapabilities?.transcriptComposerEnabled == true)
        }
    }

    /// The off branch is its own test rather than a second assertion, because
    /// turning the composer OFF is the operator's exit from the soak and a
    /// setter that ignored its argument would pass the on-only test.
    @Test func setterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.transcriptComposerFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                DaemonCapabilitiesResult(
                    controlModeEnabled: false, transcriptComposerEnabled: false)
            }

            await state.setTranscriptComposerEnabled(false)

            #expect(written == [false])
            #expect(state.daemonCapabilities?.transcriptComposerEnabled == false)
        }
    }

    /// A write the daemon refused must not be followed by a read-back, and must
    /// not leave the toggle showing a state nothing persisted.
    @Test func setterSurfacesAFailureAndLeavesCapabilitiesAlone() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.transcriptComposerFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setTranscriptComposerEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.daemonCapabilities == nil)
            #expect(state.alertMessage != nil)
        }
    }
}
