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
    #expect(state.claudeTokens.isEmpty)
    #expect(state.globalDefaultClaudeTokenID == nil)
}

@MainActor
@Test func appState_handlesUsageUpdatedDeltaInPlace() {
    let state = AppState()
    let profileID = UUID()
    let profile = ModelProfile(id: profileID, name: "test", kind: .oauth)
    state.claudeTokens = [ModelProfileWithUsage(profile: profile, usage: nil)]

    let usage = ModelProfileUsage(profileID: profileID, fiveHourPct: 0.42)
    state.handleDelta(.modelProfileUsageUpdated(usage))

    #expect(state.claudeTokens.count == 1)
    #expect(state.claudeTokens[0].usage?.fiveHourPct == 0.42)
}

@MainActor
@Test func appState_handlesProfilesChangedDeltaWithoutCrash() {
    let state = AppState()
    // No daemon running — the spawned refresh task will fail and be swallowed.
    state.handleDelta(.modelProfilesChanged)
    #expect(true)
}
