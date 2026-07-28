import XCTest
@testable import TBDApp
import TBDShared

final class ArchiveTombstoneTests: XCTestCase {
    let testRepoID = UUID()

    // MARK: - Fixtures

    func makeWorktree(
        id: UUID,
        repoID: UUID? = nil,
        status: WorktreeStatus = .active,
        displayName: String? = nil
    ) -> Worktree {
        let shortID = id.uuidString.prefix(8)
        Worktree(
            id: id,
            repoID: repoID ?? self.testRepoID,
            name: "test-\(shortID)",
            displayName: displayName ?? "Test \(shortID)",
            branch: "main",
            path: "/tmp/test",
            status: status,
            tmuxServer: "test-server"
        )
    }

    // MARK: - AC1.1: visibleWorktrees excludes tombstoned IDs

    func testVisibleWorktreesExcludesTombstonedWorktree() {
        let wtID = UUID()
        let activeWt = makeWorktree(id: wtID)

        let visible = AppState.visibleWorktrees(
            from: [activeWt],
            tombstones: [wtID]
        )

        XCTAssertTrue(visible.isEmpty, "Tombstoned worktree should be excluded")
    }

    // MARK: - AC2.3: Non-tombstoned worktrees are never excluded

    func testVisibleWorktreesIncludesNonTombstonedWorktree() {
        let wtID = UUID()
        let activeWt = makeWorktree(id: wtID)

        let visible = AppState.visibleWorktrees(
            from: [activeWt],
            tombstones: []
        )

        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].id, wtID)
    }

    // MARK: - Archived worktrees are always excluded

    func testVisibleWorktreesExcludesArchivedWorktree() {
        let wtID = UUID()
        let archivedWt = makeWorktree(id: wtID, status: .archived)

        let visible = AppState.visibleWorktrees(
            from: [archivedWt],
            tombstones: []
        )

        XCTAssertTrue(visible.isEmpty, "Archived worktree should always be excluded")
    }

    // MARK: - AC1.2: Tombstone kept while daemon shows .active and fresh

    func testReconcileTombstonesKeepsFreshTombstone() {
        let wtID = UUID()
        let now = Date()
        let activeWt = makeWorktree(id: wtID, status: .active)

        let reconciled = AppState.reconcileTombstones(
            [wtID: now],
            daemonWorktrees: [activeWt],
            now: now
        )

        XCTAssertEqual(reconciled[wtID], now, "Fresh tombstone should be kept")
    }

    // MARK: - AC2.1: Tombstone evicted when daemon shows .archived

    func testReconcileTombstonesEvictsTombstoneWhenArchived() {
        let wtID = UUID()
        let now = Date()
        let archivedWt = makeWorktree(id: wtID, status: .archived)

        let reconciled = AppState.reconcileTombstones(
            [wtID: now],
            daemonWorktrees: [archivedWt],
            now: now
        )

        XCTAssertNil(reconciled[wtID], "Tombstone should be evicted when daemon shows archived")
    }

    // MARK: - AC2.1: Tombstone evicted when worktree absent from daemon

    func testReconcileTombstonesEvictsTombstoneWhenAbsent() {
        let wtID = UUID()
        let now = Date()

        let reconciled = AppState.reconcileTombstones(
            [wtID: now],
            daemonWorktrees: [],
            now: now
        )

        XCTAssertNil(reconciled[wtID], "Tombstone should be evicted when worktree absent")
    }

    // MARK: - AC2.2: Tombstone evicted when older than TTL

    func testReconcileTombstonesEvictsTombstoneOlderThanTTL() {
        let wtID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1000)
        let now = createdAt.addingTimeInterval(31) // Past 30-second TTL
        let activeWt = makeWorktree(id: wtID, status: .active)

        let reconciled = AppState.reconcileTombstones(
            [wtID: createdAt],
            daemonWorktrees: [activeWt],
            now: now,
            ttl: 30
        )

        XCTAssertNil(reconciled[wtID], "Tombstone older than TTL should be evicted")
    }

    // MARK: - TTL boundary: just before expiry

    func testReconcileTombstonesKeepsTombstoneJustBeforeTTLExpiry() {
        let wtID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1000)
        let now = createdAt.addingTimeInterval(29.9) // Just before 30-second TTL
        let activeWt = makeWorktree(id: wtID, status: .active)

        let reconciled = AppState.reconcileTombstones(
            [wtID: createdAt],
            daemonWorktrees: [activeWt],
            now: now,
            ttl: 30
        )

        XCTAssertEqual(reconciled[wtID], createdAt, "Tombstone just before TTL should be kept")
    }

    // MARK: - Multiple tombstones: mixed states

    func testReconcileTombstonesMixed() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let now = Date()
        let oldDate = now.addingTimeInterval(-31)

        let wt1 = makeWorktree(id: id1, status: .active)
        let wt2 = makeWorktree(id: id2, status: .archived)
        // id3 is absent

        let reconciled = AppState.reconcileTombstones(
            [id1: now, id2: now, id3: oldDate],
            daemonWorktrees: [wt1, wt2],
            now: now,
            ttl: 30
        )

        XCTAssertNotNil(reconciled[id1], "Fresh tombstone for active worktree should be kept")
        XCTAssertNil(reconciled[id2], "Tombstone for archived worktree should be evicted")
        XCTAssertNil(reconciled[id3], "Old tombstone should be evicted by TTL")
    }


    // MARK: - AC3.1: handleDelta(.worktreeArchived) removes row and tombstones

    @MainActor
    func testHandleDeltaWorktreeArchivedRemovesRowAndTombstones() {
        let suite = "test-\(UUID().uuidString)"
        let state = AppState(userDefaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let wtID = UUID()
        let wt = makeWorktree(id: wtID)
        state.worktrees = [testRepoID: [wt]]

        // Apply the delta
        state.handleDelta(.worktreeArchived(WorktreeIDDelta(worktreeID: wtID)))

        // Assert the worktree is removed
        XCTAssertNil(
            state.worktrees[testRepoID]?.first(where: { $0.id == wtID }),
            "Worktree should be removed from state"
        )

        // Assert the tombstone is created
        XCTAssertNotNil(
            state.recentlyArchivedWorktreeIDs[wtID],
            "Worktree ID should be tombstoned"
        )
    }

    // MARK: - External revive clears the tombstone

    @MainActor
    func testHandleDeltaWorktreeRevivedClearsTombstone() {
        let suite = "test-\(UUID().uuidString)"
        let state = AppState(userDefaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let wtID = UUID()

        // Seed a tombstone
        state.recentlyArchivedWorktreeIDs[wtID] = Date()

        // Verify the tombstone exists
        XCTAssertNotNil(state.recentlyArchivedWorktreeIDs[wtID])

        // Simulate an external revive via delta
        let reviveWt = makeWorktree(id: wtID)
        let delta = WorktreeDelta(
            worktreeID: reviveWt.id,
            repoID: reviveWt.repoID,
            name: reviveWt.name,
            path: reviveWt.path,
            status: reviveWt.status
        )
        state.handleDelta(.worktreeRevived(delta))

        // Assert the tombstone is cleared
        XCTAssertNil(
            state.recentlyArchivedWorktreeIDs[wtID],
            "Tombstone should be cleared on external revive delta"
        )
    }

    // MARK: - AC4.1: Clearing tombstone makes worktree visible again

    func testClearingTombstoneRestoresVisibility() {
        let wtID = UUID()
        let activeWt = makeWorktree(id: wtID)
        var tombstones: [UUID: Date] = [wtID: Date()]

        // Before clearing: worktree should be hidden
        var visible = AppState.visibleWorktrees(
            from: [activeWt],
            tombstones: Set(tombstones.keys)
        )
        XCTAssertTrue(visible.isEmpty, "Tombstoned worktree should be hidden")

        // Clear the tombstone
        tombstones.removeValue(forKey: wtID)

        // After clearing: worktree should be visible again
        visible = AppState.visibleWorktrees(
            from: [activeWt],
            tombstones: Set(tombstones.keys)
        )
        XCTAssertEqual(visible.count, 1, "Cleared tombstone should restore visibility")
        XCTAssertEqual(visible[0].id, wtID)
    }

    // MARK: - Failed creation alert: .creating worktree archived

    /// Test pure static helper: .creating worktree produces failure message
    func testCreationFailureMessageForCreatingWorktree() {
        let wtID = UUID()
        let creatingWt = makeWorktree(id: wtID, status: .creating, displayName: "MyNewWorktree")

        let message = AppState.creationFailureMessageIfCreating(creatingWt)

        XCTAssertNotNil(message, "Message should be produced for .creating worktree")
        XCTAssertTrue(message?.contains("Couldn't create worktree") ?? false)
        XCTAssertTrue(message?.contains("MyNewWorktree") ?? false)
    }

    /// Test pure static helper: .active worktree does not produce message
    func testCreationFailureMessageForActiveWorktree() {
        let wtID = UUID()
        let activeWt = makeWorktree(id: wtID, status: .active)

        let message = AppState.creationFailureMessageIfCreating(activeWt)

        XCTAssertNil(message, "No message should be produced for .active worktree")
    }

    /// Test pure static helper: nil worktree does not produce message
    func testCreationFailureMessageForNilWorktree() {
        let message = AppState.creationFailureMessageIfCreating(nil)

        XCTAssertNil(message, "No message should be produced for nil worktree")
    }

    @MainActor
    func testArchivingCreatingWorktreeShowsErrorAlert() {
        let suite = "test-\(UUID().uuidString)"
        let state = AppState(userDefaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let wtID = UUID()
        let creatingWt = makeWorktree(id: wtID, status: .creating, displayName: "MyNewWorktree")
        state.worktrees = [testRepoID: [creatingWt]]

        // Alert should not be set initially
        XCTAssertNil(state.alertMessage)
        XCTAssertFalse(state.alertIsError)

        // Apply the archive delta
        state.handleDelta(.worktreeArchived(WorktreeIDDelta(worktreeID: wtID)))

        // Alert should now be set and marked as error
        XCTAssertNotNil(state.alertMessage, "Error alert should be shown")
        XCTAssertTrue(state.alertIsError, "Alert should be marked as error")
        XCTAssertTrue(state.alertMessage?.contains("Couldn't create worktree") ?? false)
        XCTAssertTrue(state.alertMessage?.contains("MyNewWorktree") ?? false)
    }

    @MainActor
    func testArchivingActiveWorktreeDoesNotShowAlert() {
        let suite = "test-\(UUID().uuidString)"
        let state = AppState(userDefaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let wtID = UUID()
        let activeWt = makeWorktree(id: wtID, status: .active)
        state.worktrees = [testRepoID: [activeWt]]

        // Alert should not be set initially
        XCTAssertNil(state.alertMessage)

        // Apply the archive delta for an active (not .creating) worktree
        state.handleDelta(.worktreeArchived(WorktreeIDDelta(worktreeID: wtID)))

        // Alert should NOT be shown for an active worktree archive
        XCTAssertNil(state.alertMessage, "No alert should be shown for active worktree archive")
    }

    @MainActor
    func testArchivingUnknownWorktreeHandledGracefully() {
        let suite = "test-\(UUID().uuidString)"
        let state = AppState(userDefaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let unknownWtID = UUID()

        // Apply archive delta for a worktree we don't know about
        // (e.g., archived by another client)
        state.handleDelta(.worktreeArchived(WorktreeIDDelta(worktreeID: unknownWtID)))

        // Should not crash and should not show an alert
        XCTAssertNil(state.alertMessage, "No alert for unknown worktree")
    }

}
