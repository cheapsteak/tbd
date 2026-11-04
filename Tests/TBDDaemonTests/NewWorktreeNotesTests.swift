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
/// An ordinary new worktree has no note: the side panel's Notes pill makes the
/// first one on its first click. The one note a creation makes is the
/// populated provenance note of a conversation revived on a fresh branch,
/// which `WorktreeConversationCarryoverTests` covers.
/// Design: docs/specs/2026-11-03-side-panel-toggle-pills-design.md, "Notes".
@Suite("Notes on worktree create")
struct NewWorktreeNotesTests {

    /// The worktree's `worktree_panel` rows, read raw so a malformed row
    /// counts too.
    private func worktreePanelRowCount(_ db: TBDDatabase, worktreeID: UUID) async throws -> Int {
        try await db.writerForTests.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM worktree_panel WHERE worktreeID = ?",
                arguments: [worktreeID.uuidString]) ?? -1
        }
    }

    /// An ordinary create makes no note and opens no panel: no
    /// `worktree_panel` row and no surface. The tab order holds only the
    /// terminals, and a terminal has focus.
    @Test func anOrdinaryCreateMakesNoNote() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)

        let wt = try await lifecycle.createWorktree(repoID: repo.id, skipClaude: true)

        #expect(try await db.notes.list(worktreeID: wt.id).isEmpty)
        #expect(try await worktreePanelRowCount(db, worktreeID: wt.id) == 0)
        #expect(try await db.panelSurface.surfaces(worktreeID: wt.id).isEmpty)
        let terminalIDs = try await db.terminals.list(worktreeID: wt.id).map(\.id)
        let order = try await db.worktrees.getTabOrder(worktreeID: wt.id)
        #expect(Set(order) == Set(terminalIDs))
        let active = try #require(try await db.worktrees.getActiveTabID(worktreeID: wt.id))
        #expect(terminalIDs.contains(active))
    }

    /// Creation writes no surface and broadcasts no panel surface.
    @Test func anOrdinaryCreateWritesNoSurfaceAndBroadcastsNone() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
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

        #expect(try await db.notes.list(worktreeID: wt.id).isEmpty)
        #expect(try await db.panelSurface.surfaces(worktreeID: wt.id).isEmpty)
        let panelBroadcasts = recorder.deltas.filter {
            if case .panelSurfaceChanged = $0 { return true }
            return false
        }
        #expect(panelBroadcasts.isEmpty)
    }

    /// A create gated on a `preSession` hook makes no note once the hook
    /// finishes either.
    @Test func aPreSessionGatedCreateMakesNoNote() async throws {
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
        let terminalIDs = try await db.terminals.list(worktreeID: pending.id).map(\.id)
        let order = try await db.worktrees.getTabOrder(worktreeID: pending.id)
        #expect(Set(order) == Set(terminalIDs))
        let active = try #require(try await db.worktrees.getActiveTabID(worktreeID: pending.id))
        #expect(terminalIDs.contains(active))
    }

    /// A carryover create gated on a `preSession` hook makes its provenance
    /// note once the hook finishes, with the seed as its content, and opens
    /// no panel for it.
    @Test func aPreSessionGatedCarryoverCreateMakesTheProvenanceNote() async throws {
        let (_, cleanup) = isolateTBDHome()
        defer { cleanup() }
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try TBDDatabase(inMemory: true)
        let lifecycle = makeLifecycle(db: db)
        let repo = try await makeTestRepo(db: db, tempDir: tempDir, repoDir: repoDir)
        try await installPreSessionHook(repoDir: repoDir)

        let seed = "# Revived conversation\n"
        let pending = try await lifecycle.beginCreateWorktree(repoID: repo.id)
        let completion = try await lifecycle.completeCreateWorktree(
            worktreeID: pending.id,
            skipClaude: true,
            carryover: ConversationCarryover(
                sourceSessionID: UUID().uuidString, notesSeed: seed)
        )
        guard case .preSessionPending(let phase3) = completion else {
            Issue.record("expected .preSessionPending when a preSession hook resolves")
            return
        }
        try writeMarker(worktreeID: pending.id, exitCode: 0)
        await phase3.value

        let notes = try await db.notes.list(worktreeID: pending.id)
        #expect(notes.count == 1)
        let summary = try #require(notes.first)
        #expect(summary.title == "Notes")
        let note = try #require(try await db.notes.get(id: summary.id))
        #expect(note.content == seed)
        #expect(try await worktreePanelRowCount(db, worktreeID: pending.id) == 0)
        let order = try await db.worktrees.getTabOrder(worktreeID: pending.id)
        #expect(!order.contains(summary.id))
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
