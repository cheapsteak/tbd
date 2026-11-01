import Foundation
import GRDB
import DaemonTestSupport
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

// Nested under TBDHomeSerialized: uses `isolateTBDHome` (process-global
// TBD_HOME mutation) so hook resolution and runtime dirs never touch the
// developer's real ~/tbd. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {
@Suite("Automatic note panel on worktree create")
struct NoteTabOnCreateTests {

    /// With `auto_create_notes_enabled` on, a create makes one "Notes" note
    /// and opens it as the worktree's one panel. The note stays out of the
    /// tab order, which holds only the terminals, and a terminal keeps focus.
    @Test func creationOpensInitialNotePanelWhenEnabled() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCreateNotes(true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

        let notes = try await db.notes.list(worktreeID: wt.id)
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(note.title == "Notes")
        #expect(!note.hasLegacyContent)
        let panelContent = try await db.panelSurface.worktreePanels(worktreeID: wt.id).map(\.content)
        let expectedContent: [WorktreePanelContent] = [.note(noteID: note.id)]
        #expect(panelContent == expectedContent)

        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let order = try await db.worktrees.getTabOrder(worktreeID: wt.id)
        #expect(!order.contains(note.id))
        #expect(Set(order) == Set(terminals.map(\.id)))
        let active = try await db.worktrees.getActiveTabID(worktreeID: wt.id)
        #expect(terminals.map(\.id).contains(try #require(active)))
    }

    /// With the setting off, an ordinary create makes no note and opens no
    /// panel. A conversation carryover still does, whatever the setting:
    /// `WorktreeConversationCarryoverTests` runs with it off and asserts
    /// the seeded note and its panel.
    @Test func creationOpensNoNotePanelWhenDisabled() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCreateNotes(false)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

        #expect(try await db.notes.list(worktreeID: wt.id).isEmpty)
        #expect(try await db.panelSurface.worktreePanels(worktreeID: wt.id).isEmpty)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let order = try await db.worktrees.getTabOrder(worktreeID: wt.id)
        #expect(Set(order) == Set(terminals.map(\.id)))
        let active = try await db.worktrees.getActiveTabID(worktreeID: wt.id)
        #expect(terminals.map(\.id).contains(try #require(active)))
    }

    /// The awaiting-listing marker of a tab's row, or nil when it has none.
    private func awaitingListing(_ db: TBDDatabase, tabID: UUID) async throws -> Bool? {
        try await db.writerForTests.read { dbc in
            try Bool.fetchOne(
                dbc, sql: "SELECT awaitingListing FROM workspace_tab_surface WHERE id = ?",
                arguments: [tabID.uuidString])
        }
    }

    /// The starter note shows in the main tab: creation writes the active
    /// tab's surface open, with the Notes panel in front, before the app has
    /// synced any tab, and broadcasts it. The app's first sync keeps that
    /// tab open and imports a second tab collapsed.
    @Test func creationSeedsTheMainTabWithNotesInFrontOpen() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCreateNotes(true)
        let recorder = BroadcastRecorder()
        let subscriptions = StateSubscriptionManager()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                recorder.record(delta)
            }
            return true
        }
        let lifecycle = makeLifecycle(db: db, subscriptions: subscriptions)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

        let note = try #require(try await db.notes.list(worktreeID: wt.id).first)
        let notePanel = try #require(try await db.panelSurface.worktreePanels(worktreeID: wt.id).first)
        #expect(notePanel.content == .note(noteID: note.id))
        let mainTabID = try #require(try await db.worktrees.getActiveTabID(worktreeID: wt.id))
        let seeded = try #require(try await db.panelSurface.surface(tabID: mainTabID))
        #expect(seeded.primary == .terminal(terminalID: mainTabID))
        #expect(seeded.side.panels.isEmpty)
        #expect(seeded.side.activePanelID == notePanel.id)
        #expect(seeded.side.collapsed == false)
        #expect(seeded.worktreePanels == [notePanel])
        #expect(try await awaitingListing(db, tabID: mainTabID) == true)
        #expect(try await db.panelSurface.surfaces(worktreeID: wt.id).map(\.id) == [mainTabID])
        let broadcast: [PanelSurfaceDelta] = recorder.deltas.compactMap {
            if case .panelSurfaceChanged(let delta) = $0, delta.worktreeID == wt.id { return delta }
            return nil
        }
        try #require(broadcast.count == 1)
        #expect(broadcast[0].tabs == [seeded])

        // The app's first sync lists the main tab and a second one.
        let secondTabID = UUID()
        let entries = [mainTabID, secondTabID].enumerated().map { position, tabID in
            SyncTabEntry(
                tabID: tabID, position: position, label: nil, primary: .terminal(terminalID: tabID),
                importCandidate: WorkspaceTabSurface(
                    id: tabID, worktreeID: wt.id, primary: .terminal(terminalID: tabID)))
        }
        let outcome = try await db.panelSurface.syncTabs(worktreeID: wt.id, entries: entries, now: Date())

        #expect(outcome.imported == [secondTabID])
        let main = try #require(try await db.panelSurface.surface(tabID: mainTabID))
        #expect(main.side == seeded.side, "the sync keeps the main tab open on the note")
        #expect(try await awaitingListing(db, tabID: mainTabID) == false)
        let second = try #require(try await db.panelSurface.surface(tabID: secondTabID))
        #expect(second.side.activePanelID == notePanel.id)
        #expect(second.side.collapsed == true)
    }

    /// With the setting off, creation writes no surface and broadcasts none.
    @Test func creationWithNotesOffSeedsNothing() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCreateNotes(false)
        let recorder = BroadcastRecorder()
        let subscriptions = StateSubscriptionManager()
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                recorder.record(delta)
            }
            return true
        }
        let lifecycle = makeLifecycle(db: db, subscriptions: subscriptions)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

        #expect(try await db.panelSurface.surfaces(worktreeID: wt.id).isEmpty)
        let panelBroadcasts = recorder.deltas.filter {
            if case .panelSurfaceChanged = $0 { return true }
            return false
        }
        #expect(panelBroadcasts.isEmpty)
    }

    @Test func preSessionGatedCreateOpensNotePanelWhenEnabled() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCreateNotes(true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id, skipClaude: true
        )
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected .preSessionPending when a preSession hook resolves")
            return
        }
        try writeMarker(worktreeID: pending.id, exitCode: 0)
        await phase3.value

        let notes = try await db.notes.list(worktreeID: pending.id)
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        let panelContent = try await db.panelSurface.worktreePanels(worktreeID: pending.id).map(\.content)
        let expectedContent: [WorktreePanelContent] = [.note(noteID: note.id)]
        #expect(panelContent == expectedContent)
        let terminals = try await db.terminals.list(worktreeID: pending.id)
        let order = try await db.worktrees.getTabOrder(worktreeID: pending.id)
        #expect(!order.contains(note.id))
        #expect(Set(order) == Set(terminals.map(\.id)))
        let active = try await db.worktrees.getActiveTabID(worktreeID: pending.id)
        #expect(terminals.map(\.id).contains(try #require(active)))
    }

    @Test func preSessionGatedCreateOpensNoNotePanelWhenDisabled() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCreateNotes(false)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id, skipClaude: true
        )
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected .preSessionPending when a preSession hook resolves")
            return
        }
        try writeMarker(worktreeID: pending.id, exitCode: 0)
        await phase3.value

        #expect(try await db.notes.list(worktreeID: pending.id).isEmpty)
        #expect(try await db.panelSurface.worktreePanels(worktreeID: pending.id).isEmpty)
        let terminals = try await db.terminals.list(worktreeID: pending.id)
        let order = try await db.worktrees.getTabOrder(worktreeID: pending.id)
        #expect(Set(order) == Set(terminals.map(\.id)))
        let active = try await db.worktrees.getActiveTabID(worktreeID: pending.id)
        #expect(terminals.map(\.id).contains(try #require(active)))
    }

    @Test func rowDeletedMidCarryoverCreateLeavesNoOrphanNote() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id,
            skipClaude: true,
            carryover: ConversationCarryover(
                sourceSessionID: UUID().uuidString,
                notesSeed: "# Revived conversation\n"
            )
        )
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected .preSessionPending")
            return
        }
        // Repo removal mid-wait deletes the worktree row; the carryover-note
        // FK must block a stray insert (best-effort helper swallows the error).
        try await db.worktrees.deleteForRepo(repoID: repo.id)
        try writeMarker(worktreeID: pending.id, exitCode: 0)
        await phase3.value

        #expect(try await db.notes.list(worktreeID: pending.id).isEmpty,
                "no note row may be created for a deleted worktree")
        #expect(try await db.panelSurface.worktreePanels(worktreeID: pending.id).isEmpty)
    }
}
}
