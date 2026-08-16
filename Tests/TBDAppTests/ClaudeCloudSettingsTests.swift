import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The Settings surface for the Claude cloud gate.
///
/// The caption is the whole reason the capability carries two booleans: the
/// daemon wires the built-in provider only at boot, so the persisted flag and
/// the live provider can disagree in BOTH directions, and a toggle that said
/// only "on" would be lying in the most confusing of the four states.
///
/// Every test that constructs `AppState` does so against a unique throwaway
/// `UserDefaults` suite and tears it down — TBDApp ships as an unbundled SPM
/// executable, so `UserDefaults.standard` is the running developer's real
/// `TBDApp.plist`.
@MainActor
@Suite("ClaudeCloudSettings")
struct ClaudeCloudSettingsTests {

    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-cloud-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    // MARK: - The caption, one case per branch

    @Test func captionOffAndNeverLive() {
        #expect(AppState.claudeCloudStatusCaption(enabled: false, live: false)
                == "Off. Turning this on requires a daemon restart before cloud sessions appear.")
    }

    @Test func captionOnButNotYetRestarted() {
        #expect(AppState.claudeCloudStatusCaption(enabled: true, live: false)
                == "On, but restart the daemon before cloud sessions appear.")
    }

    @Test func captionOnAndLive() {
        #expect(AppState.claudeCloudStatusCaption(enabled: true, live: true)
                == "On and running — cloud sessions are being polled.")
    }

    @Test func captionOffButStillLiveFromBeforeTheChange() {
        #expect(AppState.claudeCloudStatusCaption(enabled: false, live: true)
                == "Off, but the provider registered before this change is still live in the daemon — restart to fully stop it.")
    }

    // MARK: - The inner-gate predicate, both branches

    /// Cloud is a second gate INSIDE the remote-sessions switch, never a
    /// bypass, so the toggle is inert while the outer flag is off. A pure
    /// predicate rather than an inline `.disabled(...)` expression, so both
    /// branches are assertable.
    @Test func toggleIsOperableOnlyWhileRemoteSessionsAreEnabled() {
        #expect(AppState.claudeCloudToggleOperable(remoteBackendsEnabled: true))
        #expect(!AppState.claudeCloudToggleOperable(remoteBackendsEnabled: false))
    }

    // MARK: - The setter, both branches

    @Test func setterPersistsAndRefreshesCapabilities() async {
        await withAppState { state in
            var written: [Bool] = []
            var refreshes = 0
            state.claudeCloudFlagSetter = { @MainActor enabled in written.append(enabled) }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return DaemonCapabilitiesResult(controlModeEnabled: false, claudeCloudEnabled: true)
            }

            await state.setClaudeCloudEnabled(true)

            #expect(written == [true])
            #expect(refreshes == 1)
            #expect(state.daemonCapabilities?.claudeCloudEnabled == true)
        }
    }

    @Test func setterSurfacesAFailureAndLeavesCapabilitiesAlone() async {
        struct Boom: Error {}
        await withAppState { state in
            var refreshes = 0
            state.claudeCloudFlagSetter = { @MainActor _ in throw Boom() }
            state.daemonCapabilitiesFetcher = { @MainActor in
                refreshes += 1
                return nil
            }

            await state.setClaudeCloudEnabled(true)

            #expect(refreshes == 0, "a failed write must not be followed by a refresh")
            #expect(state.alertMessage != nil)
        }
    }
}
