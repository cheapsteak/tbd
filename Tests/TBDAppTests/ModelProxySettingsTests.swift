import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The Settings surface for the two model-proxy gates — the proxy itself, and
/// the transcript streaming that reads what the proxy writes.
///
/// The pairing is the point: the daemon owns the coupling (streaming on turns
/// the proxy on; the proxy off turns streaming off), and the app's job is only
/// to send the gesture and read the daemon back. So every test here asserts the
/// app forwarded the toggled value and re-fetched capabilities — never that it
/// computed a coupled value of its own.
///
/// Every test that constructs `AppState` does so against a unique throwaway
/// `UserDefaults` suite and tears it down — TBDApp ships as an unbundled SPM
/// executable, so `UserDefaults.standard` is the running developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("ModelProxySettings")
struct ModelProxySettingsTests {

    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-model-proxy-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    // MARK: - Model proxy gate

    @Test func modelProxySetterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.modelProxyFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return DaemonCapabilitiesResult(
                    controlModeEnabled: false, modelProxyEnabled: true, modelProxySupported: true)
            }

            await state.setModelProxyEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(state.daemonCapabilities?.modelProxyEnabled == true)
        }
    }

    /// The off branch is its own test rather than a second assertion, because
    /// turning the proxy OFF is the operator's exit from the soak and a setter
    /// that ignored its argument would pass the on-only test.
    @Test func modelProxySetterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.modelProxyFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                DaemonCapabilitiesResult(
                    controlModeEnabled: false, modelProxyEnabled: false,
                    modelProxySupported: true, transcriptStreamingEnabled: false)
            }

            await state.setModelProxyEnabled(false)

            #expect(written == [false])
            #expect(state.daemonCapabilities?.modelProxyEnabled == false)
            #expect(
                state.daemonCapabilities?.transcriptStreamingEnabled == false,
                "the daemon's coupled write is what the read-back must show")
        }
    }

    /// A write the daemon refused must not be followed by a read-back, and must
    /// not leave the toggle showing a state nothing persisted.
    @Test func modelProxySetterSurfacesAFailureAndLeavesCapabilitiesAlone() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.modelProxyFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setModelProxyEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.daemonCapabilities == nil)
            #expect(state.alertMessage != nil)
        }
    }

    // MARK: - Transcript streaming gate

    @Test func streamingSetterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.transcriptStreamingFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return DaemonCapabilitiesResult(
                    controlModeEnabled: false, modelProxyEnabled: true,
                    modelProxySupported: true, transcriptStreamingEnabled: true)
            }

            await state.setTranscriptStreamingEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(state.daemonCapabilities?.transcriptStreamingEnabled == true)
        }
    }

    @Test func streamingSetterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.transcriptStreamingFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                DaemonCapabilitiesResult(
                    controlModeEnabled: false, modelProxyEnabled: true,
                    modelProxySupported: true, transcriptStreamingEnabled: false)
            }

            await state.setTranscriptStreamingEnabled(false)

            #expect(written == [false])
            #expect(state.daemonCapabilities?.transcriptStreamingEnabled == false)
            #expect(
                state.daemonCapabilities?.modelProxyEnabled == true,
                "turning streaming off leaves the proxy where the operator put it")
        }
    }

    /// The coupling lives in the daemon, so the app must send the gesture even
    /// when the proxy it depends on is currently off — an app that pre-empted
    /// the write would make "turn streaming on" a no-op on exactly the fleet
    /// that has never opted in.
    @Test func streamingSetterFiresEvenWhileTheProxyIsOff() async {
        await withAppState { state in
            var written: [Bool] = []
            state.modelProxyFlagSetter = { @MainActor _ in
                Issue.record("the streaming toggle must not write the proxy flag itself")
            }
            state.transcriptStreamingFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                // What the daemon reports after coupling the two columns.
                DaemonCapabilitiesResult(
                    controlModeEnabled: false, modelProxyEnabled: true,
                    modelProxySupported: true, transcriptStreamingEnabled: true)
            }
            // The starting point: nobody has ever turned the proxy on.
            state.daemonCapabilities = DaemonCapabilitiesResult(
                controlModeEnabled: false, modelProxyEnabled: false,
                modelProxySupported: true, transcriptStreamingEnabled: false)

            await state.setTranscriptStreamingEnabled(true)

            #expect(written == [true], "the app forwards the gesture regardless of the proxy state")
            #expect(state.daemonCapabilities?.modelProxyEnabled == true)
            #expect(state.daemonCapabilities?.transcriptStreamingEnabled == true)
        }
    }

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

    // MARK: - Help strings

    /// Both help strings carry a promise the operator acts on — that the change
    /// applies to sessions started after it, and (for streaming) that it turns
    /// the proxy on too. Pinned here so a rewrite that drops either has to be
    /// deliberate.
    @Test func helpStringsStateWhenTheChangeAppliesAndWhatItTurnsOn() {
        #expect(AppState.modelProxyHelp.contains("Applies to sessions started after you change it."))
        #expect(AppState.modelProxyHelp.contains("Off by default (soaking)."))
        #expect(
            AppState.transcriptStreamingHelp.contains(
                "Turning this on also turns on the model proxy."))
        #expect(
            AppState.transcriptStreamingHelp.contains(
                "Applies to sessions started after you change it."))
    }
}
