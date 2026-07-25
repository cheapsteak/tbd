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

    @Test func selectingAnotherRemoteSessionReplacesThePreviousOne() {
        withState { state in
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            state.selectRemoteSession(provider: "acme", sessionID: "s2")

            #expect(state.selectedRemoteSession == RemoteSessionSelection(provider: "acme", sessionID: "s2"))
        }
    }

    /// Back/forward navigation entries never encode a remote-session
    /// selection (documented scope cut, same as scratch), but applying a
    /// `.repo` or `.worktrees` history entry must still clear a lingering
    /// remote-session selection so it never survives navigating away.
    @Test func navigatingBackToARepoEntryClearsRemoteSessionSelection() {
        withState { state in
            let repoID = UUID()
            let wtID = UUID()
            state.repos = [Repo(id: repoID, path: "/tmp/r", displayName: "r", defaultBranch: "main")]
            state.worktrees = [repoID: [makeWorktree(id: wtID, repoID: repoID)]]

            // History: [.repo(repoID)] (index 0), [.worktrees([wtID])] (index 1, current).
            state.selectRepo(id: repoID)
            state.selectedWorktreeIDs = [wtID]

            // Remote-session selection is set without going through
            // recordNavigation (documented scope cut) — history still points
            // at index 1.
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.selectedRemoteSession != nil)
            #expect(state.canGoBack == true)

            state.navigateBack()

            #expect(state.selectedRemoteSession == nil)
            #expect(state.selectedRepoID == repoID)
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
}
