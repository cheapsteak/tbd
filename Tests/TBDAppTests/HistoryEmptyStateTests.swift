import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// Tests for `HistoryLoadState.emptyTabsContent` — the decision that drives
/// what a worktree's main area shows when it has no open tabs. Loading states
/// and any worktree with at least one past session show history; an empty load
/// result or a failed fetch falls back to the "No terminals" placeholder.
@Suite("History empty-state decision")
struct HistoryEmptyStateTests {

    private func session(_ id: String) -> SessionSummary {
        SessionSummary(
            sessionId: id,
            filePath: "/tmp/\(id).jsonl",
            modifiedAt: Date(),
            fileSize: 100,
            lineCount: 10,
            firstUserMessage: "Hello",
            lastUserMessage: "Goodbye",
            cwd: "/tmp",
            gitBranch: "main"
        )
    }

    @Test("idle shows history (avoids placeholder flash before first fetch)")
    func idleShowsHistory() {
        #expect(HistoryLoadState.idle.emptyTabsContent == .history)
    }

    @Test("loading shows history")
    func loadingShowsHistory() {
        #expect(HistoryLoadState.loading.emptyTabsContent == .history)
    }

    @Test("loadingStale shows history")
    func loadingStaleShowsHistory() {
        #expect(HistoryLoadState.loadingStale([session("a")]).emptyTabsContent == .history)
    }

    @Test("loaded with sessions shows history")
    func loadedWithSessionsShowsHistory() {
        #expect(HistoryLoadState.loaded([session("a")]).emptyTabsContent == .history)
    }

    @Test("loaded with no sessions shows placeholder")
    func loadedEmptyShowsPlaceholder() {
        #expect(HistoryLoadState.loaded([]).emptyTabsContent == .placeholder)
    }

    @Test("failed shows placeholder")
    func failedShowsPlaceholder() {
        #expect(HistoryLoadState.failed("boom").emptyTabsContent == .placeholder)
    }

    // MARK: - shouldPopulateHistoryForEmptyTabs

    private func makeWorktree(status: WorktreeStatus) -> Worktree {
        Worktree(
            repoID: UUID(),
            name: "test",
            displayName: "Test",
            branch: "main",
            path: "/tmp/test",
            status: status,
            tmuxServer: "test-server"
        )
    }

    @Test("main worktree does not populate history for empty tabs")
    func mainWorktreeSkipsHistoryFetch() {
        let worktree = makeWorktree(status: .main)
        #expect(AppState.shouldPopulateHistoryForEmptyTabs(worktree: worktree) == false)
    }

    @Test("non-main worktree populates history for empty tabs")
    func nonMainWorktreeFetchesHistory() {
        for status in [WorktreeStatus.active, .archived, .creating, .failed] {
            let worktree = makeWorktree(status: status)
            #expect(AppState.shouldPopulateHistoryForEmptyTabs(worktree: worktree) == true)
        }
    }
}
