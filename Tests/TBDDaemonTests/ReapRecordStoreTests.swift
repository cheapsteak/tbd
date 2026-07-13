import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

@Suite("ReapRecordStore")
struct ReapRecordStoreTests {
    @Test func insertListGetMarkRestored() async throws {
        let db = try TBDDatabase(inMemory: true)
        let rec = ReapRecord(kind: .agentWorktree, repoPath: "/r", worktreePath: "/r/.claude/worktrees/agent-x",
                             branch: "b", headSHA: "abc", snapshotRef: "refs/tbd/snapshots/x", apparentBytes: 42)
        try await db.reapRecords.insert(rec)
        let listed = try await db.reapRecords.list(repoPath: "/r")
        // GRDB persists Date as a "yyyy-MM-dd HH:mm:ss.SSS" string (millisecond
        // precision), so a round-tripped Date() is never bit-identical to the
        // in-memory value — compare every field exactly except reapedAt, which
        // gets a millisecond tolerance.
        #expect(listed.count == 1)
        let got = try #require(listed.first)
        #expect(got.id == rec.id)
        #expect(got.kind == rec.kind)
        #expect(got.repoPath == rec.repoPath)
        #expect(got.worktreePath == rec.worktreePath)
        #expect(got.branch == rec.branch)
        #expect(got.headSHA == rec.headSHA)
        #expect(got.snapshotRef == rec.snapshotRef)
        #expect(got.apparentBytes == rec.apparentBytes)
        #expect(abs(got.reapedAt.timeIntervalSince1970 - rec.reapedAt.timeIntervalSince1970) < 0.01)
        #expect(got.restoredAt == nil)
        #expect(try await db.reapRecords.list(repoPath: "/other").isEmpty)
        try await db.reapRecords.markRestored(id: rec.id, at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try await db.reapRecords.get(id: rec.id)?.restoredAt != nil)
    }
    @Test func unrestoredOlderThanFiltersRestoredMissingSnapshotAndRecent() async throws {
        let db = try TBDDatabase(inMemory: true)
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)

        let eligible = ReapRecord(
            kind: .scratchpad, repoPath: "", worktreePath: "/scratch/old",
            snapshotRef: "refs/tbd/snapshots/old",
            reapedAt: cutoff.addingTimeInterval(-3600))
        let alreadyRestored = ReapRecord(
            kind: .scratchpad, repoPath: "", worktreePath: "/scratch/restored",
            snapshotRef: "refs/tbd/snapshots/restored",
            reapedAt: cutoff.addingTimeInterval(-3600),
            restoredAt: cutoff.addingTimeInterval(-1800))
        let noSnapshot = ReapRecord(
            kind: .scratchpad, repoPath: "", worktreePath: "/scratch/no-snapshot",
            reapedAt: cutoff.addingTimeInterval(-3600))
        let tooRecent = ReapRecord(
            kind: .scratchpad, repoPath: "", worktreePath: "/scratch/recent",
            snapshotRef: "refs/tbd/snapshots/recent",
            reapedAt: cutoff.addingTimeInterval(3600))

        for rec in [eligible, alreadyRestored, noSnapshot, tooRecent] {
            try await db.reapRecords.insert(rec)
        }

        let result = try await db.reapRecords.unrestoredOlderThan(cutoff)
        #expect(result.map(\.id) == [eligible.id])
    }

    @Test func gcConfigDefaultsOnAndSetterFlips() async throws {
        let db = try TBDDatabase(inMemory: true)
        #expect(try await db.config.get().gcEnabled == true)
        #expect(try await db.config.get().gcGraceSeconds == 3600)
        try await db.config.setGCEnabled(false)
        #expect(try await db.config.get().gcEnabled == false)
    }
}
