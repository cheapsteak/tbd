import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// `AppState.remoteTranscriptEnabled` is read from `daemon.capabilities`, the
/// same route `transcriptComposerEnabled` takes. Each test uses a throwaway
/// `UserDefaults` suite, because `UserDefaults.standard` on this unbundled
/// executable is the developer's real `TBDApp.plist`.
@MainActor
@Suite("RemoteTranscriptFlagApp")
struct RemoteTranscriptFlagAppTests {

    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-remote-transcript-flag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    @Test func offUntilCapabilitiesArrive() async {
        await withAppState { state in
            #expect(state.daemonCapabilities == nil)
            #expect(state.remoteTranscriptEnabled == Config.remoteTranscriptEnabledDefault)
            #expect(state.remoteTranscriptEnabled == false)
        }
    }

    @Test func followsTheDaemonOn() async {
        await withAppState { state in
            var caps = DaemonCapabilitiesResult(controlModeEnabled: false)
            caps.remoteTranscriptEnabled = true
            state.daemonCapabilities = caps
            #expect(state.remoteTranscriptEnabled)
        }
    }

    @Test func followsTheDaemonOff() async {
        await withAppState { state in
            var caps = DaemonCapabilitiesResult(controlModeEnabled: false)
            caps.remoteTranscriptEnabled = false
            state.daemonCapabilities = caps
            #expect(state.remoteTranscriptEnabled == false)
        }
    }

    /// The remote flag does not imply the composer flag: the remote composer
    /// needs both, so each is read on its own.
    @Test func doesNotImplyTheComposerFlag() async {
        await withAppState { state in
            var caps = DaemonCapabilitiesResult(controlModeEnabled: false)
            caps.remoteTranscriptEnabled = true
            state.daemonCapabilities = caps
            #expect(state.remoteTranscriptEnabled)
            #expect(state.transcriptComposerEnabled == false)
        }
    }
}
