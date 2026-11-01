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

    private static func file(_ path: String) -> PanelContent {
        .file(FileReference(path: path))
    }

    private func makeWorktree(_ db: TBDDatabase, name: String = "w") async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/pc-\(UUID())", displayName: name, defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: name, branch: "b",
            path: "/tmp/pc-wt-\(UUID())", tmuxServer: "srv")
        return wt.id
    }

    /// Seeds one tab through the store: a terminal primary plus one side
    /// panel at `panelID` with `history` (a one-entry history of
    /// `panelContent` when nil).
    @discardableResult
    private func seedTab(
        _ db: TBDDatabase, worktreeID: UUID, tabID: UUID = UUID(), panelID: PanelID = UUID(),
        panelContent: PanelContent = .file(FileReference(path: "/a.txt")),
        history: PanelHistory? = nil, revision: UInt64 = 0, position: Int = 0
    ) async throws -> WorkspaceTabSurface {
        let panel = ViewerPanel(id: panelID, history: history ?? .seeded(with: panelContent))
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, label: "tab",
            primary: .terminal(terminalID: UUID()),
            side: SideRegion(
                panels: [panel], activePanelID: panelID, recency: [panelID],
                collapsed: false, width: 0.4),
            revision: revision)
        try await db.panelSurface.commit(surface: surface, position: position, receipt: nil, now: Date())
        return surface
    }

    /// Seeds a tab whose side region has no panels.
    @discardableResult
    private func seedEmptyTab(
        _ db: TBDDatabase, worktreeID: UUID, tabID: UUID = UUID(), position: Int = 0
    ) async throws -> WorkspaceTabSurface {
        let surface = WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID, label: "empty",
            primary: .terminal(terminalID: UUID()), side: .empty, revision: 0)
        try await db.panelSurface.commit(surface: surface, position: position, receipt: nil, now: Date())
        return surface
    }

    private func makeCoordinator(
        _ db: TBDDatabase, recorder: BroadcastRecorder,
        makeID: @escaping @Sendable () -> UUID = UUID.init
    ) -> PanelCoordinator {
        PanelCoordinator(db: db, broadcast: { recorder.record($0) }, makeID: makeID)
    }

    private func envelope(
        worktreeID: UUID, tabID: UUID, operationID: UUID = UUID(), baseRevision: UInt64? = nil,
        origin: PanelOperationOrigin = .appUser, _ operation: PanelOperation
    ) -> PanelOperationEnvelope {
        PanelOperationEnvelope(
            operationID: operationID, worktreeID: worktreeID, tabID: tabID,
            baseRevision: baseRevision, origin: origin, operation: operation)
    }

    private func receiptCount(_ db: TBDDatabase, worktreeID: UUID) async throws -> Int {
        try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_operation_receipt WHERE worktreeID = ?",
                arguments: [worktreeID.uuidString]) ?? 0
        }
    }

    private func surfaceDeltas(_ recorder: BroadcastRecorder) -> [PanelSurfaceDelta] {
        recorder.deltas.compactMap {
            if case .panelSurfaceChanged(let delta) = $0 { return delta }
            return nil
        }
    }

    // MARK: - No setting gates an operation

    /// The retired `config.panel_tabs_enabled` column still exists in a fresh
    /// test database until the reconciler drops it. Writing 0 into it proves
    /// no code path consults it: a gate that read the old flag would refuse.
    @Test("an app and an agent operation both apply with no config consulted")
    func operationsApplyWhateverTheRetiredColumnHolds() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "UPDATE config SET panel_tabs_enabled = 0")
        }
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)
        let coordinator = makeCoordinator(db, recorder: BroadcastRecorder())

        let fromApp = try await coordinator.apply(envelope(
            worktreeID: wtID, tabID: tab.id, origin: .appUser, .setCollapsed(true)))
        let fromAgent = try await coordinator.apply(envelope(
            worktreeID: wtID, tabID: tab.id, origin: .agentCLI, .setCollapsed(false)))

        #expect(fromApp.tab.side.collapsed == true)
        #expect(fromAgent.tab.side.collapsed == false)
    }

    @Test(arguments: [PanelOperationOrigin.appUser, .agentCLI])
    func operationAppliesForEveryOrigin(origin: PanelOperationOrigin) async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        let result = try await coordinator.apply(envelope(
            worktreeID: wtID, tabID: tab.id, origin: origin,
            .open(content: Self.file("/b.txt"), newPanel: false)))

        #expect(result.replayed == false)
        #expect(result.tab.revision > tab.revision)
        #expect(result.tab.side.panels.compactMap(\.content) == [Self.file("/b.txt")])
        #expect(recorder.count == 1)
    }

    // MARK: - get

    @Test func getReturnsHistories() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let history: PanelHistory = {
            var built = PanelHistory.seeded(with: Self.file("/a.txt"))
            built.recordReplacement(outgoing: Self.file("/a.txt"), incoming: Self.file("/a2.txt"))
            return built
        }()
        let panelID = UUID()
        let tab = try await seedTab(db, worktreeID: wtID, panelID: panelID, history: history)
        try await db.worktrees.setActiveTabID(worktreeID: wtID, tabID: tab.id)
        let coordinator = makeCoordinator(db, recorder: BroadcastRecorder())

        let whole = try await coordinator.get(worktreeID: wtID, tabID: nil)
        #expect(whole.tabs == [tab])
        #expect(whole.tabs.first?.side.panel(id: panelID)?.history == history)
        #expect(whole.activeTabID == tab.id)

        let scoped = try await coordinator.get(worktreeID: wtID, tabID: tab.id)
        #expect(scoped.tabs == [tab])
        #expect(scoped.tabs.first?.side.panel(id: panelID)?.history == history)
    }

    /// A tab-scoped get answers about one tab, and still names the
    /// worktree's active tab, so `tbd panel list --tab` can mark it.
    @Test func getScopedReportsActiveTab() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let active = try await seedTab(db, worktreeID: wtID, position: 0)
        let inactive = try await seedTab(db, worktreeID: wtID, position: 1)
        try await db.worktrees.setActiveTabID(worktreeID: wtID, tabID: active.id)
        let coordinator = makeCoordinator(db, recorder: BroadcastRecorder())

        let onActive = try await coordinator.get(worktreeID: wtID, tabID: active.id)
        #expect(onActive.tabs == [active])
        #expect(onActive.activeTabID == active.id)

        let onInactive = try await coordinator.get(worktreeID: wtID, tabID: inactive.id)
        #expect(onInactive.tabs == [inactive])
        #expect(onInactive.activeTabID == active.id, "the active tab is the worktree's, whichever tab was asked for")

        // A tab under another worktree is not this worktree's tab.
        let otherWtID = try await makeWorktree(db, name: "other")
        let foreign = try await coordinator.get(worktreeID: otherWtID, tabID: active.id)
        #expect(foreign.tabs.isEmpty)
        #expect(foreign.activeTabID == nil, "the other worktree has no active tab recorded")
    }

    // MARK: - Resource existence

    @Test func openOfMissingNoteIsInvalidResource() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let missingNoteID = UUID()

        let openMissing = envelope(
            worktreeID: wtID, tabID: tab.id, .open(content: .note(noteID: missingNoteID), newPanel: false))
        let error = await #expect(throws: PanelCoordinatorError.self) {
            _ = try await coordinator.apply(openMissing)
        }
        guard case .invalidResource(let detail)? = error else {
            Issue.record("expected invalidResource, got \(String(describing: error))")
            return
        }
        #expect(detail.contains(missingNoteID.uuidString))
        #expect(recorder.count == 0)
        #expect(try await receiptCount(db, worktreeID: wtID) == 0)
        #expect(try await db.panelSurface.surface(tabID: tab.id) == tab)
    }

    @Test func openOfOwnNoteApplies() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let note = try await db.notes.create(worktreeID: wtID)
        let tab = try await seedTab(db, worktreeID: wtID)
        let coordinator = makeCoordinator(db, recorder: BroadcastRecorder())

        let result = try await coordinator.apply(envelope(
            worktreeID: wtID, tabID: tab.id, .open(content: .note(noteID: note.id), newPanel: false)))

        #expect(result.tab.side.panels.contains { $0.content == .note(noteID: note.id) })
    }

    @Test func transcriptOfForeignTerminalIsInvalidResource() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let otherWtID = try await makeWorktree(db, name: "other")
        let foreignTerminal = try await db.terminals.create(
            worktreeID: otherWtID, tmuxWindowID: "1", tmuxPaneID: "%1")
        let tab = try await seedTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        let openForeign = envelope(
            worktreeID: wtID, tabID: tab.id,
            .open(content: .transcript(terminalID: foreignTerminal.id), newPanel: false))
        let error = await #expect(throws: PanelCoordinatorError.self) {
            _ = try await coordinator.apply(openForeign)
        }
        guard case .invalidResource? = error else {
            Issue.record("expected invalidResource, got \(String(describing: error))")
            return
        }
        #expect(recorder.count == 0)
    }

    // MARK: - Stale base revision

    @Test func staleBaseRelabelsPanelNotFound() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID, revision: 5)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let missingPanelID = UUID()

        let stale = envelope(
            worktreeID: wtID, tabID: tab.id, baseRevision: 1, .close(panelID: missingPanelID))
        await #expect(throws: PanelCoordinatorError.staleTarget(.panelNotFound(missingPanelID))) {
            _ = try await coordinator.apply(stale)
        }
        #expect(recorder.count == 0)
    }

    @Test func freshBaseKeepsPanelNotFoundAsOperation() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID, revision: 5)
        let coordinator = makeCoordinator(db, recorder: BroadcastRecorder())
        let missingPanelID = UUID()

        let fresh = envelope(
            worktreeID: wtID, tabID: tab.id, baseRevision: 5, .close(panelID: missingPanelID))
        await #expect(throws: PanelCoordinatorError.operation(.panelNotFound(missingPanelID))) {
            _ = try await coordinator.apply(fresh)
        }

        let noBase = envelope(worktreeID: wtID, tabID: tab.id, .close(panelID: missingPanelID))
        await #expect(throws: PanelCoordinatorError.operation(.panelNotFound(missingPanelID))) {
            _ = try await coordinator.apply(noBase)
        }
    }

    /// Only a vanished panel is relabelled: any other rejection under a stale
    /// base stays an operation error.
    @Test func staleBaseKeepsOtherErrorsAsOperation() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let panelID = UUID()
        let tab = try await seedTab(db, worktreeID: wtID, panelID: panelID, revision: 5)
        let coordinator = makeCoordinator(db, recorder: BroadcastRecorder())
        let web = PanelContent.web(URL(string: "https://example.com")!)

        let stale = envelope(
            worktreeID: wtID, tabID: tab.id, baseRevision: 1,
            .navigate(panelID: panelID, destination: web))
        let expected = PanelCoordinatorError.operation(
            .kindMismatch(panelID: panelID, expected: .file, actual: .web))
        await #expect(throws: expected) {
            _ = try await coordinator.apply(stale)
        }
    }

    @Test func staleBaseWithSurvivingTargetApplies() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let panelID = UUID()
        let tab = try await seedTab(db, worktreeID: wtID, panelID: panelID, revision: 5)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        let result = try await coordinator.apply(envelope(
            worktreeID: wtID, tabID: tab.id, baseRevision: 1,
            .navigate(panelID: panelID, destination: Self.file("/new.txt"))))

        #expect(result.tab.revision > tab.revision)
        #expect(result.tab.side.panel(id: panelID)?.content == Self.file("/new.txt"))
        #expect(recorder.count == 1)
    }

    // MARK: - Broadcast and replay

    @Test func applyBroadcastsTheCommittedTab() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID, revision: 3)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let opID = UUID()

        let result = try await coordinator.apply(envelope(
            worktreeID: wtID, tabID: tab.id, operationID: opID, baseRevision: 3,
            .open(content: Self.file("/b.txt"), newPanel: true)))
        #expect(result.replayed == false)
        #expect(result.tab.revision > tab.revision)

        let deltas = surfaceDeltas(recorder)
        #expect(recorder.count == 1)
        let delta = try #require(deltas.first)
        #expect(delta.worktreeID == wtID)
        #expect(delta.tabs == [result.tab])
        #expect(delta.removedTabIDs.isEmpty)
        #expect(delta.activeTabID == nil)
        #expect(delta.originOperationID == opID)

        // What was broadcast is what was stored and what the receipt replays.
        #expect(try await db.panelSurface.surface(tabID: tab.id) == result.tab)
        #expect(try await db.panelSurface.receipt(operationID: opID) == result)
    }

    @Test func replayDoesNotBroadcast() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let tab = try await seedTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        let once = envelope(
            worktreeID: wtID, tabID: tab.id, .open(content: Self.file("/b.txt"), newPanel: true))
        let first = try await coordinator.apply(once)
        #expect(first.replayed == false)
        #expect(recorder.count == 1)

        let second = try await coordinator.apply(once)
        #expect(second.replayed == true)
        #expect(second.tab == first.tab)
        #expect(recorder.count == 1)

        // The replay re-applied nothing: still one new panel, first's revision.
        let stored = try await db.panelSurface.surface(tabID: tab.id)
        #expect(stored?.revision == first.tab.revision)
        #expect(stored?.side.panels.count == 2)
    }

    /// An operation ID already applied to one tab, sent again for another, is
    /// a caller bug: it neither replays the first tab's result nor applies to
    /// the second tab.
    @Test func reusedOperationIDForAnotherTabIsRefused() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let firstTab = try await seedTab(db, worktreeID: wtID)
        let secondTab = try await seedTab(db, worktreeID: wtID, position: 1)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let opID = UUID()

        let applied = try await coordinator.apply(envelope(
            worktreeID: wtID, tabID: firstTab.id, operationID: opID,
            .open(content: Self.file("/b.txt"), newPanel: true)))
        #expect(applied.replayed == false)
        #expect(recorder.count == 1)

        let reused = envelope(
            worktreeID: wtID, tabID: secondTab.id, operationID: opID,
            .open(content: Self.file("/c.txt"), newPanel: true))
        await #expect(throws: PanelCoordinatorError.operationIDReused(opID)) {
            _ = try await coordinator.apply(reused)
        }
        #expect(recorder.count == 1, "a refused operation broadcasts nothing")
        #expect(try await db.panelSurface.surface(tabID: secondTab.id) == secondTab)
        #expect(try await db.panelSurface.surface(tabID: firstTab.id) == applied.tab)
        #expect(try await db.panelSurface.receipt(operationID: opID) == applied,
                "the first tab's receipt is untouched")
    }

    // MARK: - tabNotFound

    @Test func missingTabIsTabNotFound() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let missingTabID = UUID()

        let missing = envelope(
            worktreeID: wtID, tabID: missingTabID, .open(content: Self.file("/b.txt"), newPanel: false))
        await #expect(throws: PanelCoordinatorError.tabNotFound(missingTabID)) {
            _ = try await coordinator.apply(missing)
        }
        #expect(recorder.count == 0)
    }

    @Test func tabOfAnotherWorktreeIsTabNotFound() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let otherWtID = try await makeWorktree(db, name: "other")
        let tab = try await seedTab(db, worktreeID: wtID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)

        // The envelope claims the tab lives in `otherWtID`; it must not
        // mutate or broadcast under the wrong worktree.
        let misattributed = envelope(
            worktreeID: otherWtID, tabID: tab.id, .open(content: Self.file("/b.txt"), newPanel: false))
        await #expect(throws: PanelCoordinatorError.tabNotFound(tab.id)) {
            _ = try await coordinator.apply(misattributed)
        }
        #expect(recorder.count == 0)
        #expect(try await db.panelSurface.surface(tabID: tab.id) == tab)
    }

    // MARK: - Close drops the panel's history row

    @Test func closeLeavesNoHistoryRow() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let panelID = UUID()
        let tab = try await seedTab(db, worktreeID: wtID, panelID: panelID)
        let coordinator = makeCoordinator(db, recorder: BroadcastRecorder())

        let result = try await coordinator.apply(envelope(
            worktreeID: wtID, tabID: tab.id, .close(panelID: panelID)))
        #expect(result.tab.side.panels.isEmpty)
        #expect(result.tab.side.activePanelID == nil)

        let count = try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM panel_history WHERE panelID = ?",
                arguments: [panelID.uuidString])
        }
        #expect(count == 0)
    }

    // MARK: - A failed commit does not broadcast

    /// The reducer succeeds, then the store refuses the write: `makeID` mints
    /// a panel ID whose history row belongs to another tab, tripping the
    /// store's cross-tab guard. The transaction rolls back, nothing is
    /// broadcast, and the target tab is unchanged.
    @Test func failedCommitAfterReduceDoesNotBroadcast() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let collisionID = UUID()
        try await seedTab(db, worktreeID: wtID, panelID: collisionID, position: 0)
        let target = try await seedEmptyTab(db, worktreeID: wtID, position: 1)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder, makeID: { collisionID })

        let colliding = envelope(
            worktreeID: wtID, tabID: target.id, .open(content: Self.file("/x.txt"), newPanel: true))
        await #expect(throws: (any Error).self) {
            _ = try await coordinator.apply(colliding)
        }

        #expect(recorder.count == 0)
        #expect(try await db.panelSurface.surface(tabID: target.id) == target)
        #expect(try await receiptCount(db, worktreeID: wtID) == 0)
    }

    // MARK: - Concurrent applies on a production DatabasePool

    /// Actor isolation does not span `await`, so a coordinator that loaded a
    /// surface, reduced, then awaited a separate write could let a concurrent
    /// same-tab apply read the stale revision and clobber the first. Only a
    /// real `DatabasePool` (temp-file database) shows it; the in-memory queue
    /// serializes FIFO. `apply` goes through `applyReducing`, so every one of
    /// K navigates lands.
    @Test func concurrentSameTabAppliesDoNotLoseUpdatesUnderPool() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc-race-\(UUID()).sqlite")
        let db = try TBDDatabase(path: tmp.path)
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: tmp.path + suffix)
            }
        }
        let wtID = try await makeWorktree(db)
        let panelID = UUID()
        let tab = try await seedTab(db, worktreeID: wtID, panelID: panelID)
        let recorder = BroadcastRecorder()
        let coordinator = makeCoordinator(db, recorder: recorder)
        let tabID = tab.id

        let k = 6
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<k {
                group.addTask {
                    let navigate = PanelOperationEnvelope(
                        operationID: UUID(), worktreeID: wtID, tabID: tabID, baseRevision: nil,
                        origin: .appUser,
                        operation: .navigate(
                            panelID: panelID, destination: .file(FileReference(path: "/f\(i).txt"))))
                    _ = try await coordinator.apply(navigate)
                }
            }
            try await group.waitForAll()
        }

        let stored = try await db.panelSurface.surface(tabID: tabID)
        #expect((stored?.revision ?? 0) > tab.revision)
        let paths = Set((stored?.side.panel(id: panelID)?.history.entries ?? []).compactMap {
            content -> String? in
            if case .file(let ref) = content { return ref.path }
            return nil
        })
        for i in 0..<k {
            #expect(paths.contains("/f\(i).txt"), "navigate to /f\(i).txt was lost")
        }
        #expect(recorder.count == k)
    }
}
