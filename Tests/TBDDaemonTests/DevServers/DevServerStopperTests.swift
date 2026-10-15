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
                                         postKillWait: .zero, clock: EventDrivenTestClock()),
            commandRunner: r)
    }

    private func request(
        stop: String?, targets: [DevServerKillTarget], files: [String],
        unverifiable: [String] = [], runningOnlyByStatus: Bool = false, filePID: Int32 = 500
    ) -> DevServerStopRequest {
        DevServerStopRequest(
            name: "localstack",
            declared: DeclaredDevServer(name: "localstack", command: "docker compose up localstack",
                                        stop: stop, source: .repoTOML),
            cwd: "/tmp/acme/w", commandEnvironment: ["DEV_SERVER_NAME": "localstack"],
            killTargets: targets, unverifiable: unverifiable, runningOnlyByStatus: runningOnlyByStatus,
            runningFiles: files.map { DevServerStopRunningFile(path: $0, pid: filePID, startTime: start) })
    }

    /// A pid whose process cannot be read is not known to be gone: a stop
    /// keeps its running file rather than deleting it.
    @Test func aStopKeepsTheFileOfAProcessThatCannotBeRead() async throws {
        let s = FakeDevServerSignalling(); s.add(pid: 500, pgid: 500, start: start)
        s.makeUnreadable(500)
        let r = FakeDevServerCommandRunner()
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        let report = await stopper(s, r).stop(request(
            stop: "docker compose stop localstack", targets: [], files: [file]))
        #expect(report.succeeded)
        #expect(FileManager.default.fileExists(atPath: file), "a failed read is not a dead process")
        #expect(report.message?.contains("could not be read") == true)
    }

    /// A kill target that cannot be read is neither signalled nor taken for
    /// stopped: the stop fails and the file stays.
    @Test func aSignallingStopRefusesAProcessThatCannotBeRead() async throws {
        let s = FakeDevServerSignalling(); s.add(pid: 500, pgid: 500, start: start)
        s.makeUnreadable(500)
        let file = try tempFile()
        defer { try? FileManager.default.removeItem(atPath: file) }
        let report = await stopper(s, FakeDevServerCommandRunner()).stop(request(
            stop: nil, targets: [DevServerKillTarget(pid: 500, expectedStart: start, tolerance: 1)], files: [file]))
        #expect(!report.succeeded)
        #expect(s.sentSignals.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func aDeclaredStopRunsInsteadOfSignalling() async throws {
        let s = FakeDevServerSignalling()
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
        #expect(!FileManager.default.fileExists(atPath: file), "the process it names is gone")
    }

    /// A `stop` that exits 0 while the process its running file names is
    /// still alive (it only asked a supervisor, say) keeps the file: the
    /// server still reads running, and the stale-file sweep removes the file
    /// once the process is gone.
    @Test func aDeclaredStopKeepsTheFileOfAProcessThatOutlivesIt() async throws {
        let s = FakeDevServerSignalling(); s.add(pid: 500, pgid: 500, start: start)
        let r = FakeDevServerCommandRunner()
        let file = try tempFile(); defer { try? FileManager.default.removeItem(atPath: file) }
        let report = await stopper(s, r).stop(request(
            stop: "docker compose stop localstack", targets: [], files: [file]))
        #expect(report.succeeded)
        #expect(report.message?.contains("still alive") == true)
        #expect(s.sentSignals.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    /// The pid is now someone else's (the start time differs): the file is
    /// stale, so it goes.
    @Test func aDeclaredStopDeletesTheFileOfAReusedPid() async throws {
        let s = FakeDevServerSignalling(); s.add(pid: 500, pgid: 500, start: start.addingTimeInterval(60))
        let file = try tempFile()
        let report = await stopper(s, FakeDevServerCommandRunner()).stop(request(
            stop: "docker compose stop localstack", targets: [], files: [file]))
        #expect(report.succeeded)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    /// Archive's mode: repo code runs only on a user gesture, so a declared
    /// `stop` is skipped and the verified process is signalled instead.
    @Test func withoutRepoCommandsADeclaredStopIsSkippedAndTheTargetSignalled() async throws {
        let s = FakeDevServerSignalling(); s.add(pid: 500, pgid: 500, start: start)
        let r = FakeDevServerCommandRunner()
        let file = try tempFile()
        let report = await stopper(s, r).stop(request(
            stop: "docker compose stop localstack",
            targets: [DevServerKillTarget(pid: 500, expectedStart: start, tolerance: 1)], files: [file]),
            allowRepoCommands: false)
        #expect(report.succeeded)
        #expect(r.runs.isEmpty)
        #expect(s.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    /// A server only its declared `stop` could end, with no process TBD may
    /// signal, is left running in archive's mode — and says why.
    @Test func withoutRepoCommandsAServerOnlyItsStopCanEndIsLeftRunning() async {
        let r = FakeDevServerCommandRunner()
        let s = FakeDevServerSignalling()
        let report = await stopper(s, r).stop(request(
            stop: "docker compose stop localstack", targets: [], files: [], runningOnlyByStatus: true),
            allowRepoCommands: false)
        #expect(!report.succeeded)
        #expect(report.message?.contains("left running") == true)
        #expect(r.runs.isEmpty)
        #expect(s.sentSignals.isEmpty)
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
            .firstHand(pid: 500),
            DevServerKillTarget(pid: 501, expectedStart: start, tolerance: 1),
        ], files: []))
        #expect(report.succeeded)
        #expect(s.sentSignals == [.init(pgid: 500, signal: SIGTERM)])
        #expect(r.runs.isEmpty)
    }

    @Test func aRefusedGroupFailsTheStopAndKeepsTheFile() async throws {
        let s = FakeDevServerSignalling(own: 777)
        s.add(pid: 777, pgid: 777, start: start)
        let file = try tempFile(); defer { try? FileManager.default.removeItem(atPath: file) }
        let report = await stopper(s, FakeDevServerCommandRunner()).stop(request(
            stop: nil, targets: [DevServerKillTarget(pid: 777, expectedStart: start, tolerance: 1)], files: [file]))
        #expect(!report.succeeded)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    /// Running only through `status` (a detached container), no `stop`, and
    /// no process TBD may signal: the stop fails and says what to declare.
    @Test func aStatusOnlyServerWithoutAStopCommandFailsWithNothingToStop() async {
        let r = FakeDevServerCommandRunner()
        let report = await stopper(FakeDevServerSignalling(), r).stop(request(
            stop: nil, targets: [], files: [], runningOnlyByStatus: true))
        #expect(!report.succeeded)
        #expect(report.message?.contains("declare a `stop` command") == true)
        #expect(r.runs.isEmpty)
    }

    /// A server whose tab ended since the snapshot has nothing left to stop,
    /// and that is a success.
    @Test func aServerWithNoTargetsThatWasNotStatusOnlyStopsCleanly() async {
        let report = await stopper(FakeDevServerSignalling(), FakeDevServerCommandRunner()).stop(request(
            stop: nil, targets: [], files: [], runningOnlyByStatus: false))
        #expect(report.succeeded)
    }

    @Test func anUnverifiableTargetFailsTheStop() async throws {
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start)
        let file = try tempFile(); defer { try? FileManager.default.removeItem(atPath: file) }
        let report = await stopper(s, FakeDevServerCommandRunner()).stop(request(
            stop: nil, targets: [], files: [file], unverifiable: ["pid 500 cannot be verified"]))
        #expect(!report.succeeded)
        #expect(report.message?.contains("pid 500") == true)
        #expect(s.sentSignals.isEmpty)
        #expect(s.sentToProcesses.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func aPidSignalledAloneIsNamedInTheReport() async {
        let s = FakeDevServerSignalling()
        s.add(pid: 500, pgid: 500, start: start)
        s.add(pid: 600, pgid: 500, start: start)
        let report = await stopper(s, FakeDevServerCommandRunner()).stop(request(
            stop: nil, targets: [DevServerKillTarget(pid: 600, expectedStart: start, tolerance: 1)], files: []))
        #expect(report.succeeded)
        #expect(report.message?.contains("does not lead its own process group") == true)
        #expect(s.sentSignals.isEmpty)
    }
}

@Suite("Dev server command environment")
struct DevServerCommandEnvironmentTests {
    /// A daemon relaunched by LaunchServices can carry launchd's bare PATH;
    /// `stop` and `status` commands get the package-manager floor appended.
    @Test func aBarePathGetsTheFallbackDirectoriesAppended() {
        let env = ProductionDevServerCommandRunner.processEnvironment(
            declared: ["FEATURE_X": "1"],
            inheriting: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/acme-home"])
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(Array(path.prefix(2)) == ["/usr/bin", "/bin"], "the inherited order wins")
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/tmp/acme-home/.local/bin"))
        #expect(env["FEATURE_X"] == "1")
    }

    /// A PATH the server declares is kept first, and still gets the floor.
    @Test func aDeclaredPathLeadsAndIsAugmented() {
        let env = ProductionDevServerCommandRunner.processEnvironment(
            declared: ["PATH": "/opt/acme/bin"], inheriting: ["PATH": "/usr/bin", "HOME": "/tmp/acme-home"])
        let path = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == "/opt/acme/bin")
        #expect(path.contains("/usr/local/bin"))
    }
}
