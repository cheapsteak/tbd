import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The Settings surface for the transcript-streaming gate. The app's job is
/// only to send the gesture and read the daemon back, so every test here
/// asserts the app forwarded the toggled value and re-fetched capabilities.
///
/// Every test that constructs `AppState` does so against a unique throwaway
/// `UserDefaults` suite and tears it down — TBDApp ships as an unbundled SPM
/// executable, so `UserDefaults.standard` is the running developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("TranscriptStreamingSettings")
struct TranscriptStreamingSettingsTests {

    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-transcript-streaming-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    @Test func streamingSetterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.transcriptStreamingFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return DaemonCapabilitiesResult(
                    controlModeEnabled: false, transcriptStreamingEnabled: true)
            }

            await state.setTranscriptStreamingEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(state.daemonCapabilities?.transcriptStreamingEnabled == true)
        }
    }

    /// The off branch is its own test rather than a second assertion: a setter
    /// that ignored its argument would pass the on-only test.
    @Test func streamingSetterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.transcriptStreamingFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                DaemonCapabilitiesResult(
                    controlModeEnabled: false, transcriptStreamingEnabled: false)
            }

            await state.setTranscriptStreamingEnabled(false)

            #expect(written == [false])
            #expect(state.daemonCapabilities?.transcriptStreamingEnabled == false)
        }
    }

    /// A write the daemon refused must not be followed by a read-back, and must
    /// not leave the toggle showing a state nothing persisted.
    @Test func streamingSetterSurfacesAFailureAndLeavesCapabilitiesAlone() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.transcriptStreamingFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setTranscriptStreamingEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.daemonCapabilities == nil)
            #expect(state.alertMessage != nil)
        }
    }

    /// The help string carries promises the operator acts on: the change
    /// applies to sessions started after it, and only where Claude Code loads
    /// TBD's mod. Pinned so a rewrite that drops either has to be deliberate.
    @Test func helpStringStatesWhenTheChangeAppliesAndWhatItNeeds() {
        #expect(
            AppState.transcriptStreamingHelp.contains(
                "Applies to sessions started after you turn it on, and only where Claude Code loads TBD's mod."))
        #expect(AppState.transcriptStreamingHelp.contains("Off by default (soaking)."))
    }
}
