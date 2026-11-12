import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Tier 1. What the app says when a create on a chosen Claude profile fails.
///
/// The daemon refuses a chosen profile that is missing or has no credentials,
/// before it creates anything. The tab bar's `+` menu lists every profile,
/// signed out or not, so without an alert that click would do nothing at all.
@MainActor
@Suite("Explicit profile failure alert")
struct ExplicitProfileFailureAlertTests {

    private static let refusal = DaemonClientError.rpcError(
        "Model profile acme-work is not logged in.", code: nil)

    // MARK: - A Claude tab

    @Test func aRefusedProfileTabSaysWhy() throws {
        let message = try #require(AppState.claudeTerminalFailureAlert(
            Self.refusal, profileID: UUID(), loginSession: false))
        #expect(message.hasPrefix("Couldn't open a Claude tab:"))
        #expect(message.contains("acme-work is not logged in"))
    }

    @Test func aTabWithoutAChosenProfileStaysQuiet() {
        let message = AppState.claudeTerminalFailureAlert(
            Self.refusal, profileID: nil, loginSession: false)
        #expect(message == nil)
    }

    @Test func aLostConnectionStaysQuiet() {
        let message = AppState.claudeTerminalFailureAlert(
            DaemonClientError.daemonNotRunning, profileID: UUID(), loginSession: false)
        #expect(message == nil)
    }

    /// Unchanged: a login tab says why it failed, whatever the error.
    @Test func aLoginTabAlwaysSaysWhy() {
        let message = AppState.claudeTerminalFailureAlert(
            DaemonClientError.daemonNotRunning, profileID: UUID(), loginSession: true)
        #expect(message == "Failed to open login session: TBD daemon is not running")
    }

    // MARK: - A worktree

    private func withAppState(_ body: (AppState) async throws -> Void) async rethrows {
        let suite = TestDefaultsSuite("TBDAppTests.ExplicitProfileFailureAlert")
        defer { suite.tearDown() }
        try await body(AppState(userDefaults: suite.defaults))
    }

    /// Creates a worktree whose create RPC throws `error`, and waits until the
    /// creation task has removed its placeholder. The alert, if any, is set in
    /// the same main-actor turn, so it is in place by then.
    private func failCreate(
        _ state: AppState, error: DaemonClientError, profileID: UUID?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let repoID = UUID()
        state.worktreeCreator = { @MainActor _ in throw error }
        state.createWorktree(repoID: repoID, profileID: profileID)
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { state.worktrees[repoID]?.isEmpty == true }
        }
        guard outcome == .timedOut else { return }
        Issue.record(
            BoundedWaitTimeout(
                what: "the failed create's placeholder to go",
                observed: "\(state.worktrees[repoID]?.count ?? 0) row(s)",
                deadline: TestDeadlines.saturatedPass),
            sourceLocation: sourceLocation)
    }

    @Test func aRefusedWorktreeOnAChosenProfileSaysWhy() async {
        await withAppState { state in
            await failCreate(state, error: Self.refusal, profileID: UUID())
            #expect(state.alertMessage?.hasPrefix("Couldn't create worktree:") == true)
            #expect(state.alertMessage?.contains("acme-work is not logged in") == true)
            #expect(state.alertIsError)
        }
    }

    @Test func aFailedWorktreeWithoutAChosenProfileStaysQuiet() async {
        await withAppState { state in
            await failCreate(state, error: Self.refusal, profileID: nil)
            #expect(state.alertMessage == nil)
        }
    }

    @Test func aLostConnectionOnAChosenProfileStaysQuiet() async {
        await withAppState { state in
            await failCreate(state, error: .daemonNotRunning, profileID: UUID())
            #expect(state.alertMessage == nil)
        }
    }
}
