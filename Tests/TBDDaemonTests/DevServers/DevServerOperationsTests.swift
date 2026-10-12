import Clocks
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Dev server operations")
struct DevServerOperationsTests {
    @Test func stopAllForArchiveStopsRunningServersAndSkipsStoppedOnes() async throws {
        let db = try TBDDatabase(inMemory: true)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-srvops-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("[servers.web]\ncommand = \"a\"\n[servers.api]\ncommand = \"b\"\n".utf8)
            .write(to: URL(fileURLWithPath: path + "/tbd.toml"))
        let worktree = try await db.worktrees.createScratch(name: "s", displayName: "s", path: path, tmuxServer: "tbd-srvops")
        let local = try #require(try await db.worktrees.getLocal(id: worktree.id))
        let webTab = try await db.terminals.create(worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
                                                   kind: .shell, serverName: "web")
        let inspector = FakeDevServerTabInspector()
        inspector.set(.running(pid: 500, expectedStart: nil), for: webTab.id)
        let signalling = FakeDevServerSignalling()
        signalling.add(pid: 500, pgid: 500, start: Date())
        let runner = FakeDevServerCommandRunner()
        let operations = DevServerOperations(
            db: db, tabInspector: inspector, commandRunner: runner,
            stopper: DevServerStopper(
                killer: DevServerGroupKiller(signalling: signalling, grace: .seconds(5),
                                             pollInterval: .seconds(5), postKillWait: .zero, clock: TestClock()),
                commandRunner: runner),
            runningFiles: DevServerRunningFileStore(directory: URL(fileURLWithPath: path + "/files")),
            probe: DevServerProcessProbe(info: { _ in nil }), environment: [:])
        let reports = await operations.stopAllForArchive(worktree: local)
        #expect(reports.map(\.name) == ["web"])
        #expect(reports.allSatisfy { $0.succeeded })
        #expect(signalling.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
        // The tab is archive's to close.
        #expect(try await db.terminals.get(id: webTab.id) != nil)
    }
}
