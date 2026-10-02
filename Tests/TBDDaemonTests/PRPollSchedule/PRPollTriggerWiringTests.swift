import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// The PR schedule's triggers, driven through the real RPC handlers: hook
/// events stamp the activity ledger, `pr.refresh` records a selection, a
/// `pr.attach` that binds a new PR kicks the scheduler. Triggers only move due
/// times or wake the loop — none of them may call `gh` on its own.
@Suite("PRPollTriggerWiring", .serialized)
struct PRPollTriggerWiringTests {
    @Test func aHookEventStampsTheLedger() async throws {
        let h = try await TriggerHarness.make()
        #expect(await h.router.activityLedger.snapshot().hooks[h.terminalID] == nil)
        try await h.sendTerminalActivity(state: .idle)
        #expect(await h.router.activityLedger.snapshot().hooks[h.terminalID] != nil)
    }

    /// The other branch of the `origin == nil` guard: an app-originated
    /// interrupt is a user action, not agent activity.
    @Test func aUserInterruptDoesNotStampTheLedger() async throws {
        let h = try await TriggerHarness.make()
        try await h.sendTerminalActivity(state: .idle, origin: .userInterrupt)
        #expect(await h.router.activityLedger.snapshot().hooks[h.terminalID] == nil)
    }

    @Test func anAskUserQuestionHookStampsTheLedger() async throws {
        let h = try await TriggerHarness.make()
        let response = await h.router.handle(try RPCRequest(
            method: RPCMethod.terminalAskUserQuestionPending,
            params: TerminalAskUserQuestionPendingParams(
                terminalID: h.terminalID, toolUseID: "toolu_1", inputJSON: "{}",
                timestampMillis: 0)))
        #expect(response.success)
        #expect(await h.router.activityLedger.snapshot().hooks[h.terminalID] != nil)
    }

    @Test func prRefreshMarksTheWorktreeSelected() async throws {
        let h = try await TriggerHarness.make()
        #expect(await h.router.activityLedger.snapshot().selections[h.worktreeID] == nil)
        try await h.sendPRRefresh()
        #expect(await h.router.activityLedger.snapshot().selections[h.worktreeID] != nil)
    }

    @Test func aBoundAttachKicksTheScheduler() async throws {
        let h = try await TriggerHarness.make()
        let kicks = KickCounter()
        await h.router.prPollScheduler.setKickProbeForTests { await kicks.bump() }
        let outcome = try await h.sendPRAttach(url: "https://github.com/acme/acme-prod/pull/12")
        #expect(outcome == "bound")
        #expect(await kicks.count == 1)
    }

    /// Only a new binding kicks: attaching the same PR again binds nothing.
    @Test func anAlreadyBoundAttachDoesNotKick() async throws {
        let h = try await TriggerHarness.make()
        let url = "https://github.com/acme/acme-prod/pull/12"
        _ = try await h.sendPRAttach(url: url)
        let kicks = KickCounter()
        await h.router.prPollScheduler.setKickProbeForTests { await kicks.bump() }
        let outcome = try await h.sendPRAttach(url: url)
        #expect(outcome == "alreadyBound")
        #expect(await kicks.count == 0)
    }

    /// The closure `Daemon` installs on the ledger: the first hook after a
    /// quiet window kicks the scheduler, and a second hook inside the window
    /// does not.
    @Test func aPossibleActivationKicksOncePerWindow() async throws {
        let h = try await TriggerHarness.make()
        let kicks = KickCounter()
        await h.router.prPollScheduler.setKickProbeForTests { await kicks.bump() }
        let router = h.router
        await router.activityLedger.setOnPossibleActivation { [weak router] _ in
            await router?.prPollScheduler.kick()
        }
        try await h.sendTerminalActivity(state: .working)
        #expect(await kicks.count == 1)
        try await h.sendTerminalActivity(state: .idle)
        #expect(await kicks.count == 1)
    }

    @Test func flagOffTheLegacyPollerIsUnaffectedByTriggers() async throws {
        let h = try await TriggerHarness.make()
        try await h.sendTerminalActivity(state: .working)
        _ = try await h.sendPRAttach(url: "https://github.com/acme/acme-prod/pull/12")
        let before = await h.gh.allQueries().count
        try await h.sendTerminalActivity(state: .idle)
        #expect(await h.router.prPollScheduler.isRunning == false)
        // A trigger alone never calls gh.
        #expect(await h.gh.allQueries().count == before)
    }
}

private actor KickCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// One worktree in `acme/acme-prod` with one terminal, on the legs harness's
/// router and fake `gh`. No worktree starts with a selection stamp, so every
/// ledger entry a test sees was written by the handler it drove.
private struct TriggerHarness {
    let legs: PRPollLegsHarness
    let terminalID: UUID

    var router: RPCRouter { legs.router }
    var gh: PRPollLegsGH { legs.gh }
    var worktreeID: UUID { legs.worktreeID(0) }

    static func make() async throws -> TriggerHarness {
        let legs = try await PRPollLegsHarness.make(
            bindings: [], responses: [:], worktreeCount: 1, activeWorktrees: [])
        let terminal = try await legs.db.terminals.create(
            worktreeID: legs.worktreeID(0), tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "Codex", kind: .codex)
        return TriggerHarness(legs: legs, terminalID: terminal.id)
    }

    func sendTerminalActivity(state: TerminalActivityState,
                              origin: TerminalActivityEventOrigin? = nil) async throws {
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminalID, activityState: state, origin: origin)))
        #expect(response.success)
    }

    func sendPRRefresh() async throws {
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.prRefresh, params: PRRefreshParams(worktreeID: worktreeID)))
        #expect(response.success)
    }

    func sendPRAttach(url: String) async throws -> String {
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.prAttach,
            params: PRBindingRefParams(worktreeID: worktreeID, url: url, number: nil,
                                       source: nil)))
        return try response.decodeResult(PRAttachResult.self).outcome
    }
}
