import Foundation
import TestSupport
import Testing
@testable import TBDApp
import TBDShared

/// Selecting an adopted remote lane must reach the same surface the Remote
/// section's row reaches.
///
/// The bug these cover shipped because it is invisible to a unit test that
/// does not ask this exact question: adoption moved sessions into the repo
/// tree (#625) and an adopted session is rendered by its worktree row ALONE —
/// `RemoteSectionView.sessions` drops it (it resolved to a known repo) and
/// `RepoSectionView.matchedRemoteSessions` drops it (a row stands for it) — so
/// the lane row became the only way in, while nothing mapped that row to a
/// `RemoteSessionSelection`. The row landed on an ordinary worktree pane for a
/// row with no path, no tmux server and no terminals.
///
/// The state-level tests below are written against symbols that already
/// existed (`selectedWorktreeIDs`, `selectedRemoteSession`,
/// `DetailSectionHostPager.targetTab`), so they fail against the pre-fix tree
/// rather than merely describing the fix.
@MainActor
@Suite("Remote lane surface")
struct RemoteLaneSurfaceTests {

    private func withStateAsync(_ body: (AppState) async -> Void) async {
        let defaultsSuite = TestDefaultsSuite("RemoteLaneSurface")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        await body(AppState(userDefaults: defaults))
    }

    /// An adopted lane, shaped like `RemoteSessionAdopter` mints them.
    private func lane(
        repoID: UUID, provider: String = "acme", sessionID: String = "s1"
    ) -> Worktree {
        Worktree(
            repoID: repoID, name: "remote://\(provider)/\(sessionID)", displayName: "lane",
            branch: "", path: "remote://\(provider)/\(sessionID)", tmuxServer: "",
            location: .remote(provider: provider, sessionID: sessionID))
    }

    private func localWorktree(repoID: UUID) -> Worktree {
        Worktree(
            repoID: repoID, name: "brave-otter", displayName: "brave-otter",
            branch: "tbd/brave-otter", path: "/tmp/brave-otter", tmuxServer: "srv")
    }

    // MARK: - The mapping (pure)

    @Test func remoteSurfaceSelection_mapsALaneRowToItsSessionBinding() {
        let repoID = UUID()
        let row = lane(repoID: repoID)
        #expect(AppState.remoteSurfaceSelection(forWorktreeSelection: [row.id], in: [row])
            == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
    }

    @Test func remoteSurfaceSelection_isNilForALocalRow() {
        let repoID = UUID()
        let row = localWorktree(repoID: repoID)
        #expect(AppState.remoteSurfaceSelection(forWorktreeSelection: [row.id], in: [row]) == nil)
    }

    /// The decision, stated: the remote surface describes ONE session, while a
    /// multi-selection means the split terminal grid. A mixed selection keeps
    /// the grid rather than promoting one member to own the detail area.
    @Test func remoteSurfaceSelection_isNilForAMixedOrMultiSelection() {
        let repoID = UUID()
        let remote = lane(repoID: repoID)
        let local = localWorktree(repoID: repoID)
        let secondRemote = lane(repoID: repoID, sessionID: "s2")
        #expect(AppState.remoteSurfaceSelection(
            forWorktreeSelection: [remote.id, local.id], in: [remote, local]) == nil)
        #expect(AppState.remoteSurfaceSelection(
            forWorktreeSelection: [remote.id, secondRemote.id],
            in: [remote, secondRemote]) == nil)
    }

    @Test func remoteSurfaceSelection_isNilForAnEmptySelectionOrUnknownID() {
        let repoID = UUID()
        let row = lane(repoID: repoID)
        #expect(AppState.remoteSurfaceSelection(forWorktreeSelection: [], in: [row]) == nil)
        #expect(AppState.remoteSurfaceSelection(forWorktreeSelection: [UUID()], in: [row]) == nil)
    }

    /// A creation placeholder carries an empty session id — no session exists
    /// yet, so there is nothing to attach to or describe. It keeps the
    /// worktree pane (which is where its "Creating…" row state lives) until
    /// the adopted row swaps in.
    @Test func remoteSurfaceSelection_isNilForACreationPlaceholder() {
        let repoID = UUID()
        let placeholder = Worktree(
            repoID: repoID, name: "brave-otter", displayName: "brave-otter",
            branch: "", path: "", status: .creating, tmuxServer: "",
            location: .remote(provider: "acme", sessionID: ""))
        #expect(AppState.remoteSurfaceSelection(
            forWorktreeSelection: [placeholder.id], in: [placeholder]) == nil)
    }

    // MARK: - Selecting the row lands on the remote surface

    @Test func selectingALaneRowEstablishesItsRemoteSessionAndRoutesToTheRemoteTab() async {
        await withStateAsync { state in
            let repoID = UUID()
            let row = lane(repoID: repoID)
            state.worktrees[repoID] = [row]

            state.selectedWorktreeIDs = [row.id]

            #expect(state.selectedRemoteSession
                == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
            // The pane follows from exactly this value — same pure decision the
            // pager makes on every update.
            #expect(DetailSectionHostPager.targetTab(
                isConnected: true,
                selectedRemoteSession: state.selectedRemoteSession,
                selectedRemoteProvider: nil) == .remote)
            // And the host renders chrome for it.
            #expect(state.remoteSessionHostSelection
                == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
        }
    }

    /// The row stays selected: it is a worktree row in the repo tree, and its
    /// sidebar highlight comes from the List selection. Clearing it — which is
    /// what `activateRemoteSession` does for a Remote-section row — would
    /// deselect the very row the user clicked.
    @Test func selectingALaneRowKeepsTheRowSelected() async {
        await withStateAsync { state in
            let repoID = UUID()
            let row = lane(repoID: repoID)
            state.worktrees[repoID] = [row]

            state.selectedWorktreeIDs = [row.id]

            #expect(state.selectedWorktreeIDs == [row.id])
        }
    }

    /// The bookkeeping that makes the surface work is shared with the
    /// Remote-section row, so a lane row cannot reach the same view in a
    /// different state: unread cleared, keep-alive recency touched (this is
    /// what mounts the attach), detach flag cleared on a genuine transition.
    @Test func selectingALaneRowRunsTheSameSurfaceBookkeepingAsASessionRow() async {
        await withStateAsync { state in
            let repoID = UUID()
            let row = lane(repoID: repoID)
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            state.worktrees[repoID] = [row]
            state.unreadByRemoteSession[selection] =
                UnreadSummary(type: .attentionNeeded, mostRecentAt: Date())
            state.markRemoteSessionDetached(selection, exitCode: 0)

            state.selectedWorktreeIDs = [row.id]

            #expect(state.unreadByRemoteSession[selection] == nil)
            #expect(state.recentlyAttachedRemoteSessions.first == selection)
            #expect(state.explicitlyDetachedRemoteSessions[selection] == nil)
        }
    }

    /// Load-bearing negative control: selecting a LOCAL row must still clear
    /// remote mode, or the remote pane stays in front of a local worktree.
    @Test func selectingALocalRowStillClearsTheRemoteSurface() async {
        await withStateAsync { state in
            let repoID = UUID()
            let remote = lane(repoID: repoID)
            let local = localWorktree(repoID: repoID)
            state.worktrees[repoID] = [remote, local]
            state.selectedWorktreeIDs = [remote.id]
            #expect(state.selectedRemoteSession != nil)

            state.selectedWorktreeIDs = [local.id]

            #expect(state.selectedRemoteSession == nil)
            #expect(DetailSectionHostPager.targetTab(
                isConnected: true,
                selectedRemoteSession: state.selectedRemoteSession,
                selectedRemoteProvider: nil) == .other)
        }
    }

    /// Extending the selection off a lane onto a local row drops back to the
    /// grid — the mixed-selection rule, observed through the state.
    @Test func extendingTheSelectionOffALaneClearsTheRemoteSurface() async {
        await withStateAsync { state in
            let repoID = UUID()
            let remote = lane(repoID: repoID)
            let local = localWorktree(repoID: repoID)
            state.worktrees[repoID] = [remote, local]
            state.selectedWorktreeIDs = [remote.id]

            state.selectedWorktreeIDs = [remote.id, local.id]

            #expect(state.selectedRemoteSession == nil)
        }
    }

    /// Back/forward replays a worktree entry as `selectedRemoteSession = nil`
    /// followed by the selection assignment, so returning to a lane must
    /// re-establish its surface rather than land on the empty pane.
    @Test func returningToALaneSelectionReestablishesTheSurface() async {
        await withStateAsync { state in
            let repoID = UUID()
            let remote = lane(repoID: repoID)
            let local = localWorktree(repoID: repoID)
            state.worktrees[repoID] = [remote, local]
            state.selectedWorktreeIDs = [remote.id]
            state.selectedWorktreeIDs = [local.id]
            #expect(state.selectedRemoteSession == nil)

            state.navigateBack()

            #expect(state.selectedWorktreeIDs == [remote.id])
            #expect(state.selectedRemoteSession
                == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
        }
    }

    /// Selecting a Remote-section row is unchanged: it owns the whole detail
    /// area and clears the worktree selection.
    @Test func selectingASessionRowStillClearsTheWorktreeSelection() async {
        await withStateAsync { state in
            let repoID = UUID()
            let local = localWorktree(repoID: repoID)
            state.worktrees[repoID] = [local]
            state.selectedWorktreeIDs = [local.id]

            state.selectRemoteSession(provider: "acme", sessionID: "s9")

            #expect(state.selectedWorktreeIDs.isEmpty)
            #expect(state.selectedRemoteSession
                == RemoteSessionSelection(provider: "acme", sessionID: "s9"))
        }
    }
}
