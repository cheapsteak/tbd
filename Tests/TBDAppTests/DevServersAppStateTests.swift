import Foundation
import Testing
import TBDShared
@testable import TBDApp

@MainActor
@Suite("Dev servers in AppState")
struct DevServersAppStateTests {
    private func withState(_ body: (AppState) async throws -> Void) async rethrows {
        let suiteName = "TBDAppTests.DevServers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(AppState(userDefaults: defaults))
    }

    private func info(_ name: String, _ state: DevServerStateKind, url: String? = nil) -> DevServerInfo {
        DevServerInfo(name: name, label: name, source: "tbd.toml", state: state, exitCode: nil,
                      endpoints: url.map { [DevServerEndpoint(name: "app", url: $0)] } ?? [],
                      terminalID: nil, pid: nil, hasStopCommand: false)
    }

    private func list(_ servers: [DevServerInfo], id: UUID = UUID()) -> DevServerListResult {
        DevServerListResult(worktreeID: id, servers: servers, parseErrors: [], runningFileDiagnostics: [])
    }

    @Test func theSummaryFillsTheDotSet() async {
        await withState { state in
            let id = UUID()
            state.devServerSummaryFetcher = { DevServerSummaryResult(runningWorktreeIDs: [id]) }
            await state.refreshDevServerSummary()
            #expect(state.devServerRunningWorktreeIDs == [id])
        }
    }

    @Test func aListIsStoredPerWorktreeAndAskedWithTheStatusFlag() async {
        await withState { state in
            let id = UUID()
            var asked: [Bool] = []
            let result = self.list([self.info("web", .stopped)], id: id)
            state.devServerListFetcher = { _, run in asked.append(run); return result }
            await state.refreshDevServers(worktreeID: id, runStatusCommands: true)
            #expect(state.devServerLists[id]?.servers.map(\.name) == ["web"])
            #expect(asked == [true])
        }
    }

    @Test func aFailedActionIsShownAndASuccessClearsIt() async {
        await withState { state in
            let id = UUID()
            let empty = self.list([], id: id)
            state.devServerListFetcher = { _, _ in empty }
            state.devServerSummaryFetcher = { DevServerSummaryResult(runningWorktreeIDs: []) }
            state.devServerActionSender = { _, _, _ in
                DevServerActionResult(outcomes: [.init(name: "web", status: .failed, message: "cwd missing")])
            }
            await state.performDevServerAction(.start, worktreeID: id, names: ["web"])
            #expect(state.devServerActionMessages[id] == ["web: cwd missing"])
            state.devServerActionSender = { _, _, _ in
                DevServerActionResult(outcomes: [.init(name: "web", status: .started)])
            }
            await state.performDevServerAction(.start, worktreeID: id, names: ["web"])
            #expect(state.devServerActionMessages[id] == nil)
        }
    }

    @Test func thePrimaryURLIsTheFirstRunningServerWithOne() {
        let l = list([info("api", .running), info("old", .exited, url: "http://x"),
                      info("web", .running, url: "https://localhost:1")])
        #expect(AppState.primaryDevServerURL(l) == "https://localhost:1")
        #expect(AppState.primaryDevServerURL(list([info("api", .running)])) == nil)
    }

    @Test func theButtonShowsOnlyWithAServer() {
        #expect(!AppState.showsServersButton(nil))
        #expect(!AppState.showsServersButton(list([])))
        #expect(AppState.showsServersButton(list([info("web", .stopped)])))
    }

    /// A saved entry opens in Closed Terminals, never the tab.
    @Test func showLastOutputOpensTheSavedEntryWhenThereIsOne() async {
        await withState { state in
            let worktreeID = UUID(), entryID = UUID(), terminalID = UUID()
            var opened: [UUID] = [], focused: [UUID] = []
            state.devServerLastOutputOpener = { _, id in opened.append(id) }
            state.devServerTabFocuser = { _, id in focused.append(id) }
            var server = self.info("web", .exited)
            server.lastOutputID = entryID
            server.terminalID = terminalID
            await state.showDevServerLastOutput(worktreeID: worktreeID, server: server)
            #expect(opened == [entryID])
            #expect(focused.isEmpty)
        }
    }

    /// tmux: no saved entry, so the dead pane in the server's tab is the output.
    @Test func showLastOutputFocusesTheTabWithoutASavedEntry() async {
        await withState { state in
            let worktreeID = UUID(), terminalID = UUID()
            var opened: [UUID] = [], focused: [UUID] = []
            state.devServerLastOutputOpener = { _, id in opened.append(id) }
            state.devServerTabFocuser = { _, id in focused.append(id) }
            var server = self.info("web", .exited)
            server.terminalID = terminalID
            await state.showDevServerLastOutput(worktreeID: worktreeID, server: server)
            #expect(focused == [terminalID])
            #expect(opened.isEmpty)
        }
    }

    @Test func focusingAServerTabLeavesSessionHistory() async {
        await withState { state in
            let worktreeID = UUID()
            state.historyActiveWorktrees.insert(worktreeID)
            state.focusDevServerTab(worktreeID: worktreeID, terminalID: UUID())
            #expect(!state.historyActiveWorktrees.contains(worktreeID))
        }
    }

    @Test func aChangeDeltaRefreshesTheDotSet() async {
        await withState { state in
            let id = UUID()
            state.devServerSummaryFetcher = { DevServerSummaryResult(runningWorktreeIDs: [id]) }
            state.handleDelta(.devServersChanged)
            // The arm runs in a Task; yield until it lands.
            for _ in 0..<200 where state.devServerRunningWorktreeIDs.isEmpty { await Task.yield() }
            #expect(state.devServerRunningWorktreeIDs == [id])
        }
    }
}
