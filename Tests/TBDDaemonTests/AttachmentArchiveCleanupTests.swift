import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

// Nested under TBDHomeSerialized: this walks `TBDConstants.attachmentsDir`,
// which resolves from the process-global TBD_HOME. See TBDHomeSerializedSuites.swift.
extension TBDHomeSerialized {

/// The archive-time half of the attachments reconciler pair.
///
/// Best effort, and deliberately so: a revived worktree does not get its images
/// back, and the hourly sweep is what covers every path this misses.
@Suite("attachments are reclaimed when a worktree is removed")
struct AttachmentArchiveCleanupTests {
    private let fm = FileManager.default

    /// The fake home goes under the run's fenced scratch root, not
    /// `fm.temporaryDirectory` — `scripts/test.sh` reclaims the former even when
    /// the test process is killed, and does not fence the latter at all.
    private func isolateTBDHome() -> (URL, () -> Void) {
        let home = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdatt"))
        try? fm.createDirectory(at: home, withIntermediateDirectories: true)
        let prior = setTBDHome(home.path)
        return (home, {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: home)
        })
    }

    private func stageAttachment(_ worktreeID: UUID) -> String {
        let path = TBDConstants.attachmentPath(
            worktreeID: worktreeID, attachmentID: UUID())
        try? fm.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        return path
    }

    @Test func removingAWorktreeUnlinksItsAttachments() async throws {
        let (_, restore) = isolateTBDHome()
        defer { restore() }
        let db = try TBDDatabase(inMemory: true)
        let worktreeID = UUID()
        let path = stageAttachment(worktreeID)
        #expect(fm.fileExists(atPath: path))

        let gc = OrphanGC(db: db, git: GitManager(), broadcast: { _ in })
        await gc.removedWorktreeCleanup(
            worktreeID: worktreeID,
            worktreePath: "/tmp/gone-\(UUID().uuidString)",
            repoPath: "/tmp/repo")

        #expect(!fm.fileExists(atPath: path))
        #expect(!fm.fileExists(
            atPath: TBDConstants.attachmentsDir(worktreeID: worktreeID).path))
    }

    /// The master switch governs ALL GC deletion, including this event-driven
    /// path — one toggle covers every collector.
    @Test func gcDisabledLeavesThemAlone() async throws {
        let (_, restore) = isolateTBDHome()
        defer { restore() }
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let worktreeID = UUID()
        let path = stageAttachment(worktreeID)

        let gc = OrphanGC(db: db, git: GitManager(), broadcast: { _ in })
        await gc.removedWorktreeCleanup(
            worktreeID: worktreeID,
            worktreePath: "/tmp/gone-\(UUID().uuidString)",
            repoPath: "/tmp/repo")

        #expect(fm.fileExists(atPath: path))
    }

    /// Another worktree's images are not this worktree's business.
    @Test func aSiblingWorktreesAttachmentsSurvive() async throws {
        let (_, restore) = isolateTBDHome()
        defer { restore() }
        let db = try TBDDatabase(inMemory: true)
        let removed = UUID()
        let sibling = UUID()
        _ = stageAttachment(removed)
        let survivor = stageAttachment(sibling)

        let gc = OrphanGC(db: db, git: GitManager(), broadcast: { _ in })
        await gc.removedWorktreeCleanup(
            worktreeID: removed,
            worktreePath: "/tmp/gone-\(UUID().uuidString)",
            repoPath: "/tmp/repo")

        #expect(fm.fileExists(atPath: survivor))
    }
}

}
