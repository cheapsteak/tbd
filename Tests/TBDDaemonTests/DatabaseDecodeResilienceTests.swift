import Testing
import Foundation
import GRDB
@testable import TBDDaemonLib
@testable import TBDShared

/// Regression coverage for the 2026-07-06 crash-loop: a `notification` row with
/// `type = "limit_reached"` (at the time, a `NotificationType` case only
/// present on an unmerged branch) made `toModel()`'s force-unwrap crash the
/// daemon on startup, because `notifications.list` decodes the whole result
/// set. `limit_reached` has since merged as a real case (PR #341), so these
/// tests plant a synthetic never-valid rawValue instead. They assert the
/// failable `toModel()` SKIPS the offending row (no throw/crash) while valid
/// rows in the same fetch are unaffected.
@Suite("Database Decode Resilience Tests")
struct DatabaseDecodeResilienceTests {

    // MARK: - Helpers

    private func makeWorktree(_ db: TBDDatabase, name: String) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/decode-test-\(UUID().uuidString)",
            displayName: "test",
            defaultBranch: "main"
        )
        return try await db.worktrees.create(
            repoID: repo.id,
            name: name,
            branch: "tbd/\(name)",
            path: "/tmp/decode-test/.tbd/worktrees/\(name)",
            tmuxServer: "tbd-test"
        )
    }

    /// Raw UPDATE bypassing the type-safe insert path so we can plant a value
    /// the model layer would never write itself.
    private func rawUpdate(_ db: TBDDatabase, sql: String, _ args: [String]) async throws {
        try await db.writerForTests.write { conn in
            try conn.execute(sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Like `rawUpdate` but with foreign-key enforcement disabled for the plant,
    /// so we can corrupt an FK column (e.g. `worktreeID`) to a non-UUID string —
    /// simulating exactly the "out-of-band corruption" (manual sqlite edit / a
    /// future schema regression) that the failable `toModel()` UUID guards defend
    /// against. Runs outside a transaction (autocommit) so `PRAGMA foreign_keys`
    /// takes effect, and restores enforcement afterward.
    private func rawUpdateNoFK(_ db: TBDDatabase, sql: String, _ args: [String]) async throws {
        try await db.writerForTests.writeWithoutTransaction { conn in
            try conn.execute(sql: "PRAGMA foreign_keys = OFF")
            defer { try? conn.execute(sql: "PRAGMA foreign_keys = ON") }
            try conn.execute(sql: sql, arguments: StatementArguments(args))
        }
    }

    // MARK: - NotificationStore

    @Test("valid notification row decodes and is returned")
    func validNotificationDecodes() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-valid")
        _ = try await db.notifications.create(worktreeID: wt.id, type: .error)

        let unread = try await db.notifications.unread(worktreeID: wt.id)
        #expect(unread.count == 1)
        #expect(unread.first?.type == .error)

        let summary = try await db.notifications.unreadSummaryByWorktree()
        #expect(summary[wt.id]?.type == .error)
    }

    @Test("unknown notification type is skipped by unreadSummaryByWorktree (RPC path)")
    func unknownTypeSkippedInSummary() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtBad = try await makeWorktree(db, name: "wt-bad-type")
        let wtGood = try await makeWorktree(db, name: "wt-good-type")

        let bad = try await db.notifications.create(worktreeID: wtBad.id, type: .responseComplete)
        // Plant an enum rawValue NotificationType can never gain (synthetic,
        // test-only) so this stays unknown even as real cases are added.
        try await rawUpdate(db, sql: "UPDATE notification SET type = ? WHERE id = ?",
                            ["test_only_unknown_type", bad.id.uuidString])
        _ = try await db.notifications.create(worktreeID: wtGood.id, type: .error)

        // Must not throw/crash even though one row has an unknown type.
        let summary = try await db.notifications.unreadSummaryByWorktree()
        #expect(summary[wtBad.id] == nil)          // bad row skipped
        #expect(summary[wtGood.id]?.type == .error) // valid row unaffected
    }

    @Test("unknown notification type is skipped by unread() path")
    func unknownTypeSkippedInUnread() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-unread-mixed")

        _ = try await db.notifications.create(worktreeID: wt.id, type: .error)
        let bad = try await db.notifications.create(worktreeID: wt.id, type: .responseComplete)
        try await rawUpdate(db, sql: "UPDATE notification SET type = ? WHERE id = ?",
                            ["future_type", bad.id.uuidString])

        let unread = try await db.notifications.unread(worktreeID: wt.id)
        #expect(unread.count == 1)            // bad row skipped
        #expect(unread.first?.type == .error) // valid row unaffected
    }

    @Test("malformed notification id is skipped; valid rows unaffected")
    func malformedNotificationIDSkipped() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtBad = try await makeWorktree(db, name: "wt-bad-id")
        let wtGood = try await makeWorktree(db, name: "wt-good-id")

        let bad = try await db.notifications.create(worktreeID: wtBad.id, type: .responseComplete)
        try await rawUpdate(db, sql: "UPDATE notification SET id = ? WHERE id = ?",
                            ["not-a-uuid", bad.id.uuidString])
        _ = try await db.notifications.create(worktreeID: wtGood.id, type: .error)

        let summary = try await db.notifications.unreadSummaryByWorktree()
        #expect(summary[wtBad.id] == nil)           // malformed-id row skipped
        #expect(summary[wtGood.id]?.type == .error) // valid row unaffected
    }

    // MARK: - WorktreeStore

    @Test("unknown worktree status falls back to .active; worktree still returned")
    func unknownWorktreeStatusFallsBackToDefault() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/decode-wt-\(UUID().uuidString)",
            displayName: "test",
            defaultBranch: "main"
        )
        let good = try await db.worktrees.create(
            repoID: repo.id, name: "good", branch: "b-good",
            path: "/tmp/decode-wt/good", tmuxServer: "srv"
        )
        let bad = try await db.worktrees.create(
            repoID: repo.id, name: "bad", branch: "b-bad",
            path: "/tmp/decode-wt/bad", tmuxServer: "srv"
        )
        // Plant a WorktreeStatus rawValue this build does not recognize.
        try await rawUpdate(db, sql: "UPDATE worktree SET status = ? WHERE id = ?",
                            ["future_status", bad.id.uuidString])

        // Unknown status must NOT drop the row (dropping could orphan its
        // terminals/tmux); it falls back to the safe `.active` default.
        let listed = try await db.worktrees.list(repoID: repo.id)
        let ids = listed.map(\.id)
        #expect(ids.contains(bad.id))    // bad row preserved, not dropped
        #expect(ids.contains(good.id))   // valid row unaffected
        #expect(listed.first { $0.id == bad.id }?.status == .active) // defaulted
    }

    @Test("malformed worktree id is skipped by list; valid worktree still returned")
    func malformedWorktreeIDSkipped() async throws {
        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(
            path: "/tmp/decode-wt-\(UUID().uuidString)",
            displayName: "test",
            defaultBranch: "main"
        )
        let good = try await db.worktrees.create(
            repoID: repo.id, name: "good-id", branch: "b-good",
            path: "/tmp/decode-wt/good-id", tmuxServer: "srv"
        )
        let bad = try await db.worktrees.create(
            repoID: repo.id, name: "bad-id", branch: "b-bad",
            path: "/tmp/decode-wt/bad-id", tmuxServer: "srv"
        )
        // A malformed primary-key UUID is genuinely unrecoverable — the row must
        // be dropped (this is the DROP branch that remains after status now
        // falls back to a default).
        try await rawUpdate(db, sql: "UPDATE worktree SET id = ? WHERE id = ?",
                            ["not-a-uuid", bad.id.uuidString])

        // Must not throw/crash even though one row has a malformed id.
        let listed = try await db.worktrees.list(repoID: repo.id)
        let ids = listed.map(\.id)
        #expect(!ids.contains(bad.id))   // malformed-id row dropped
        #expect(ids.contains(good.id))   // valid row unaffected
    }

    // MARK: - NoteStore

    @Test("NoteStore.update throws when its row's id was corrupted out-of-band")
    func noteUpdateThrowsOnMalformedID() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wt = try await makeWorktree(db, name: "wt-note")
        let note = try await db.notes.create(worktreeID: wt.id)

        // Corrupt the primary key out-of-band, then call update() for the original
        // id. This exercises update()'s error path: `fetchOne(key:)` no longer
        // finds the renamed row, so it throws. (`id` has no FK, so a plain raw
        // UPDATE suffices.)
        //
        // Note on the deeper `toModel()`-nil guard inside update(): it is defensive
        // dead code under the DB's invariants — reaching it needs `fetchOne` to
        // succeed (valid id) AND `record.update` to commit (FK-valid worktreeID, a
        // real UUID) yet `toModel()` to still return nil (a non-UUID field), which
        // is self-contradictory. So the reachable throw here is the "Note not
        // found" guard; either way update() surfaces the corruption as a throw
        // rather than returning a bogus model.
        try await rawUpdate(db, sql: "UPDATE note SET id = ? WHERE id = ?",
                            ["not-a-uuid", note.id.uuidString])

        await #expect(throws: (any Error).self) {
            _ = try await db.notes.update(id: note.id, title: "renamed")
        }
    }

    // MARK: - NotificationStore (malformed worktreeID)

    @Test("malformed notification worktreeID is skipped; valid rows unaffected")
    func malformedNotificationWorktreeIDSkipped() async throws {
        let db = try TBDDatabase(inMemory: true)
        let wtBad = try await makeWorktree(db, name: "wt-bad-wtid")
        let wtGood = try await makeWorktree(db, name: "wt-good-wtid")

        let bad = try await db.notifications.create(worktreeID: wtBad.id, type: .responseComplete)
        // Corrupt the worktreeID column so the second UUID guard in toModel fires.
        // Needs FK enforcement off — worktreeID references worktree.id.
        try await rawUpdateNoFK(db, sql: "UPDATE notification SET worktreeID = ? WHERE id = ?",
                                ["not-a-uuid", bad.id.uuidString])
        _ = try await db.notifications.create(worktreeID: wtGood.id, type: .error)

        let unreadBad = try await db.notifications.unread(worktreeID: wtBad.id)
        #expect(unreadBad.isEmpty)                  // malformed-worktreeID row skipped

        let summary = try await db.notifications.unreadSummaryByWorktree()
        #expect(summary[wtBad.id] == nil)           // absent from summary
        #expect(summary[wtGood.id]?.type == .error) // valid row unaffected
    }
}
