import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

/// Thread-safe broadcast sink. `PanelCoordinator.broadcast` is a synchronous
/// `@Sendable` closure invoked from inside the actor's own method body
/// (never concurrently with itself, since the actor serializes), so a plain
/// lock-protected buffer is sufficient — no need for an actor recorder plus
/// the cross-actor await dance that would introduce its own ordering risk.
final class BroadcastRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _deltas: [StateDelta] = []

    func record(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        _deltas.append(delta)
    }

    var deltas: [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return _deltas
    }

    var count: Int { deltas.count }
}

@Suite("PanelCoordinatorTests")
struct PanelCoordinatorTests {

    private func makeWorktree(_ db: TBDDatabase, name: String = "w") async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/pc-\(UUID())", displayName: name, defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "b",
            path: "/tmp/pc-wt-\(UUID())", tmuxServer: "srv")
        return wt.id
    }

    /// Seeds one tab directly via the store: a primary terminal plus a side
    /// viewer panel at `panelID`.
    @discardableResult
    private func seedTab(
        _ db: TBDDatabase, worktreeID: UUID, tabID: UUID = UUID(), panelID: PanelID = UUID(),
        panelContent: PanelContent = .file(FileReference(path: "/a.txt")), revision: UInt64 = 0
    ) async throws -> WorkspaceTabSurface {
        let layout = PanelLayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [.primary, .panel(PanelSlot(id: panelID, content: panelContent))],
            ratios: [0.5, 0.5]))
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, label: "tab",
            primary: .terminal(terminalID: UUID()), layout: layout, revision: revision)
        let history = PanelHistory.seeded(with: panelContent)
        let state = PanelSurfaceState(surface: surface, histories: [panelID: history])
        try await db.panelSurface.commit(state: state, position: 0, receipt: nil, now: Date())
        return surface
    }

    private func makeCoordinator(
        _ db: TBDDatabase, recorder: BroadcastRecorder,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) -> PanelCoordinator {
        PanelCoordinator(db: db, broadcast: { recorder.record($0) }, now: now, makeID: makeID)
    }

    private func receiptCount(_ db: TBDDatabase, worktreeID: UUID) async throws -> Int {
        try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_operation_receipt WHERE worktreeID = ?",
                arguments: [worktreeID.uuidString]) ?? 0
        }
    }

    // MARK: - Gating (both branches of each flag)

    @Test func surfaceDisabledRejectsEveryOriginZeroBroadcastsZeroReceipts() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        // Neither flag flipped on — daemon_panel_surface_enabled is off.

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: nil,
            origin: .appUser,
            operation: .open(content: .file(FileReference(path: "/b.txt")), placement: .automatic))

        await #expect(throws: PanelCoordinatorError.surfaceDisabled) {
            _ = try await coordinator.apply(envelope)
        }
        #expect(recorder.count == 0)
        #expect(try await receiptCount(db, worktreeID: wtID) == 0)
    }

    @Test func agentCLIRejectedWhenAgentFlagOffEvenWithSurfaceFlagOn() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        // agent_panel_control_enabled left off.
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: nil,
            origin: .agentCLI,
            operation: .open(content: .file(FileReference(path: "/b.txt")), placement: .automatic))

        await #expect(throws: PanelCoordinatorError.agentControlDisabled) {
            _ = try await coordinator.apply(envelope)
        }
        #expect(recorder.count == 0)
        #expect(try await receiptCount(db, worktreeID: wtID) == 0)
    }

    @Test func appUserSucceedsWithOnlySurfaceFlagOn() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        // agent_panel_control_enabled stays off — appUser doesn't need it.
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: nil,
            origin: .appUser,
            operation: .open(content: .file(FileReference(path: "/b.txt")), placement: .automatic))

        let result = try await coordinator.apply(envelope)
        #expect(result.replayed == false)
        #expect(recorder.count == 1)
    }

    // MARK: - Happy path: open, revision +1, broadcast, receipt

    @Test func happyPathOpenIncrementsRevisionBroadcastsAndPersistsReceipt() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        try await db.config.setAgentPanelControlEnabled(true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID, revision: 3)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let opID = UUID()

        let envelope = PanelOperationEnvelope(
            operationID: opID, worktreeID: wtID, tabID: tab.id, baseRevision: 3,
            origin: .agentCLI,
            operation: .open(content: .file(FileReference(path: "/b.txt")), placement: .automatic))

        let result = try await coordinator.apply(envelope)
        #expect(result.replayed == false)
        #expect(result.tab.revision == 4)

        #expect(recorder.count == 1)
        guard case .panelSurfaceChanged(let delta) = recorder.deltas[0] else {
            Issue.record("expected panelSurfaceChanged delta")
            return
        }
        #expect(delta.worktreeID == wtID)
        #expect(delta.tabs == [result.tab])
        #expect(delta.originOperationID == opID)

        let receipt = try await db.panelSurface.receipt(operationID: opID)
        #expect(receipt == result)
    }

    // MARK: - Idempotent replay: no re-apply, no re-persist, one broadcast total

    @Test func duplicateOperationIDReplaysWithoutReapplyingOrRebroadcasting() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let opID = UUID()

        let envelope = PanelOperationEnvelope(
            operationID: opID, worktreeID: wtID, tabID: tab.id, baseRevision: nil,
            origin: .appUser,
            operation: .open(content: .file(FileReference(path: "/b.txt")), placement: .automatic))

        let first = try await coordinator.apply(envelope)
        #expect(first.replayed == false)
        #expect(recorder.count == 1)

        let second = try await coordinator.apply(envelope)
        #expect(second.replayed == true)
        #expect(second.tab == first.tab)
        #expect(recorder.count == 1)  // no second broadcast

        // State unchanged by the replay: still exactly first's revision.
        let state = try await db.panelSurface.state(tabID: tab.id)
        #expect(state?.surface.revision == first.tab.revision)
    }

    // MARK: - baseRevision semantic rebase

    @Test func staleBaseRevisionWithVanishedPanelMapsToStaleTarget() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID, revision: 5)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let missingPanelID = UUID()

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: 1,  // stale
            origin: .appUser,
            operation: .close(panelID: missingPanelID))

        await #expect(throws: PanelCoordinatorError.staleTarget(.panelNotFound(missingPanelID))) {
            _ = try await coordinator.apply(envelope)
        }
        #expect(recorder.count == 0)
    }

    @Test func freshBaseRevisionWithVanishedPanelMapsToOperationError() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID, revision: 5)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let missingPanelID = UUID()

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: 5,  // fresh
            origin: .appUser,
            operation: .close(panelID: missingPanelID))

        await #expect(throws: PanelCoordinatorError.operation(.panelNotFound(missingPanelID))) {
            _ = try await coordinator.apply(envelope)
        }
        #expect(recorder.count == 0)
    }

    @Test func staleBaseRevisionWithSurvivingTargetAppliesSemanticRebase() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let panelID = UUID()
        let tab = try await seedTab(db, worktreeID: wtID, panelID: panelID, revision: 5)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        let envelope = PanelOperationEnvelope(
            // stale relative to the tab's current revision (5), but the panel
            // this operation targets still exists — must apply, not reject.
            operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: 1,
            origin: .appUser,
            operation: .navigate(panelID: panelID, destination: .file(FileReference(path: "/new.txt"))))

        let result = try await coordinator.apply(envelope)
        #expect(result.tab.revision == 6)
        #expect(recorder.count == 1)
    }

    // MARK: - §5.5 resource existence

    @Test func transcriptDestinationWithForeignTerminalIsInvalidResource() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let otherWtID = try await makeWorktree(db, name: "other")
        let foreignTerminal = try await db.terminals.create(
            worktreeID: otherWtID, tmuxWindowID: "1", tmuxPaneID: "%1")
        let tab = try await seedTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: nil,
            origin: .appUser,
            operation: .open(content: .transcript(terminalID: foreignTerminal.id), placement: .automatic))

        await #expect(throws: PanelCoordinatorError.self) {
            _ = try await coordinator.apply(envelope)
        }
        #expect(recorder.count == 0)
        #expect(try await receiptCount(db, worktreeID: wtID) == 0)
    }

    // MARK: - tabNotFound

    @Test func tabNotFoundThrowsAndBroadcastsNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let missingTabID = UUID()

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: missingTabID, baseRevision: nil,
            origin: .appUser,
            operation: .open(content: .file(FileReference(path: "/b.txt")), placement: .automatic))

        await #expect(throws: PanelCoordinatorError.tabNotFound(missingTabID)) {
            _ = try await coordinator.apply(envelope)
        }
        #expect(recorder.count == 0)
    }

    @Test func tabBelongingToAnotherWorktreeIsTreatedAsNotFound() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let otherWtID = try await makeWorktree(db, name: "other")
        let tab = try await seedTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        // Envelope claims the tab lives in `otherWtID`, but it actually
        // belongs to `wtID` — must not mutate/broadcast under the wrong id.
        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: otherWtID, tabID: tab.id, baseRevision: nil,
            origin: .appUser,
            operation: .open(content: .file(FileReference(path: "/b.txt")), placement: .automatic))

        await #expect(throws: PanelCoordinatorError.tabNotFound(tab.id)) {
            _ = try await coordinator.apply(envelope)
        }
        #expect(recorder.count == 0)
    }

    // MARK: - selectTab coverage lives in PanelCoordinatorPlacementTests (Task 9)

    // MARK: - Carry-forward #1: a tab-removing op leaves no stale surface/history row

    @Test func closeOperationLeavesNoStalePanelHistoryRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let panelID = UUID()
        let tab = try await seedTab(db, worktreeID: wtID, panelID: panelID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: nil,
            origin: .appUser, operation: .close(panelID: panelID))

        let result = try await coordinator.apply(envelope)
        #expect(result.tab.layout.allPanelIDs.isEmpty)

        let state = try await db.panelSurface.state(tabID: tab.id)
        #expect(state?.histories.isEmpty == true)
        try await db.writerForTests.read { dbc in
            let count = try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_history WHERE panelID = ?",
                arguments: [panelID.uuidString])
            #expect(count == 0)
        }
    }

    // MARK: - Actor-reentrancy lost update (production DatabasePool)

    /// Regression for the reviewer's CRITICAL: actor isolation does NOT span
    /// `await`, so a coordinator that loaded state, reduced, then awaited a
    /// SEPARATE `commit` could have a concurrent same-tab apply read the stale
    /// pre-commit revision (pool reads see a WAL snapshot) and silently clobber
    /// the first. Only reproduces under a real `DatabasePool` (temp-file db) —
    /// the in-memory `DatabaseQueue` used elsewhere serializes FIFO and hides
    /// it. `applyReducing` closes the window by doing load→reduce→persist in
    /// one write transaction; every concurrent apply then rebases on the last
    /// committed tree, so all K increments and all K effects survive.
    @Test func concurrentSameTabAppliesDoNotLoseUpdatesUnderPool() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-race-\(UUID()).sqlite")
        let db = try TBDDatabase(path: tmp.path)
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: tmp.path + suffix)
            }
        }
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let panelID = UUID()
        let tab = try await seedTab(db, worktreeID: wtID, panelID: panelID, revision: 0)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        // K concurrent navigates on the SAME panel, each a distinct destination
        // and distinct operationID. navigate always increments revision by one
        // and pushes history — additive without touching split ratios, so no
        // reducer rejection muddies the lost-update signal.
        let k = 6
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<k {
                group.addTask {
                    let env = PanelOperationEnvelope(
                        operationID: UUID(), worktreeID: wtID, tabID: tab.id, baseRevision: nil,
                        origin: .appUser,
                        operation: .navigate(
                            panelID: panelID,
                            destination: .file(FileReference(path: "/f\(i).txt"))))
                    _ = try await coordinator.apply(env)
                }
            }
            try await group.waitForAll()
        }

        let finalState = try await db.panelSurface.state(tabID: tab.id)
        // No lost update: each of the K applies incremented the revision.
        #expect(finalState?.surface.revision == UInt64(k))
        // Every navigate's destination survives in the panel's durable history.
        let paths = Set((finalState?.histories[panelID]?.entries ?? []).compactMap {
            content -> String? in
            if case .file(let ref) = content { return ref.path }
            return nil
        })
        for i in 0..<k {
            #expect(paths.contains("/f\(i).txt"), "navigate to /f\(i).txt was lost")
        }
        #expect(recorder.count == k)
    }

    // MARK: - Broadcast ordering against a FAILED commit

    /// The disable-broadcast check proves a broadcast fires on success; this
    /// proves none fires when the persist THROWS after a successful reduce.
    /// Trips Task 6's cross-tab `panelHistoryOwnedByOtherTab` guard by forcing
    /// the reducer to mint a new panel whose id already belongs to another
    /// tab's history row — the write transaction rolls back, so no broadcast
    /// and the target tab is unchanged.
    @Test func failedCommitAfterReduceLeavesStateUnchangedAndDoesNotBroadcast() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)

        // Tab T2 owns a panel_history row for `collisionID`.
        let collisionID = UUID()
        _ = try await seedTab(db, worktreeID: wtID, panelID: collisionID)

        // Tab T1: primary-only layout so `open .beside` mints a fresh panel.
        let t1ID = UUID()
        let t1 = WorkspaceTabSurface(
            id: t1ID, worktreeID: wtID, label: "t1",
            primary: .terminal(terminalID: UUID()), layout: .primary, revision: 0)
        try await db.panelSurface.commit(
            state: PanelSurfaceState(surface: t1, histories: [:]),
            position: 1, receipt: nil, now: Date())

        let recorder = BroadcastRecorder()
        // makeID always returns the colliding id — the new panel slot's id will
        // equal a panelID already owned by T2, tripping the store's guard.
        let coordinator = makeCoordinator(db, recorder: recorder, makeID: { collisionID })

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: t1ID, baseRevision: nil,
            origin: .appUser,
            operation: .open(
                content: .file(FileReference(path: "/x.txt")),
                placement: .beside(target: .primary, edge: .right, share: nil)))

        await #expect(throws: (any Error).self) {
            _ = try await coordinator.apply(envelope)
        }
        // No broadcast on a rolled-back commit.
        #expect(recorder.count == 0)
        // T1 is untouched: revision still 0, still primary-only, no phantom panel.
        let reloaded = try await db.panelSurface.state(tabID: t1ID)
        #expect(reloaded?.surface.revision == 0)
        #expect(reloaded?.surface.layout == .primary)
        #expect(reloaded?.histories.isEmpty == true)
    }
}
