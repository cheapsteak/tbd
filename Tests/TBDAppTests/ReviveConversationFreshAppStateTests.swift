import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tier 1 state-action tests. The injected reviver replaces the external
/// daemon boundary; all selection, alert, and revive-state behavior remains
/// real AppState behavior.
@MainActor
@Suite("Fresh conversation revive AppState action")
struct ReviveConversationFreshAppStateTests {
    private struct TestError: LocalizedError {
        var errorDescription: String? { "fresh branch unavailable" }
    }

    private func withAppState(
        _ body: @MainActor (AppState, UserDefaults) async throws -> Void
    ) async rethrows {
        let suiteName = "TBDAppTests.ReviveConversationFresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(AppState(userDefaults: defaults), defaults)
    }

    private func makeWorktree(
        id: UUID = UUID(),
        repoID: UUID,
        status: WorktreeStatus
    ) -> Worktree {
        Worktree(
            id: id,
            repoID: repoID,
            name: "acme",
            displayName: "Acme",
            branch: "tbd/acme",
            path: "/tmp/acme",
            status: status,
            tmuxServer: "tbd-test"
        )
    }

    @Test("forwards dimensions and session while preserving revive state")
    func successWithWarningPreservesReviveStateAndNavigatesToFreshWorktree() async {
        await withAppState { state, defaults in
            let repoID = UUID()
            let archived = makeWorktree(repoID: repoID, status: .archived)
            let fresh = makeWorktree(repoID: repoID, status: .active)
            let sentinelID = UUID()
            let sentinel = ReviveState.done(snapshot: makeWorktree(repoID: repoID, status: .archived))
            let sessionID = "session-123"
            state.archivedWorktrees = [repoID: [archived]]
            state.worktrees = [repoID: [fresh]]
            state.revivingArchived = [sentinelID: sentinel]

            // Set the size while auto-resize is disabled so setup cannot arm
            // its daemon-bound debounce, then enable the pure size calculation.
            defaults.set(false, forKey: AppState.terminalAutoResizeKey)
            state.mainAreaSize = CGSize(width: 1200, height: 800)
            defaults.set(true, forKey: AppState.terminalAutoResizeKey)
            let expectedSize = state.mainAreaTerminalSize()
            var received: (UUID, String, Int?, Int?)?
            state.freshConversationReviver = { worktreeID, receivedSessionID, cols, rows in
                received = (worktreeID, receivedSessionID, cols, rows)
                return WorktreeReviveConversationFreshResult(
                    worktree: fresh,
                    warning: "Created from cached origin/main at def5678."
                )
            }

            await state.reviveConversationOnFreshBranch(worktreeID: archived.id, sessionId: sessionID)

            #expect(state.revivingArchived == [sentinelID: sentinel])
            #expect(state.selectedWorktreeIDs == [fresh.id])
            #expect(state.alertMessage == "Created from cached origin/main at def5678.")
            #expect(state.alertIsError == false)
            #expect(received?.0 == archived.id)
            #expect(received?.1 == sessionID)
            #expect(received?.2 == expectedSize.cols)
            #expect(received?.3 == expectedSize.rows)
        }
    }

    @Test("selects fresh worktree without showing an alert when there is no warning")
    func successWithoutWarningSelectsFreshWorktree() async {
        await withAppState { state, _ in
            let repoID = UUID()
            let archived = makeWorktree(repoID: repoID, status: .archived)
            let fresh = makeWorktree(repoID: repoID, status: .active)
            state.archivedWorktrees = [repoID: [archived]]
            state.worktrees = [repoID: [fresh]]
            state.freshConversationReviver = { _, _, _, _ in
                WorktreeReviveConversationFreshResult(worktree: fresh, warning: nil)
            }

            await state.reviveConversationOnFreshBranch(worktreeID: archived.id, sessionId: "session-456")

            #expect(state.selectedWorktreeIDs == [fresh.id])
            #expect(state.alertMessage == nil)
            #expect(state.alertIsError == false)
        }
    }

    @Test("shows an error without changing revive state when fresh revive fails")
    func failurePreservesReviveStateAndShowsError() async {
        await withAppState { state, _ in
            let repoID = UUID()
            let archived = makeWorktree(repoID: repoID, status: .archived)
            let sentinelID = UUID()
            let sentinel = ReviveState.inFlight(snapshot: makeWorktree(repoID: repoID, status: .archived))
            state.archivedWorktrees = [repoID: [archived]]
            state.revivingArchived = [sentinelID: sentinel]
            state.freshConversationReviver = { _, _, _, _ in throw TestError() }

            await state.reviveConversationOnFreshBranch(worktreeID: archived.id, sessionId: "session-789")

            #expect(state.revivingArchived == [sentinelID: sentinel])
            #expect(state.alertMessage == "Couldn't revive conversation on a fresh branch: fresh branch unavailable")
            #expect(state.alertIsError)
        }
    }
}
