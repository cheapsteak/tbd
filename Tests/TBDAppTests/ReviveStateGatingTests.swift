import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Revive completion gating around the blocking `preSession` hook:
/// `beginReviveWorktree` returns promptly with the row still `.creating`
/// while the hook runs, so the archived view's `.done` ("Revived") state
/// must wait until the worktree is actually usable. `settleReviveState`
/// gates the immediate flip; `promoteRevivedWorktrees` performs the
/// deferred flip when the periodic refresh observes the row `.active`.
@MainActor
@Suite("Revive state gating")
struct ReviveStateGatingTests {

    /// Build an isolated AppState (never `UserDefaults.standard` — that's the
    /// developer's real TBDApp.plist) and tear the suite down afterward.
    private func withAppState(_ body: (AppState) throws -> Void) rethrows {
        let suiteName = "ReviveStateGatingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(AppState(userDefaults: defaults))
    }

    private func makeWorktree(id: UUID = UUID(), status: WorktreeStatus) -> Worktree {
        Worktree(
            id: id, repoID: UUID(), name: "acme", displayName: "acme",
            branch: "tbd/acme", path: "/tmp/acme", status: status,
            tmuxServer: "tbd-test"
        )
    }

    // MARK: - settleReviveState (immediate flip on RPC return)

    @Test func settleMarksDoneWhenRevivedWorktreeIsAlreadyUsable() {
        withAppState { state in
            let id = UUID()
            let snapshot = makeWorktree(id: id, status: .archived)
            state.revivingArchived[id] = .inFlight(snapshot: snapshot)

            // No blocking preSession hook: the RPC returns the row `.active`.
            state.settleReviveState(id: id, snapshot: snapshot, revived: makeWorktree(id: id, status: .active))

            #expect(state.revivingArchived[id] == .done(snapshot: snapshot))
        }
    }

    @Test func settleKeepsInFlightWhileHookStillRunning() {
        withAppState { state in
            let id = UUID()
            let snapshot = makeWorktree(id: id, status: .archived)
            state.revivingArchived[id] = .inFlight(snapshot: snapshot)

            // Blocking preSession hook: the RPC returns the row `.creating`.
            state.settleReviveState(id: id, snapshot: snapshot, revived: makeWorktree(id: id, status: .creating))

            #expect(state.revivingArchived[id] == .inFlight(snapshot: snapshot))
        }
    }

    // MARK: - promoteRevivedWorktrees (deferred flip via the refresh path)

    @Test func inFlightRevivePromotesToDoneWhenRefreshObservesActiveRow() {
        withAppState { state in
            let id = UUID()
            let snapshot = makeWorktree(id: id, status: .archived)
            state.revivingArchived[id] = .inFlight(snapshot: snapshot)
            // RPC returned `.creating` (hook running) — stays in flight.
            state.settleReviveState(id: id, snapshot: snapshot, revived: makeWorktree(id: id, status: .creating))
            #expect(state.revivingArchived[id] == .inFlight(snapshot: snapshot))

            // Later poll observes the hook finished and the row flipped `.active`.
            state.promoteRevivedWorktrees(observing: [makeWorktree(id: id, status: .active)])

            #expect(state.revivingArchived[id] == .done(snapshot: snapshot))
        }
    }

    @Test func creatingObservationDoesNotPromote() {
        withAppState { state in
            let id = UUID()
            let snapshot = makeWorktree(id: id, status: .archived)
            state.revivingArchived[id] = .inFlight(snapshot: snapshot)

            // Hook still running: the poll sees the row `.creating`.
            state.promoteRevivedWorktrees(observing: [makeWorktree(id: id, status: .creating)])

            #expect(state.revivingArchived[id] == .inFlight(snapshot: snapshot))
        }
    }

    @Test func promotionIgnoresUnrelatedWorktreesAndSettledEntries() {
        withAppState { state in
            let inFlightID = UUID()
            let doneID = UUID()
            let inFlightSnapshot = makeWorktree(id: inFlightID, status: .archived)
            let doneSnapshot = makeWorktree(id: doneID, status: .archived)
            state.revivingArchived[inFlightID] = .inFlight(snapshot: inFlightSnapshot)
            state.revivingArchived[doneID] = .done(snapshot: doneSnapshot)

            // A poll that doesn't contain the in-flight row leaves it alone,
            // and already-done entries are never rewritten.
            state.promoteRevivedWorktrees(observing: [makeWorktree(status: .active)])

            #expect(state.revivingArchived[inFlightID] == .inFlight(snapshot: inFlightSnapshot))
            #expect(state.revivingArchived[doneID] == .done(snapshot: doneSnapshot))
        }
    }
}
