import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

/// Task 9: the coordinator's `.automatic` recency rewrite (spec C §6.1 rule
/// 1 / Phase 1 decision record #3) and `selectTab` handling. Both behaviors
/// the reducer deliberately does NOT own — see `PanelCoordinator.swift`.
@Suite("PanelCoordinatorPlacementTests")
struct PanelCoordinatorPlacementTests {

    private func makeWorktree(_ db: TBDDatabase, name: String = "w") async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/pcp-\(UUID())", displayName: name, defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "b",
            path: "/tmp/pcp-wt-\(UUID())", tmuxServer: "srv")
        return wt.id
    }

    private func makeCoordinator(
        _ db: TBDDatabase, recorder: BroadcastRecorder,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) -> PanelCoordinator {
        PanelCoordinator(db: db, broadcast: { recorder.record($0) }, now: now, makeID: makeID)
    }

    /// A tab with a primary-only layout (zero viewer panels).
    private func seedZeroPanelTab(_ db: TBDDatabase, worktreeID: UUID, tabID: UUID = UUID()) async throws -> WorkspaceTabSurface {
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, label: "tab",
            primary: .terminal(terminalID: UUID()), layout: .primary, revision: 0)
        try await db.panelSurface.commit(
            state: PanelSurfaceState(surface: surface, histories: [:]),
            position: 0, receipt: nil, now: Date())
        return surface
    }

    /// A tab whose layout has TWO viewer panels (pre-order: panelA, panelB)
    /// beside the primary. Both histories are seeded in the SAME commit —
    /// with no other write, both `panel_history` rows get an identical
    /// `updatedAt`, i.e. a genuine tie.
    private func seedTwoPanelTab(
        _ db: TBDDatabase, worktreeID: UUID, tabID: UUID = UUID(),
        panelA: PanelID, panelB: PanelID, now: Date
    ) async throws -> WorkspaceTabSurface {
        let contentA = PanelContent.file(FileReference(path: "/a.txt"))
        let contentB = PanelContent.file(FileReference(path: "/b.txt"))
        let layout = PanelLayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [.primary, .panel(PanelSlot(id: panelA, content: contentA)),
                       .panel(PanelSlot(id: panelB, content: contentB))],
            ratios: [0.34, 0.33, 0.33]))
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, label: "tab",
            primary: .terminal(terminalID: UUID()), layout: layout, revision: 0)
        let state = PanelSurfaceState(surface: surface, histories: [
            panelA: .seeded(with: contentA),
            panelB: .seeded(with: contentB),
        ])
        try await db.panelSurface.commit(state: state, position: 0, receipt: nil, now: now)
        return surface
    }

    /// Touches panel B's history with a NEW piece of content at `now`, so its
    /// `panel_history.updatedAt` advances past panel A's (which is untouched
    /// by this call — `writeSurfaceAndHistory` only bumps `updatedAt` for
    /// rows whose decoded content actually changed).
    private func bumpPanelBRecency(
        _ db: TBDDatabase, surface: WorkspaceTabSurface, panelA: PanelID, panelB: PanelID, now: Date
    ) async throws {
        var historyB = MRUHistory<PanelContent>.seeded(with: .file(FileReference(path: "/b.txt")))
        historyB.recordReplacement(
            outgoing: .file(FileReference(path: "/b.txt")),
            incoming: .file(FileReference(path: "/b2.txt")))
        let state = PanelSurfaceState(surface: surface, histories: [
            panelA: .seeded(with: .file(FileReference(path: "/a.txt"))),
            panelB: historyB,
        ])
        try await db.panelSurface.commit(state: state, position: 0, receipt: nil, now: now)
    }

    // MARK: - §6.1 recency rewrite: recency winner beats pre-order-first

    @Test func recencyWinnerChosenOverPreOrderFirst() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let panelA = UUID()
        let panelB = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)  // strictly later
        let surface = try await seedTwoPanelTab(
            db, worktreeID: wtID, panelA: panelA, panelB: panelB, now: t0)
        // B becomes the more-recently-navigated panel.
        try await bumpPanelBRecency(db, surface: surface, panelA: panelA, panelB: panelB, now: t1)

        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let newContent = PanelContent.file(FileReference(path: "/new.txt"))

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: surface.id, baseRevision: nil,
            origin: .appUser, operation: .open(content: newContent, placement: .automatic))

        let result = try await coordinator.apply(envelope)

        // Panel B (most-recently-navigated) got rewritten to, NOT panel A
        // (pre-order-first).
        #expect(result.tab.layout.panelSlot(id: panelB)?.content == newContent)
        #expect(result.tab.layout.panelSlot(id: panelA)?.content == .file(FileReference(path: "/a.txt")))
    }

    // MARK: - §6.1 recency rewrite: no-history tie falls back to pre-order-first

    @Test func noHistoryTieFallsBackToPreOrderFirstMatchingReducerDefault() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let panelA = UUID()
        let panelB = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        // Both panels seeded in ONE commit — identical updatedAt, a tie.
        let surface = try await seedTwoPanelTab(
            db, worktreeID: wtID, panelA: panelA, panelB: panelB, now: t0)

        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let newContent = PanelContent.file(FileReference(path: "/new.txt"))

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: surface.id, baseRevision: nil,
            origin: .appUser, operation: .open(content: newContent, placement: .automatic))

        let result = try await coordinator.apply(envelope)

        // Same outcome the UN-rewritten reducer default produces on a copy of
        // the identical starting state (first panel in pre-order).
        let unrewrittenState = try PanelSurfaceReducer.apply(
            .open(content: newContent, placement: .automatic),
            to: PanelSurfaceState(surface: surface, histories: [
                panelA: .seeded(with: .file(FileReference(path: "/a.txt"))),
                panelB: .seeded(with: .file(FileReference(path: "/b.txt"))),
            ]))

        #expect(result.tab.layout.panelSlot(id: panelA)?.content == newContent)
        #expect(result.tab.layout.panelSlot(id: panelA)?.content
                == unrewrittenState.surface.layout.panelSlot(id: panelA)?.content)
        #expect(result.tab.layout.panelSlot(id: panelB)?.content
                == unrewrittenState.surface.layout.panelSlot(id: panelB)?.content)
    }

    // MARK: - §6.1 recency rewrite: zero panels passes `.automatic` through

    @Test func zeroPanelTabPassesAutomaticThroughToBesideSplit() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let surface = try await seedZeroPanelTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let newContent = PanelContent.file(FileReference(path: "/new.txt"))

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: surface.id, baseRevision: nil,
            origin: .appUser, operation: .open(content: newContent, placement: .automatic))

        let result = try await coordinator.apply(envelope)

        // Reducer's own `.automatic` default: split right of primary at 0.35.
        guard case .split(let split) = result.tab.layout else {
            Issue.record("expected a split, got \(result.tab.layout)")
            return
        }
        #expect(split.children.count == 2)
        #expect(split.children.first == .primary)
        let side: Double = PanelSurfaceReducer.defaultSideShare
        #expect(split.ratios == [1 - side, side])
        #expect(result.tab.layout.allPanelIDs.count == 1)
        #expect(result.tab.layout.panelSlot(id: result.tab.layout.allPanelIDs[0])?.content == newContent)
    }

    // MARK: - selectTab: happy path

    @Test func selectTabHappyPathPersistsActiveTabAndBroadcasts() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let surface = try await seedZeroPanelTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let opID = UUID()

        let envelope = PanelOperationEnvelope(
            operationID: opID, worktreeID: wtID, tabID: surface.id, baseRevision: nil,
            origin: .appUser, operation: .selectTab(tabID: surface.id))

        let result = try await coordinator.apply(envelope)
        #expect(result.replayed == false)
        #expect(result.tab == surface)

        // activeTabID persisted via the EXISTING WorktreeStore column — no
        // duplicate authority.
        let activeTabID = try await db.worktrees.getActiveTabID(worktreeID: wtID)
        #expect(activeTabID == surface.id)

        #expect(recorder.count == 1)
        guard case .panelSurfaceChanged(let delta) = recorder.deltas[0] else {
            Issue.record("expected panelSurfaceChanged delta")
            return
        }
        #expect(delta.worktreeID == wtID)
        #expect(delta.tabs.isEmpty)
        #expect(delta.removedTabIDs.isEmpty)
        #expect(delta.activeTabID == surface.id)
        #expect(delta.originOperationID == opID)

        // No surface mutation: revision/layout unchanged.
        let reloaded = try await db.panelSurface.state(tabID: surface.id)
        #expect(reloaded?.surface.revision == surface.revision)
        #expect(reloaded?.surface.layout == surface.layout)
    }

    // MARK: - selectTab: unknown tab

    @Test func selectTabUnknownTabThrowsTabNotFound() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let surface = try await seedZeroPanelTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let missingTabID = UUID()

        let envelope = PanelOperationEnvelope(
            operationID: UUID(), worktreeID: wtID, tabID: surface.id, baseRevision: nil,
            origin: .appUser, operation: .selectTab(tabID: missingTabID))

        await #expect(throws: PanelCoordinatorError.tabNotFound(missingTabID)) {
            _ = try await coordinator.apply(envelope)
        }
        #expect(recorder.count == 0)
        let activeTabID = try await db.worktrees.getActiveTabID(worktreeID: wtID)
        #expect(activeTabID == nil)
    }

    // MARK: - selectTab: idempotent by receipt

    @Test func selectTabIsIdempotentByReceipt() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setPanelSurfaceEnabled(true)
        let wtID = try await makeWorktree(db)
        let surface = try await seedZeroPanelTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let opID = UUID()

        let envelope = PanelOperationEnvelope(
            operationID: opID, worktreeID: wtID, tabID: surface.id, baseRevision: nil,
            origin: .appUser, operation: .selectTab(tabID: surface.id))

        let first = try await coordinator.apply(envelope)
        #expect(first.replayed == false)
        #expect(recorder.count == 1)

        let second = try await coordinator.apply(envelope)
        #expect(second.replayed == true)
        #expect(second.tab == first.tab)
        #expect(recorder.count == 1)  // no second broadcast

        let activeTabID = try await db.worktrees.getActiveTabID(worktreeID: wtID)
        #expect(activeTabID == surface.id)
    }
}
