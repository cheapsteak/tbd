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
@Suite("Automatic note on worktree create")
struct NoteTabOnCreateTests {

    /// The worktree's `worktree_panel` rows, read raw so a malformed row
    /// counts too.
    private func worktreePanelRowCount(_ db: TBDDatabase, worktreeID: UUID) async throws -> Int {
        try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM worktree_panel WHERE worktreeID = ?",
                arguments: [worktreeID.uuidString]) ?? -1
        }
    }

    /// With `auto_create_notes_enabled` on, a create makes one empty "Notes"
    /// note and opens no panel for it: no `worktree_panel` row and no
    /// surface. The note stays out of the tab order, which holds only the
    /// terminals, and a terminal keeps focus.
    @Test func creationCreatesInitialNoteWithoutAPanelWhenEnabled() async throws {
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
        #expect(try await worktreePanelRowCount(db, worktreeID: wt.id) == 0)
        #expect(try await db.panelSurface.surfaces(worktreeID: wt.id).isEmpty)

        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let order = try await db.worktrees.getTabOrder(worktreeID: wt.id)
        #expect(!order.contains(note.id))
        #expect(Set(order) == Set(terminals.map(\.id)))
        let active = try await db.worktrees.getActiveTabID(worktreeID: wt.id)
        #expect(terminals.map(\.id).contains(try #require(active)))
    }

    /// With the setting off, an ordinary create makes no note and opens no
    /// panel. A conversation carryover still makes its note, whatever the
    /// setting: `WorktreeConversationCarryoverTests` runs with it off and
    /// asserts the seeded note and that no panel opens.
    @Test func creationCreatesNoNoteWhenDisabled() async throws {
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
        #expect(try await worktreePanelRowCount(db, worktreeID: wt.id) == 0)
        #expect(try await db.panelSurface.surfaces(worktreeID: wt.id).isEmpty)
        let terminals = try await db.terminals.list(worktreeID: wt.id)
        let order = try await db.worktrees.getTabOrder(worktreeID: wt.id)
        #expect(Set(order) == Set(terminals.map(\.id)))
        let active = try await db.worktrees.getActiveTabID(worktreeID: wt.id)
        #expect(terminals.map(\.id).contains(try #require(active)))
    }

    /// Whether or not the setting makes a note, creation writes no surface
    /// and broadcasts no panel surface.
    @Test(arguments: [false, true])
    func creationWritesNoSurfaceAndBroadcastsNone(autoCreateNotes: Bool) async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        try await db.config.setAutoCreateNotes(autoCreateNotes)
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

        let expectedNoteCount: Int = autoCreateNotes ? 1 : 0
        #expect(try await db.notes.list(worktreeID: wt.id).count == expectedNoteCount)
        #expect(try await db.panelSurface.surfaces(worktreeID: wt.id).isEmpty)
        let panelBroadcasts = recorder.deltas.filter {
            if case .panelSurfaceChanged = $0 { return true }
            return false
        }
        #expect(panelBroadcasts.isEmpty)
    }

    /// A create gated on a `preSession` hook makes the note once the hook
    /// finishes, and opens no panel for it.
    @Test func preSessionGatedCreateCreatesNoteWithoutAPanelWhenEnabled() async throws {
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
        #expect(note.title == "Notes")
        #expect(try await worktreePanelRowCount(db, worktreeID: pending.id) == 0)
        #expect(try await db.panelSurface.surfaces(worktreeID: pending.id).isEmpty)
        let terminals = try await db.terminals.list(worktreeID: pending.id)
        let order = try await db.worktrees.getTabOrder(worktreeID: pending.id)
        #expect(!order.contains(note.id))
        #expect(Set(order) == Set(terminals.map(\.id)))
        let active = try await db.worktrees.getActiveTabID(worktreeID: pending.id)
        #expect(terminals.map(\.id).contains(try #require(active)))
    }

    @Test func preSessionGatedCreateCreatesNoNoteWhenDisabled() async throws {
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
        #expect(try await worktreePanelRowCount(db, worktreeID: pending.id) == 0)
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
