import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Tests for `AppState.selectRemoteSession(provider:sessionID:)` and its
/// mutual exclusivity with `selectedWorktreeIDs` / `selectedRepoID` /
/// `selectedScratchSection`. Mirrors `ScratchSectionSelectionTests` — a
/// fourth, parallel selection concept that must never end up simultaneously
/// "on" with any of the other three, or `ContentView`'s detail-pane routing
/// picks the wrong pane.
@MainActor
@Suite("Remote session selection")
struct RemoteSessionSelectionTests {

    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "TBDAppTests.RemoteSessionSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(AppState(userDefaults: defaults))
    }

    private func makeWorktree(id: UUID, repoID: UUID?) -> Worktree {
        Worktree(
            id: id,
            repoID: repoID,
            name: "test-\(id.uuidString.prefix(8))",
            displayName: "Test \(id.uuidString.prefix(8))",
            branch: "main",
            path: "/tmp/test",
            status: .active,
            tmuxServer: "test-server"
        )
    }

    @Test func selectRemoteSessionSetsSelectionAndClearsOtherSelections() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            state.selectedWorktreeIDs = [wtID]

            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
            #expect(state.selectedRepoID == nil)
            #expect(state.selectedScratchSection == false)
            #expect(state.selectedWorktreeIDs.isEmpty)
        }
    }

    @Test func selectingRepoClearsRemoteSessionSelection() {
        withState { state in
            let repoID = UUID()
            state.repos = [Repo(id: repoID, path: "/tmp/r", displayName: "r", defaultBranch: "main")]

            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.selectedRemoteSession != nil)

            state.selectRepo(id: repoID)

            #expect(state.selectedRemoteSession == nil)
            #expect(state.selectedRepoID == repoID)
        }
    }

    @Test func selectingWorktreeClearsRemoteSessionSelection() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]

            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.selectedRemoteSession != nil)

            state.selectedWorktreeIDs = [wtID]

            #expect(state.selectedRemoteSession == nil)
            #expect(state.selectedWorktreeIDs == [wtID])
        }
    }

    @Test func selectingScratchSectionClearsRemoteSessionSelection() {
        withState { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.selectedRemoteSession != nil)

            state.selectScratchSection()

            #expect(state.selectedRemoteSession == nil)
            #expect(state.selectedScratchSection == true)
        }
    }

    @Test func remoteSessionSelectionDefaultsToNil() {
        withState { state in
            #expect(state.selectedRemoteSession == nil)
        }
    }

    // MARK: - Task 10: remoteSessionRequestedTab (context-menu tab-jump hint)

    @Test func selectRemoteSessionDefaultsRequestedTabToNil() {
        withState { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.remoteSessionRequestedTab == nil)
        }
    }

    @Test func selectRemoteSessionWithTabSetsRequestedTab() {
        withState { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1", tab: .log)
            #expect(state.remoteSessionRequestedTab == .log)
        }
    }

    /// A later plain selection (no `tab:` argument) must overwrite a stale
    /// hint from a previous context-menu jump — otherwise reselecting the
    /// same row by a plain click could replay an old "jump to Log" request.
    @Test func laterPlainSelectionOverwritesAStaleRequestedTab() {
        withState { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1", tab: .log)
            #expect(state.remoteSessionRequestedTab == .log)

            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(state.remoteSessionRequestedTab == nil)
        }
    }

    @Test func selectingAnotherRemoteSessionReplacesThePreviousOne() {
        withState { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s2")

            #expect(state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s2"))
        }
    }

    /// As of this task, a remote-session selection IS a first-class
    /// navigation entry (unlike scratch spaces, which keep the documented
    /// scope cut) — selecting one pushes its own history entry, so back
    /// from it lands on whatever was selected immediately before, not on
    /// whatever the remote session's OWN selection happened to have
    /// clobbered in local state.
    @Test func navigatingBackFromARemoteSessionLandsOnThePriorEntry() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.repos = [Repo(id: repoID, path: "/tmp/r", displayName: "r", defaultBranch: "main")]
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]

            // History: [.repo(repoID)] (index 0), [.worktrees([wtID])] (index 1),
            // [.remoteSession(...)] (index 2, current).
            state.selectRepo(id: repoID)
            state.selectedWorktreeIDs = [wtID]
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.selectedRemoteSession != nil)
            #expect(state.canGoBack == true)

            state.navigateBack()

            // Lands on the immediately-prior entry — the worktree selection —
            // not all the way back at the repo.
            #expect(state.selectedRemoteSession == nil)
            #expect(state.selectedWorktreeIDs == [wtID])
            #expect(state.selectedRepoID == nil)

            state.navigateBack()

            #expect(state.selectedRepoID == repoID)
        }
    }

    /// Applying a `.repo`/`.worktrees` history entry (via back/forward, not
    /// through a fresh remote selection) must still clear a lingering
    /// remote-session selection so it never survives navigating away — this
    /// is now exercised by ordinary back-navigation off a remote entry
    /// rather than by a special case, since `.remoteSession` participates in
    /// history like everything else.
    @Test func navigatingBackToAWorktreeEntryClearsRemoteSessionSelection() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]

            state.selectedWorktreeIDs = [wtID]
            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            state.navigateBack()

            #expect(state.selectedRemoteSession == nil)
            #expect(state.selectedWorktreeIDs == [wtID])
        }
    }

    // MARK: - unreadByRemoteSession: clear-on-select

    @Test func selectingASessionClearsItsOwnUnreadEntry() {
        withState { state in
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            state.unreadByRemoteSession[selection] = UnreadSummary(type: .attentionNeeded, mostRecentAt: Date())

            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(state.unreadByRemoteSession[selection] == nil)
        }
    }

    @Test func selectingOneSessionDoesNotClearAnotherSessionsUnreadEntry() {
        withState { state in
            let other = RemoteSessionSelection(provider: "acme", sessionID: "s2")
            state.unreadByRemoteSession[other] = UnreadSummary(type: .error, mostRecentAt: Date())

            state.selectRemoteSession(provider: "acme", sessionID: "s1")

            #expect(state.unreadByRemoteSession[other] != nil)
        }
    }

    // MARK: - handleRemoteSessionAttentionDelta: write-on-delta

    @Test func attentionDeltaWaitingInputRecordsAttentionNeeded() {
        withState { state in
            state.handleRemoteSessionAttentionDelta(
                RemoteSessionAttentionDelta(provider: "acme", sessionID: "s1", title: "fix ci", kind: "waiting_input", reason: nil)
            )
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            #expect(state.unreadByRemoteSession[selection]?.type == .attentionNeeded)
        }
    }

    @Test func attentionDeltaExitedWithNonzeroExitCodeRecordsError() {
        withState { state in
            state.remoteSessions = [RemoteSessionInfo(
                provider: "acme",
                payload: RemoteSessionPayload(id: "s1", state: .exited, exitCode: 1),
                gone: false, dismissed: false, lastSeen: Date()
            )]
            state.handleRemoteSessionAttentionDelta(
                RemoteSessionAttentionDelta(provider: "acme", sessionID: "s1", title: nil, kind: "exited", reason: nil)
            )
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            #expect(state.unreadByRemoteSession[selection]?.type == .error)
        }
    }

    @Test func attentionDeltaExitedWithZeroExitCodeRecordsResponseComplete() {
        withState { state in
            state.remoteSessions = [RemoteSessionInfo(
                provider: "acme",
                payload: RemoteSessionPayload(id: "s1", state: .exited, exitCode: 0),
                gone: false, dismissed: false, lastSeen: Date()
            )]
            state.handleRemoteSessionAttentionDelta(
                RemoteSessionAttentionDelta(provider: "acme", sessionID: "s1", title: nil, kind: "exited", reason: nil)
            )
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            #expect(state.unreadByRemoteSession[selection]?.type == .responseComplete)
        }
    }

    @Test func attentionDeltaSkipsBookkeepingForTheCurrentlySelectedSession() {
        withState { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.handleRemoteSessionAttentionDelta(
                RemoteSessionAttentionDelta(provider: "acme", sessionID: "s1", title: nil, kind: "waiting_input", reason: nil)
            )
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            #expect(state.unreadByRemoteSession[selection] == nil)
        }
    }

    /// Pins the ordering bug fixed in this pass: the attention delta and the
    /// separate `.remoteSessionsChanged` mirror refresh are broadcast
    /// independently, so the attention delta can arrive BEFORE the mirror
    /// has this session's exit code. Classification must come from the
    /// delta's own `exitCode` field, not `remoteSessions.first { ... }`,
    /// which here still has the mirror's default `exitCode: nil` (as if a
    /// crashed session hadn't been refreshed into the mirror yet).
    @Test func attentionDeltaClassifiesFromItsOwnExitCodeWhenMirrorIsStale() {
        withState { state in
            // Mirror NOT yet refreshed — pre-seeded with a stale/default
            // exitCode of nil, unlike `attentionDeltaExitedWithNonzeroExitCodeRecordsError`
            // above, which seeds the mirror with the correct nonzero code.
            state.remoteSessions = [RemoteSessionInfo(
                provider: "acme",
                payload: RemoteSessionPayload(id: "s1", state: .running, exitCode: nil),
                gone: false, dismissed: false, lastSeen: Date()
            )]
            state.handleRemoteSessionAttentionDelta(
                RemoteSessionAttentionDelta(
                    provider: "acme", sessionID: "s1", title: nil, kind: "exited", reason: nil, exitCode: 1
                )
            )
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            #expect(state.unreadByRemoteSession[selection]?.type == .error,
                     "a nonzero exit code carried on the delta must classify as error even when the mirror is stale")
        }
    }

    /// Older-daemon payloads never set `exitCode` on the delta (back-compat
    /// default `nil`) — classification must fall back to the mirror lookup,
    /// preserving the pre-existing behavior.
    @Test func attentionDeltaFallsBackToMirrorWhenDeltaExitCodeIsNil() {
        withState { state in
            state.remoteSessions = [RemoteSessionInfo(
                provider: "acme",
                payload: RemoteSessionPayload(id: "s1", state: .exited, exitCode: 1),
                gone: false, dismissed: false, lastSeen: Date()
            )]
            state.handleRemoteSessionAttentionDelta(
                RemoteSessionAttentionDelta(provider: "acme", sessionID: "s1", title: nil, kind: "exited", reason: nil)
            )
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            #expect(state.unreadByRemoteSession[selection]?.type == .error)
        }
    }

    @Test func attentionDeltaMergesToHigherSeverityWithoutDowngrading() {
        withState { state in
            state.remoteSessions = [RemoteSessionInfo(
                provider: "acme",
                payload: RemoteSessionPayload(id: "s1", state: .exited, exitCode: 1),
                gone: false, dismissed: false, lastSeen: Date()
            )]
            // Error (severity 4) arrives first...
            state.handleRemoteSessionAttentionDelta(
                RemoteSessionAttentionDelta(provider: "acme", sessionID: "s1", title: nil, kind: "exited", reason: nil)
            )
            // ...then a lower-severity attentionNeeded (severity 3) must not
            // downgrade it.
            state.handleRemoteSessionAttentionDelta(
                RemoteSessionAttentionDelta(provider: "acme", sessionID: "s1", title: nil, kind: "waiting_input", reason: nil)
            )
            let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            #expect(state.unreadByRemoteSession[selection]?.type == .error)
        }
    }

    // MARK: - remoteSessionDisplayName / renameRemoteSession

    @Test func displayNameFallsBackToProviderTitleWhenNoOverride() {
        withState { state in
            let name = state.remoteSessionDisplayName(provider: "acme", sessionID: "s1", providerTitle: "fix ci")
            #expect(name == "fix ci")
        }
    }

    @Test func displayNameFallsBackToSessionIDWhenNoOverrideAndNoTitle() {
        withState { state in
            let name = state.remoteSessionDisplayName(provider: "acme", sessionID: "s1", providerTitle: nil)
            #expect(name == "s1")
        }
    }

    @Test func renamingOverridesTheProviderTitle() {
        withState { state in
            state.renameRemoteSession(provider: "acme", sessionID: "s1", displayName: "🔧 my session")
            let name = state.remoteSessionDisplayName(provider: "acme", sessionID: "s1", providerTitle: "fix ci")
            #expect(name == "🔧 my session")
        }
    }

    @Test func renamingOneSessionDoesNotAffectAnother() {
        withState { state in
            state.renameRemoteSession(provider: "acme", sessionID: "s1", displayName: "renamed")
            let name = state.remoteSessionDisplayName(provider: "acme", sessionID: "s2", providerTitle: "other title")
            #expect(name == "other title")
        }
    }

    /// `RenameableLabel`'s `allowsEmptyCommit` (wired in `RemoteSessionRowView`)
    /// commits `""` to clear an override back to the provider's title — the
    /// same "clear to default" affordance a blank tab rename has. Renaming
    /// to blank must REMOVE the key (not store `""`), or `remoteSessionDisplayName`
    /// would show a blank name forever instead of falling back.
    @Test func renamingToEmptyStringClearsTheOverride() {
        withState { state in
            state.renameRemoteSession(provider: "acme", sessionID: "s1", displayName: "my session")
            #expect(state.remoteSessionDisplayName(provider: "acme", sessionID: "s1", providerTitle: "fix ci") == "my session")

            state.renameRemoteSession(provider: "acme", sessionID: "s1", displayName: "")

            let name = state.remoteSessionDisplayName(provider: "acme", sessionID: "s1", providerTitle: "fix ci")
            #expect(name == "fix ci")
            let key = AppState.remoteSessionKey(provider: "acme", sessionID: "s1")
            #expect(state.remoteSessionDisplayNames[key] == nil)
        }
    }

    /// Whitespace-only counts as empty too (mirrors `RenameableLabel.commit`'s
    /// own trimming before it decides whether to call `onCommit`).
    @Test func renamingToWhitespaceOnlyClearsTheOverride() {
        withState { state in
            state.renameRemoteSession(provider: "acme", sessionID: "s1", displayName: "my session")
            state.renameRemoteSession(provider: "acme", sessionID: "s1", displayName: "   ")
            let key = AppState.remoteSessionKey(provider: "acme", sessionID: "s1")
            #expect(state.remoteSessionDisplayNames[key] == nil)
        }
    }

    // MARK: - Task 9d: selection unification (remote rows tagged into
    // `selectedWorktreeIDs` for List-native keyboard nav / focus ring)

    /// Simulates what happens when arrow-key navigation (not a click) lands
    /// on a remote row: SwiftUI's `List(selection:)` writes the row's tag
    /// directly into `selectedWorktreeIDs` — `RemoteSessionRowView.onTapGesture`
    /// never fires for a keyboard-only move. The `didSet` must still route
    /// this into `selectRemoteSession` so the row's own highlight and
    /// `selectedRemoteSession` end up correct exactly as a click would.
    @Test func remoteSessionTagEnteringSelectedWorktreeIDsRoutesThroughSelectRemoteSession() {
        withState { state in
            let session = RemoteSessionInfo(
                provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                gone: false, dismissed: false, lastSeen: Date())
            state.remoteSessions = [session]

            // Simulate the List binding writing the tag straight in (what
            // arrow-key traversal does), not `selectRemoteSession` itself.
            state.selectedWorktreeIDs = [session.id]

            #expect(state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s1"))
        }
    }

    /// The remote id must not linger in `selectedWorktreeIDs` at rest — every
    /// other consumer of that set (keyboard shortcuts, jump menu, navigation
    /// history, persisted restore) assumes every member is a real
    /// `Worktree.id`.
    @Test func remoteSessionTagIsStrippedBackOutOfSelectedWorktreeIDs() {
        withState { state in
            let session = RemoteSessionInfo(
                provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                gone: false, dismissed: false, lastSeen: Date())
            state.remoteSessions = [session]

            state.selectedWorktreeIDs = [session.id]

            #expect(state.selectedWorktreeIDs.isEmpty)
        }
    }

    /// Landing on a remote row via the shared Set also clears repo/scratch
    /// selection, exactly like `selectRemoteSession` called directly.
    @Test func remoteSessionTagEnteringSelectedWorktreeIDsClearsRepoAndScratchSelection() {
        withState { state in
            let repoID = UUID()
            state.repos = [Repo(id: repoID, path: "/tmp/r", displayName: "r", defaultBranch: "main")]
            state.selectRepo(id: repoID)
            #expect(state.selectedRepoID == repoID)

            let session = RemoteSessionInfo(
                provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                gone: false, dismissed: false, lastSeen: Date())
            state.remoteSessions = [session]
            state.selectedWorktreeIDs = [session.id]

            #expect(state.selectedRepoID == nil)
        }
    }

    /// Regression guard: a plain worktree selection must behave EXACTLY as
    /// before this feature, even with unrelated remote sessions loaded —
    /// the new remote-tag branch in the `didSet` must never fire for a real
    /// worktree id.
    @Test func plainWorktreeSelectionIsUnaffectedByLoadedRemoteSessions() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            state.remoteSessions = [RemoteSessionInfo(
                provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                gone: false, dismissed: false, lastSeen: Date())]

            state.selectedWorktreeIDs = [wtID]

            #expect(state.selectedWorktreeIDs == [wtID])
            #expect(state.selectionOrder == [wtID])
            #expect(state.selectedRemoteSession == nil)
        }
    }

    // MARK: - Fix pass 1, item 2: mixed local+remote selection must not
    // wipe local ids

    /// The bug: `List(selection:)` writing a shift-extended range that spans
    /// a local worktree row AND a remote row lands both tags in
    /// `selectedWorktreeIDs` in one assignment. Before this fix, the
    /// remote-tag branch unconditionally routed through
    /// `selectRemoteSession`, whose `selectedWorktreeIDs = []` wiped the
    /// local id out from under the very selection that just set it — a
    /// regression `.tag()`-ing remote rows into the shared Set made
    /// possible for the first time (previously remote rows had no tag at
    /// all). Local ids must survive; `selectedRemoteSession` must NOT be set
    /// (this is a local selection, not a remote one).
    @Test func mixedLocalAndRemoteSelectionPreservesTheLocalID() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            let session = RemoteSessionInfo(
                provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                gone: false, dismissed: false, lastSeen: Date())
            state.remoteSessions = [session]

            // Simulates a shift+↓ range extending FROM the local worktree
            // row ONTO the remote row: the List binding writes both tags in
            // a single assignment.
            state.selectedWorktreeIDs = [wtID, session.id]

            #expect(state.selectedWorktreeIDs == [wtID],
                     "the remote tag must be stripped but the local id must survive")
            #expect(state.selectedRemoteSession == nil,
                     "a mixed selection is a local selection, not a remote one")
        }
    }

    /// Same bug, opposite gesture direction: a range that starts on a remote
    /// row and extends onto a local worktree row must land in exactly the
    /// same place — local id preserved, no remote selection recorded.
    /// (`selectedWorktreeIDs` is a Set, so the two directions produce an
    /// identical Set value at the `didSet` boundary — this test exists to
    /// document that the fix is direction-agnostic, per the review's
    /// explicit ask to test both directions, not because the code could
    /// plausibly special-case order.)
    @Test func mixedRemoteAndLocalSelectionPreservesTheLocalID() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            let session = RemoteSessionInfo(
                provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                gone: false, dismissed: false, lastSeen: Date())
            state.remoteSessions = [session]

            // Simulates a shift+↑ range extending FROM the remote row ONTO
            // the local worktree row.
            state.selectedWorktreeIDs = [session.id, wtID]

            #expect(state.selectedWorktreeIDs == [wtID],
                     "the remote tag must be stripped but the local id must survive")
            #expect(state.selectedRemoteSession == nil,
                     "a mixed selection is a local selection, not a remote one")
        }
    }

    /// A mixed selection must still run the ordinary worktree-selection
    /// bookkeeping (`selectionOrder`, navigation history) for the surviving
    /// local id — exactly once, not skipped and not duplicated by the
    /// nested `didSet` invocation the internal `subtract` triggers.
    @Test func mixedSelectionRunsWorktreeBookkeepingExactlyOnceForTheSurvivingLocalID() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            let session = RemoteSessionInfo(
                provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                gone: false, dismissed: false, lastSeen: Date())
            state.remoteSessions = [session]

            state.selectedWorktreeIDs = [wtID, session.id]

            #expect(state.selectionOrder == [wtID])
            #expect(state.canGoBack == false, "exactly one navigation entry recorded, nothing to go back to")
        }
    }

    /// A mixed selection that also includes a repo header tag must strip
    /// BOTH foreign tags down to the surviving local worktree id, not just
    /// the remote one — the two special-case branches in the `didSet` must
    /// compose.
    @Test func mixedSelectionAlsoStripsARepoHeaderTag() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.repos = [Repo(id: repoID, path: "/tmp/r", displayName: "r", defaultBranch: "main")]
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]
            let session = RemoteSessionInfo(
                provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                gone: false, dismissed: false, lastSeen: Date())
            state.remoteSessions = [session]

            state.selectedWorktreeIDs = [wtID, repoID, session.id]

            #expect(state.selectedWorktreeIDs == [wtID])
        }
    }
}
