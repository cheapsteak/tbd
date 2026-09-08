import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// `AppState.transcriptStreamingEnabled` — the single place the app asks
/// whether a transcript pane should tail a model-proxy stream file at all.
///
/// Every test constructs `AppState` against a unique throwaway `UserDefaults`
/// suite and tears it down: TBDApp ships as an unbundled SPM executable, so
/// `UserDefaults.standard` is the running developer's real `TBDApp.plist`.
@MainActor
@Suite("TranscriptStreamingFlag")
struct TranscriptStreamingFlagTests {

    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-transcript-streaming-flag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    /// The app is launched by `open`, which drops shell env, so capabilities
    /// are nil until the first RPC lands. Reading that as "off" is what keeps a
    /// provisional row from appearing and then vanishing a moment later.
    @Test("capabilities that have not arrived read as off")
    func nilCapabilitiesReadAsOff() async {
        await withAppState { state in
            #expect(state.daemonCapabilities == nil)
            #expect(state.transcriptStreamingEnabled == false)
        }
    }

    @Test("the daemon reporting streaming on turns it on")
    func capabilityOnEnables() async {
        await withAppState { state in
            state.daemonCapabilities = DaemonCapabilitiesResult(
                controlModeEnabled: false, transcriptStreamingEnabled: true)

            #expect(state.transcriptStreamingEnabled)
        }
    }

    /// The off branch is its own assertion rather than an inference from the
    /// nil case: a property that ignored the field entirely and always returned
    /// false would pass the nil test too.
    @Test("the daemon reporting streaming off keeps it off")
    func capabilityOffDisables() async {
        await withAppState { state in
            state.daemonCapabilities = DaemonCapabilitiesResult(
                controlModeEnabled: false, transcriptStreamingEnabled: false)

            #expect(state.transcriptStreamingEnabled == false)
        }
    }
}
