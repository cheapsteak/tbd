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

    @Test func reportNeedsAPidAndAURLUnlessClearing() {
        #expect(throws: (any Error).self) { try ServerReport.parse(["web"]) }
        #expect(throws: (any Error).self) { try ServerReport.parse(["web", "--pid", "12"]) }
        #expect(throws: (any Error).self) { try ServerReport.parse(["web", "--clear", "--pid", "12"]) }
        #expect((try? ServerReport.parse(["web", "--pid", "12", "--url", "http://localhost:3000"])) != nil)
        #expect((try? ServerReport.parse(["web", "--clear"])) != nil)
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
