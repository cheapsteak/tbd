import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The memo behind `AppState.sidebarMatchedRemoteSessions(repoID:)`. Each test
/// reads the sort counter, the test seam that counts recomputes, so a
/// re-sort is observable directly rather than inferred from timing.
@MainActor
@Suite("AppState — matched-session memo")
struct AppStateMatchedSessionsMemoTests {
    private typealias Fixture = MatchedSessionFixtures

    private func withState(_ body: (AppState, UUID) -> Void) {
        let suite = "AppStateMatchedSessionsMemoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(userDefaults: defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        state.repos = [repo]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        body(state, repo.id)
    }

    /// Three sessions for `repo`, created in the order c, a, b so the sorted
    /// order (a, b, c by stamp) differs from the input order.
    private func seed(_ state: AppState, _ repo: UUID) {
        state.remoteSessions = [
            Fixture.info("c", createdAt: "2026-03-03T00:00:00Z", repo: repo),
            Fixture.info("a", createdAt: "2026-03-01T00:00:00Z", repo: repo),
            Fixture.info("b", createdAt: "2026-03-02T00:00:00Z", repo: repo),
        ]
    }

    private func ids(_ sessions: [RemoteSessionInfo]) -> [String] {
        sessions.map(\.payload.id)
    }

    @Test func lastSeenOnlyChangeReSortsNothingAndReturnsTheNewValue() {
        withState { state, repo in
            seed(state, repo)
            _ = state.sidebarMatchedRemoteSessions(repoID: repo)
            let warm = state.sidebarMatchedSessionsSortCount

            let bumped = Date(timeIntervalSince1970: 7_777)
            state.remoteSessions = state.remoteSessions.map { session in
                Fixture.info(session.payload.id, createdAt: session.payload.createdAt,
                             repo: repo, lastSeen: bumped)
            }
            let result = state.sidebarMatchedRemoteSessions(repoID: repo)

            #expect(state.sidebarMatchedSessionsSortCount == warm)
            #expect(ids(result) == ["a", "b", "c"])
            #expect(result.allSatisfy { $0.lastSeen == bumped })
        }
    }

    @Test func rowStateChangesReSortNothingAndAreVisibleOnAHit() {
        withState { state, repo in
            seed(state, repo)
            _ = state.sidebarMatchedRemoteSessions(repoID: repo)
            let warm = state.sidebarMatchedSessionsSortCount

            state.remoteSessions = state.remoteSessions.map { session in
                session.payload.id == "b"
                    ? Fixture.info("b", createdAt: session.payload.createdAt, repo: repo,
                                   state: .exited, agent: .waitingInput, gone: true)
                    : session
            }
            let result = state.sidebarMatchedRemoteSessions(repoID: repo)

            #expect(state.sidebarMatchedSessionsSortCount == warm)
            let b = result.first { $0.payload.id == "b" }
            #expect(b?.payload.state == .exited)
            #expect(b?.gone == true)
            #expect(b?.payload.agentState == .waitingInput)
        }
    }

    @Test func createdAtChangeReSortsAndReorders() {
        withState { state, repo in
            seed(state, repo)
            _ = state.sidebarMatchedRemoteSessions(repoID: repo)
            let warm = state.sidebarMatchedSessionsSortCount

            state.remoteSessions = state.remoteSessions.map { session in
                session.payload.id == "a"
                    ? Fixture.info("a", createdAt: "2026-04-01T00:00:00Z", repo: repo)
                    : session
            }
            let result = state.sidebarMatchedRemoteSessions(repoID: repo)

            #expect(state.sidebarMatchedSessionsSortCount == warm + 1)
            #expect(ids(result) == ["b", "c", "a"])
        }
    }

    @Test func archivingDropsTheSession() {
        withState { state, repo in
            seed(state, repo)
            _ = state.sidebarMatchedRemoteSessions(repoID: repo)
            let warm = state.sidebarMatchedSessionsSortCount

            state.remoteSessions = state.remoteSessions.map { session in
                session.payload.id == "b"
                    ? Fixture.info("b", createdAt: "2026-03-02T00:00:00Z", archived: true, repo: repo)
                    : session
            }

            #expect(ids(state.sidebarMatchedRemoteSessions(repoID: repo)) == ["a", "c"])
            #expect(state.sidebarMatchedSessionsSortCount == warm + 1)
        }
    }

    @Test func dismissingDropsTheSession() {
        withState { state, repo in
            seed(state, repo)
            _ = state.sidebarMatchedRemoteSessions(repoID: repo)
            let warm = state.sidebarMatchedSessionsSortCount

            state.remoteSessions = state.remoteSessions.map { session in
                session.payload.id == "a"
                    ? Fixture.info("a", createdAt: "2026-03-01T00:00:00Z", dismissed: true, repo: repo)
                    : session
            }

            #expect(ids(state.sidebarMatchedRemoteSessions(repoID: repo)) == ["b", "c"])
            #expect(state.sidebarMatchedSessionsSortCount == warm + 1)
        }
    }

    @Test func resolvingToAnotherRepoDropsTheSession() {
        withState { state, repo in
            seed(state, repo)
            _ = state.sidebarMatchedRemoteSessions(repoID: repo)
            let warm = state.sidebarMatchedSessionsSortCount

            state.remoteSessions = state.remoteSessions.map { session in
                session.payload.id == "c"
                    ? Fixture.info("c", createdAt: "2026-03-03T00:00:00Z", repo: UUID())
                    : session
            }

            #expect(ids(state.sidebarMatchedRemoteSessions(repoID: repo)) == ["a", "b"])
            #expect(state.sidebarMatchedSessionsSortCount == warm + 1)
        }
    }

    @Test func anAppendedSessionAppears() {
        withState { state, repo in
            seed(state, repo)
            _ = state.sidebarMatchedRemoteSessions(repoID: repo)
            let warm = state.sidebarMatchedSessionsSortCount

            state.remoteSessions.append(
                Fixture.info("z", createdAt: "2026-02-01T00:00:00Z", repo: repo))

            #expect(ids(state.sidebarMatchedRemoteSessions(repoID: repo)) == ["z", "a", "b", "c"])
            #expect(state.sidebarMatchedSessionsSortCount == warm + 1)
        }
    }

    @Test func adoptingASessionDropsItsMirrorRow() {
        withState { state, repo in
            seed(state, repo)
            _ = state.sidebarMatchedRemoteSessions(repoID: repo)
            let warm = state.sidebarMatchedSessionsSortCount

            state.worktrees[repo] = [SidebarGroupFixtures.row("lane", repoID: repo, remote: "b")]

            #expect(ids(state.sidebarMatchedRemoteSessions(repoID: repo)) == ["a", "c"])
            #expect(state.sidebarMatchedSessionsSortCount == warm + 1)
        }
    }

    @Test func sidebarRoutesAndRevealReuseTheWarmMemo() {
        withState { state, repo in
            seed(state, repo)
            _ = state.sidebarMatchedRemoteSessions(repoID: repo)
            let warm = state.sidebarMatchedSessionsSortCount

            #expect(ids(state.sidebarRemoteGroups(repoID: repo).sessions) == ["a", "b", "c"])
            _ = state.sidebarGroupReveal(worktreeIDs: [], selection: nil)

            #expect(state.sidebarMatchedSessionsSortCount == warm)
        }
    }
}
