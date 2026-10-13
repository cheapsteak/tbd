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

    /// `fromStatus` marks a state the server's `status` command decided, as
    /// the daemon does.
    private func info(_ name: String, _ state: DevServerStateKind, url: String? = nil,
                      fromStatus: Bool = false, terminalID: UUID? = nil) -> DevServerInfo {
        DevServerInfo(name: name, label: name, source: "tbd.toml", state: state, exitCode: nil,
                      endpoints: url.map { [DevServerEndpoint(name: "app", url: $0)] } ?? [],
                      terminalID: terminalID, pid: nil, hasStopCommand: false,
                      stateFromStatusCommand: fromStatus ? true : nil, hasStatusCommand: true)
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
            let probed = self.list([self.info("db", .running, fromStatus: true),
                                    self.info("cache", .unknown, fromStatus: true),
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

    /// Only a state the daemon says a `status` command decided is
    /// remembered, with the tab the server had then: a server running by its
    /// TBD tab or a running file is read live.
    @Test func onlyStatesTheStatusCommandDecidedAreRemembered() {
        let tab = UUID()
        var tabbed = info("tab", .running, terminalID: UUID())
        tabbed.pid = 42
        let filed = info("file", .running, url: "http://localhost:1")
        let l = list([info("db", .running, fromStatus: true, terminalID: tab),
                      info("cache", .unknown, fromStatus: true), info("web", .stopped),
                      info("plain", .running), tabbed, filed])
        #expect(AppState.statusCommandStates(in: l) == [
            "db": DevServerRememberedStatus(state: .running, terminalID: tab),
            "cache": DevServerRememberedStatus(state: .unknown, terminalID: nil),
        ])
    }

    /// The remembered answer covers a stopped server, and an exited one whose
    /// tab is the one the `status` run saw (a detached command's finished
    /// tab). A newer exited tab and every other state are live and win.
    @Test func theLastKnownStatusCoversAStoppedServerAndTheSameExitedTab() {
        let seen = UUID(), newer = UUID()
        var savedOnly = info("saved", .exited)
        savedOnly.lastOutputID = seen
        let l = list([info("same", .exited, terminalID: seen), info("newer", .exited, terminalID: newer),
                      info("web", .stopped), savedOnly, info("tabless", .exited),
                      info("live", .unknown, terminalID: seen)])
        let known = DevServerRememberedStatus(state: .running, terminalID: seen)
        let merged = AppState.withLastKnownStatus(l, lastKnown: [
            "same": known, "newer": known, "web": DevServerRememberedStatus(state: .running, terminalID: nil),
            "saved": known, "tabless": DevServerRememberedStatus(state: .running, terminalID: nil),
            "live": known,
        ])
        #expect(merged.servers.map(\.state) == [.running, .exited, .running, .running, .exited, .unknown])
    }

    /// `docker compose up -d db` with `status = "docker compose ps db"`: the
    /// command exits at once and its tab reads exited, so only the `status`
    /// command knows the container runs. The daemon's next change delta
    /// (no `status` commands) must not flip the menu to Exited.
    @Test func aDetachedServerStaysRunningAfterItsTabExits() async {
        await withState { state in
            let id = UUID(), tab = UUID()
            let probed = self.list([self.info("db", .running, fromStatus: true, terminalID: tab)], id: id)
            let quiet = self.list([self.info("db", .exited, terminalID: tab)], id: id)
            state.devServerListFetcher = { _, run in run ? probed : quiet }
            state.devServerSummaryFetcher = { DevServerSummaryResult(runningWorktreeIDs: []) }
            state.devServerActionSender = { _, _, _ in
                DevServerActionResult(outcomes: [.init(name: "db", status: .started, terminalID: tab)])
            }
            await state.performDevServerAction(.start, worktreeID: id, names: ["db"])
            #expect(state.devServerLists[id]?.servers.map(\.state) == [.running])
            await state.refreshDevServers(worktreeID: id, trigger: .change)
            #expect(state.devServerLists[id]?.servers.map(\.state) == [.running])
            // A newer start's tab that exited is a new fact and wins.
            let restarted = self.list([self.info("db", .exited, terminalID: UUID())], id: id)
            state.devServerListFetcher = { _, _ in restarted }
            await state.refreshDevServers(worktreeID: id, trigger: .change)
            #expect(state.devServerLists[id]?.servers.map(\.state) == [.exited])
        }
    }

    /// A remembered answer is dropped once the server no longer declares a
    /// `status` command, or is gone; it does not come back with it.
    @Test func aRememberedAnswerIsDroppedWithItsStatusCommandOrServer() async {
        await withState { state in
            let id = UUID()
            let probed = self.list([self.info("db", .running, fromStatus: true),
                                    self.info("cache", .running, fromStatus: true)], id: id)
            var noStatus = self.info("db", .stopped)
            noStatus.hasStatusCommand = false
            let changed = self.list([noStatus], id: id)
            let back = self.list([self.info("db", .stopped), self.info("cache", .stopped)], id: id)
            state.devServerListFetcher = { _, run in run ? probed : changed }
            await state.refreshDevServerStatus(worktreeID: id)
            #expect(state.devServerLastStatus[id]?.count == 2)
            await state.refreshDevServers(worktreeID: id, trigger: .change)
            #expect(state.devServerLists[id]?.servers.map(\.state) == [.stopped])
            #expect(state.devServerLastStatus[id] == nil)
            state.devServerListFetcher = { _, _ in back }
            await state.refreshDevServers(worktreeID: id, trigger: .change)
            #expect(state.devServerLists[id]?.servers.map(\.state) == [.stopped, .stopped])
        }
    }

    /// An archived worktree leaves nothing remembered behind.
    @Test func archivingAWorktreeForgetsItsDevServerState() async {
        await withState { state in
            let id = UUID()
            let probed = self.list([self.info("db", .running, fromStatus: true)], id: id)
            state.devServerListFetcher = { _, _ in probed }
            await state.refreshDevServerStatus(worktreeID: id)
            #expect(state.devServerLastStatus[id] != nil)
            state.removeArchivedWorktreeFromState(id: id)
            #expect(state.devServerLastStatus[id] == nil)
            #expect(state.devServerFetchedLists[id] == nil)
            #expect(state.devServerStatusGenerations[id] == nil)
            #expect(state.devServerLandedStatusGenerations[id] == nil)
            #expect(state.devServerLists[id] == nil)
        }
    }

    /// A newer `status` run that fails must not discard the answers of an
    /// older run still in flight.
    @Test func aFailedNewerStatusRunLeavesAnOlderRunsAnswers() async {
        struct Refused: Error {}
        await withState { state in
            let id = UUID()
            let probed = self.list([self.info("db", .running, fromStatus: true)], id: id)
            let quiet = self.list([self.info("db", .stopped)], id: id)
            var pending: CheckedContinuation<DevServerListResult, Never>?
            var statusCalls = 0
            state.devServerListFetcher = { _, run in
                guard run else { return quiet }
                statusCalls += 1
                if statusCalls == 1 { return await withCheckedContinuation { pending = $0 } }
                throw Refused()
            }
            await state.refreshDevServers(worktreeID: id, trigger: .selection)
            let slow = Task { await state.refreshDevServerStatus(worktreeID: id) }
            for _ in 0..<500 where pending == nil { await Task.yield() }
            guard let held = pending else {
                Issue.record("the first status refresh never reached its fetch")
                return
            }
            await state.refreshDevServerStatus(worktreeID: id)
            #expect(statusCalls == 2)
            held.resume(returning: probed)
            await slow.value
            #expect(state.devServerLists[id]?.servers.map(\.state) == [.running])
        }
    }

    /// A slow `status` run overtaken by a quick refresh without one (a Start
    /// is followed by the daemon's change delta) still lands its answers.
    @Test func anOvertakenStatusRunStillLandsItsAnswers() async {
        await withState { state in
            let id = UUID()
            let probed = self.list([self.info("db", .running, fromStatus: true)], id: id)
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
