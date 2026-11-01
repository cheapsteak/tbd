import Testing
import Foundation
import GRDB
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

// A revive reopens a worktree panel for each of the worktree's notes, in
// creation order (side panel notes spec, "Daemon → Reclamation"): archiving
// deletes the panels and keeps the notes, so without this a revived
// worktree's notes would show only in the side strip's + menu. The store
// does it in the transaction that takes the row out of `archived`
// (`WorktreeStore.revive`, and `WorktreeStore.updateStatus` for the
// hook-gated revive and for adopt), so every revive path goes through it;
// the suites below drive each path through its real entry point.

// MARK: - Shared fixtures

/// Stamps a note's `createdAt`, so a test fixes the creation order apart
/// from the insertion order.
private func stampCreatedAt(_ db: TBDDatabase, noteID: UUID, _ date: Date) async throws {
    try await db.writerForTests.write { dbc in
        try dbc.execute(
            sql: "UPDATE note SET createdAt = ? WHERE id = ?", arguments: [date, noteID.uuidString])
    }
}

/// Adds a note to the worktree, stamped a minute older than every note it
/// already has, so the newest insert is the oldest note. Returns every note
/// of the worktree, oldest first.
private func addOlderNote(_ db: TBDDatabase, worktreeID: UUID) async throws -> [UUID] {
    let existing = try await db.notes.list(worktreeID: worktreeID)
        .sorted { $0.createdAt < $1.createdAt }
    let added = try await db.notes.create(worktreeID: worktreeID)
    let oldest: Date = existing.first?.createdAt ?? Date()
    try await stampCreatedAt(db, noteID: added.id, oldest.addingTimeInterval(-60))
    let existingIDs: [UUID] = existing.map(\.id)
    return [added.id] + existingIDs
}

/// Two notes added the way `addOlderNote` adds them, so the second insert
/// comes first in creation order. Returns every note of the worktree,
/// oldest first.
private func addTwoNotes(_ db: TBDDatabase, worktreeID: UUID) async throws -> [UUID] {
    _ = try await addOlderNote(db, worktreeID: worktreeID)
    return try await addOlderNote(db, worktreeID: worktreeID)
}

/// The note panel contents a revive should leave, one per note in `noteIDs`'
/// order.
private func notePanels(_ noteIDs: [UUID]) -> [WorktreePanelContent] {
    noteIDs.map { WorktreePanelContent.note(noteID: $0) }
}

private func panelContents(_ db: TBDDatabase, worktreeID: UUID) async throws -> [WorktreePanelContent] {
    try await db.panelSurface.worktreePanels(worktreeID: worktreeID).map(\.content)
}

private func panelRowCount(_ db: TBDDatabase, worktreeID: UUID) async throws -> Int {
    try await db.writerForTests.read { dbc in
        try Int.fetchOne(
            dbc, sql: "SELECT COUNT(*) FROM worktree_panel WHERE worktreeID = ?",
            arguments: [worktreeID.uuidString]) ?? -1
    }
}

/// Seeds a tab of the worktree whose side region has no panels.
@discardableResult
private func seedEmptyTab(
    _ db: TBDDatabase, worktreeID: UUID, position: Int = 0
) async throws -> WorkspaceTabSurface {
    let surface = WorkspaceTabSurface(
        id: UUID(), worktreeID: worktreeID, label: "empty",
        primary: .terminal(terminalID: UUID()), side: .empty)
    try await db.panelSurface.commit(surface: surface, position: position, receipt: nil, now: Date())
    return surface
}

/// Thread-safe collector for broadcast deltas.
private final class ReviveDeltaLog: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    /// Every `panelSurfaceChanged` broadcast for `worktreeID`, in order.
    func panelDeltas(worktreeID: UUID) -> [PanelSurfaceDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas.compactMap { delta -> PanelSurfaceDelta? in
            guard case .panelSurfaceChanged(let panel) = delta, panel.worktreeID == worktreeID else {
                return nil
            }
            return panel
        }
    }
}

// MARK: - The store

/// `WorktreeStore.revive` and `WorktreeStore.updateStatus`, the writes every
/// revive path ends in. Tier 1: in-memory database only.
@Suite("Revive reopens note panels: the store")
struct WorktreeReviveNotePanelsStoreTests {

    private func makeWorktree(
        _ db: TBDDatabase, status: WorktreeStatus = .active
    ) async throws -> UUID {
        let repo = try await db.repos.create(
            path: "/tmp/revive-panels-\(UUID())", displayName: "r", defaultBranch: "main")
        return try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: "/tmp/revive-panels-wt-\(UUID())", tmuxServer: "srv", status: status).id
    }

    /// The archive deletes the panels and keeps the notes; the revive opens
    /// one panel per note, ordered by creation rather than by insertion or
    /// by the order the panels had before the archive, and rewrites no
    /// surface, because the archive deleted them all.
    @Test func reviveReopensAPanelPerNoteInCreationOrder() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let noteIDs = try await addTwoNotes(db, worktreeID: wtID)
        for noteID in noteIDs.reversed() {
            _ = try await db.panelSurface.openWorktreePanel(
                worktreeID: wtID, content: .note(noteID: noteID), now: Date())
        }
        try await db.worktrees.archive(id: wtID)
        #expect(try await panelRowCount(db, worktreeID: wtID) == 0, "precondition: archive deletes the panels")

        let rewritten = try await db.worktrees.revive(id: wtID)

        let expected: [WorktreePanelContent] = notePanels(noteIDs)
        #expect(try await panelContents(db, worktreeID: wtID) == expected)
        #expect(rewritten.isEmpty)
        #expect(try await db.worktrees.get(id: wtID)?.status == .active)
    }

    /// A note that already has a panel keeps it, with its ID, and the notes
    /// without one are appended after every existing panel. A surface the
    /// worktree still has is rewritten with the new list at a fresh
    /// revision, and returned.
    @Test func reviveKeepsExistingPanelsAndAppendsTheRest() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        let noteIDs = try await addTwoNotes(db, worktreeID: wtID)
        try await db.worktrees.archive(id: wtID)
        let tab = try await seedEmptyTab(db, worktreeID: wtID)
        _ = try await db.panelSurface.openWorktreePanel(worktreeID: wtID, content: .changes, now: Date())
        let newerNote = try #require(noteIDs.last)
        let olderNote = try #require(noteIDs.first)
        _ = try await db.panelSurface.openWorktreePanel(
            worktreeID: wtID, content: .note(noteID: newerNote), now: Date())
        let held = try await db.panelSurface.worktreePanels(worktreeID: wtID)
        let revisionBefore = try #require(try await db.panelSurface.surface(tabID: tab.id)).revision

        let rewritten = try await db.worktrees.revive(id: wtID)

        let panels = try await db.panelSurface.worktreePanels(worktreeID: wtID)
        let contents: [WorktreePanelContent] = panels.map(\.content)
        let expected: [WorktreePanelContent] = [.changes, .note(noteID: newerNote), .note(noteID: olderNote)]
        #expect(contents == expected)
        let heldIDs: [PanelID] = held.map(\.id)
        let keptIDs: [PanelID] = Array(panels.prefix(2)).map(\.id)
        #expect(keptIDs == heldIDs, "an existing panel keeps its ID")
        let rewrittenIDs: [UUID] = rewritten.map(\.id)
        let expectedIDs: [UUID] = [tab.id]
        #expect(rewrittenIDs == expectedIDs)
        #expect(rewritten.first?.worktreePanels == panels)
        #expect(try await db.panelSurface.surfaces(worktreeID: wtID) == rewritten)
        let revisionAfter = try #require(rewritten.first).revision
        #expect(revisionAfter > revisionBefore)
    }

    @Test func reviveOfAWorktreeWithNoNotesOpensNoPanel() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db)
        try await db.worktrees.archive(id: wtID)

        let rewritten = try await db.worktrees.revive(id: wtID)

        #expect(rewritten.isEmpty)
        #expect(try await panelRowCount(db, worktreeID: wtID) == 0)
        #expect(try await db.worktrees.get(id: wtID)?.status == .active)
    }

    /// Only a write that takes the row out of `archived` reopens panels:
    /// `revive` of a `.creating` row opens none, `updateStatus` from
    /// `archived` to `.creating` reopens them, and `updateStatus` from
    /// `.creating` to `.active` does not reopen a panel removed in between.
    @Test func onlyAWriteLeavingArchivedReopens() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtID = try await makeWorktree(db, status: .creating)
        let note = try await db.notes.create(worktreeID: wtID)

        _ = try await db.worktrees.revive(id: wtID)
        #expect(try await panelRowCount(db, worktreeID: wtID) == 0, "the row was not archived")

        try await db.worktrees.archive(id: wtID)
        _ = try await db.worktrees.updateStatus(id: wtID, status: .creating)
        let reopened: [WorktreePanelContent] = [.note(noteID: note.id)]
        #expect(try await panelContents(db, worktreeID: wtID) == reopened)

        try await db.writerForTests.write { dbc in
            try dbc.execute(
                sql: "DELETE FROM worktree_panel WHERE worktreeID = ?", arguments: [wtID.uuidString])
        }
        _ = try await db.worktrees.updateStatus(id: wtID, status: .active)
        #expect(try await panelRowCount(db, worktreeID: wtID) == 0, "the row was not archived")
    }

    /// A scratch promote retires the scratch row as archived and leaves its
    /// notes with it; a status write out of `archived` reopens nothing for
    /// it, and leaves the main worktree's panels as the promote left them.
    @Test func aPromoteRetiredScratchRowReopensNothing() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/revive-panels-promote-\(UUID())", displayName: "r", defaultBranch: "main")
        let scratch = try await db.worktrees.createScratch(
            name: "s", displayName: "s", path: "/tmp/revive-panels-scratch-\(UUID())",
            tmuxServer: "tbd-scratch")
        let main = try await db.worktrees.createMain(
            repoID: repo.id, name: "main", branch: "main",
            path: "/tmp/revive-panels-main-\(UUID())", tmuxServer: "tbd-main")
        let note = try await db.notes.create(worktreeID: scratch.id)
        _ = try await db.panelSurface.openWorktreePanel(
            worktreeID: scratch.id, content: .note(noteID: note.id), now: Date())
        try await db.worktrees.promoteScratchMigration(
            scratchID: scratch.id, mainWorktreeID: main.id, repoID: repo.id, tmuxServer: "tbd-main")
        let mainPanels = try await db.panelSurface.worktreePanels(worktreeID: main.id)

        let revived = try await db.worktrees.revive(id: scratch.id)
        #expect(revived.isEmpty)
        #expect(try await panelRowCount(db, worktreeID: scratch.id) == 0)

        try await db.worktrees.archive(id: scratch.id)
        let updated = try await db.worktrees.updateStatus(id: scratch.id, status: .active)
        #expect(updated.isEmpty)
        #expect(try await panelRowCount(db, worktreeID: scratch.id) == 0)
        #expect(try await db.panelSurface.worktreePanels(worktreeID: main.id) == mainPanels)
        #expect(try await db.notes.get(id: note.id) != nil)
    }
}

// MARK: - Local revive, adopt, remote lanes

/// The revive paths that need no `TBD_HOME`: the lifecycle's ungated
/// revive (tier 2, a real git repo), adopting an archived worktree's path
/// (tier 2), and a remote lane's revive and filing-sync return (in-memory,
/// a scripted fake provider).
@Suite("Revive reopens note panels: lifecycle, adopt, remote")
struct WorktreeReviveNotePanelsPathTests {

    private func plainLifecycle(_ db: TBDDatabase) -> WorktreeLifecycle {
        WorktreeLifecycle(
            db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver())
    }

    @Test func lifecycleReviveReopensAPanelPerNoteInCreationOrder() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = plainLifecycle(db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)
        let noteIDs = try await addTwoNotes(db, worktreeID: wt.id)
        try await lifecycle.archiveWorktree(worktreeID: wt.id, force: true)
        #expect(try await panelRowCount(db, worktreeID: wt.id) == 0, "precondition: archive deletes the panels")

        let revived = try await lifecycle.reviveWorktree(worktreeID: wt.id, skipClaude: true)

        #expect(revived.status == .active)
        let expected: [WorktreePanelContent] = notePanels(noteIDs)
        #expect(try await panelContents(db, worktreeID: wt.id) == expected)
    }

    @Test func adoptingAnArchivedWorktreesPathReopensItsNotePanels() async throws {
        let (tempDir, repoDir, worktreePath, _) = try await makeRepoWithExternalWorktree()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = plainLifecycle(db)
        let repo = try await db.repos.create(path: repoDir.path, displayName: "test", defaultBranch: "main")
        let insertion = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)
        guard case .inserted(let adopted) = insertion else {
            Issue.record("expected .inserted, got \(insertion)")
            return
        }
        let noteIDs = try await addTwoNotes(db, worktreeID: adopted.id)
        try await db.worktrees.archive(id: adopted.id)

        let outcome = try await lifecycle.adoptWorktree(repoID: repo.id, path: worktreePath)

        guard case .revived(let revived) = outcome else {
            Issue.record("expected .revived, got \(outcome)")
            return
        }
        #expect(revived.id == adopted.id)
        let expected: [WorktreePanelContent] = notePanels(noteIDs)
        #expect(try await panelContents(db, worktreeID: adopted.id) == expected)
    }

    /// `worktree.revive` on a remote lane the provider can unarchive. The
    /// lane was archived without panels, as one archived before notes moved
    /// into the side panel was.
    @Test func remoteLaneReviveReopensItsNotePanels() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive", "unarchive"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": false}"#)],
            tag: "revive-note-panels")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: true)
        let noteIDs = try await addTwoNotes(fixture.db, worktreeID: lane.id)

        let response = await fixture.router().handle(try RPCRequest(
            method: RPCMethod.worktreeRevive,
            params: WorktreeReviveParams(worktreeID: lane.id),
            actor: .app))

        #expect(response.success, "the revive was refused: \(response.error ?? "no error")")
        #expect(try await fixture.status(of: lane) == .active)
        let expected: [WorktreePanelContent] = notePanels(noteIDs)
        #expect(try await panelContents(fixture.db, worktreeID: lane.id) == expected)
    }

    /// The filing sync returns a lane to the active list when the provider
    /// reports it unarchived.
    @Test func filingSyncReturnReopensItsNotePanels() async throws {
        let db = try TBDDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("revive-note-panels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let registryURL = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "fake", "exec": "/nonexistent/fake"}]"#
            .write(to: registryURL, atomically: true, encoding: .utf8)
        _ = try await db.repos.create(
            path: "/tmp/revive-note-panels-\(UUID().uuidString)", displayName: "api",
            defaultBranch: "main", remoteURL: "https://github.com/acme/api")
        let describe = providerOK(
            #"{"contract_versions": [1], "name": "fake", "capabilities": ["archive", "unarchive"]}"#)
        let manager = RemoteProviderManager(
            db: db, subscriptions: StateSubscriptionManager(),
            runner: FakeProviderInvoker(script: [describe]), registryURL: registryURL,
            actuationLog: ActuationLog(path: dir.appendingPathComponent("actuations.jsonl").path))
        await manager.loadRegistryAndDescribe()
        let adoption = RemoteSessionPayload(
            id: "a", state: .running, agentState: .working, meta: ["repo": "acme/api"], archived: nil)
        try await manager.apply(snapshot: [adoption], provider: "fake")
        let row = try #require(try await db.worktrees.findRemote(provider: "fake", sessionID: "a"))
        let noteIDs = try await addTwoNotes(db, worktreeID: row.id)
        try await db.worktrees.archive(id: row.id)

        let unarchived = RemoteSessionPayload(
            id: "a", state: .running, agentState: .working, meta: ["repo": "acme/api"], archived: false)
        try await manager.apply(snapshot: [unarchived], provider: "fake")

        #expect(try await db.worktrees.get(id: row.id)?.status == .active)
        let expected: [WorktreePanelContent] = notePanels(noteIDs)
        #expect(try await panelContents(db, worktreeID: row.id) == expected)
    }
}

// MARK: - Paths that need TBD_HOME

extension TBDHomeSerialized {
/// The hook-gated revive and the scratch revives, which write under
/// `TBD_HOME` (the hook's completion marker, the scratch folder).
@Suite("Revive reopens note panels: hook-gated and scratch")
struct WorktreeReviveNotePanelsHomeTests {

    private func makeRouter(_ db: TBDDatabase) -> (router: RPCRouter, deltas: ReviveDeltaLog) {
        let deltas = ReviveDeltaLog()
        let subs = StateSubscriptionManager()
        subs.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                deltas.append(delta)
            }
            return true
        }
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            subscriptions: subs, actuationLog: makeTestActuationLog())
        return (router, deltas)
    }

    private func makeScratch(_ router: RPCRouter, name: String) async throws -> Worktree {
        let created = await router.handle(try RPCRequest(
            method: RPCMethod.scratchCreate, params: ScratchCreateParams(name: name)))
        return try created.decodeResult(Worktree.self)
    }

    /// A hook-gated revive leaves `archived` for `.creating` before the hook
    /// runs, and the panels reopen then, so a tab synced while the hook runs
    /// carries them. Finishing the revive duplicates none.
    @Test func aHookGatedReviveReopensThePanelsWhenItLeavesArchived() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)
        let created = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let creation = try await lifecycle.completeCreateWorktree(worktreeID: created.id, skipClaude: true)
        if case .preSessionPending(let phase3) = creation {
            try writeMarker(worktreeID: created.id, exitCode: 0)
            await phase3.value
        }
        let noteIDs = try await addTwoNotes(db, worktreeID: created.id)
        try await lifecycle.archiveWorktree(worktreeID: created.id, force: true)
        #expect(try await panelRowCount(db, worktreeID: created.id) == 0, "precondition: archive deletes the panels")

        let completion = try await lifecycle.beginReviveWorktree(worktreeID: created.id, skipClaude: true)
        guard case .preSessionPending(let pending, let phase3) = completion else {
            Issue.record("expected .preSessionPending when a preSession hook resolves")
            return
        }

        #expect(pending.status == .creating)
        let expected: [WorktreePanelContent] = notePanels(noteIDs)
        #expect(try await panelContents(db, worktreeID: created.id) == expected)
        let reopenedIDs: [PanelID] = try await db.panelSurface.worktreePanels(worktreeID: created.id).map(\.id)

        try writeMarker(worktreeID: created.id, exitCode: 0)
        await phase3.value

        #expect(try await db.worktrees.get(id: created.id)?.status == .active)
        let finalIDs: [PanelID] = try await db.panelSurface.worktreePanels(worktreeID: created.id).map(\.id)
        #expect(finalIDs == reopenedIDs)
    }

    /// `scratch.revive` reopens the panels in creation order. A surface the
    /// worktree still has is rewritten with them, and the rewrite is
    /// broadcast as one `panelSurfaceChanged`.
    @Test func scratchReviveReopensThePanelsAndBroadcastsTheRewrite() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db)
        let wt = try await makeScratch(router, name: "revive-note-panels")
        let noteIDs = try await addTwoNotes(db, worktreeID: wt.id)
        let archive = await router.handle(try RPCRequest(
            method: RPCMethod.scratchArchive, params: ScratchArchiveParams(worktreeID: wt.id)))
        try #require(archive.success)
        let tab = try await seedEmptyTab(db, worktreeID: wt.id)
        let deltasBefore = deltas.panelDeltas(worktreeID: wt.id).count

        let revive = await router.handle(try RPCRequest(
            method: RPCMethod.scratchRevive, params: ScratchReviveParams(worktreeID: wt.id)))

        #expect(revive.success, "the revive was refused: \(revive.error ?? "no error")")
        let expected: [WorktreePanelContent] = notePanels(noteIDs)
        #expect(try await panelContents(db, worktreeID: wt.id) == expected)
        let broadcast = Array(deltas.panelDeltas(worktreeID: wt.id).dropFirst(deltasBefore))
        #expect(broadcast.count == 1)
        let rewritten = try #require(broadcast.first?.tabs.first)
        #expect(rewritten.id == tab.id)
        let rewrittenContents: [WorktreePanelContent] = rewritten.worktreePanels.map(\.content)
        #expect(rewrittenContents == expected)
    }

    /// `worktree.revive` routes a scratch space to the same revive, and one
    /// with no notes comes back with no panels and no panel broadcast.
    @Test func worktreeReviveOfAScratchWithNoNotesOpensNoPanel() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db)
        let wt = try await makeScratch(router, name: "revive-no-notes")
        try #require(try await db.notes.list(worktreeID: wt.id).isEmpty)
        let archive = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive, params: WorktreeArchiveParams(worktreeID: wt.id)))
        try #require(archive.success)
        let deltasBefore = deltas.panelDeltas(worktreeID: wt.id).count

        let revive = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeRevive, params: WorktreeReviveParams(worktreeID: wt.id)))

        #expect(revive.success, "the revive was refused: \(revive.error ?? "no error")")
        #expect(try await db.worktrees.get(id: wt.id)?.status == .active)
        #expect(try await panelRowCount(db, worktreeID: wt.id) == 0)
        #expect(deltas.panelDeltas(worktreeID: wt.id).count == deltasBefore)
    }

    /// A scratch row a promote retired is refused a revive, and keeps no
    /// panel: its notes stay with it, and the main worktree's panels stay as
    /// the promote left them.
    @Test func aPromoteRetiredScratchRowIsUntouched() async throws {
        let (_, cleanup) = isolateTBDHome(); defer { cleanup() }
        let db = try TBDDatabase(inMemory: true)
        let (router, deltas) = makeRouter(db)
        let wt = try await makeScratch(router, name: "revive-promoted")
        let note = try await db.notes.create(worktreeID: wt.id)
        _ = try await db.panelSurface.openWorktreePanel(
            worktreeID: wt.id, content: .note(noteID: note.id), now: Date())
        let repo = try await db.repos.create(
            path: "/tmp/r-\(UUID().uuidString)", displayName: "r", defaultBranch: "main")
        let main = try await db.worktrees.create(
            repoID: repo.id, name: "main", branch: "main",
            path: "/tmp/main-\(UUID().uuidString)", tmuxServer: "tbd-y", status: .main)
        try await db.worktrees.promoteScratchMigration(
            scratchID: wt.id, mainWorktreeID: main.id, repoID: repo.id, tmuxServer: "tbd-y")
        // A directory at the stale scratch path, so the folder check is not
        // what refuses the revive.
        try FileManager.default.createDirectory(atPath: wt.localPath, withIntermediateDirectories: true)
        let mainPanels = try await db.panelSurface.worktreePanels(worktreeID: main.id)
        let deltasBefore = deltas.panelDeltas(worktreeID: wt.id).count

        let revive = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeRevive, params: WorktreeReviveParams(worktreeID: wt.id)))

        #expect(!revive.success)
        #expect(try await db.worktrees.get(id: wt.id)?.status == .archived)
        #expect(try await panelRowCount(db, worktreeID: wt.id) == 0)
        #expect(try await db.notes.get(id: note.id) != nil)
        #expect(try await db.panelSurface.worktreePanels(worktreeID: main.id) == mainPanels)
        #expect(deltas.panelDeltas(worktreeID: wt.id).count == deltasBefore)
    }
}
}
