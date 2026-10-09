import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

/// The `OrphanGC` leg that reclaims `~/tbd/repos/<repoID>/unsent-prompts/*`
/// files older than 30 days — the first messages the app saves when a
/// worktree creation fails with one composed for it.
///
/// Tier 2: a real temp tree, an in-memory database, a fixed clock. The repos
/// root comes through the leg's own seam and every other base the sweep walks
/// is pointed inside the same temp home, so this suite never reads the
/// process-global `TBD_HOME`.
@Suite("OrphanGC reclaims unsent first messages")
struct OrphanGCUnsentPromptTests: ~Copyable {
    private let fm = FileManager.default
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let repoID = UUID()
    private let day: TimeInterval = 24 * 60 * 60
    let home: URL

    init() {
        home = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdgcup"), isDirectory: true)
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
            remoteTranscriptsEnvironment: environment,
            reposBase: TBDConstants.reposDir(environment: environment))
    }

    /// Writes an unsent-prompt file at the path `TBDConstants` gives the repo,
    /// modified `age` before the suite's fixed clock.
    private func writeDraft(_ name: String, age: TimeInterval) -> String {
        let directory = TBDConstants.unsentPromptsDir(repoID: repoID, environment: environment)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name).path
        fm.createFile(atPath: path, contents: Data("draft\n".utf8))
        let stamp = clock.addingTimeInterval(-age)
        try? fm.setAttributes([.modificationDate: stamp], ofItemAtPath: path)
        return path
    }

    private func newDB() throws -> TBDDatabase { try TBDDatabase(inMemory: true) }

    @Test func aFileOlderThanThirtyDaysIsReclaimed() async throws {
        let db = try newDB()
        let path = writeDraft("20260101-000000-old.md", age: 31 * day)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path) == false, "\(path) survived the sweep")
        #expect(result.planned.contains("REAP unsent-prompt \(path)"))
        #expect(result.reaped >= 1)
    }

    @Test func aFileYoungerThanThirtyDaysIsKept() async throws {
        let db = try newDB()
        let path = writeDraft("20260101-000000-young.md", age: 29 * day)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: path), "\(path) was reclaimed inside its retention")
        #expect(result.planned.contains("KEEP retention \(path)"))
    }

    @Test func aDryRunReportsTheReclaimButKeepsTheFile() async throws {
        let db = try newDB()
        let path = writeDraft("20260101-000000-old.md", age: 31 * day)

        let result = await makeGC(db: db).sweep(dryRun: true)

        #expect(fm.fileExists(atPath: path), "a dry run removed \(path)")
        #expect(result.planned.contains("REAP unsent-prompt \(path)"))
    }

    @Test func nothingIsReclaimedWithGCDisabled() async throws {
        let db = try newDB()
        try await db.config.setGCEnabled(false)
        let old = writeDraft("20260101-000000-old.md", age: 31 * day)
        let young = writeDraft("20260101-000000-young.md", age: day)

        let result = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: old), "\(old) was reclaimed with gcEnabled off")
        #expect(fm.fileExists(atPath: young))
        #expect(result.planned.contains { $0.contains("unsent-prompt") } == false)
    }

    @Test func aDirectoryInsideUnsentPromptsIsLeftAlone() async throws {
        let db = try newDB()
        let directory = TBDConstants.unsentPromptsDir(repoID: repoID, environment: environment)
            .appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.setAttributes(
            [.modificationDate: clock.addingTimeInterval(-60 * day)], ofItemAtPath: directory.path)

        _ = await makeGC(db: db).sweep()

        #expect(fm.fileExists(atPath: directory.path))
    }
}
