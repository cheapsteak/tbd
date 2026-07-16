import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Startup sweep that migrates legacy `claude_settings_overlay` column values
/// (v53, PR #452) to the file-backed `~/tbd/repos/<repoID>/claude-settings.json`.
/// Uses the environment-dict injection seam (TBD_HOME → tmp dir) — no setenv.
@Suite("claude_settings_overlay column → file sweep")
struct ClaudeSettingsOverlaySweepTests {

    private func makeTmpHome() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-cso-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func setColumn(_ db: TBDDatabase, repoID: UUID, fragment: String) async throws {
        try await db.repos.writer.write { db in
            try db.execute(
                sql: "UPDATE repo SET claude_settings_overlay = ? WHERE id = ?",
                arguments: [fragment, repoID.uuidString]
            )
        }
    }

    private func columnValue(_ db: TBDDatabase, repoID: UUID) async throws -> String? {
        try await db.repos.writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT claude_settings_overlay FROM repo WHERE id = ?",
                arguments: [repoID.uuidString]
            )
        }
    }

    @Test func columnValueWritesFileAndNullsColumn() async throws {
        let tmp = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let env = ["TBD_HOME": tmp.path]

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/cso-sweep-1", displayName: "s1", defaultBranch: "main")
        let fragment = #"{"skillOverrides":{"x":"off"}}"#
        try await setColumn(db, repoID: repo.id, fragment: fragment)

        await db.repos.sweepClaudeSettingsOverlayColumnToFiles(environment: env)

        let path = TBDConstants.claudeSettingsOverlayPath(repoID: repo.id, environment: env)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == fragment)
        #expect(try await columnValue(db, repoID: repo.id) == nil)

        // Idempotent — a second run is a no-op and leaves the file intact.
        await db.repos.sweepClaudeSettingsOverlayColumnToFiles(environment: env)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == fragment)
    }

    @Test func existingFileWinsButColumnStillNulled() async throws {
        let tmp = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let env = ["TBD_HOME": tmp.path]

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/cso-sweep-2", displayName: "s2", defaultBranch: "main")
        try await setColumn(db, repoID: repo.id, fragment: #"{"fromColumn":true}"#)

        // Pre-existing overlay file — the sweep must NOT overwrite it.
        let path = TBDConstants.claudeSettingsOverlayPath(repoID: repo.id, environment: env)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let existing = #"{"fromFile":true}"#
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        await db.repos.sweepClaudeSettingsOverlayColumnToFiles(environment: env)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == existing)
        #expect(try await columnValue(db, repoID: repo.id) == nil)
    }

    @Test func nullColumnIsNoOp() async throws {
        let tmp = try makeTmpHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let env = ["TBD_HOME": tmp.path]

        let db = try TBDDatabase(inMemory: true)
        let repo = try await db.repos.create(path: "/tmp/cso-sweep-3", displayName: "s3", defaultBranch: "main")

        await db.repos.sweepClaudeSettingsOverlayColumnToFiles(environment: env)

        let path = TBDConstants.claudeSettingsOverlayPath(repoID: repo.id, environment: env)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try await columnValue(db, repoID: repo.id) == nil)
    }
}
