import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

/// The periodic half of the remote-transcript cache reconciler: the leg that
/// reclaims `~/tbd/remote-transcripts/<provider>/<session>/` once TBD no longer
/// tracks the session — no undismissed `remote_session` row and no unarchived
/// `worktree` row — and nothing has written to it within `gcGraceSeconds`.
///
/// Tier 2: a real temp tree, an in-memory database, a fixed clock. The cache
/// root comes through the leg's own environment seam, and every other base the
/// sweep walks is pointed inside the same temp home, so this suite never reads
/// the process-global `TBD_HOME` and needs no `TBDHomeSerialized` nesting.
///
/// The session ids below all need escaping (`/`, `.`, `%`, a space), so a leg
/// that compared rows against unescaped names — or escaped them differently
/// from `TBDConstants` — reaps a tracked session's cache and fails the keep
/// tests.
@Suite("OrphanGC reclaims remote transcript caches")
struct OrphanGCRemoteTranscriptCacheTests: ~Copyable {
    private let fm = FileManager.default
    /// The sweep's fixed reading of now. Every fixture's age is expressed
    /// against it, so nothing here depends on wall-clock time.
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let provider = "agent.box"
    let home: URL

    init() {
        home = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdgcrt"), isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    private var environment: [String: String] { ["TBD_HOME": home.path] }

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
            modelProxyBase: home.appendingPathComponent("mp", isDirectory: true),
            streamsBase: home.appendingPathComponent("st", isDirectory: true),
            attachmentsBase: home.appendingPathComponent("a", isDirectory: true),
            remoteTranscriptsEnvironment: environment)
    }

    /// The grace window the sweep reads from `config.gcGraceSeconds`, at its
    /// shipped default.
    private var grace: TimeInterval { TimeInterval(Config.defaultGCGraceSeconds) }

    /// Writes a cache for the session at the path `TBDConstants` gives it and
    /// backdates the directory and its files, so the grace window has elapsed
    /// against this suite's fixed clock unless the caller asks otherwise.
    @discardableResult
    private func writeCache(sessionID: String, age: TimeInterval? = nil) -> String {
        let directory = TBDConstants.remoteTranscriptDir(
            provider: provider, sessionID: sessionID, environment: environment)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent(TBDConstants.remoteTranscriptFileName)
        let state = directory.appendingPathComponent(TBDConstants.remoteTranscriptStateFileName)
        fm.createFile(atPath: transcript.path, contents: Data(#"{"type":"user"}"#.utf8))
        fm.createFile(atPath: state.path, contents: Data(#"{"length":15,"generation":0}"#.utf8))
        let stamp = clock.addingTimeInterval(-(age ?? grace * 2))
        for path in [transcript.path, state.path, directory.path] {
            try? fm.setAttributes([.creationDate: stamp, .modificationDate: stamp], ofItemAtPath: path)
        }
        return directory.path
    }

    private func newDB() throws -> TBDDatabase { try TBDDatabase(inMemory: true) }

    // MARK: - Reclaim

    /// **The discriminating sweep test.** A cache no row refers to, untouched
    /// for longer than the grace window, is gone after one sweep.
    @Test func anOldCacheNoRowRefersToIsReclaimed() async throws {
        let db = try newDB()
        let path = writeCache(sessionID: "gone/../session 1.%2F")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path) == false, "\(path) survived the sweep")
        #expect(result.planned.contains("REAP remote-transcript-cache \(path)"))
        #expect(result.reaped >= 1)
    }

    /// `dryRun` reports the same reclaim and removes nothing.
    @Test func aDryRunReportsTheReclaimButKeepsTheDirectory() async throws {
        let db = try newDB()
        let path = writeCache(sessionID: "gone/../session 1.%2F")

        let result = await makeGC(db: db).sweep(dryRun: true)

        #expect(fm.fileExists(atPath: path), "a dry run removed \(path)")
        #expect(result.planned.contains("REAP remote-transcript-cache \(path)"))
    }

    /// The off branch of `gcEnabled`: the same fixture the reclaim test removes
    /// is left alone and not even planned.
    @Test func nothingIsReclaimedWithGCDisabled() async throws {
        let db = try newDB()
        try await db.config.setGCEnabled(false)
        let path = writeCache(sessionID: "gone/../session 1.%2F")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path), "\(path) was reclaimed with gcEnabled off")
        #expect(result.planned.contains { $0.contains("remote-transcript-cache") } == false)
    }

    // MARK: - Keep

    /// An unarchived worktree row carrying the session keeps its cache,
    /// however old, and an unrelated orphan beside it is still reclaimed — so
    /// the keep is the row's doing, not a leg that reaps nothing.
    @Test func anUnarchivedWorktreeRowKeepsItsSessionsCache() async throws {
        let db = try newDB()
        let sessionID = "lane/with.dots %"
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        _ = try await db.worktrees.createRemote(
            repoID: repo.id, name: "acme-remote", branch: "acme-branch",
            provider: provider, sessionID: sessionID, status: .active)
        let kept = writeCache(sessionID: sessionID)
        let orphan = writeCache(sessionID: "orphan")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: kept), "an unarchived worktree row's cache was reclaimed")
        #expect(result.planned.contains("KEEP tracked-session \(kept)"))
        #expect(fm.fileExists(atPath: orphan) == false)
    }

    /// An old cache whose only row is an archived lane is reclaimed: archiving
    /// keeps the worktree row, so a sweep that waited for rows to disappear
    /// would never reclaim it.
    @Test func anOldCacheWhoseOnlyRowIsAnArchivedLaneIsReclaimed() async throws {
        let db = try newDB()
        let sessionID = "deleted/../lane"
        let repo = try await db.repos.create(
            path: "/tmp/acme-\(UUID().uuidString)", displayName: "acme", defaultBranch: "main")
        _ = try await db.worktrees.createRemote(
            repoID: repo.id, name: "acme-remote", branch: "acme-branch",
            provider: provider, sessionID: sessionID, status: .archived)
        let path = writeCache(sessionID: sessionID)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path) == false, "an archived lane pinned its cache")
        #expect(result.planned.contains("REAP remote-transcript-cache \(path)"))
    }

    /// An undismissed mirror row keeps its cache.
    @Test func anUndismissedRemoteSessionRowKeepsItsSessionsCache() async throws {
        let db = try newDB()
        let sessionID = "mirror/../x.y"
        _ = try await db.remoteSessions.applySnapshot(
            provider: provider,
            sessions: [RemoteSessionPayload(id: sessionID, state: .running)],
            now: clock)
        let kept = writeCache(sessionID: sessionID)
        let orphan = writeCache(sessionID: "orphan")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: kept), "an undismissed mirror row's cache was reclaimed")
        #expect(result.planned.contains("KEEP tracked-session \(kept)"))
        #expect(fm.fileExists(atPath: orphan) == false)
    }

    /// An old cache whose only row is dismissed is reclaimed: dismissing keeps
    /// the row with `dismissed = 1`, so a dismiss whose eager removal failed
    /// is reclaimed here.
    @Test func anOldCacheWhoseOnlyRowIsDismissedIsReclaimed() async throws {
        let db = try newDB()
        let sessionID = "dismissed.one"
        _ = try await db.remoteSessions.applySnapshot(
            provider: provider,
            sessions: [RemoteSessionPayload(id: sessionID, state: .running)],
            now: clock)
        _ = try await db.remoteSessions.dismiss(provider: provider, sessionID: sessionID)
        let path = writeCache(sessionID: sessionID)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path) == false, "a dismissed row pinned its cache")
        #expect(result.planned.contains("REAP remote-transcript-cache \(path)"))
    }

    /// An undismissed `gone` mirror row — a session the provider stopped
    /// reporting — is still tracked, and keeps its cache.
    @Test func anUndismissedGoneRowKeepsItsSessionsCache() async throws {
        let db = try newDB()
        let sessionID = "gone/one"
        _ = try await db.remoteSessions.applySnapshot(
            provider: provider,
            sessions: [RemoteSessionPayload(id: sessionID, state: .running)],
            now: clock)
        #expect(try await db.remoteSessions.markGone(provider: provider, sessionID: sessionID))
        let kept = writeCache(sessionID: sessionID)
        let orphan = writeCache(sessionID: "orphan")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: kept), "an undismissed gone row's cache was reclaimed")
        #expect(result.planned.contains("KEEP tracked-session \(kept)"))
        #expect(fm.fileExists(atPath: orphan) == false)
    }

    /// The same `gone` session once dismissed is no longer tracked.
    @Test func aDismissedGoneRowDoesNotKeepItsCache() async throws {
        let db = try newDB()
        let sessionID = "gone/dismissed"
        _ = try await db.remoteSessions.applySnapshot(
            provider: provider,
            sessions: [RemoteSessionPayload(id: sessionID, state: .running)],
            now: clock)
        #expect(try await db.remoteSessions.markGone(provider: provider, sessionID: sessionID))
        _ = try await db.remoteSessions.dismiss(provider: provider, sessionID: sessionID)
        let path = writeCache(sessionID: sessionID)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path) == false, "a dismissed gone row pinned its cache")
        #expect(result.planned.contains("REAP remote-transcript-cache \(path)"))
    }

    /// Rows that cannot be read skip the whole leg rather than reading as
    /// "nothing is referenced".
    @Test func unreadableRowsSkipTheLeg() async throws {
        let db = try newDB()
        try await db.writerForTests.write { conn in
            try conn.execute(sql: "DROP TABLE remote_session")
        }
        let path = writeCache(sessionID: "orphan")

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path), "an orphan was reclaimed with rows unreadable")
        #expect(result.planned.contains("KEEP rows-unreadable remote-transcript-caches"))
    }

    /// A directory whose contents cannot be listed has no readable age, and is
    /// kept rather than guessed at.
    @Test func aDirectoryWhoseAgeCannotBeReadIsKept() async throws {
        let db = try newDB()
        let path = writeCache(sessionID: "unreadable")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path))
        #expect(result.planned.contains("KEEP unknown-age \(path)"))
    }

    /// An orphan written to within `gcGraceSeconds` is kept: a sync that raced
    /// a dismiss must not lose its file mid-write.
    @Test func anOrphanWrittenWithinTheGraceWindowIsKept() async throws {
        let db = try newDB()
        let young = writeCache(sessionID: "raced/dismiss", age: grace - 60)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: young), "a cache inside the grace window was reclaimed")
        #expect(result.planned.contains("KEEP grace \(young)"))
    }

    /// The window is the configured `gcGraceSeconds`, not a constant of the
    /// leg's own: widened, it keeps a cache the default window would reclaim.
    @Test func theGraceWindowFollowsTheConfig() async throws {
        let db = try newDB()
        try await db.writerForTests.write { conn in
            try conn.execute(
                sql: "UPDATE config SET gc_grace_seconds = ?",
                arguments: [Config.defaultGCGraceSeconds * 4])
        }
        let path = writeCache(sessionID: "wide/window", age: grace * 2)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path), "a cache inside the configured window was reclaimed")
        #expect(result.planned.contains("KEEP grace \(path)"))
    }

    /// One freshly written file makes the whole directory young, even when the
    /// directory and its other file are old: an append touches only the
    /// transcript.
    @Test func aRecentAppendKeepsAnOtherwiseOldDirectory() async throws {
        let db = try newDB()
        let path = writeCache(sessionID: "appended")
        let transcript = URL(fileURLWithPath: path)
            .appendingPathComponent(TBDConstants.remoteTranscriptFileName).path
        let recent = clock.addingTimeInterval(-60)
        try fm.setAttributes([.modificationDate: recent], ofItemAtPath: transcript)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path))
        #expect(result.planned.contains("KEEP grace \(path)"))
    }
}
