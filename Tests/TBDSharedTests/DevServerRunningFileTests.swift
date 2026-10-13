import Foundation
import Testing
@testable import TBDShared

@Suite("Dev server running files")
struct DevServerRunningFileTests {
    private let start = Date(timeIntervalSince1970: 1_760_190_000)

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-devsrv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func file(root: String = "/tmp/acme/fix-login", server: String = "web",
                      pid: Int32 = 81234, startTime: Double = 1_760_190_000) -> DevServerRunningFile {
        DevServerRunningFile(
            version: 1, root: root, server: server,
            endpoints: [DevServerEndpoint(name: "app", url: "https://localhost:24123")],
            pid: pid, startTime: startTime)
    }

    private func probe(_ map: [Int32: DevServerProcessInfo]) -> DevServerProcessProbe {
        DevServerProcessProbe(info: { map[$0] })
    }

    // MARK: Liveness

    @Test func aLiveProcessWithAMatchingStartTimeIsLive() {
        let p = probe([81234: DevServerProcessInfo(startTime: start.addingTimeInterval(0.4), isZombie: false)])
        #expect(DevServerRunningFileStore.liveness(of: file(), probe: p) == .live)
    }

    @Test func aDeadPidIsStale() {
        guard case .stale = DevServerRunningFileStore.liveness(of: file(), probe: probe([:])) else {
            Issue.record("a pid with no process read live"); return
        }
    }

    /// The reused-pid case: same number, different process.
    @Test func aReusedPidWithAMismatchedStartTimeIsStale() {
        let p = probe([81234: DevServerProcessInfo(startTime: start.addingTimeInterval(5), isZombie: false)])
        guard case .stale = DevServerRunningFileStore.liveness(of: file(), probe: p) else {
            Issue.record("a start time five seconds off read live"); return
        }
    }

    @Test func aZombieIsStale() {
        let p = probe([81234: DevServerProcessInfo(startTime: start, isZombie: true)])
        guard case .stale = DevServerRunningFileStore.liveness(of: file(), probe: p) else {
            Issue.record("a zombie read live"); return
        }
    }

    /// A failed read says nothing about the process: unknown, never stale,
    /// so nothing deletes the file on its account.
    @Test func aProbeThatFailsReadsUnknownNotStale() {
        let p = DevServerProcessProbe(read: { _ in .unreadable("sysctl failed") })
        guard case .unknown = DevServerRunningFileStore.liveness(of: file(), probe: p) else {
            Issue.record("a failed probe read live or stale"); return
        }
    }

    @Test func theRealKernelProbeReadsAPidWithNoProcessAsGone() {
        // pid_max on darwin is 99999; this pid cannot exist.
        #expect(DevServerProcessProbe.kernelRead(pid: 999_999) == .gone)
    }

    @Test func theRealKernelProbeSeesThisProcess() throws {
        let me = getpid()
        let info = try #require(DevServerProcessProbe.kernelInfo(pid: me))
        #expect(!info.isZombie)
        #expect(info.startTime <= Date())
        #expect(DevServerProcessProbe.kernelInfo(pid: -1) == nil)
    }

    // MARK: Decoding

    @Test func aHigherVersionIsRejectedAsUnsupported() throws {
        var f = file(); f.version = 2
        let data = try JSONEncoder().encode(f)
        guard case .failure(.unsupportedVersion(2)) = DevServerRunningFileStore.decode(data) else {
            Issue.record("version 2 decoded"); return
        }
    }

    @Test(arguments: [
        #"{"version":1}"#,
        #"not json"#,
        #"{"version":1,"root":"/tmp/x","server":"web","endpoints":[],"pid":1,"startTime":1}"#,
        #"{"version":1,"root":"relative","server":"web","endpoints":[{"name":"a","url":"http://localhost:1"}],"pid":1,"startTime":1}"#,
        #"{"version":1,"root":"/tmp/x","server":"web","endpoints":[{"name":"a","url":"localhost:1"}],"pid":1,"startTime":1}"#,
        #"{"version":1,"root":"/tmp/x","server":"web","endpoints":[{"name":"a","url":"http://localhost:1"},{"name":"a","url":"http://localhost:2"}],"pid":1,"startTime":1}"#,
    ])
    func malformedFilesAreRejected(_ text: String) {
        guard case .failure(.malformed) = DevServerRunningFileStore.decode(Data(text.utf8)) else {
            Issue.record("\(text) decoded"); return
        }
    }

    @Test func unknownFieldsAreIgnored() throws {
        let text = #"{"version":1,"root":"/tmp/x","server":"web","endpoints":[{"name":"a","url":"http://localhost:1","extra":true}],"pid":7,"startTime":1760190000,"future":"field"}"#
        guard case .success(let f) = DevServerRunningFileStore.decode(Data(text.utf8)) else {
            Issue.record("unknown fields failed the decode"); return
        }
        #expect(f.pid == 7)
    }

    // MARK: Store

    @Test func writeIsReadBackByScanAndRemoveDeletesIt() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = DevServerRunningFileStore(directory: dir)
        let path = try store.write(file())
        #expect(path.hasSuffix(".json"))
        let scan = store.scan()
        #expect(scan.entries.map(\.file) == [file()])
        #expect(scan.diagnostics.isEmpty)
        #expect(store.remove(root: "/tmp/acme/fix-login", server: "web") == [path])
        #expect(store.scan().entries.isEmpty)
    }

    /// A second report for the same root and server replaces the first rather
    /// than leaving two files describing one server.
    @Test func aSecondWriteForTheSameServerLeavesOneFile() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = DevServerRunningFileStore(directory: dir)
        // A file another writer named differently, for the same server.
        let foreign = dir.appendingPathComponent("someone-else.json")
        try JSONEncoder().encode(file(pid: 1)).write(to: foreign)
        _ = try store.write(file(pid: 2))
        #expect(store.scan().entries.map(\.file.pid) == [2])
    }

    @Test func scanNamesMalformedFilesAndSkipsNonJSON() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{".utf8).write(to: dir.appendingPathComponent("broken.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".hidden.json"))
        let scan = DevServerRunningFileStore(directory: dir).scan()
        #expect(scan.entries.isEmpty)
        #expect(scan.diagnostics.map { ($0.path as NSString).lastPathComponent } == ["broken.json"])
    }

    @Test func aMissingDirectoryScansEmpty() {
        let store = DevServerRunningFileStore(directory: URL(fileURLWithPath: "/tmp/tbd-devsrv-missing-\(UUID().uuidString)"))
        #expect(store.scan() == DevServerRunningFileScan(entries: [], diagnostics: []))
    }

    // MARK: Attribution (Review Focus 1, 5)

    @Test func normalizedRootResolvesSymlinks() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(DevServerRunningFileStore.normalizedRoot(link.path)
                == DevServerRunningFileStore.normalizedRoot(real.path + "/"))
    }

    @Test func attributionMatchesOnlyTheWorktreeWhoseRootMatches() throws {
        let dir = try makeDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a", isDirectory: true)
        let b = dir.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let idA = UUID(), idB = UUID()
        let entries = [
            DevServerRunningFileEntry(path: "/x/1.json", file: file(root: a.path), modifiedAt: nil),
            DevServerRunningFileEntry(path: "/x/2.json", file: file(root: b.path), modifiedAt: nil),
            DevServerRunningFileEntry(path: "/x/3.json", file: file(root: "/tmp/acme/elsewhere"), modifiedAt: nil),
        ]
        let byWorktree = DevServerRunningFileStore.attribute(entries, worktreePaths: [idA: a.path, idB: b.path])
        #expect(byWorktree[idA]?.map(\.path) == ["/x/1.json"])
        #expect(byWorktree[idB]?.map(\.path) == ["/x/2.json"])
        #expect(byWorktree.values.flatMap { $0 }.count == 2)
    }

    @Test func devServersDirHonorsTheOverrideAndDefaultsUnderHome() {
        #expect(TBDConstants.devServersDir(environment: ["DEV_SERVERS_DIR": "/tmp/acme-ds"]).path == "/tmp/acme-ds")
        #expect(TBDConstants.devServersDir(environment: ["DEV_SERVERS_DIR": ""]).path
                .hasSuffix("/.local/state/dev-servers"))
    }

    @Test func serversConfigPathHonorsTBDHome() {
        let id = UUID()
        #expect(TBDConstants.serversConfigPath(repoID: id, environment: ["TBD_HOME": "/tmp/acme-home"])
                == "/tmp/acme-home/repos/\(id.uuidString)/servers.toml")
    }
}
