import Foundation
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

@MainActor
@Suite("Main toolbar snapshot")
struct MainToolbarSnapshotTests {
    private func withState(_ body: (AppState, [Repo], [Worktree]) throws -> Void) rethrows {
        let suite = TestDefaultsSuite("TBDAppTests.MainToolbarSnapshot")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let first = Repo(path: "/tmp/acme", displayName: "acme")
        let second = Repo(path: "/tmp/widgets", displayName: "widgets")
        state.repos = [first, second]
        let worktrees = [
            Worktree(repoID: first.id, name: "main", displayName: "main", branch: "main",
                     path: "/tmp/acme", status: .main, tmuxServer: "acme"),
            Worktree(repoID: first.id, name: "feature", displayName: "feature", branch: "feature",
                     path: "/tmp/acme-feature", tmuxServer: "acme"),
        ]
        state.worktrees = [first.id: worktrees]
        try body(state, [first, second], worktrees)
    }

    private func server(_ name: String, _ state: DevServerStateKind, url: String? = nil) -> DevServerInfo {
        DevServerInfo(name: name, label: name, source: "tbd.toml", state: state, exitCode: nil,
                      endpoints: url.map { [DevServerEndpoint(name: "app", url: $0)] } ?? [],
                      terminalID: nil, pid: nil, hasStopCommand: false,
                      stateFromStatusCommand: nil, hasStatusCommand: true, exitedTab: nil)
    }

    private func list(_ servers: [DevServerInfo], id: UUID) -> DevServerListResult {
        DevServerListResult(worktreeID: id, servers: servers, parseErrors: [], runningFileDiagnostics: [])
    }

    @Test func nothingSelected() {
        withState { state, repos, _ in
            let snapshot = MainToolbarSnapshot.make(from: state)
            #expect(snapshot.servers == nil)
            #expect(snapshot.remote == nil)
            let titles: [String] = snapshot.filter.options.map(\.title)
            #expect(titles == ["All Repos", "acme", "widgets"])
            let ids: [UUID?] = snapshot.filter.options.map(\.id)
            let expectedIDs: [UUID?] = [nil, repos[0].id, repos[1].id]
            #expect(ids == expectedIDs)
            #expect(snapshot.filter.selected == nil)
            #expect(snapshot.filter.selectedIsKnown)
        }
    }

    @Test func filterNamingAMissingRepo() {
        withState { state, _, _ in
            let missing = UUID()
            state.repoFilter = missing
            let filter = MainToolbarSnapshot.make(from: state).filter
            #expect(!filter.selectedIsKnown)
            #expect(filter.selected == missing)
        }
    }

    @Test func serversNeedOneSelectedWorktreeAndAList() {
        withState { state, _, worktrees in
            let a = worktrees[0].id
            let b = worktrees[1].id
            state.devServerLists[a] = list([server("web", .stopped)], id: a)

            state.selectedWorktreeIDs = [a, b]
            #expect(MainToolbarSnapshot.make(from: state).servers == nil)

            state.selectedWorktreeIDs = [b]
            #expect(MainToolbarSnapshot.make(from: state).servers == nil)

            state.selectedWorktreeIDs = [a]
            let idle = MainToolbarSnapshot.make(from: state).servers
            #expect(idle?.worktreeID == a)
            #expect(idle?.title == "Servers")
            #expect(idle?.isRunning == false)
            #expect(idle?.primaryURL == nil)
            #expect(idle?.help == "Dev servers")
            #expect(idle?.accessibilityLabel == "Dev servers")

            state.devServerLists[a] = list(
                [server("web", .running, url: "http://localhost:3000"), server("api", .running)], id: a)
            let running = MainToolbarSnapshot.make(from: state).servers
            #expect(running?.title == "2 running")
            #expect(running?.isRunning == true)
            #expect(running?.primaryURL == "http://localhost:3000")
            #expect(running?.help == "Open http://localhost:3000 · more options")
            #expect(running?.accessibilityLabel == "Dev servers, 2 running")

            state.devServerLists[a] = list([], id: a)
            #expect(MainToolbarSnapshot.make(from: state).servers == nil)
        }
    }

    @Test func remoteFlagsMirrorAppState() {
        withState { state, _, _ in
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            #expect(MainToolbarSnapshot.make(from: state).remote == nil)

            state.remoteProviders = [RemoteProviderStatus(
                config: RemoteProviderConfig(name: "acme", exec: "/bin/acme"),
                describe: nil, health: .ok, errorMessage: nil, remediationLabel: nil, remediationCommand: nil)]
            state.remoteSessions = [RemoteSessionInfo(
                provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                gone: false, dismissed: false, lastSeen: Date())]
            state.selectedRemoteSession = selection

            let remote = MainToolbarSnapshot.make(from: state).remote
            #expect(remote?.selection == selection)
            #expect(remote?.showsStop == state.remoteSessionShowsStop(selection))
            #expect(remote?.showsReconnect == state.attachedRemoteSelections.contains(selection))
            #expect(remote?.showsTranscript == state.remoteSessionShowsTranscriptToggle(selection))
            #expect(remote?.transcriptOpen == state.remoteTranscriptOpen)
            #expect(remote?.showsStop == true)

            // A session the mirror no longer holds offers no Stop; with the
            // other two flags false too, the whole group disappears.
            state.remoteSessions = []
            let gone = MainToolbarSnapshot.make(from: state).remote
            let anyFlag = state.remoteSessionShowsStop(selection)
                || state.attachedRemoteSelections.contains(selection)
                || state.remoteSessionShowsTranscriptToggle(selection)
            #expect((gone != nil) == anyFlag)
        }
    }

    @Test func remotePresentationSymbolAndHelp() {
        let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
        let open = RemotePresentation(
            selection: selection, showsTranscript: true, showsReconnect: false,
            showsStop: false, transcriptOpen: true)
        var closed = open
        closed.transcriptOpen = false
        #expect(open.transcriptSymbolName == "text.bubble.fill")
        #expect(open.transcriptHelp == "Hide transcript")
        #expect(closed.transcriptSymbolName == "text.bubble")
        #expect(closed.transcriptHelp == "Show transcript")
    }

    @Test func layoutStateMapsPresence() {
        let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
        let filter = RepoFilterPresentation(
            options: [.init(id: nil, title: "All Repos")], selected: nil, selectedIsKnown: true)
        let servers = ServersPresentation(
            worktreeID: UUID(), title: "Servers", isRunning: false, primaryURL: nil,
            help: "Dev servers", accessibilityLabel: "Dev servers")
        let remote = RemotePresentation(
            selection: selection, showsTranscript: true, showsReconnect: false,
            showsStop: true, transcriptOpen: false)

        let bare = MainToolbarSnapshot(
            canGoBack: false, canGoForward: false, filter: filter, servers: nil, remote: nil)
        #expect(bare.layoutState(sidebarCollapsed: false) == MainToolbarLayoutState(
            sidebarCollapsed: false, showsServers: false, showsTranscript: false,
            showsReconnect: false, showsStop: false))

        let full = MainToolbarSnapshot(
            canGoBack: true, canGoForward: true, filter: filter, servers: servers, remote: remote)
        #expect(full.layoutState(sidebarCollapsed: true) == MainToolbarLayoutState(
            sidebarCollapsed: true, showsServers: true, showsTranscript: true,
            showsReconnect: false, showsStop: true))
    }

    @Test func backForwardMirrorHistory() {
        withState { state, _, worktrees in
            var snapshot = MainToolbarSnapshot.make(from: state)
            #expect(snapshot.canGoBack == state.canGoBack)
            #expect(snapshot.canGoForward == state.canGoForward)

            state.recordNavigation(.worktrees([worktrees[0].id]))
            state.recordNavigation(.worktrees([worktrees[1].id]))
            snapshot = MainToolbarSnapshot.make(from: state)
            #expect(snapshot.canGoBack == state.canGoBack)
            #expect(snapshot.canGoForward == state.canGoForward)
            #expect(snapshot.canGoBack)
            #expect(!snapshot.canGoForward)

            state.navigateBack()
            snapshot = MainToolbarSnapshot.make(from: state)
            #expect(snapshot.canGoBack == state.canGoBack)
            #expect(snapshot.canGoForward == state.canGoForward)
            #expect(snapshot.canGoForward)
        }
    }
}
