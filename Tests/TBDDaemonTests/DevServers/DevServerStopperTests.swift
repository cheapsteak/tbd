import Clocks
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Dev server stop rules")
struct DevServerStopperTests {
    private let start = Date(timeIntervalSince1970: 1_760_190_000)

    private func tempFile() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-devstop-\(UUID().uuidString).json").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func stopper(_ s: FakeDevServerSignalling, _ r: FakeDevServerCommandRunner) -> DevServerStopper {
        DevServerStopper(
            killer: DevServerGroupKiller(signalling: s, grace: .seconds(5), pollInterval: .seconds(5),
                                         postKillWait: .zero, clock: TestClock()),
            commandRunner: r)
    }

    private func request(stop: String?, targets: [DevServerKillTarget], files: [String]) -> DevServerStopRequest {
        DevServerStopRequest(
            name: "localstack",
            declared: DeclaredDevServer(name: "localstack", command: "docker compose up localstack",
                                        stop: stop, source: .repoTOML),
            cwd: "/tmp/acme/w", commandEnvironment: ["DEV_SERVER_NAME": "localstack"],
            killTargets: targets, runningFilePaths: files)
    }

    @Test func aDeclaredStopRunsInsteadOfSignalling() async throws {
        let s = FakeDevServerSignalling(); s.add(pid: 500, pgid: 500, start: start)
        let r = FakeDevServerCommandRunner()
        let file = try tempFile()
        let report = await stopper(s, r).stop(request(
            stop: "docker compose stop localstack",
            targets: [DevServerKillTarget(pid: 500, expectedStart: start, tolerance: 1)], files: [file]))
        #expect(report.succeeded)
        #expect(r.runs.map(\.command) == ["docker compose stop localstack"])
        #expect(r.runs.first?.cwd == "/tmp/acme/w")
        #expect(r.runs.first?.timeout == .seconds(60))
        #expect(s.sentSignals.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func aFailingStopCommandDoesNotFallBackToSignals() async throws {
        let s = FakeDevServerSignalling(); s.add(pid: 500, pgid: 500, start: start)
        let r = FakeDevServerCommandRunner(outcomes: ["docker compose stop localstack": .exited(3)])
        let file = try tempFile(); defer { try? FileManager.default.removeItem(atPath: file) }
        let report = await stopper(s, r).stop(request(
            stop: "docker compose stop localstack",
            targets: [DevServerKillTarget(pid: 500, expectedStart: start, tolerance: 1)], files: [file]))
        #expect(!report.succeeded)
        #expect(report.message?.contains("3") == true)
        #expect(s.sentSignals.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func aStopCommandTimeoutIsAFailure() async {
        let r = FakeDevServerCommandRunner(outcomes: ["s": .timedOut])
        let report = await stopper(FakeDevServerSignalling(), r).stop(request(stop: "s", targets: [], files: []))
        #expect(!report.succeeded)
    }

    @Test func withoutAStopCommandEachGroupIsKilledOnce() async {
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start)
        s.add(pid: 501, pgid: 500, start: start)
        let r = FakeDevServerCommandRunner()
        let report = await stopper(s, r).stop(request(stop: nil, targets: [
            DevServerKillTarget(pid: 500, expectedStart: nil, tolerance: 0),
            DevServerKillTarget(pid: 501, expectedStart: start, tolerance: 1),
        ], files: []))
        #expect(report.succeeded)
        #expect(s.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
        #expect(r.runs.isEmpty)
    }

    @Test func aRefusedGroupFailsTheStopAndKeepsTheFile() async throws {
        let s = FakeDevServerSignalling(own: 777)
        s.add(pid: 500, pgid: 777, start: start)
        let file = try tempFile(); defer { try? FileManager.default.removeItem(atPath: file) }
        let report = await stopper(s, FakeDevServerCommandRunner()).stop(request(
            stop: nil, targets: [DevServerKillTarget(pid: 500, expectedStart: start, tolerance: 1)], files: [file]))
        #expect(!report.succeeded)
        #expect(FileManager.default.fileExists(atPath: file))
    }
}
