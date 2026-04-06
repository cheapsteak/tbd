import Foundation
import Testing
@testable import TBDApp
import TBDShared

// DaemonClient is a concrete actor (no protocol), so we can't inject a stub.
// These tests verify pure-Swift state mutations on AppState — full integration
// coverage lives in the daemon RPC tests (Phase 05/06/07) and manual QA per
// the parent plan's DoD.

@MainActor
@Test func appState_initialClaudeTokensEmpty() {
    let state = AppState()
    #expect(state.claudeTokens.isEmpty)
    #expect(state.globalDefaultClaudeTokenID == nil)
}

@MainActor
@Test func appState_handlesUsageUpdatedDeltaInPlace() {
    let state = AppState()
    let tokenID = UUID()
    let token = ClaudeToken(id: tokenID, name: "test", kind: .oauth)
    state.claudeTokens = [ClaudeTokenWithUsage(token: token, usage: nil)]

    let usage = ClaudeTokenUsage(tokenID: tokenID, fiveHourPct: 0.42)
    state.handleDelta(.claudeTokenUsageUpdated(usage))

    #expect(state.claudeTokens.count == 1)
    #expect(state.claudeTokens[0].usage?.fiveHourPct == 0.42)
}

@MainActor
@Test func appState_handlesTokensChangedDeltaWithoutCrash() {
    let state = AppState()
    // No daemon running — the spawned refresh task will fail and be swallowed.
    state.handleDelta(.claudeTokensChanged)
    #expect(true)
}
