import ArgumentParser
import Foundation
import Testing
import TBDShared
@testable import TBDCLI

@Suite("tbd server")
struct ServerCommandsTests {
    @Test func everySubcommandIsRegistered() {
        let names = ServerCommand.configuration.subcommands.map { $0._commandName }
        #expect(names == ["list", "start", "stop", "restart", "status", "open", "report"])
        #expect(TBDCommand.configuration.subcommands.contains { $0._commandName == "server" })
    }

    @Test func endpointsParseNamedAndUnnamedURLs() throws {
        let endpoints = try ServerCommand.parseEndpoints(
            ["https://localhost:24123", "api=http://localhost:8004/api", "http://localhost:6006"], server: "web")
        #expect(endpoints == [
            DevServerEndpoint(name: "main", url: "https://localhost:24123"),
            DevServerEndpoint(name: "api", url: "http://localhost:8004/api"),
            DevServerEndpoint(name: "main-2", url: "http://localhost:6006"),
        ])
    }

    @Test(arguments: ["localhost:3000", "api=", "=http://x", "not a url"])
    func badURLsAreRejected(_ raw: String) {
        #expect(throws: (any Error).self) { try ServerCommand.parseEndpoints([raw], server: "web") }
    }

    @Test(arguments: [
        ["api=http://localhost:1", "api=http://localhost:2"],
        ["main=http://localhost:1", "http://localhost:2"],
    ])
    func duplicateEndpointNamesAreRejected(_ raw: [String]) {
        #expect(throws: (any Error).self) { try ServerCommand.parseEndpoints(raw, server: "web") }
    }

    @Test func reportNeedsAPidAndAURLUnlessClearing() {
        #expect(throws: (any Error).self) { try ServerReport.parse(["web"]) }
        #expect(throws: (any Error).self) { try ServerReport.parse(["web", "--pid", "12"]) }
        #expect(throws: (any Error).self) { try ServerReport.parse(["web", "--clear", "--pid", "12"]) }
        #expect((try? ServerReport.parse(["web", "--pid", "12", "--url", "http://localhost:3000"])) != nil)
        #expect((try? ServerReport.parse(["web", "--clear"])) != nil)
    }

    /// `restart` with no names restarts the declared servers its stop
    /// stopped — never every declared server — and nothing when none was
    /// running.
    @Test func reportReadsTheStartTimeOfARunningProcess() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let probe = DevServerProcessProbe(info: { pid in
            pid == 42 ? DevServerProcessInfo(startTime: started, isZombie: false) : nil
        })
        #expect(try ServerReport.reportedStartTime(pid: 42, probe: probe) == started)
    }

    /// A zombie's file would read as stale at once: refuse it, by name.
    @Test func reportRefusesAZombiePid() {
        let probe = DevServerProcessProbe(info: { _ in
            DevServerProcessInfo(startTime: Date(timeIntervalSince1970: 1_800_000_000), isZombie: true)
        })
        let error = #expect(throws: CLIError.self) { try ServerReport.reportedStartTime(pid: 42, probe: probe) }
        #expect(error?.description.contains("zombie") == true)
    }

    @Test func reportRefusesAMissingPid() {
        let probe = DevServerProcessProbe(info: { _ in nil })
        let error = #expect(throws: CLIError.self) { try ServerReport.reportedStartTime(pid: 42, probe: probe) }
        #expect(error?.description == "No process with pid 42 is running.")
    }

    @Test func restartWithNoNamesStartsOnlyWhatItStopped() {
        let stopped = DevServerActionResult(outcomes: [
            .init(name: "web", status: .stopped),
            .init(name: "api", status: .stopped),
            .init(name: "db", status: .notRunning),
        ])
        let all = ServerRestart.restartPlan(requested: [], stopped: stopped, declared: ["web", "api", "db"])
        #expect(all.start == ["web", "api"])
        #expect(all.skipped.isEmpty)
        let none = ServerRestart.restartPlan(
            requested: [], stopped: DevServerActionResult(outcomes: []), declared: ["web"])
        #expect(none.start.isEmpty)
        let named = ServerRestart.restartPlan(
            requested: ["db"], stopped: DevServerActionResult(outcomes: []), declared: [])
        #expect(named.start == ["db"])
    }

    /// A stopped server with no declaration (a running file's, or a tab
    /// whose declaration is gone) cannot be started: it is skipped, not
    /// handed to `server.start` to fail.
    @Test func restartWithNoNamesSkipsUndeclaredServers() {
        let stopped = DevServerActionResult(outcomes: [
            .init(name: "web", status: .stopped),
            .init(name: "storybook", status: .stopped),
        ])
        let plan = ServerRestart.restartPlan(requested: [], stopped: stopped, declared: ["web"])
        #expect(plan.start == ["web"])
        #expect(plan.skipped == ["storybook"])
    }

    private func list(_ servers: [DevServerInfo], errors: [DevServerParseError] = []) -> DevServerListResult {
        DevServerListResult(worktreeID: UUID(), servers: servers, parseErrors: errors, runningFileDiagnostics: [])
    }
    private func server(_ name: String, _ state: DevServerStateKind, urls: [(String, String)] = []) -> DevServerInfo {
        DevServerInfo(name: name, label: name, source: "tbd.toml", state: state, exitCode: nil,
                      endpoints: urls.map { DevServerEndpoint(name: $0.0, url: $0.1) },
                      terminalID: nil, pid: nil, hasStopCommand: false)
    }

    @Test func openPicksTheFirstRunningServerWithAURL() throws {
        let l = list([server("api", .running), server("web", .running, urls: [("app", "https://localhost:1")])])
        #expect(try ServerCommand.urlToOpen(in: l, server: nil, endpoint: nil) == "https://localhost:1")
    }

    @Test func openHonoursANamedEndpoint() throws {
        let l = list([server("web", .running, urls: [("app", "https://a"), ("api", "http://b")])])
        #expect(try ServerCommand.urlToOpen(in: l, server: "web", endpoint: "api") == "http://b")
    }

    @Test func openFailsClearlyWithNoReportedURL() {
        let l = list([server("web", .running)])
        #expect(throws: (any Error).self) { try ServerCommand.urlToOpen(in: l, server: "web", endpoint: nil) }
        #expect(throws: (any Error).self) { try ServerCommand.urlToOpen(in: l, server: nil, endpoint: nil) }
    }

    @Test func theListNamesParseErrors() {
        let text = ServerCommand.render(list(
            [server("web", .stopped)],
            errors: [DevServerParseError(path: "/tmp/acme/w/tbd.toml", message: "bad table")]))
        #expect(text.contains("web"))
        #expect(text.contains("/tmp/acme/w/tbd.toml"))
        #expect(text.contains("bad table"))
    }
}
