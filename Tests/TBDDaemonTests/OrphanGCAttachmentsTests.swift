import Foundation
import GRDB
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

// Nested under TBDHomeSerialized for the same reason the archive suite is: the
// leg walks `TBDConstants.attachmentsDir`, which resolves the process-global
// TBD_HOME. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {

/// The hourly half of the attachments reconciler pair.
///
/// Every branch fails toward KEEPING, because the two mistakes are not
/// symmetric: a leaked image is a few hundred kilobytes a later sweep still
/// finds, while a wrong reap destroys something a person staged for a message
/// they have not sent yet.
///
/// Tier 2: a real temp tree under an isolated TBD_HOME, an in-memory database,
/// a fixed clock.
@Suite("OrphanGC reclaims composer attachments")
struct OrphanGCAttachmentsTests {
    private let fm = FileManager.default
    /// The sweep's fixed reading of now. Every fixture's age is expressed
    /// against it, so nothing here depends on wall-clock time.
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    /// The fake home goes under the run's fenced scratch root, not
    /// `fm.temporaryDirectory` — `scripts/test.sh` reclaims the former even when
    /// the test process is killed, and does not fence the latter at all.
    private func isolateTBDHome() -> (URL, () -> Void) {
        let home = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdgca"))
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        let prior = setTBDHome(home.path)
        return (home, {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: home)
        })
    }

    private func makeGC(db: TBDDatabase, home: URL) -> OrphanGC {
        let fixed = clock
        return OrphanGC(
            db: db, git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: { [] },
            scratchpadBase: home.appendingPathComponent("s", isDirectory: true),
            now: { fixed },
            profileDirBase: home.appendingPathComponent("p", isDirectory: true),
            holdersBase: home.appendingPathComponent("h", isDirectory: true))
    }

    /// Writes one attachment and backdates it, so the 14-day floor has elapsed
    /// against this suite's fixed clock unless the caller asks otherwise.
    @discardableResult
    private func stage(_ worktreeID: UUID, ageDays: Double = 30) -> String {
        let path = TBDConstants.attachmentPath(
            worktreeID: worktreeID, attachmentID: UUID())
        try? fm.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        let stamp = clock.addingTimeInterval(-ageDays * 86_400)
        try? fm.setAttributes(
            [.creationDate: stamp, .modificationDate: stamp], ofItemAtPath: path)
        return path
    }

    /// A live worktree row whose id this suite chooses, so the attachments
    /// directory it stages can be named after it.
    private func insertWorktree(_ db: TBDDatabase, id: UUID) async throws {
        try await db.writerForTests.write { conn in
            try WorktreeRecord(from: Worktree(
                id: id, repoID: nil, name: "wt", displayName: "wt", branch: "",
                path: "/tmp/tbd-nonexistent-\(id.uuidString)",
                status: .active, tmuxServer: "tbd-test", sortOrder: 1)).insert(conn)
        }
    }

    // MARK: - Keeps

    @Test func aLiveWorktreesAttachmentsAreKept() async throws {
        let (home, restore) = isolateTBDHome()
        defer { restore() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        let worktreeID = UUID()
        try await insertWorktree(db, id: worktreeID)
        let path = stage(worktreeID)

        let result = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: path))
        #expect(result.planned.contains { $0.hasPrefix("KEEP live-worktree") })
    }

    /// An archived row is still a row: the archive path's own unlink is what
    /// handles it, so this leg must read every status rather than only `.active`
    /// and reap a directory out from under a worktree somebody can still revive.
    @Test func anArchivedWorktreesAttachmentsAreKept() async throws {
        let (home, restore) = isolateTBDHome()
        defer { restore() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        let worktreeID = UUID()
        try await db.writerForTests.write { conn in
            try WorktreeRecord(from: Worktree(
                id: worktreeID, repoID: nil, name: "wt", displayName: "wt", branch: "",
                path: "/tmp/tbd-nonexistent-\(worktreeID.uuidString)",
                status: .archived, tmuxServer: "tbd-test", sortOrder: 1)).insert(conn)
        }
        let path = stage(worktreeID)

        let result = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: path))
        #expect(result.planned.contains { $0.hasPrefix("KEEP live-worktree") })
    }

    /// A directory whose name is not a UUID was put there by a human or by a
    /// future feature. Classifying it under a rule that never considered it is
    /// exactly the mistake this leg must not make.
    @Test func aNonUUIDDirectoryIsKept() async throws {
        let (home, restore) = isolateTBDHome()
        defer { restore() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        let stray = TBDConstants.attachmentsDir.appendingPathComponent("notes-i-kept")
        try fm.createDirectory(at: stray, withIntermediateDirectories: true)
        fm.createFile(atPath: stray.appendingPathComponent("x.png").path, contents: Data())

        let result = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: stray.path))
        #expect(result.planned.contains { $0.hasPrefix("KEEP not-a-worktree-id") })
    }

    /// The floor: an image staged for a message somebody has not sent yet.
    @Test func anOrphanYoungerThanTheFloorIsKept() async throws {
        let (home, restore) = isolateTBDHome()
        defer { restore() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        let path = stage(UUID(), ageDays: 3)

        let result = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: path))
        #expect(result.planned.contains { $0.hasPrefix("KEEP younger-than-floor") })
    }

    /// **Skip the whole leg on a failed database read**, never read an empty row
    /// list as "no worktree is live" and reap everything.
    ///
    /// The worktree table is dropped rather than the whole database closed,
    /// deliberately: closing would fail `sweep`'s own opening `config.get()` and
    /// the test would pass without this leg ever running. Dropping one table
    /// leaves every earlier read working and fails exactly the read under test.
    @Test func anUnreadableWorktreeListSkipsTheLeg() async throws {
        let (home, restore) = isolateTBDHome()
        defer { restore() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        let path = stage(UUID())

        try await db.writerForTests.write { conn in
            try conn.execute(sql: "DROP TABLE worktree")
        }
        let result = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: path), "a failed read must reap nothing")
        #expect(result.planned.contains("KEEP rows-unreadable attachments"))
    }

    // MARK: - Reaps

    @Test func anOldOrphanIsReaped() async throws {
        let (home, restore) = isolateTBDHome()
        defer { restore() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setTranscriptComposerEnabled(true)
        let orphan = UUID()
        let path = stage(orphan)

        let result = await makeGC(db: db, home: home).sweep()

        #expect(!fm.fileExists(atPath: path))
        #expect(!fm.fileExists(
            atPath: TBDConstants.attachmentsDir(worktreeID: orphan).path))
        #expect(result.planned.contains { $0.hasPrefix("REAP attachments") })
        #expect(result.reaped >= 1)
    }

    // MARK: - The flag

    /// With the flag off the leg does nothing in a real sweep — the whole
    /// feature is inert, and a sweep that reclaimed for it would be acting on a
    /// feature nobody turned on.
    @Test func theFlagOffLeavesEverythingAlone() async throws {
        let (home, restore) = isolateTBDHome()
        defer { restore() }
        let db = try TBDDatabase(inMemory: true)
        let path = stage(UUID())

        let result = await makeGC(db: db, home: home).sweep()

        #expect(fm.fileExists(atPath: path))
        #expect(!result.planned.contains { $0.contains("attachments") })
    }

    /// `dryRun` bypasses the flag, exactly as it bypasses `gcEnabled`: someone
    /// deciding whether to turn a default-off flag on needs to see what it would
    /// reclaim first. It plans and touches nothing.
    @Test func aDryRunPlansWithTheFlagOffAndUnlinksNothing() async throws {
        let (home, restore) = isolateTBDHome()
        defer { restore() }
        let db = try TBDDatabase(inMemory: true)
        let orphan = UUID()
        let path = stage(orphan)

        let result = await makeGC(db: db, home: home).sweep(dryRun: true)

        #expect(fm.fileExists(atPath: path), "a dry run must never touch disk")
        #expect(result.planned.contains { $0.hasPrefix("REAP attachments") })
        #expect(result.reaped == 0)
    }
}

}
