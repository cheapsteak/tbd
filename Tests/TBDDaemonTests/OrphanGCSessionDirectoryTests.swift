import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

/// The `OrphanGC` arm that reclaims `~/tbd/sessions/<claudeSessionID>/`: a
/// directory stays while a terminal row, or a closed-terminal history row in a
/// worktree that is not archived, names its session; otherwise it goes once
/// nothing in it was written within `gcGraceSeconds`. A kept directory's
/// `composer-draft.unrestored` goes 30 days after its last write.
///
/// Tier 2: a real temp tree, an in-memory database, a fixed clock. The
/// sessions base comes through the GC's own seam, so the suite never reads the
/// process-global `TBD_HOME`.
@Suite("OrphanGC reclaims session directories")
struct OrphanGCSessionDirectoryTests: ~Copyable {
    private let fm = FileManager.default
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    let home: URL

    init() {
        home = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdgcsd"), isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    private var sessionsBase: URL { home.appendingPathComponent("sessions", isDirectory: true) }

    private func makeGC(db: TBDDatabase) -> OrphanGC {
        let fixed = clock
        return OrphanGC(
            db: db, git: GitManager(),
            broadcast: { _ in },
            liveCWDsProvider: { [] },
            scratchpadBase: home.appendingPathComponent("s", isDirectory: true),
            now: { fixed },
            profileDirBase: home.appendingPathComponent("p", isDirectory: true),
            hangStackBase: home.appendingPathComponent("hs", isDirectory: true),
            processSnapshotProvider: { [] },
            holdersBase: home.appendingPathComponent("h", isDirectory: true),
            attachmentsBase: home.appendingPathComponent("a", isDirectory: true),
            remoteTranscriptsEnvironment: ["TBD_HOME": home.path],
            reposBase: home.appendingPathComponent("repos", isDirectory: true),
            sessionsBase: sessionsBase,
            devServersBase: home.appendingPathComponent("ds", isDirectory: true))
    }

    private var grace: TimeInterval { TimeInterval(Config.defaultGCGraceSeconds) }

    private func newDB() throws -> TBDDatabase { try TBDDatabase(inMemory: true) }

    /// Writes a session directory with a mod-written file and backdates the
    /// directory and its entries, so the grace window has elapsed unless the
    /// caller asks otherwise.
    @discardableResult
    private func writeSession(_ id: String, age: TimeInterval? = nil) -> String {
        let directory = sessionsBase.appendingPathComponent(id, isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let alive = directory.appendingPathComponent(SessionModFiles.aliveFileName)
        fm.createFile(atPath: alive.path, contents: Data("{}".utf8))
        stamp(alive.path, age: age ?? grace * 2)
        stamp(directory.path, age: age ?? grace * 2)
        return directory.path
    }

    private func stamp(_ path: String, age: TimeInterval) {
        let date = clock.addingTimeInterval(-age)
        try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: path)
    }

    private func writeUnrestored(in directory: String, age: TimeInterval) -> String {
        let path = "\(directory)/\(SessionModFiles.composerDraftUnrestoredFileName)"
        fm.createFile(atPath: path, contents: Data("draft".utf8))
        stamp(path, age: age)
        // The draft's own write moved the directory's dates; put them back so
        // only the file's age differs.
        stamp(directory, age: grace * 2)
        return path
    }

    private func makeWorktree(_ db: TBDDatabase, status: WorktreeStatus = .active) async throws -> Worktree {
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        return try await db.worktrees.create(
            repoID: repo.id, name: "acme-wt", branch: "acme-branch",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "acme-server", status: status)
    }

    private func addTerminal(_ db: TBDDatabase, worktree: Worktree, sessionID: String) async throws -> Terminal {
        try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            claudeSessionID: sessionID)
    }

    // MARK: - Keep

    @Test func aDirectoryNamedByATerminalRowIsKept() async throws {
        let db = try newDB()
        let worktree = try await makeWorktree(db)
        _ = try await addTerminal(db, worktree: worktree, sessionID: "sess-terminal")
        let kept = writeSession("sess-terminal")
        let orphan = writeSession("sess-orphan")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: kept))
        #expect(result.planned.contains("KEEP referenced \(kept)"))
        #expect(fm.fileExists(atPath: orphan) == false)
    }

    @Test func aDirectoryNamedByHistoryInAnActiveWorktreeIsKept() async throws {
        let db = try newDB()
        let worktree = try await makeWorktree(db)
        let terminal = try await addTerminal(db, worktree: worktree, sessionID: "sess-history")
        await db.terminalHistory.recordOnClose(terminal: terminal, capture: nil)
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "DELETE FROM terminal")
        }
        let kept = writeSession("sess-history")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: kept), "history in an active worktree did not keep it")
        #expect(result.planned.contains("KEEP referenced \(kept)"))
    }

    @Test func aDirectoryNamedOnlyByHistoryInAnArchivedWorktreeIsReclaimed() async throws {
        let db = try newDB()
        let worktree = try await makeWorktree(db)
        let terminal = try await addTerminal(db, worktree: worktree, sessionID: "sess-archived-history")
        await db.terminalHistory.recordOnClose(terminal: terminal, capture: nil)
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "DELETE FROM terminal")
        }
        try await db.worktrees.archive(id: worktree.id)
        let path = writeSession("sess-archived-history")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path) == false, "history in an archived worktree pinned it")
        #expect(result.planned.contains("REAP session-directory \(path)"))
    }

    @Test func aDirectoryNamedOnlyByArchivedClaudeSessionsIsReclaimed() async throws {
        let db = try newDB()
        let worktree = try await makeWorktree(db)
        try await db.worktrees.archive(id: worktree.id, claudeSessionIDs: ["sess-archived-list"])
        let path = writeSession("sess-archived-list")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path) == false, "archivedClaudeSessions pinned it")
        #expect(result.planned.contains("REAP session-directory \(path)"))
    }

    @Test func anUnreferencedDirectoryInsideTheGraceWindowIsKept() async throws {
        let db = try newDB()
        let young = writeSession("sess-young", age: grace - 60)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: young))
        #expect(result.planned.contains("KEEP grace \(young)"))
    }

    @Test func anUnreferencedOldDirectoryIsReclaimed() async throws {
        let db = try newDB()
        let path = writeSession("sess-old")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path) == false)
        #expect(result.planned.contains("REAP session-directory \(path)"))
        #expect(result.reaped >= 1)
    }

    // MARK: - Unrestored drafts

    @Test func anOldUnrestoredDraftIsRemovedFromAKeptDirectory() async throws {
        let db = try newDB()
        let worktree = try await makeWorktree(db)
        _ = try await addTerminal(db, worktree: worktree, sessionID: "sess-draft")
        let directory = writeSession("sess-draft")
        let draft = writeUnrestored(in: directory, age: OrphanGC.unrestoredDraftRetention + 60)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: draft) == false)
        #expect(fm.fileExists(atPath: directory), "the kept directory itself was removed")
        #expect(result.planned.contains("REAP unrestored-draft \(draft)"))
        #expect(result.reaped >= 1, "the draft removal was not counted")
    }

    @Test func aYoungUnrestoredDraftIsKept() async throws {
        let db = try newDB()
        let worktree = try await makeWorktree(db)
        _ = try await addTerminal(db, worktree: worktree, sessionID: "sess-draft")
        let directory = writeSession("sess-draft")
        let draft = writeUnrestored(in: directory, age: OrphanGC.unrestoredDraftRetention - 3600)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: draft))
        #expect(result.planned.contains("KEEP retention \(draft)"))
    }

    // MARK: - Failure, dry run, gate

    @Test func unreadableRowsSkipTheArm() async throws {
        let db = try newDB()
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "DROP TABLE terminal_history")
        }
        let path = writeSession("sess-orphan")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path), "an orphan was reclaimed with rows unreadable")
        #expect(result.planned.contains("KEEP rows-unreadable session-directories"))
    }

    @Test func aDryRunRemovesNothing() async throws {
        let db = try newDB()
        let worktree = try await makeWorktree(db)
        _ = try await addTerminal(db, worktree: worktree, sessionID: "sess-draft")
        let keptDirectory = writeSession("sess-draft")
        let draft = writeUnrestored(in: keptDirectory, age: OrphanGC.unrestoredDraftRetention + 60)
        let orphan = writeSession("sess-orphan")

        let result = await makeGC(db: db).sweep(dryRun: true)

        #expect(fm.fileExists(atPath: orphan))
        #expect(fm.fileExists(atPath: draft))
        #expect(result.planned.contains("REAP session-directory \(orphan)"))
        #expect(result.planned.contains("REAP unrestored-draft \(draft)"))
        #expect(result.reaped == 0)
    }

    @Test func nothingIsReclaimedWithGCDisabled() async throws {
        let db = try newDB()
        try await db.config.setGCEnabled(false)
        let path = writeSession("sess-orphan")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path))
        #expect(result.planned.contains { $0.contains("session-directory") } == false)
    }
}
