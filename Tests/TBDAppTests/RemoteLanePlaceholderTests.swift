import Foundation
import TestSupport
import Testing
@testable import TBDApp
import TBDShared

/// The optimistic sidebar row for a remote lane: `remote.create` is an SSM-shaped
/// round trip with a 60s timeout and a retry, and before this the row appeared
/// only at the very end of that chain.
///
/// Two halves are covered here. The pure correlation
/// (`RemoteLanePlaceholder`) — which is what makes "the placeholder is retired
/// by the `(provider, sessionID)` pair, never by a worktree id" testable at
/// all — and `AppState.createRemoteLane`, driven through the injectable
/// `remoteSessionCreator` / `remoteLaneRowsRefresher` seams (`DaemonClient` is
/// concrete, no protocol; tests must never touch `~/tbd`).
/// Counts calls made through an injected seam. A reference type for the same
/// reason `RemoteAppStateTests.Recorder` is one — the seams are escaping
/// closures.
@MainActor
private final class CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@MainActor
@Suite("Remote lane placeholder")
struct RemoteLanePlaceholderTests {

    private func withStateAsync(_ body: (AppState) async -> Void) async {
        let defaultsSuite = TestDefaultsSuite("RemoteLane")
        defer { defaultsSuite.tearDown() }
        let defaults = defaultsSuite.defaults
        await body(AppState(userDefaults: defaults))
    }

    /// The row adoption would mint for `sessionID` — same `(provider, sessionID)`
    /// binding in `location`, an unrelated UUID, exactly as
    /// `RemoteSessionAdopter` produces it.
    private func adoptedRow(
        repoID: UUID, provider: String, sessionID: String, parentWorktreeID: UUID? = nil
    ) -> Worktree {
        Worktree(
            repoID: repoID, name: "remote://\(provider)/\(sessionID)", displayName: "adopted",
            branch: "", path: "remote://\(provider)/\(sessionID)", tmuxServer: "",
            parentWorktreeID: parentWorktreeID,
            location: .remote(provider: provider, sessionID: sessionID))
    }

    // MARK: - Correlation (pure)

    @Test func adoptedRow_matchesOnProviderAndSessionPair() {
        let repoID = UUID()
        let lane = PendingRemoteLane(
            id: UUID(), repoID: repoID, provider: "acme", sessionID: "s1")
        let row = adoptedRow(repoID: repoID, provider: "acme", sessionID: "s1")

        #expect(RemoteLanePlaceholder.adoptedRow(for: lane, in: [row])?.id == row.id)
    }

    /// The pair is the whole match: same session id under a different provider
    /// is a different lane.
    @Test func adoptedRow_ignoresSameSessionIDFromAnotherProvider() {
        let repoID = UUID()
        let lane = PendingRemoteLane(
            id: UUID(), repoID: repoID, provider: "acme", sessionID: "s1")
        let other = adoptedRow(repoID: repoID, provider: "other", sessionID: "s1")

        #expect(RemoteLanePlaceholder.adoptedRow(for: lane, in: [other]) == nil)
    }

    /// The repo the daemon files the lane under is its decision, not the
    /// placeholder's guess — a row that landed in another repo section is still
    /// this lane, and leaving the placeholder behind would show it twice.
    @Test func adoptedRow_matchesEvenWhenAdoptedIntoAnotherRepo() {
        let lane = PendingRemoteLane(
            id: UUID(), repoID: UUID(), provider: "acme", sessionID: "s1")
        let row = adoptedRow(repoID: UUID(), provider: "acme", sessionID: "s1")

        #expect(RemoteLanePlaceholder.adoptedRow(for: lane, in: [row])?.id == row.id)
    }

    /// Before `remote.create` answers there is nothing to correlate on, and the
    /// placeholder's own `.remote(provider, "")` location must not let it
    /// retire itself.
    @Test func adoptedRow_isNilWhileSessionIDUnknown() {
        let placeholderID = UUID()
        let repoID = UUID()
        let lane = PendingRemoteLane(
            id: placeholderID, repoID: repoID, provider: "acme", sessionID: nil)
        let placeholderRow = Worktree(
            id: placeholderID, repoID: repoID, name: "lane", displayName: "lane",
            branch: "", path: "", status: .creating, tmuxServer: "",
            location: .remote(provider: "acme", sessionID: ""))

        #expect(RemoteLanePlaceholder.adoptedRow(for: lane, in: [placeholderRow]) == nil)
    }

    @Test func adoptedRow_ignoresLocalRows() {
        let repoID = UUID()
        let lane = PendingRemoteLane(
            id: UUID(), repoID: repoID, provider: "acme", sessionID: "s1")
        let local = Worktree(
            repoID: repoID, name: "s1", displayName: "s1", branch: "tbd/s1",
            path: "/tmp/s1", tmuxServer: "srv")

        #expect(RemoteLanePlaceholder.adoptedRow(for: lane, in: [local]) == nil)
    }

    // MARK: - Placeholder name

    @Test func displayName_prefersTitleThenSlug() {
        #expect(RemoteLanePlaceholder.displayName(
            paramsJSON: #"{"title":"Fix the parser","slug":"brave-otter"}"#,
            fallback: "generated") == "Fix the parser")
        #expect(RemoteLanePlaceholder.displayName(
            paramsJSON: #"{"slug":"brave-otter"}"#, fallback: "generated") == "brave-otter")
    }

    @Test func displayName_fallsBackForBlankMissingAndUnparseableParams() {
        #expect(RemoteLanePlaceholder.displayName(
            paramsJSON: #"{"title":"   ","repo":"acme/app"}"#,
            fallback: "generated") == "generated")
        #expect(RemoteLanePlaceholder.displayName(paramsJSON: "{}", fallback: "generated") == "generated")
        #expect(RemoteLanePlaceholder.displayName(paramsJSON: "not json", fallback: "generated") == "generated")
    }

    /// A non-string `title` (a provider free to declare that field any type)
    /// must not crash or stringify into the row name.
    @Test func displayName_ignoresNonStringTitle() {
        #expect(RemoteLanePlaceholder.displayName(
            paramsJSON: #"{"title":7,"slug":"brave-otter"}"#,
            fallback: "generated") == "brave-otter")
    }

    // MARK: - createRemoteLane: the row appears immediately

    @Test func createRemoteLane_showsPlaceholderRowWhileCreateIsInFlight() async {
        await withStateAsync { state in
            let repoID = UUID()
            state.worktrees[repoID] = []
            state.remoteLaneRowsRefresher = {}
            state.remoteSessionCreator = { _, _, _ in
                // Observed from inside the create: the row is on screen before
                // the provider has answered, which is the whole feature.
                #expect(state.worktrees[repoID]?.count == 1)
                if let placeholder = state.worktrees[repoID]?.first {
                    #expect(placeholder.status == .creating)
                    #expect(placeholder.displayName == "brave-otter")
                    #expect(placeholder.location == .remote(provider: "acme", sessionID: ""))
                    #expect(state.selectedWorktreeIDs == [placeholder.id])
                    #expect(state.pendingWorktreeIDs.contains(placeholder.id))
                }
                return RemoteSessionPayload(id: "s1", state: .running)
            }

            _ = try? await state.createRemoteLane(
                provider: "acme", paramsJSON: #"{"slug":"brave-otter"}"#, repoID: repoID)
        }
    }

    /// The nested `+` promises the lane lands under the row it was clicked on.
    @Test func createRemoteLane_nestsPlaceholderUnderItsParent() async {
        await withStateAsync { state in
            let repoID = UUID()
            let parentID = UUID()
            state.worktrees[repoID] = []
            state.remoteLaneRowsRefresher = {}
            state.remoteSessionCreator = { _, _, parent in
                #expect(parent == parentID)
                #expect(state.worktrees[repoID]?.first?.parentWorktreeID == parentID)
                return RemoteSessionPayload(id: "s1", state: .running)
            }

            _ = try? await state.createRemoteLane(
                provider: "acme", paramsJSON: "{}", parentWorktreeID: parentID, repoID: repoID)
        }
    }

    /// No repo context (the Remote section's own provider header) means no
    /// section to draw a row in — the create still happens.
    @Test func createRemoteLane_withoutRepoDrawsNoPlaceholder() async {
        await withStateAsync { state in
            let creates = CallCounter()
            state.remoteLaneRowsRefresher = {}
            state.remoteSessionCreator = { _, _, _ in
                creates.bump()
                return RemoteSessionPayload(id: "s1", state: .running)
            }

            _ = try? await state.createRemoteLane(
                provider: "acme", paramsJSON: "{}", repoID: nil)

            #expect(creates.count == 1)
            #expect(state.worktrees.isEmpty)
            #expect(state.pendingRemoteLanes.isEmpty)
        }
    }

    // MARK: - createRemoteLane: both arrival orders end with exactly one row

    /// Order A — the create answers first, and the refresh it then runs brings
    /// the adopted row.
    @Test func createRemoteLane_swapsPlaceholderWhenRowArrivesAfterCreate() async {
        await withStateAsync { state in
            let repoID = UUID()
            state.worktrees[repoID] = []
            let row = adoptedRow(repoID: repoID, provider: "acme", sessionID: "s1")
            state.remoteSessionCreator = { _, _, _ in RemoteSessionPayload(id: "s1", state: .running) }
            state.remoteLaneRowsRefresher = {
                // What `refreshWorktrees` would have merged in, placeholder
                // preserved alongside it (pendingWorktreeIDs).
                let placeholders = (state.worktrees[repoID] ?? [])
                    .filter { state.pendingWorktreeIDs.contains($0.id) }
                state.worktrees[repoID] = [row] + placeholders
            }

            _ = try? await state.createRemoteLane(
                provider: "acme", paramsJSON: "{}", repoID: repoID)

            #expect(state.worktrees[repoID]?.map(\.id) == [row.id])
            #expect(state.pendingRemoteLanes.isEmpty)
            #expect(state.pendingWorktreeIDs.isEmpty)
            #expect(state.selectedWorktreeIDs == [row.id])
            #expect(state.activeToast == nil)
        }
    }

    /// Order B — a poll landed while the create was still in flight, so the
    /// adopted row is already on screen when the session id becomes knowable.
    /// The swap must still leave one row, not two.
    @Test func createRemoteLane_swapsPlaceholderWhenRowArrivedBeforeCreateReturned() async {
        await withStateAsync { state in
            let repoID = UUID()
            state.worktrees[repoID] = []
            let row = adoptedRow(repoID: repoID, provider: "acme", sessionID: "s1")
            let refreshes = CallCounter()
            state.remoteLaneRowsRefresher = { refreshes.bump() }
            state.remoteSessionCreator = { _, _, _ in
                let placeholders = (state.worktrees[repoID] ?? [])
                    .filter { state.pendingWorktreeIDs.contains($0.id) }
                state.worktrees[repoID] = [row] + placeholders
                #expect(state.worktrees[repoID]?.count == 2, "both rows are visible until the session id lands")
                return RemoteSessionPayload(id: "s1", state: .running)
            }

            _ = try? await state.createRemoteLane(
                provider: "acme", paramsJSON: "{}", repoID: repoID)

            #expect(state.worktrees[repoID]?.map(\.id) == [row.id])
            #expect(state.pendingRemoteLanes.isEmpty)
            #expect(state.selectedWorktreeIDs == [row.id])
            #expect(refreshes.count == 0, "the row was already here; no refresh needed to find it")
        }
    }

    /// A user who clicked elsewhere during a minute-long create must not be
    /// yanked onto the new lane when it lands.
    @Test func createRemoteLane_leavesSelectionAloneWhenUserMovedOn() async {
        await withStateAsync { state in
            let repoID = UUID()
            let elsewhere = UUID()
            state.worktrees[repoID] = []
            let row = adoptedRow(repoID: repoID, provider: "acme", sessionID: "s1")
            state.remoteSessionCreator = { _, _, _ in
                state.selectedWorktreeIDs = [elsewhere]
                return RemoteSessionPayload(id: "s1", state: .running)
            }
            state.remoteLaneRowsRefresher = {
                let placeholders = (state.worktrees[repoID] ?? [])
                    .filter { state.pendingWorktreeIDs.contains($0.id) }
                state.worktrees[repoID] = [row] + placeholders
            }

            _ = try? await state.createRemoteLane(
                provider: "acme", paramsJSON: "{}", repoID: repoID)

            #expect(state.worktrees[repoID]?.map(\.id) == [row.id])
            #expect(state.selectedWorktreeIDs == [elsewhere])
        }
    }

    // MARK: - createRemoteLane: failure paths

    @Test func createRemoteLane_removesPlaceholderAndRethrowsWhenCreateFails() async {
        await withStateAsync { state in
            let repoID = UUID()
            state.worktrees[repoID] = []
            state.remoteLaneRowsRefresher = {}
            state.remoteSessionCreator = { _, _, _ in
                throw DaemonClientError.rpcError("provider timed out", code: nil)
            }

            var thrown: Error?
            do {
                _ = try await state.createRemoteLane(
                    provider: "acme", paramsJSON: "{}", repoID: repoID)
            } catch {
                thrown = error
            }

            #expect(thrown != nil, "the sheet reports this inline; it must not be swallowed")
            #expect(state.worktrees[repoID]?.isEmpty == true)
            #expect(state.pendingRemoteLanes.isEmpty)
            #expect(state.pendingWorktreeIDs.isEmpty)
            #expect(state.selectedWorktreeIDs.isEmpty, "no dangling selection on a row that is gone")
        }
    }

    /// The one-click path has no sheet to report into, so it turns the same
    /// failure into an error toast — and still leaves no ghost row.
    @Test func createRemoteSession_reportsFailureAsToastAndLeavesNoRow() async {
        await withStateAsync { state in
            let repoID = UUID()
            state.worktrees[repoID] = []
            state.remoteLaneRowsRefresher = {}
            state.remoteSessionCreator = { _, _, _ in
                throw DaemonClientError.rpcError("provider timed out", code: nil)
            }

            await state.createRemoteSession(
                provider: "acme", paramsJSON: "{}", repoID: repoID)

            #expect(state.activeToast?.style == .error)
            #expect(state.worktrees[repoID]?.isEmpty == true)
            #expect(state.pendingRemoteLanes.isEmpty)
        }
    }

    /// A session TBD cannot resolve to a repo is never adopted, so no row is
    /// ever coming. The placeholder must go anyway — a lane stuck on
    /// "Creating…" forever is worse than the delay this feature removes — and
    /// the user is told where the session went.
    @Test func createRemoteLane_dropsPlaceholderAndNotifiesWhenNoRowIsAdopted() async {
        await withStateAsync { state in
            let repoID = UUID()
            state.worktrees[repoID] = []
            state.remoteSessionCreator = { _, _, _ in RemoteSessionPayload(id: "s1", state: .running) }
            state.remoteLaneRowsRefresher = {}  // authoritative: nothing was adopted

            _ = try? await state.createRemoteLane(
                provider: "acme", paramsJSON: "{}", repoID: repoID)

            #expect(state.worktrees[repoID]?.isEmpty == true)
            #expect(state.pendingRemoteLanes.isEmpty)
            #expect(state.pendingWorktreeIDs.isEmpty)
            #expect(state.activeToast?.style == .notice)
        }
    }
}
