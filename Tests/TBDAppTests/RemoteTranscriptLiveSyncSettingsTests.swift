import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The Settings toggle for `remote_transcript_live_sync_enabled`: the setter writes
/// through the injected closure and reads the daemon back, and a failed write
/// is surfaced rather than followed by a refresh.
///
/// Every `AppState` here runs over its own throwaway `UserDefaults` suite —
/// `.standard` on this unbundled executable is the developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("Remote transcript live sync settings")
struct RemoteTranscriptLiveSyncSettingsTests {
    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-remote-transcript-live-sync-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    private static func capabilities(liveSync: Bool) -> DaemonCapabilitiesResult {
        var result = DaemonCapabilitiesResult(controlModeEnabled: false)
        result.remoteTranscriptLiveSyncEnabled = liveSync
        return result
    }

    @Test func setterPersistsOnAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.remoteTranscriptLiveSyncFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return Self.capabilities(liveSync: true)
            }

            await state.setRemoteTranscriptLiveSyncEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1, "the toggle must read the daemon back, not its own guess")
            #expect(state.daemonCapabilities?.remoteTranscriptLiveSyncEnabled == true)
        }
    }

    @Test func setterPersistsOffAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            state.remoteTranscriptLiveSyncFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                Self.capabilities(liveSync: false)
            }

            await state.setRemoteTranscriptLiveSyncEnabled(false)

            #expect(written == [false])
            #expect(state.daemonCapabilities?.remoteTranscriptLiveSyncEnabled == false)
        }
    }

    @Test func setterSurfacesAFailureAndLeavesCapabilitiesAlone() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.remoteTranscriptLiveSyncFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setRemoteTranscriptLiveSyncEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.daemonCapabilities == nil)
            #expect(state.alertMessage != nil)
        }
    }

    @Test("the toggle help names the hint requirement")
    func helpNamesTheHintRequirement() {
        #expect(GeneralSettingsTab.remoteTranscriptLiveSyncHelp.contains("transcript hint"))
    }

    @Test("a daemon that does not report the flag reads as off")
    func unreportedFlagReadsOff() throws {
        let decoded = try JSONDecoder().decode(
            DaemonCapabilitiesResult.self, from: Data(#"{"controlModeEnabled":false}"#.utf8))
        #expect(decoded.remoteTranscriptLiveSyncEnabled == false)
        #expect(Config.remoteTranscriptLiveSyncEnabledDefault == false, "the flag ships off while it soaks")
    }
}
