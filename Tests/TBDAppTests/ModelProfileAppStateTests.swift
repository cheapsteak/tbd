import Foundation
import Testing
@testable import TBDApp
import TBDShared

// DaemonClient is a concrete actor (no protocol), so we can't inject a stub.
// These tests verify pure-Swift state mutations on AppState — full integration
// coverage lives in the daemon RPC tests (Phase 05/06/07) and manual QA per
// the parent plan's DoD.

@MainActor
@Test func appState_initialModelProfilesEmpty() {
    let state = AppState()
    #expect(state.modelProfiles.isEmpty)
    #expect(state.defaultProfileID == nil)
    #expect(state.primaryAgentPreference == .claude)
}

@MainActor
@Test func appState_handlesUsageUpdatedDeltaInPlace() {
    let state = AppState()
    let profileID = UUID()
    let profile = ModelProfile(id: profileID, name: "test", kind: .oauth)
    state.modelProfiles = [ModelProfileWithUsage(profile: profile, usage: nil)]

    let usage = ModelProfileUsage(profileID: profileID, fiveHourPct: 0.42)
    state.handleDelta(.modelProfileUsageUpdated(usage))

    #expect(state.modelProfiles.count == 1)
    #expect(state.modelProfiles[0].usage?.fiveHourPct == 0.42)
}

@MainActor
@Test func appState_handlesProfilesChangedDeltaWithoutCrash() {
    let state = AppState()
    // No daemon running — the spawned refresh task will fail and be swallowed.
    state.handleDelta(.modelProfilesChanged)
    #expect(true)
}

// R7-minor: the daemon broadcasts `.modelProfilesChanged` when ANY client
// toggles control mode (handleConfigSetControlMode reuses that channel), so
// the delta handler must refresh `daemonCapabilities` too — otherwise a
// SECOND connected client keeps stale capabilities until its own reconnect.
// DaemonClient is concrete, so the refetch goes through the injectable
// `daemonCapabilitiesFetcher` seam (production default hits the daemon).
@MainActor
@Test func appState_profilesChangedDeltaRefreshesDaemonCapabilities() async {
    let state = AppState()
    state.daemonCapabilitiesFetcher = {
        DaemonCapabilitiesResult(
            controlModeEnabled: true, tmuxVersion: "3.6a", controlModeSupported: true)
    }
    #expect(state.daemonCapabilities == nil)

    state.handleDelta(.modelProfilesChanged)

    // The handler refreshes in a spawned task — poll (60s CI-safe bound).
    var refreshed = false
    for _ in 0..<1200 {
        if state.daemonCapabilities?.controlModeEnabled == true { refreshed = true; break }
        try? await Task.sleep(for: .milliseconds(50))
    }
    #expect(refreshed, ".modelProfilesChanged must refresh daemonCapabilities on non-toggling clients")
}

@MainActor
@Test func appState_capabilitiesRefreshFailureKeepsLastKnownValue() async {
    // Best-effort semantics: `.modelProfilesChanged` fires for many config
    // changes; a transient RPC failure during the refetch must not nil out
    // good capabilities (which would silently flip new panes off control mode).
    let state = AppState()
    state.daemonCapabilities = DaemonCapabilitiesResult(
        controlModeEnabled: true, tmuxVersion: "3.6a", controlModeSupported: true)
    state.daemonCapabilitiesFetcher = { nil }

    state.handleDelta(.modelProfilesChanged)

    // Bounded negative check: give the refresh task ample time to (wrongly)
    // clobber the value.
    try? await Task.sleep(for: .milliseconds(500))
    #expect(state.daemonCapabilities?.controlModeEnabled == true,
            "a failed capabilities refetch must keep the last known value")
}

@MainActor
@Test func appState_dismissedProxyWarningsStartsEmptyAndAcceptsInsertions() {
    // The banner dismissal logic in TerminalPanelView writes to this set so a
    // dismissed banner stays dismissed across view reconstructions (tab
    // switches, parent re-renders). The contract is just that AppState
    // exposes a published Set<UUID> that round-trips terminal IDs.
    let state = AppState()
    #expect(state.dismissedProxyWarnings.isEmpty)

    let terminalA = UUID()
    let terminalB = UUID()
    state.dismissedProxyWarnings.insert(terminalA)
    #expect(state.dismissedProxyWarnings.contains(terminalA))
    #expect(!state.dismissedProxyWarnings.contains(terminalB))

    // Idempotent — a second dismissal is a no-op.
    state.dismissedProxyWarnings.insert(terminalA)
    #expect(state.dismissedProxyWarnings.count == 1)
}
