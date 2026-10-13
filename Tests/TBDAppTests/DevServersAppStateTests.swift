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
            await state.refreshDevServers(worktreeID: id, trigger: .refreshStatus)
            #expect(state.devServerLists[id]?.servers.map(\.name) == ["web"])
            #expect(asked == [true])
        }
    }

    /// Repo `status` commands are repo-authored shell: only a gesture on the
    /// servers runs them, never selecting a worktree or a daemon delta.
    @Test func onlyAGestureRunsStatusCommands() {
        #expect(!DevServerRefreshTrigger.selection.runsStatusCommands)
        #expect(!DevServerRefreshTrigger.change.runsStatusCommands)
        #expect(DevServerRefreshTrigger.action.runsStatusCommands)
        #expect(DevServerRefreshTrigger.refreshStatus.runsStatusCommands)
    }

    @Test func selectingAWorktreeAsksWithoutStatusCommands() async {
        await withState { state in
            let id = UUID()
            var asked: [Bool] = []
            let result = self.list([self.info("web", .stopped)], id: id)
            state.devServerListFetcher = { _, run in asked.append(run); return result }
            await state.refreshDevServers(worktreeID: id, trigger: .selection)
            #expect(asked == [false])
        }
    }

    @Test func aChangeDeltaRefreshesTheSelectedListWithoutStatusCommands() async {
        await withState { state in
            let id = UUID()
            var asked: [Bool] = []
            let result = self.list([self.info("web", .stopped)], id: id)
            state.devServerListFetcher = { _, run in asked.append(run); return result }
            state.devServerSummaryFetcher = { DevServerSummaryResult(runningWorktreeIDs: []) }
            state.selectedWorktreeIDs = [id]
            asked = []
            await state.refreshDevServersAfterChange()
            #expect(asked.last == false)
            #expect(!asked.contains(true), "a delta ran the repo's status commands")
        }
    }

    @Test func refreshStatusAndActionsAskWithStatusCommands() async {
        await withState { state in
            let id = UUID()
            var asked: [Bool] = []
            let result = self.list([self.info("web", .stopped)], id: id)
            state.devServerListFetcher = { _, run in asked.append(run); return result }
            state.devServerSummaryFetcher = { DevServerSummaryResult(runningWorktreeIDs: []) }
            state.devServerActionSender = { _, _, _ in
                DevServerActionResult(outcomes: [.init(name: "web", status: .started)])
            }
            await state.refreshDevServerStatus(worktreeID: id)
            #expect(asked == [true])
            asked = []
            await state.performDevServerAction(.start, worktreeID: id, names: ["web"])
            #expect(asked == [true])
        }
    }

    /// A refresh without `status` commands reads a status-only server as
    /// stopped; the menu keeps what its last `status` run found.
    @Test func theLastKnownStatusSurvivesARefreshWithoutStatusCommands() async {
        await withState { state in
            let id = UUID()
            let probed = self.list([self.info("db", .running), self.info("cache", .unknown),
                                    self.info("web", .stopped)], id: id)
            let quiet = self.list([self.info("db", .stopped), self.info("cache", .stopped),
                                   self.info("web", .stopped)], id: id)
            state.devServerListFetcher = { _, run in run ? probed : quiet }
            await state.refreshDevServerStatus(worktreeID: id)
            await state.refreshDevServers(worktreeID: id, trigger: .change)
            #expect(state.devServerLists[id]?.servers.map(\.state) == [.running, .unknown, .stopped])
            // The next `status` run replaces what is known.
            let stoppedNow = self.list([self.info("db", .stopped), self.info("cache", .stopped),
                                        self.info("web", .stopped)], id: id)
            state.devServerListFetcher = { _, run in run ? stoppedNow : quiet }
            await state.refreshDevServerStatus(worktreeID: id)
            await state.refreshDevServers(worktreeID: id, trigger: .selection)
            #expect(state.devServerLists[id]?.servers.map(\.state) == [.stopped, .stopped, .stopped])
        }
    }

    /// Before any `status` run, a status-only server reads stopped.
    @Test func withoutAStatusRunAStatusOnlyServerReadsStopped() async {
        await withState { state in
            let id = UUID()
            let quiet = self.list([self.info("db", .stopped)], id: id)
            state.devServerListFetcher = { _, _ in quiet }
            await state.refreshDevServers(worktreeID: id, trigger: .selection)
            #expect(state.devServerLists[id] == quiet)
        }
    }

    /// Only a state that a `status` command alone produced is remembered: a
    /// server running by its TBD tab or a running file is read live.
    @Test func onlyStatusOnlyStatesAreRemembered() {
        var tabbed = info("tab", .running)
        tabbed.terminalID = UUID()
        tabbed.pid = 42
        let filed = info("file", .running, url: "http://localhost:1")
        var undeclared = info("loose", .running)
        undeclared.source = nil
        let l = list([info("db", .running), info("cache", .unknown), info("web", .stopped),
                      tabbed, filed, undeclared])
        #expect(AppState.statusOnlyStates(in: l) == ["db": .running, "cache": .unknown])
    }

    /// A live state (exited tab, running file) wins over a remembered one.
    @Test func aLiveStateWinsOverTheLastKnownStatus() {
        let l = list([info("db", .exited), info("web", .stopped)])
        let merged = AppState.withLastKnownStatus(l, lastKnown: ["db": .running, "web": .running])
        #expect(merged.servers.map(\.state) == [.exited, .running])
    }

    /// A slow `status` run overtaken by a quick refresh without one (a Start
    /// is followed by the daemon's change delta) still lands its answers.
    @Test func anOvertakenStatusRunStillLandsItsAnswers() async {
        await withState { state in
            let id = UUID()
            let probed = self.list([self.info("db", .running)], id: id)
            let quiet = self.list([self.info("db", .stopped)], id: id)
            var pending: CheckedContinuation<DevServerListResult, Never>?
            state.devServerListFetcher = { _, run in
                if run { return await withCheckedContinuation { pending = $0 } }
                return quiet
            }
            let slow = Task { await state.refreshDevServerStatus(worktreeID: id) }
            for _ in 0..<500 where pending == nil { await Task.yield() }
            guard let held = pending else {
                Issue.record("the status refresh never reached its fetch")
                return
            }
            await state.refreshDevServers(worktreeID: id, trigger: .change)
            #expect(state.devServerLists[id]?.servers.map(\.state) == [.stopped])
            held.resume(returning: probed)
            await slow.value
            #expect(state.devServerLists[id]?.servers.map(\.state) == [.running])
        }
    }

    /// Refreshes overlap (their triggers do not await them): a read that
    /// started earlier but answers later must not overwrite a newer one.
    @Test func anOlderListRefreshCannotOverwriteANewerOne() async {
        await withState { state in
            let id = UUID()
            let older = self.list([self.info("web", .running)], id: id)
            let newer = self.list([self.info("web", .stopped)], id: id)
            var pending: CheckedContinuation<DevServerListResult, Never>?
            var calls = 0
            state.devServerListFetcher = { _, _ in
                calls += 1
                if calls == 1 { return await withCheckedContinuation { pending = $0 } }
                return newer
            }
            let first = Task { await state.refreshDevServers(worktreeID: id, trigger: .selection) }
            for _ in 0..<500 where pending == nil { await Task.yield() }
            guard let held = pending else {
                Issue.record("the first refresh never reached its fetch")
                return
            }
            await state.refreshDevServers(worktreeID: id, trigger: .selection)
            #expect(state.devServerLists[id] == newer)
            held.resume(returning: older)
            await first.value
            #expect(state.devServerLists[id] == newer, "the older read landed over the newer one")
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
