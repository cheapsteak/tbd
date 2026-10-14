import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

@Suite("OrphanGC reclaims stale dev server running files")
struct OrphanGCDevServerFileTests: ~Copyable {
    private let fm = FileManager.default
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    let home: URL
    let filesDir: URL

    init() {
        home = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbdgcds"), isDirectory: true)
        filesDir = home.appendingPathComponent("dev-servers", isDirectory: true)
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    private func makeGC(db: TBDDatabase, live: Set<Int32> = []) -> OrphanGC {
        makeGC(db: db, probe: DevServerProcessProbe(info: { pid in
            live.contains(pid)
                ? DevServerProcessInfo(startTime: Date(timeIntervalSince1970: 1_000), isZombie: false)
                : nil
        }))
    }

    private func makeGC(db: TBDDatabase, probe: DevServerProcessProbe) -> OrphanGC {
        let fixed = clock
        let environment = ["TBD_HOME": home.path]
        return OrphanGC(
            db: db, git: GitManager(), broadcast: { _ in },
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
            reposBase: TBDConstants.reposDir(environment: environment),
            devServersBase: filesDir,
            devServerProbe: probe)
    }

    private func writeFile(_ name: String, pid: Int32, age: TimeInterval, body: String? = nil) throws -> String {
        let path = filesDir.appendingPathComponent(name).path
        let text = body ?? #"{"version":1,"root":"/tmp/acme/w","server":"web","endpoints":[{"name":"app","url":"http://localhost:1"}],"pid":\#(pid),"startTime":1000}"#
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try fm.setAttributes([.modificationDate: clock.addingTimeInterval(-age)], ofItemAtPath: path)
        return path
    }

    @Test func aStaleFilePastTheGraceIsReclaimed() async throws {
        let db = try TBDDatabase(inMemory: true)
        let path = try writeFile("web-a.json", pid: 500, age: 30 * 24 * 3600)
        let result = await makeGC(db: db).sweep()
        #expect(!fm.fileExists(atPath: path))
        #expect(result.planned.contains("REAP dev-server-file \(path)"))
    }

    @Test func aLiveFileIsKeptHoweverOld() async throws {
        let db = try TBDDatabase(inMemory: true)
        let path = try writeFile("web-a.json", pid: 500, age: 30 * 24 * 3600)
        _ = await makeGC(db: db, live: [500]).sweep()
        #expect(fm.fileExists(atPath: path))
    }

    /// A probe that fails is not a dead process: the file is kept however
    /// old, so a server that may still run keeps its record.
    @Test func aFileWhoseProcessCannotBeProbedIsKeptHoweverOld() async throws {
        let db = try TBDDatabase(inMemory: true)
        let path = try writeFile("web-a.json", pid: 500, age: 30 * 24 * 3600)
        let result = await makeGC(db: db, probe: DevServerProcessProbe(read: { _ in .unreadable("sysctl failed") }))
            .sweep()
        #expect(fm.fileExists(atPath: path))
        #expect(result.planned.contains("KEEP unknown \(path)"))
    }

    @Test func aStaleFileInsideTheGraceIsKept() async throws {
        let db = try TBDDatabase(inMemory: true)
        let path = try writeFile("web-a.json", pid: 500, age: 1)
        _ = await makeGC(db: db).sweep()
        #expect(fm.fileExists(atPath: path))
    }

    @Test func malformedAndNewerVersionFilesAreKept() async throws {
        let db = try TBDDatabase(inMemory: true)
        let broken = try writeFile("broken.json", pid: 0, age: 30 * 24 * 3600, body: "{")
        let future = try writeFile("future.json", pid: 0, age: 30 * 24 * 3600, body: #"{"version":2}"#)
        _ = await makeGC(db: db).sweep()
        #expect(fm.fileExists(atPath: broken))
        #expect(fm.fileExists(atPath: future))
    }

    @Test func nothingIsReclaimedWithGCDisabled() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.config.setGCEnabled(false)
        let path = try writeFile("web-a.json", pid: 500, age: 30 * 24 * 3600)
        _ = await makeGC(db: db).sweep()
        #expect(fm.fileExists(atPath: path))
    }

    @Test func aDryRunPlansButKeeps() async throws {
        let db = try TBDDatabase(inMemory: true)
        let path = try writeFile("web-a.json", pid: 500, age: 30 * 24 * 3600)
        let result = await makeGC(db: db).sweep(dryRun: true)
        #expect(fm.fileExists(atPath: path))
        #expect(result.planned.contains("REAP dev-server-file \(path)"))
    }
}
