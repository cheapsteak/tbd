import Foundation
import Testing
import TBDShared
@testable import TBDApp

@Suite("Servers toolbar menu")
struct ServersToolbarMenuTests {
    private func info(
        _ name: String = "web", _ state: DevServerStateKind, url: String? = nil,
        declared: Bool = true, terminalID: UUID? = nil, lastOutputID: UUID? = nil
    ) -> DevServerInfo {
        DevServerInfo(name: name, label: "Web app", source: declared ? "tbd.toml" : nil, state: state,
                      exitCode: nil,
                      endpoints: url.map { [DevServerEndpoint(name: "app", url: $0)] } ?? [],
                      terminalID: terminalID, pid: nil, hasStopCommand: false, lastOutputID: lastOutputID)
    }

    private func list(_ servers: [DevServerInfo], errors: [DevServerParseError] = []) -> DevServerListResult {
        DevServerListResult(worktreeID: UUID(), servers: servers, parseErrors: errors, runningFileDiagnostics: [])
    }

    private func bulk(startAll: Bool, stopAll: [String]) -> [ServersMenuEntry] {
        [.separator,
         .item(title: "Start all", isEnabled: startAll, command: .start(names: [])),
         .item(title: "Stop all", isEnabled: !stopAll.isEmpty, command: .stop(names: stopAll)),
         .item(title: "Refresh status", isEnabled: true, command: .refreshStatus)]
    }

    @Test func leadItemOnlyWithAPrimaryURL() {
        let withURL = ServersToolbarMenu.entries(list: list([info(.running, url: "http://a")]), messages: [])
        let withoutURL = ServersToolbarMenu.entries(list: list([info(.stopped, url: "http://a")]), messages: [])
        let lead: ServersMenuEntry = .item(title: "Open http://a", isEnabled: true, command: .open(url: "http://a"))
        #expect(withURL.first == lead)
        #expect(withURL[1] == .separator)
        #expect(withoutURL.first == .header("Web app — stopped · tbd.toml"))
    }

    @Test func exitedServerOffersLastOutputEnabledByEitherID() {
        func entry(_ server: DevServerInfo) -> ServersMenuEntry? {
            ServersToolbarMenu.entries(list: list([server]), messages: []).first {
                if case .item(let title, _, _) = $0 { return title == "Show last output" }
                return false
            }
        }
        let none: ServersMenuEntry = .item(title: "Show last output", isEnabled: false,
                                           command: .showLastOutput(serverName: "web"))
        let saved: ServersMenuEntry = .item(title: "Show last output", isEnabled: true,
                                            command: .showLastOutput(serverName: "web"))
        #expect(entry(info(.exited)) == none)
        #expect(entry(info(.exited, lastOutputID: UUID())) == saved)
        #expect(entry(info(.exited, terminalID: UUID())) == saved)
        #expect(entry(info(.stopped, terminalID: UUID())) == nil)
    }

    @Test func runningDeclaredServerOffersStopAndRestart() {
        let actual = ServersToolbarMenu.entries(list: list([info(.running)]), messages: [])
        let expected: [ServersMenuEntry] = [
            .header("Web app — running · tbd.toml"),
            .item(title: "Stop", isEnabled: true, command: .stop(names: ["web"])),
            .item(title: "Restart", isEnabled: true, command: .restart(names: ["web"])),
        ] + bulk(startAll: false, stopAll: ["web"])
        #expect(actual == expected)
    }

    @Test func stoppedDeclaredServerOffersStart() {
        let actual = ServersToolbarMenu.entries(list: list([info(.stopped)]), messages: [])
        let expected: [ServersMenuEntry] = [
            .header("Web app — stopped · tbd.toml"),
            .item(title: "Start", isEnabled: true, command: .start(names: ["web"])),
        ] + bulk(startAll: true, stopAll: [])
        #expect(actual == expected)
    }

    @Test func undeclaredExitedServerWithATabOffersClose() {
        let tab = UUID()
        let actual = ServersToolbarMenu.entries(
            list: list([info(.exited, declared: false, terminalID: tab)]), messages: [])
        let expected: [ServersMenuEntry] = [
            .header("Web app — exited · undeclared"),
            .item(title: "Show last output", isEnabled: true, command: .showLastOutput(serverName: "web")),
            .item(title: "Close", isEnabled: true, command: .stop(names: ["web"])),
        ] + bulk(startAll: false, stopAll: ["web"])
        #expect(actual == expected)
    }

    @Test func bulkItemsAndTheirEnablement() {
        let allRunning = ServersToolbarMenu.entries(
            list: list([info("a", .running), info("b", .running)]), messages: [])
        let mixed = ServersToolbarMenu.entries(
            list: list([info("a", .running), info("b", .stopped)]), messages: [])
        let allRunningTail: [ServersMenuEntry] = bulk(startAll: false, stopAll: ["a", "b"])
        let mixedTail: [ServersMenuEntry] = bulk(startAll: true, stopAll: ["a"])
        #expect(Array(allRunning.suffix(4)) == allRunningTail)
        #expect(Array(mixed.suffix(4)) == mixedTail)
    }

    @Test func problemsTrailAfterASeparator() {
        let errors = [DevServerParseError(path: "/repo/dir/tbd.toml", message: "bad key")]
        let actual = ServersToolbarMenu.entries(list: list([info(.stopped)], errors: errors), messages: ["web: failed"])
        let expectedTail: [ServersMenuEntry] = [
            .separator, .note("tbd.toml: bad key"), .note("web: failed"),
        ]
        #expect(Array(actual.suffix(3)) == expectedTail)
    }

    @Test func noProblemsNoTrailingSeparator() {
        let actual = ServersToolbarMenu.entries(list: list([info(.stopped)]), messages: [])
        let expectedTail: [ServersMenuEntry] = [.item(title: "Refresh status", isEnabled: true, command: .refreshStatus)]
        #expect(Array(actual.suffix(1)) == expectedTail)
    }
}
