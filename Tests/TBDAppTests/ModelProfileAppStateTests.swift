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
