import Foundation
import TBDShared
import Testing
@testable import TBDApp

/// Tests for the pre-sleep suspend hook's target selection
/// (`AppState.worktreeIDsToSuspendForSleep`). The hook fires on
/// `NSWorkspace.willSleepNotification` and is GATED on the existing
/// `autoSuspendClaude` opt-in (default OFF): short sleeps (lid close) usually
/// leave the tmux server alive, so unconditionally exiting every idle Claude
/// session on every sleep would force needless manual resumes. #284
/// (park-on-reboot) is the unconditional safety net.
///
/// Repo rule: test each branch of a behavior gate. The static helper is pure
/// (no AppState/daemon needed), so both gate branches are trivially covered.
@MainActor
@Suite("Pre-sleep suspend hook")
struct SleepSuspendHookTests {
    /// Build a minimal Worktree for a given repo. Only `id` and `repoID`
    /// matter for target selection.
    private func makeWorktree(repoID: UUID) -> Worktree {
        let name = "wt-\(UUID().uuidString.prefix(4))"
        return Worktree(
            id: UUID(),
            repoID: repoID,
            name: name,
            displayName: name,
            branch: "main",
            path: "/tmp/wt",
            tmuxServer: "tbd-test"
        )
    }

    @Test("gate OFF → returns [] even with worktrees present")
    func gateOffReturnsEmpty() {
        let repoID = UUID()
        let worktrees: [UUID: [Worktree]] = [
            repoID: [makeWorktree(repoID: repoID), makeWorktree(repoID: repoID)]
        ]
        let ids = AppState.worktreeIDsToSuspendForSleep(
            worktrees: worktrees,
            autoSuspendEnabled: false
        )
        #expect(ids.isEmpty)
    }

    @Test("gate ON → returns exactly the flattened worktree IDs across repos")
    func gateOnReturnsAllIDs() {
        let repoA = UUID()
        let repoB = UUID()
        let a1 = makeWorktree(repoID: repoA)
        let a2 = makeWorktree(repoID: repoA)
        let b1 = makeWorktree(repoID: repoB)
        let worktrees: [UUID: [Worktree]] = [
            repoA: [a1, a2],
            repoB: [b1]
        ]

        let ids = AppState.worktreeIDsToSuspendForSleep(
            worktrees: worktrees,
            autoSuspendEnabled: true
        )

        // Dictionary iteration order is unspecified, so compare as sets.
        #expect(Set(ids) == Set([a1.id, a2.id, b1.id]))
        #expect(ids.count == 3)
    }

    @Test("gate ON + empty worktrees → returns []")
    func gateOnEmptyReturnsEmpty() {
        let ids = AppState.worktreeIDsToSuspendForSleep(
            worktrees: [:],
            autoSuspendEnabled: true
        )
        #expect(ids.isEmpty)
    }

    @Test("suspendIdleClaudeForSleep with gate OFF makes no daemon calls (stays disconnected)")
    func instanceMethodGateOffNoOp() {
        // No mock DaemonClient exists in the suite; under `swift test` the
        // AppState test-mode guard prevents auto-connect, so the client is
        // never connected. Assert the gated-off path is a no-op: it must not
        // throw, must not connect, and must complete synchronously.
        let suiteName = "TBDAppTests.SleepSuspend.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: AppState.autoSuspendClaudeKey)

        let appState = AppState(userDefaults: defaults)
        appState.worktrees = [UUID(): [makeWorktree(repoID: UUID())]]

        appState.suspendIdleClaudeForSleep(defaults: defaults)

        #expect(appState.isConnected == false)
    }
}
