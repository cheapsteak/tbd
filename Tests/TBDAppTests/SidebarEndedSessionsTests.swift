import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The default-off "Collapse ended remote sessions" sidebar option:
/// `AppState.sidebarCollapseEndedSessionsKey`, the pure ended/live partition,
/// the layout gates, the persisted group identity and the selection reveal.
@MainActor
@Suite("Sidebar collapse ended sessions")
struct SidebarEndedSessionsTests {
    private func withState(_ body: (AppState) -> Void) {
        let suite = "SidebarEndedSessionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(AppState(userDefaults: defaults))
    }

    private func key(_ id: String) -> RemoteSessionSelection {
        RemoteSessionSelection(provider: "acme", sessionID: id)
    }

    // MARK: Three-state flag

    @Test func shippedDefaultIsOff() {
        #expect(AppState.sidebarCollapseEndedSessionsDefault == false)
    }

    @Test func resolverFollowsDefaultWhenAbsentAndHoldsExplicitChoices() {
        #expect(AppState.sidebarCollapseEndedSessionsEnabled(stored: nil, shippedDefault: false) == false)
        #expect(AppState.sidebarCollapseEndedSessionsEnabled(stored: nil, shippedDefault: true) == true)
        #expect(AppState.sidebarCollapseEndedSessionsEnabled(stored: false, shippedDefault: true) == false)
        #expect(AppState.sidebarCollapseEndedSessionsEnabled(stored: true, shippedDefault: false) == true)
        let suite = "SidebarEndedSessionsTests.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppState.sidebarCollapseEndedSessionsEnabled(defaults: defaults)
                == AppState.sidebarCollapseEndedSessionsDefault)
        defaults.set(true, forKey: AppState.sidebarCollapseEndedSessionsKey)
        #expect(AppState.sidebarCollapseEndedSessionsEnabled(defaults: defaults) == true)
    }

    // MARK: Partition

    @Test func exitedAndGoneAreEndedEverythingElseIsLive() {
        let sessions = [
            SidebarGroupFixtures.session("run"),
            SidebarGroupFixtures.session("exit", state: .exited),
            SidebarGroupFixtures.session("start", state: .starting),
            SidebarGroupFixtures.session("gone-running", gone: true),
            SidebarGroupFixtures.session("unknown", state: .unknown),
            SidebarGroupFixtures.session("gone-exited", state: .exited, gone: true)
        ]
        let split = SidebarEndedSessions(sessions: sessions, unread: [:])
        #expect(split.live.map(\.payload.id) == ["run", "start", "unknown"])
        #expect(split.ended.map(\.payload.id) == ["exit", "gone-running", "gone-exited"])
        #expect(split.endedIDs == Set(split.ended.map(\.id)))
        #expect(split.summary.counts == [.exited: 1, .gone: 2])
    }

    @Test func attentionComesFromEndedUnreadOnlyAndSkipsRoutineCompletions() {
        let sessions = [SidebarGroupFixtures.session("live"), SidebarGroupFixtures.session("a", state: .exited),
                        SidebarGroupFixtures.session("b", gone: true)]
        let now = Date()
        let liveOnly = SidebarEndedSessions(
            sessions: sessions, unread: [key("live"): UnreadSummary(type: .error, mostRecentAt: now)])
        #expect(liveOnly.summary.attention == nil)
        let routine = SidebarEndedSessions(sessions: sessions, unread: [
            key("a"): UnreadSummary(type: .responseComplete, mostRecentAt: now),
            key("b"): UnreadSummary(type: .taskComplete, mostRecentAt: now)])
        #expect(routine.summary.attention == nil)
        let mixed = SidebarEndedSessions(sessions: sessions, unread: [
            key("a"): UnreadSummary(type: .attentionNeeded, mostRecentAt: now),
            key("b"): UnreadSummary(type: .error, mostRecentAt: now)])
        let expected = [NotificationType.attentionNeeded, .error].max { $0.severity < $1.severity }
        #expect(mixed.summary.attention == expected)
    }

    // MARK: Layout gates

    private func fleet(_ state: AppState) -> UUID {
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        state.repos = [repo]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        state.worktrees = [repo.id: []]
        state.remoteSessions = [
            SidebarGroupFixtures.session("run", repoID: repo.id),
            SidebarGroupFixtures.session("exit", state: .exited, repoID: repo.id),
            SidebarGroupFixtures.session("gone", gone: true, repoID: repo.id),
            SidebarGroupFixtures.session("loose-run"),
            SidebarGroupFixtures.session("loose-exit", state: .exited)
        ]
        return repo.id
    }

    private func repoLayout(_ state: AppState, _ repoID: UUID, grouped: Bool, collapse: Bool) -> SidebarSectionLayout {
        state.sidebarRepositoryLayout(
            repoID: repoID, grouped: grouped, collapseEnded: collapse,
            matchedSessions: state.sidebarMatchedRemoteSessions(repoID: repoID))
    }

    @Test func repositoryFlagOffKeepsEverythingInline() {
        withState { state in
            let repoID = fleet(state)
            let layout = repoLayout(state, repoID, grouped: false, collapse: false)
            #expect(layout.ended == nil)
            #expect(Set(layout.inlineSessions.map(\.payload.id)) == ["run", "exit", "gone"])
        }
    }

    @Test func repositoryFlagOnSplitsAndOmitsHeaderWhenNothingEnded() {
        withState { state in
            let repoID = fleet(state)
            let layout = repoLayout(state, repoID, grouped: false, collapse: true)
            #expect(layout.inlineSessions.map(\.payload.id) == ["run"])
            #expect(Set(layout.ended?.ended.map(\.payload.id) ?? []) == ["exit", "gone"])
            state.remoteSessions = state.remoteSessions.filter { $0.payload.state != .exited && !$0.gone }
            let none = repoLayout(state, repoID, grouped: false, collapse: true)
            #expect(none.ended == nil)
            #expect(none.inlineSessions.map(\.payload.id) == ["run"])
        }
    }

    @Test func providerFlagOffAndOn() {
        withState { state in
            _ = fleet(state)
            let off = state.sidebarProviderLayout(provider: "acme", grouped: false, collapseEnded: false)
            #expect(off.ended == nil)
            #expect(off.inlineSessions.map(\.payload.id) == ["loose-run", "loose-exit"])
            let on = state.sidebarProviderLayout(provider: "acme", grouped: false, collapseEnded: true)
            #expect(on.inlineSessions.map(\.payload.id) == ["loose-run"])
            #expect(on.ended?.ended.map(\.payload.id) == ["loose-exit"])
            state.remoteSessions = state.remoteSessions.filter { $0.payload.id != "loose-exit" }
            #expect(state.sidebarProviderLayout(provider: "acme", grouped: false, collapseEnded: true).ended == nil)
        }
    }

    @Test func groupedIgnoresTheFlag() {
        withState { state in
            let repoID = fleet(state)
            let off = repoLayout(state, repoID, grouped: true, collapse: false)
            let on = repoLayout(state, repoID, grouped: true, collapse: true)
            #expect(on.ended == nil && off.ended == nil)
            #expect(on.inlineSessions.map(\.id) == off.inlineSessions.map(\.id))
            #expect(on.groupKinds == off.groupKinds)
            #expect(on.remoteGroups?.sessions.map(\.id) == off.remoteGroups?.sessions.map(\.id))
            #expect(on.remoteGroups?.exitedSessions.map(\.id) == off.remoteGroups?.exitedSessions.map(\.id))
            let pOff = state.sidebarProviderLayout(provider: "acme", grouped: true, collapseEnded: false)
            let pOn = state.sidebarProviderLayout(provider: "acme", grouped: true, collapseEnded: true)
            #expect(pOn.ended == nil && pOff.ended == nil)
            #expect(pOn.groupKinds == pOff.groupKinds)
            #expect(pOn.remoteGroups?.exitedSessions.map(\.id) == pOff.remoteGroups?.exitedSessions.map(\.id))
        }
    }

    // MARK: Persistence

    @Test func endedGroupKeyRoundTrips() {
        let repo = UUID()
        for owner in [SidebarGroupID.Owner.repository(repo), .provider("acme|x")] {
            let id = SidebarGroupID(owner: owner, kind: .ended)
            #expect(id.persistenceKey.hasPrefix("ended|"))
            #expect(SidebarGroupID(persistenceKey: id.persistenceKey) == id)
        }
        #expect(SidebarGroupID(persistenceKey: "ended|scratch|") == nil)
    }

    // MARK: Reveal

    @Test func revealOwnerFollowsWhereTheRowRenders() {
        withState { state in
            let repoID = fleet(state)
            #expect(state.sidebarEndedRevealGroups(selection: key("exit"))
                    == [.init(owner: .repository(repoID), kind: .ended)])
            #expect(state.sidebarEndedRevealGroups(selection: key("gone"))
                    == [.init(owner: .repository(repoID), kind: .ended)])
            #expect(state.sidebarEndedRevealGroups(selection: key("loose-exit"))
                    == [.init(owner: .provider("acme"), kind: .ended)])
        }
    }

    @Test func revealIsEmptyForLiveAdoptedDismissedArchivedMissingAndNil() {
        withState { state in
            let repoID = fleet(state)
            state.worktrees[repoID] = [SidebarGroupFixtures.row("adopted", repoID: repoID, remote: "exit")]
            state.remoteSessions += [
                SidebarGroupFixtures.session("dismissed", state: .exited, dismissed: true, repoID: repoID),
                SidebarGroupFixtures.session("archived", state: .exited, archived: true, repoID: repoID)
            ]
            for id in ["run", "loose-run", "exit", "dismissed", "archived", "absent"] {
                #expect(state.sidebarEndedRevealGroups(selection: key(id)).isEmpty, "\(id)")
            }
            #expect(state.sidebarEndedRevealGroups(selection: nil).isEmpty)
        }
    }
}
