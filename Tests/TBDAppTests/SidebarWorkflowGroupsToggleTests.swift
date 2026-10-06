import Foundation
import Testing
@testable import TBDApp
import TBDShared

extension SidebarSectionLayout {
    /// Group headers the section views mount for this layout, in render
    /// order, derived from the same fields they branch on. A collapsed Remote
    /// header still counts its Exited child, which mounts once it expands.
    var groupKinds: [SidebarGroupID.Kind] {
        var kinds: [SidebarGroupID.Kind] = []
        if let remoteGroups {
            kinds.append(.remote)
            if remoteGroups.hasExited { kinds.append(.exited) }
        }
        if hibernation != nil { kinds.append(.hibernated) }
        return kinds
    }
}

/// The Settings toggle that files remote, exited and hibernated rows under
/// sidebar groups (`AppState.sidebarWorkflowGroupsKey`), and the persisted
/// expansion state those groups keep across launches.
/// Spec: docs/specs/2026-10-06-sidebar-groups-toggle-design.md.
@MainActor
@Suite("Sidebar workflow groups toggle")
struct SidebarWorkflowGroupsToggleTests {
    private func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let suite = "SidebarWorkflowGroupsToggleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, suite)
    }

    private func park(_ row: Worktree, in state: AppState) {
        state.terminals[row.id] = [Terminal(
            worktreeID: row.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude,
            hibernatedAt: Date(timeIntervalSince1970: 1_800_000_000))]
    }

    /// A repository holding one row of every kind the groups move: working
    /// local, running remote, exited remote, wholly parked local, plus an
    /// unadopted running session and an unadopted exited one.
    private struct Fleet {
        let repoID: UUID
        let working: Worktree, running: Worktree, ended: Worktree, parked: Worktree
    }

    private func makeFleet(in state: AppState) -> Fleet {
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        state.repos = [repo]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        let working = SidebarGroupFixtures.row("working", repoID: repo.id, order: 0)
        let running = SidebarGroupFixtures.row("running", repoID: repo.id, remote: "lane-running", order: 1)
        let parked = SidebarGroupFixtures.row("parked", repoID: repo.id, order: 2)
        let ended = SidebarGroupFixtures.row("ended", repoID: repo.id, remote: "lane-ended", order: 3)
        state.worktrees = [repo.id: [working, running, parked, ended]]
        park(parked, in: state)
        state.remoteSessions = [
            SidebarGroupFixtures.session("lane-running", repoID: repo.id),
            SidebarGroupFixtures.session("lane-ended", state: .exited, repoID: repo.id),
            SidebarGroupFixtures.session("loose-running", repoID: repo.id),
            SidebarGroupFixtures.session("loose-ended", state: .exited, repoID: repo.id),
            SidebarGroupFixtures.session("unmatched")
        ]
        return Fleet(repoID: repo.id, working: working, running: running, ended: ended, parked: parked)
    }

    private func matched(_ state: AppState, _ repoID: UUID) -> [RemoteSessionInfo] {
        RepoSectionView.matchedRemoteSessions(
            state.remoteSessions, repoID: repoID, worktrees: state.worktrees[repoID] ?? [])
    }

    // MARK: Three-state flag

    @Test func shippedDefaultIsOff() {
        #expect(AppState.sidebarWorkflowGroupsDefault == false)
    }

    @Test func absentKeyReadsNilAndFollowsTheShippedDefault() {
        withDefaults { defaults, _ in
            #expect(defaults.object(forKey: AppState.sidebarWorkflowGroupsKey) == nil)
            #expect(AppState.sidebarWorkflowGroupsEnabled(defaults: defaults) == AppState.sidebarWorkflowGroupsDefault)
            #expect(AppState.sidebarWorkflowGroupsEnabled(stored: nil, shippedDefault: false) == false)
            #expect(AppState.sidebarWorkflowGroupsEnabled(stored: nil, shippedDefault: true) == true)
        }
    }

    @Test func explicitChoicesHoldAgainstEitherDefault() {
        #expect(AppState.sidebarWorkflowGroupsEnabled(stored: false, shippedDefault: true) == false)
        #expect(AppState.sidebarWorkflowGroupsEnabled(stored: true, shippedDefault: false) == true)
        withDefaults { defaults, _ in
            defaults.set(false, forKey: AppState.sidebarWorkflowGroupsKey)
            #expect(defaults.object(forKey: AppState.sidebarWorkflowGroupsKey) as? Bool == false)
            #expect(AppState.sidebarWorkflowGroupsEnabled(defaults: defaults) == false)
            defaults.set(true, forKey: AppState.sidebarWorkflowGroupsKey)
            #expect(AppState.sidebarWorkflowGroupsEnabled(defaults: defaults) == true)
        }
    }

    // MARK: Off — the ungrouped layout

    @Test func offRendersEveryRepositoryRowInlineWithNoHeaders() {
        withDefaults { defaults, _ in
            let state = AppState(userDefaults: defaults)
            let fleet = makeFleet(in: state)
            let layout = state.sidebarRepositoryLayout(
                repoID: fleet.repoID, grouped: false, matchedSessions: matched(state, fleet.repoID))
            #expect(layout.groupKinds.isEmpty)
            #expect(layout.remoteGroups == nil)
            #expect(layout.hibernation == nil)
            #expect(layout.inlineRoots.map(\.id) == [fleet.working.id, fleet.running.id, fleet.parked.id, fleet.ended.id])
            #expect(Set(layout.inlineSessions.map(\.payload.id)) == ["loose-running", "loose-ended"])
            #expect(layout.inlineSessions.map(\.id) == matched(state, fleet.repoID).map(\.id))
            #expect(layout.reorderVisibleIDs == nil)
        }
    }

    @Test func offRendersProviderSessionsAndScratchInline() {
        withDefaults { defaults, _ in
            let state = AppState(userDefaults: defaults)
            _ = makeFleet(in: state)
            state.remoteSessions.append(SidebarGroupFixtures.session("unmatched-ended", state: .exited))
            let provider = state.sidebarProviderLayout(provider: "acme", grouped: false)
            #expect(provider.groupKinds.isEmpty)
            #expect(provider.inlineSessions.map(\.payload.id) == ["unmatched", "unmatched-ended"])

            let pad = Worktree(repoID: nil, name: "pad", displayName: "Pad", branch: "",
                               path: "/tmp/acme-pad", tmuxServer: "acme")
            state.scratchWorktrees = [pad]
            park(pad, in: state)
            let scratch = state.sidebarScratchLayout(grouped: false)
            #expect(scratch.groupKinds.isEmpty)
            #expect(scratch.inlineRoots.map(\.id) == [pad.id])
        }
    }

    @Test func offRevealIsANoOp() {
        withDefaults { defaults, _ in
            let state = AppState(userDefaults: defaults)
            let fleet = makeFleet(in: state)
            state.repos[0].expanded = false
            let reveal = state.sidebarGroupReveal(worktreeIDs: [fleet.ended.id, fleet.parked.id], selection: nil)
            #expect(!reveal.groups.isEmpty, "The reveal must name groups, or this test is vacuous")
            state.revealSidebarGroups(reveal, grouped: false)
            #expect(state.expandedSidebarGroups.isEmpty)
            #expect(state.repos[0].expanded == false)
            state.revealSidebarGroups(reveal, grouped: true)
            #expect(!state.expandedSidebarGroups.isEmpty, "The same reveal must act when grouped")
        }
    }

    /// Turning the toggle on mid-session opens the selection's groups but
    /// leaves a collapsed repository collapsed; only the initial mount
    /// reveals as navigation.
    @Test func turningGroupsOnNeverExpandsACollapsedRepository() {
        withDefaults { defaults, _ in
            let state = AppState(userDefaults: defaults)
            let fleet = makeFleet(in: state)
            state.repos[0].expanded = false
            let reveal = state.sidebarGroupReveal(worktreeIDs: [fleet.parked.id], selection: nil)

            #expect(SidebarView.revealBaseline(previous: nil, reveal: reveal, hasRevealed: false) == nil)
            let baseline = SidebarView.revealBaseline(previous: nil, reveal: reveal, hasRevealed: true)
            #expect(baseline == reveal)
            state.revealSidebarGroups(reveal, previous: baseline, grouped: true)
            #expect(state.expandedSidebarGroups.contains(.init(owner: .repository(fleet.repoID), kind: .hibernated)))
            #expect(state.repos[0].expanded == false)

            state.revealSidebarGroups(reveal, previous: nil, grouped: true)
            #expect(state.repos[0].expanded, "The initial-mount path must expand it, or this test is vacuous")
        }
    }

    // MARK: On — the grouped layout

    @Test func onFilesRemoteExitedAndHibernatedRowsUnderHeaders() {
        withDefaults { defaults, _ in
            let state = AppState(userDefaults: defaults)
            let fleet = makeFleet(in: state)
            let layout = state.sidebarRepositoryLayout(
                repoID: fleet.repoID, grouped: true, matchedSessions: matched(state, fleet.repoID))
            #expect(layout.groupKinds == [.remote, .exited, .hibernated])
            #expect(layout.inlineRoots.map(\.id) == [fleet.working.id])
            #expect(layout.inlineSessions.isEmpty)
            #expect(layout.reorderVisibleIDs == [fleet.working.id])
            #expect(layout.remoteGroups?.remoteRoots.map(\.id) == [fleet.running.id])
            #expect(layout.remoteGroups?.exitedRoots.map(\.id) == [fleet.ended.id])
            #expect(layout.remoteGroups?.sessions.map(\.payload.id) == ["loose-running"])
            #expect(layout.remoteGroups?.exitedSessions.map(\.payload.id) == ["loose-ended"])
            #expect(layout.hibernation?.hibernatedRoots.map(\.id) == [fleet.parked.id])

            let provider = state.sidebarProviderLayout(provider: "acme", grouped: true)
            #expect(provider.groupKinds == [.remote])
            #expect(provider.inlineSessions.isEmpty)

            let reveal = state.sidebarGroupReveal(worktreeIDs: [fleet.parked.id], selection: nil)
            state.revealSidebarGroups(reveal, grouped: true)
            #expect(state.expandedSidebarGroups.contains(.init(owner: .repository(fleet.repoID), kind: .hibernated)))
        }
    }

    // MARK: Persisted expansion

    @Test func expandedGroupsSurviveAFreshAppState() {
        withDefaults { defaults, _ in
            let repoID = UUID()
            let groups: Set<SidebarGroupID> = [
                .init(owner: .repository(repoID), kind: .remote),
                .init(owner: .repository(repoID), kind: .exited),
                .init(owner: .provider("acme|west"), kind: .remote),
                .init(owner: .scratch, kind: .hibernated)
            ]
            let first = AppState(userDefaults: defaults)
            for group in groups { first.toggleSidebarGroup(group) }
            #expect(AppState(userDefaults: defaults).expandedSidebarGroups == groups)

            first.toggleSidebarGroup(.init(owner: .repository(repoID), kind: .exited))
            #expect(AppState(userDefaults: defaults).expandedSidebarGroups
                    == groups.subtracting([.init(owner: .repository(repoID), kind: .exited)]))
        }
    }

    @Test func constructingAppStateWritesNoExpansionState() {
        withDefaults { defaults, _ in
            _ = AppState(userDefaults: defaults)
            #expect(defaults.object(forKey: AppState.sidebarExpandedGroupsKey) == nil)
            let state = AppState(userDefaults: defaults)
            state.toggleSidebarGroup(.init(owner: .scratch, kind: .hibernated))
            state.toggleSidebarGroup(.init(owner: .scratch, kind: .hibernated))
            #expect(defaults.stringArray(forKey: AppState.sidebarExpandedGroupsKey) == [])
        }
    }

    @Test func unreadableEntriesAreDropped() {
        withDefaults { defaults, _ in
            defaults.set(["remote|repository|not-a-uuid", "sideways|scratch|", "remote|provider|",
                          "hibernated|scratch|"], forKey: AppState.sidebarExpandedGroupsKey)
            #expect(AppState(userDefaults: defaults).expandedSidebarGroups == [.init(owner: .scratch, kind: .hibernated)])
        }
    }

    @Test func pruningForgetsVanishedOwnersOnly() {
        withDefaults { defaults, _ in
            let kept = UUID(), gone = UUID()
            let state = AppState(userDefaults: defaults)
            state.expandedSidebarGroups = [
                .init(owner: .repository(kept), kind: .remote),
                .init(owner: .repository(gone), kind: .hibernated),
                .init(owner: .provider("acme"), kind: .remote),
                .init(owner: .provider("retired"), kind: .exited),
                .init(owner: .scratch, kind: .hibernated)
            ]
            state.pruneExpandedSidebarGroups(repoIDs: [kept])
            state.pruneExpandedSidebarGroups(providerNames: ["acme"])
            let expected: Set<SidebarGroupID> = [
                .init(owner: .repository(kept), kind: .remote),
                .init(owner: .provider("acme"), kind: .remote),
                .init(owner: .scratch, kind: .hibernated)
            ]
            #expect(state.expandedSidebarGroups == expected)
            #expect(AppState(userDefaults: defaults).expandedSidebarGroups == expected)
        }
    }

    /// `refreshRepos` prunes repository groups only on a successful fetch.
    @Test func refreshReposPrunesOnlyOnASuccessfulFetch() async {
        let suite = "SidebarWorkflowGroupsToggleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(userDefaults: defaults)
        let kept = Repo(path: "/tmp/acme", displayName: "acme")
        let goneID = UUID()
        let gone = SidebarGroupID(owner: .repository(goneID), kind: .remote)
        state.expandedSidebarGroups = [.init(owner: .repository(kept.id), kind: .hibernated), gone]

        state.reposFetcher = { throw DaemonClientError.connectionFailed("boom") }
        await state.refreshRepos()
        #expect(state.expandedSidebarGroups.contains(gone))

        state.reposFetcher = { [kept] }
        await state.refreshRepos()
        #expect(state.expandedSidebarGroups == [.init(owner: .repository(kept.id), kind: .hibernated)])
    }

    /// `refreshRemote` prunes provider groups only on a successful roster:
    /// a disabled-backend refusal and a genuine RPC failure both keep them.
    @Test func refreshRemotePrunesOnlyOnASuccessfulRoster() async {
        let suite = "SidebarWorkflowGroupsToggleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(userDefaults: defaults)
        let retired = SidebarGroupID(owner: .provider("retired"), kind: .remote)
        state.expandedSidebarGroups = [retired]
        state.retainedTranscriptsFetcher = { [] }
        state.remoteSessionsFetcher = { RemoteSessionsResult(sessions: []) }

        state.remoteProvidersFetcher = {
            throw DaemonClientError.rpcError(AppState.remoteBackendsDisabledMessage, code: nil)
        }
        await state.refreshRemote()
        #expect(state.expandedSidebarGroups == [retired])

        state.remoteProvidersFetcher = { throw DaemonClientError.connectionFailed("boom") }
        await state.refreshRemote()
        #expect(state.expandedSidebarGroups == [retired])

        state.remoteProvidersFetcher = { RemoteProvidersResult(providers: [SidebarGroupFixtures.provider()]) }
        await state.refreshRemote()
        #expect(state.expandedSidebarGroups.isEmpty)
        #expect(AppState(userDefaults: defaults).expandedSidebarGroups.isEmpty)
    }
}
