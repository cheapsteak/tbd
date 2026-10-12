import Foundation
import SwiftUI
import Testing
import TBDShared
@testable import TBDApp

@Suite("Servers split button")
@MainActor
struct ServersButtonLabelTests {
    private func info(_ state: DevServerStateKind, url: String? = nil, code: Int32? = nil) -> DevServerInfo {
        DevServerInfo(name: "web", label: "Web app", source: "tbd.toml", state: state, exitCode: code,
                      endpoints: url.map { [DevServerEndpoint(name: "app", url: $0)] } ?? [],
                      terminalID: nil, pid: nil, hasStopCommand: false)
    }

    private func list(_ servers: [DevServerInfo]) -> DevServerListResult {
        DevServerListResult(worktreeID: UUID(), servers: servers, parseErrors: [], runningFileDiagnostics: [])
    }

    @Test func theIDChangesWhenAnythingRenderedChanges() {
        let id = UUID()
        func key(_ servers: [DevServerInfo], messages: [String] = [], scheme: ColorScheme = .light) -> String {
            ServersButtonLabel.splitButtonID(worktreeID: id, list: list(servers), messages: messages, colorScheme: scheme)
        }
        let stopped = key([info(.stopped)])
        let running = key([info(.running)])
        let withURL = key([info(.running, url: "http://a")])
        let dark = key([info(.running, url: "http://a")], scheme: .dark)
        let failed = key([info(.running, url: "http://a")], messages: ["web: x"], scheme: .dark)
        let exited = key([info(.exited, code: 1)])
        var saved = info(.exited, code: 1)
        saved.lastOutputID = UUID()
        let exitedWithOutput = key([saved])
        var withTab = info(.exited, code: 1)
        withTab.terminalID = UUID()
        let exitedWithTab = key([withTab])
        #expect(Set([stopped, running, withURL, dark, failed, exited, exitedWithOutput, exitedWithTab]).count == 8)
    }

    @Test func theIDIsStableForTheSameRenderedState() {
        let id = UUID()
        let servers = [info(.running, url: "http://a")]
        let first = ServersButtonLabel.splitButtonID(worktreeID: id, list: list(servers), messages: [], colorScheme: .light)
        let second = ServersButtonLabel.splitButtonID(worktreeID: id, list: list(servers), messages: [], colorScheme: .light)
        #expect(first == second)
    }

    /// D4: "Open <main URL>" leads the menu whenever there is a main URL.
    @Test func theMenuLeadsWithTheMainURL() {
        #expect(ServersButtonLabel.leadItemTitle(primaryURL: "https://localhost:24123") == "Open https://localhost:24123")
        #expect(ServersButtonLabel.leadItemTitle(primaryURL: nil) == nil)
    }

    @Test func titlesNameTheStateAndSource() {
        #expect(ServersButtonLabel.menuTitle(for: info(.exited, code: 127)) == "Web app — exited (code 127) · tbd.toml")
        #expect(ServersButtonLabel.menuTitle(for: info(.exited)) == "Web app — exited · tbd.toml")
        var undeclared = info(.running)
        undeclared.source = nil
        #expect(ServersButtonLabel.menuTitle(for: undeclared) == "Web app — running · undeclared")
    }

    @Test func theLabelTextCountsRunningServers() {
        #expect(ServersButtonLabel.title(runningCount: 0) == "Servers")
        #expect(ServersButtonLabel.title(runningCount: 2) == "2 running")
    }

    @Test func theBakedIconIsNotATemplate() {
        let image = ServersButtonLabel.bakedIcon(running: true, colorScheme: .light)
        #expect(!image.isTemplate)
        #expect(ServersButtonLabel.bakedIcon(running: false, colorScheme: .light) !== image)
    }
}
