import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The shared `remoteTranscriptOpen` preference. Every test drives a fresh
/// `AppState` over its own `UserDefaults(suiteName:)` and removes that domain
/// afterwards: `.standard` on this unbundled executable is the developer's
/// real `TBDApp.plist`.
@MainActor
@Suite("Remote transcript open preference")
struct RemoteTranscriptOpenPreferenceTests {
    private let key = AppState.remoteTranscriptOpenKey

    private func withIsolatedDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "TBDAppTests.RemoteTranscriptOpen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    @Test("the key is the one the spec names")
    func keyMatchesSpec() {
        #expect(key == "remoteTranscriptOpen")
    }

    @Test("unset reads as open")
    func unsetReadsOpen() {
        withIsolatedDefaults { defaults in
            #expect(defaults.object(forKey: key) == nil)
            #expect(AppState(userDefaults: defaults).remoteTranscriptOpen == true)
        }
    }

    @Test("closing stores false, and a relaunch reads it back closed")
    func closedPersists() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            state.toggleRemoteTranscriptOpen()
            #expect(state.remoteTranscriptOpen == false)
            #expect(defaults.object(forKey: key) as? Bool == false)
            #expect(AppState(userDefaults: defaults).remoteTranscriptOpen == false)
        }
    }

    @Test("reopening stores an explicit true, and a relaunch reads it back open")
    func reopenedPersists() {
        withIsolatedDefaults { defaults in
            defaults.set(false, forKey: key)
            let state = AppState(userDefaults: defaults)
            #expect(state.remoteTranscriptOpen == false)
            state.toggleRemoteTranscriptOpen()
            #expect(state.remoteTranscriptOpen == true)
            #expect(defaults.object(forKey: key) as? Bool == true)
            #expect(AppState(userDefaults: defaults).remoteTranscriptOpen == true)
        }
    }

    @Test("the toggle and pane follow the provider's transcript.read alone")
    func transcriptFollowsTheProviderCapability() {
        withIsolatedDefaults { defaults in
            let state = AppState(userDefaults: defaults)
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            state.remoteProviders = [RemoteProviderStatus(
                config: RemoteProviderConfig(name: "acme", exec: "/nonexistent"),
                describe: ProviderDescribe(
                    contractVersions: [1], name: "acme",
                    capabilities: [RemoteCapability.transcriptRead]),
                health: .ok, errorMessage: nil,
                remediationLabel: nil, remediationCommand: nil)]

            // No daemon capabilities fetched: nothing on the daemon side gates it.
            #expect(state.daemonCapabilities == nil)
            #expect(state.remoteSessionShowsTranscriptToggle(selection) == true)
            #expect(state.remoteSessionShowsTranscriptPane(selection) == true)

            state.remoteProviders = [RemoteProviderStatus(
                config: RemoteProviderConfig(name: "acme", exec: "/nonexistent"),
                describe: ProviderDescribe(
                    contractVersions: [1], name: "acme", capabilities: ["attach"]),
                health: .ok, errorMessage: nil,
                remediationLabel: nil, remediationCommand: nil)]
            #expect(state.remoteSessionShowsTranscriptToggle(selection) == false)
            #expect(state.remoteSessionShowsTranscriptPane(selection) == false)
        }
    }
}
