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

    // MARK: - The caption, one case per reachable (enabled, live, remoteBackendsEnabled) branch
    //
    // `config.setClaudeCloud` persists `enabled` unconditionally — it does not
    // check the outer remote-sessions flag — so `enabled` can be true while
    // `remoteBackendsEnabled` is false, and a caption that only looked at
    // (enabled, live) could describe that state as "on" when a restart right
    // now would not actually start cloud sessions. Every branch below is a
    // state genuinely reachable by toggling the two flags independently and
    // optionally restarting.

    @Test func captionOffNeverLiveRemoteAlsoOff() {
        #expect(AppState.claudeCloudStatusCaption(enabled: false, live: false, remoteBackendsEnabled: false)
                == "Off. Turning this on requires remote sessions above enabled and a daemon restart before cloud sessions appear.")
    }

    @Test func captionOffNeverLiveRemoteOn() {
        #expect(AppState.claudeCloudStatusCaption(enabled: false, live: false, remoteBackendsEnabled: true)
                == "Off. Turning this on requires a daemon restart before cloud sessions appear.")
    }

    @Test func captionOnButNotYetRestartedRemoteOn() {
        #expect(AppState.claudeCloudStatusCaption(enabled: true, live: false, remoteBackendsEnabled: true)
                == "On, but restart the daemon before cloud sessions appear.")
    }

    /// The brief's original two-argument signature would have said "On, but
    /// restart the daemon before cloud sessions appear" here too — implying a
    /// restart alone is sufficient. It is not: the outer flag also has to be
    /// turned on before a restart can make cloud live.
    @Test func captionOnButNotYetRestartedRemoteOff() {
        #expect(AppState.claudeCloudStatusCaption(enabled: true, live: false, remoteBackendsEnabled: false)
                == "On, but remote sessions above are off — enable both, then restart the daemon before cloud sessions appear.")
    }

    @Test func captionOnAndLiveRemoteOn() {
        #expect(AppState.claudeCloudStatusCaption(enabled: true, live: true, remoteBackendsEnabled: true)
                == "On and running — cloud sessions are being polled.")
    }

    /// The brief's original two-argument signature would have said "On and
    /// running" here too — reachable by enabling both, restarting, then
    /// turning the outer flag off again without restarting. The toggle greys
    /// out via `claudeCloudToggleOperable`, but the caption must not still
    /// claim cloud sessions are being polled: a restart right now would stop
    /// them.
    @Test func captionOnAndLiveRemoteOff() {
        #expect(AppState.claudeCloudStatusCaption(enabled: true, live: true, remoteBackendsEnabled: false)
                == "On, but remote sessions above are now off — restarting will stop cloud sessions unless you re-enable remote sessions above first.")
    }

    /// `(enabled: false, live: true)` is unaffected by the outer flag's
    /// current value: turning the cloud flag off already guarantees the next
    /// restart will not bring cloud back, regardless of `remoteBackendsEnabled`
    /// — so both values of the outer flag must produce the identical message.
    @Test func captionOffButStillLiveIsUnaffectedByRemoteFlag() {
        let withRemoteOn = AppState.claudeCloudStatusCaption(enabled: false, live: true, remoteBackendsEnabled: true)
        let withRemoteOff = AppState.claudeCloudStatusCaption(enabled: false, live: true, remoteBackendsEnabled: false)
        #expect(withRemoteOn == "Off, but the provider registered before this change is still live in the daemon — restart to fully stop it.")
        #expect(withRemoteOn == withRemoteOff)
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

    // MARK: - The scope caption, state-independent (Design §3)

    /// Design §3: sessions TBD did not start have no ledger row, so they are
    /// never listed, never adopted, and have no lane. The caption is what
    /// makes that absence read as a property of the feature.
    ///
    /// Asserted on the COMPOSED string rather than against a blacklist of
    /// forbidden words, so a rewording that drops the claim fails here.
    @Test func theScopeCaptionSaysOnlySessionsStartedInTBDAppear() {
        let caption = AppState.claudeCloudScopeCaption
        #expect(caption.lowercased().contains("started"))
        #expect(caption.lowercased().contains("claude.ai"))
        #expect(!caption.isEmpty)
    }

    /// It is state-independent, which is why it is its own value: the seven
    /// arms of `claudeCloudStatusCaption` stay byte-identical.
    @Test func theStatusCaptionArmsAreUnchangedByTheScopeCaption() {
        #expect(AppState.claudeCloudStatusCaption(
            enabled: true, live: true, remoteBackendsEnabled: true)
            == "On and running — cloud sessions are being polled.")
        #expect(!AppState.claudeCloudStatusCaption(
            enabled: true, live: true, remoteBackendsEnabled: true)
            .contains("claude.ai"))
    }
}
