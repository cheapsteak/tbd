import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Task 9 (Remote sidebar section). Covers the pure, view-independent parts:
/// - `RemoteSectionView.sessions(in:forProvider:)` — per-provider filtering
///   with dismissed tombstones excluded.
/// - `RowStatusIndicator.leading(isPending:hasPRStatus:isRemote:)` — the
///   new `.remote` case and its precedence under the existing leading slot.
/// - `RemoteSessionRowView.caption(state:agentState:gone:exitCode:)` — the
///   starting/exited/gone/unavailable captions and their precedence.
/// - `AppState.remoteUnreadType(kind:exitCode:)` — the pure kind→
///   `NotificationType` mapping feeding `unreadByRemoteSession`.
/// - `AppState.remoteSectionVisible(providers:)` — section-hidden-when-no-
///   providers.
@Suite("Remote section view — pure helpers")
struct RemoteSectionViewTests {

    private func session(
        provider: String,
        id: String,
        state: RemoteProcessState = .running,
        gone: Bool = false,
        dismissed: Bool = false
    ) -> RemoteSessionInfo {
        RemoteSessionInfo(
            provider: provider,
            payload: RemoteSessionPayload(id: id, state: state),
            gone: gone, dismissed: dismissed, lastSeen: Date()
        )
    }

    // MARK: - sessions(in:forProvider:)

    @Test func filtersToOnlyTheRequestedProvider() {
        let sessions = [
            session(provider: "acme", id: "s1"),
            session(provider: "other", id: "s2"),
        ]
        let result = RemoteSectionView.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [])
        #expect(result.map(\.payload.id) == ["s1"])
    }

    @Test func excludesDismissedSessions() {
        let sessions = [
            session(provider: "acme", id: "s1", dismissed: true),
            session(provider: "acme", id: "s2", dismissed: false),
        ]
        let result = RemoteSectionView.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [])
        #expect(result.map(\.payload.id) == ["s2"])
    }

    @Test func includesGoneButNotDismissedSessions() {
        // `gone` sessions still render (dimmed, with a Dismiss action) —
        // only `dismissed` (the user's tombstone action) removes a row.
        let sessions = [session(provider: "acme", id: "s1", gone: true, dismissed: false)]
        let result = RemoteSectionView.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [])
        #expect(result.map(\.payload.id) == ["s1"])
    }

    @Test func emptyWhenNoSessionsMatchProvider() {
        let sessions = [session(provider: "other", id: "s1")]
        #expect(RemoteSectionView.sessions(in: sessions, forProvider: "acme", knownRepoIDs: []).isEmpty)
    }

    /// Task 9d: a session resolved to a local repo renders inside that
    /// repo's section instead (`RepoSectionView.matchedRemoteSessions`) — it
    /// must NOT also appear in the provider-named Remote section.
    @Test func excludesSessionsResolvedToARepo() {
        let repoID = UUID()
        let sessions = [
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: repoID),
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s2", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: nil),
        ]
        let result = RemoteSectionView.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [repoID])
        #expect(result.map(\.payload.id) == ["s2"])
    }

    /// Fix pass 1, item 1: a row pinned to a repo that has since been
    /// removed from TBD must fall back into the provider section instead of
    /// rendering nowhere — `resolvedRepoID` is a plain, un-cascaded value
    /// the daemon never clears, so the app must independently notice the id
    /// no longer names a repo it knows about.
    @Test func aSessionResolvedToARepoThatNoLongerExistsFallsBackToTheProviderSection() {
        let removedRepoID = UUID()
        let sessions = [
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: removedRepoID),
        ]
        // knownRepoIDs deliberately does NOT contain removedRepoID — the
        // repo was removed after the row was pinned.
        let result = RemoteSectionView.sessions(in: sessions, forProvider: "acme", knownRepoIDs: [])
        #expect(result.map(\.payload.id) == ["s1"])
    }

    /// The same repo-removed scenario must not silently hide a provider's
    /// header either — a provider whose only session is pinned to a
    /// now-missing repo still has something to say here.
    @Test func shouldShowHeader_trueWhenOnlySessionIsResolvedToARemovedRepo() {
        let removedRepoID = UUID()
        let sessions = [
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: removedRepoID),
        ]
        #expect(RemoteSectionView.shouldShowHeader(provider: status(health: .ok), sessions: sessions, knownRepoIDs: []))
    }

    // MARK: - knownRepoIDs(repos:repoFilter:) — final review item 3

    private func repo(id: UUID = UUID(), hidden: Bool = false) -> Repo {
        Repo(id: id, path: "/tmp/\(id)", displayName: "repo", defaultBranch: "main", hidden: hidden)
    }

    /// No filter, no hidden repos: every repo is "known" — the pre-existing
    /// behavior for the common case.
    @Test func knownRepoIDs_noFilterIncludesAllRepos() {
        let visible = repo()
        let known = RemoteSectionView.knownRepoIDs(repos: [visible], repoFilter: nil)
        #expect(known == [visible.id])
    }

    /// The hidden-repo half of the decision: a hidden repo's id counts as
    /// "known" even though `SidebarView.filteredRepos` doesn't render a
    /// section for it (when "show hidden repos" is off) — so a session
    /// matched to it is excluded from THIS section too, by analogy with a
    /// hidden repo's local worktrees vanishing from the sidebar entirely.
    /// This function deliberately never consults the hidden flag: hiding a
    /// repo hides its remote sessions along with it.
    @Test func knownRepoIDs_hiddenRepoStillCountsAsKnown() {
        let hiddenRepo = repo(hidden: true)
        let known = RemoteSectionView.knownRepoIDs(repos: [hiddenRepo], repoFilter: nil)
        #expect(known == [hiddenRepo.id], "a hidden repo must still count as known, not fall through to Remote")
    }

    /// The repo-filter half of the decision: with a filter active, only the
    /// filtered repo counts as known — every OTHER repo (even though it's
    /// still a normal, non-hidden repo in `appState.repos`) must NOT count
    /// as known, so its matched sessions fall through to this section
    /// instead of rendering nowhere while the filter narrows the sidebar to
    /// one repo section.
    @Test func knownRepoIDs_activeFilterExcludesEveryOtherRepo() {
        let filtered = repo()
        let other = repo()
        let known = RemoteSectionView.knownRepoIDs(repos: [filtered, other], repoFilter: filtered.id)
        #expect(known == [filtered.id])
        #expect(!known.contains(other.id), "an unfiltered-out repo must not count as known while a filter is active")
    }

    /// End-to-end (via `sessions(in:forProvider:knownRepoIDs:)`): a session
    /// matched to a repo excluded only by an active filter renders in the
    /// Remote section rather than nowhere.
    @Test func filteredOutRepoSessionFallsBackToRemoteSection() {
        let filtered = repo()
        let other = repo()
        let sessions = [
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: other.id),
        ]
        let known = RemoteSectionView.knownRepoIDs(repos: [filtered, other], repoFilter: filtered.id)
        let result = RemoteSectionView.sessions(in: sessions, forProvider: "acme", knownRepoIDs: known)
        #expect(result.map(\.payload.id) == ["s1"])
    }

    /// End-to-end: a session matched to a HIDDEN repo does not fall back to
    /// the Remote section — the deliberate "hide sessions along with the
    /// repo" choice, not a regression of the filtered-repo fix above.
    @Test func hiddenRepoSessionDoesNotFallBackToRemoteSection() {
        let hiddenRepo = repo(hidden: true)
        let sessions = [
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: hiddenRepo.id),
        ]
        let known = RemoteSectionView.knownRepoIDs(repos: [hiddenRepo], repoFilter: nil)
        let result = RemoteSectionView.sessions(in: sessions, forProvider: "acme", knownRepoIDs: known)
        #expect(result.isEmpty)
    }

    // MARK: - shouldShowHeader(provider:sessions:knownRepoIDs:)

    private func status(
        name: String = "acme", health: ProviderHealth,
        errorMessage: String? = nil, lastSuccess: Date? = nil
    ) -> RemoteProviderStatus {
        RemoteProviderStatus(
            config: RemoteProviderConfig(name: name, exec: "/usr/bin/true"),
            describe: nil, health: health,
            errorMessage: errorMessage, remediationLabel: nil, remediationCommand: nil,
            lastSuccessfulSnapshotAt: lastSuccess)
    }

    @Test func shouldShowHeader_trueWhenHealthyWithUnmatchedSessions() {
        let sessions = [session(provider: "acme", id: "s1")]
        #expect(RemoteSectionView.shouldShowHeader(provider: status(health: .ok), sessions: sessions, knownRepoIDs: []))
    }

    /// A fully matched provider remains the stable entry point to its desk.
    @Test func shouldShowHeader_trueWhenHealthyAndFullyMatched() {
        let repoID = UUID()
        let sessions = [
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: repoID),
        ]
        #expect(RemoteSectionView.shouldShowHeader(provider: status(health: .ok), sessions: sessions, knownRepoIDs: [repoID]))
    }

    /// The health-visibility guarantee: even with every session matched, an
    /// UNHEALTHY provider still shows its bare header so the health glyph
    /// (auth expired, stale, error) never goes dark just because grouping
    /// absorbed every row.
    @Test func shouldShowHeader_trueWhenUnhealthyEvenIfFullyMatched() {
        let repoID = UUID()
        let sessions = [
            RemoteSessionInfo(provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
                              gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: repoID),
        ]
        #expect(RemoteSectionView.shouldShowHeader(provider: status(health: .needsAuth), sessions: sessions, knownRepoIDs: [repoID]))
    }

    @Test func shouldShowHeader_trueWhenUnhealthyWithNoSessionsAtAll() {
        #expect(RemoteSectionView.shouldShowHeader(provider: status(health: .error), sessions: [], knownRepoIDs: []))
    }

    @Test func shouldShowHeader_trueWhenHealthyWithNoSessionsAtAll() {
        #expect(RemoteSectionView.shouldShowHeader(provider: status(health: .ok), sessions: [], knownRepoIDs: []))
    }

    // MARK: - RowStatusIndicator.leading — `.remote` case + precedence

    @Test func leading_remoteWhenNeitherPendingNorPRStatus() {
        #expect(RowStatusIndicator.leading(isPending: false, hasPRStatus: false, isRemote: true) == .remote)
    }

    @Test func leading_pendingBeatsRemote() {
        #expect(RowStatusIndicator.leading(isPending: true, hasPRStatus: false, isRemote: true) == .pending)
    }

    @Test func leading_prStatusBeatsRemote() {
        #expect(RowStatusIndicator.leading(isPending: false, hasPRStatus: true, isRemote: true) == .prStatus)
    }

    @Test func leading_prStatusBeatsPendingAndRemote() {
        #expect(RowStatusIndicator.leading(isPending: true, hasPRStatus: true, isRemote: true) == .prStatus)
    }

    @Test func leading_nilWhenNothingApplies() {
        #expect(RowStatusIndicator.leading(isPending: false, hasPRStatus: false) == nil)
    }

    @Test func leading_defaultsIsRemoteToFalse() {
        // Existing (local-row) call sites don't pass `isRemote` — confirm
        // the default keeps them at `nil`, not `.remote`.
        #expect(RowStatusIndicator.leading(isPending: false, hasPRStatus: false) == nil)
    }

    // MARK: - RemoteSessionRowView.caption(state:agentState:gone:exitCode:)

    @Test func caption_startingIsStartingEllipsis() {
        #expect(RemoteSessionRowView.caption(
            state: .starting, agentState: .unknown, gone: false, exitCode: nil
        ) == "Starting…")
    }

    @Test func caption_runningIsNil() {
        #expect(RemoteSessionRowView.caption(
            state: .running, agentState: .idle, gone: false, exitCode: nil
        ) == nil)
    }

    @Test func caption_runningUnknownSurfacesUnavailableAgentState() {
        #expect(RemoteSessionRowView.caption(
            state: .running, agentState: .unknown, gone: false, exitCode: nil
        ) == "agent state unavailable")
    }

    @Test func caption_runningKnownAgentStatesRemainQuiet() {
        #expect(RemoteSessionRowView.caption(
            state: .running, agentState: .working, gone: false, exitCode: nil
        ) == nil)
        #expect(RemoteSessionRowView.caption(
            state: .running, agentState: .idle, gone: false, exitCode: nil
        ) == nil)
    }

    @Test func caption_unknownSurfacesUnavailableTerminalState() {
        #expect(RemoteSessionRowView.caption(
            state: .unknown, agentState: .unknown, gone: false, exitCode: nil
        ) == "terminal state unavailable")
    }

    @Test func caption_exitedWithKnownCodeIncludesCode() {
        #expect(RemoteSessionRowView.caption(
            state: .exited, agentState: .exited, gone: false, exitCode: 1
        ) == "exited (code 1)")
    }

    @Test func caption_exitedWithoutKnownCodeOmitsCode() {
        #expect(RemoteSessionRowView.caption(
            state: .exited, agentState: .exited, gone: false, exitCode: nil
        ) == "exited")
    }

    @Test func caption_goneWinsOverExitedCode() {
        #expect(RemoteSessionRowView.caption(
            state: .exited, agentState: .exited, gone: true, exitCode: 1
        ) == "no longer reported")
    }

    @Test func caption_goneWinsOverStarting() {
        #expect(RemoteSessionRowView.caption(
            state: .starting, agentState: .unknown, gone: true, exitCode: nil
        ) == "no longer reported")
    }

    @Test func caption_goneWinsOverRunningUnknownAgentState() {
        #expect(RemoteSessionRowView.caption(
            state: .running, agentState: .unknown, gone: true, exitCode: nil
        ) == "no longer reported")
    }

    // MARK: - RemoteSessionRowView.caption(staleness:) combining

    @Test func caption_stalenessAloneRendersWhenThereIsNoOtherCaption() {
        // The maintainer's exact scenario: a plain running session (no other
        // caption) under an unhealthy provider must not go silent — this is
        // the only signal a grouped row (no visible provider header nearby)
        // gets that its data might be hours old.
        #expect(
            RemoteSessionRowView.caption(
                state: .running, agentState: .idle, gone: false,
                exitCode: nil, staleness: "as of 2h ago"
            )
                == "as of 2h ago"
        )
    }

    @Test func caption_stalenessCombinesWithUnavailableAgentState() {
        #expect(RemoteSessionRowView.caption(
            state: .running,
            agentState: .unknown,
            gone: false,
            exitCode: nil,
            staleness: "as of 2h ago"
        ) == "agent state unavailable · as of 2h ago")
    }

    @Test func caption_stalenessCombinesWithUnavailableTerminalState() {
        #expect(RemoteSessionRowView.caption(
            state: .unknown,
            agentState: .unknown,
            gone: false,
            exitCode: nil,
            staleness: "as of 2h ago"
        ) == "terminal state unavailable · as of 2h ago")
    }

    @Test func caption_stalenessCombinesWithAnExistingCaption() {
        #expect(
            RemoteSessionRowView.caption(
                state: .exited, agentState: .exited, gone: false,
                exitCode: 1, staleness: "as of 2h ago"
            )
                == "exited (code 1) · as of 2h ago"
        )
    }

    @Test func caption_stalenessCombinesWithGone() {
        #expect(
            RemoteSessionRowView.caption(
                state: .exited, agentState: .exited, gone: true,
                exitCode: 1, staleness: "as of 2h ago"
            )
                == "no longer reported · as of 2h ago"
        )
    }

    @Test func caption_nilStalenessLeavesExistingCaptionsUnchanged() {
        // Every pre-existing call site (no `staleness` argument) must render
        // exactly as before this task.
        #expect(RemoteSessionRowView.caption(
            state: .running, agentState: .idle, gone: false, exitCode: nil
        ) == nil)
        #expect(RemoteSessionRowView.caption(
            state: .starting, agentState: .unknown, gone: false, exitCode: nil
        ) == "Starting…")
    }

    // MARK: - RemoteSessionRowView.stalenessCaption(health:lastSeen:now:)

    @Test func stalenessCaption_nilWhenProviderIsHealthy() {
        #expect(RemoteSessionRowView.stalenessCaption(
            health: .ok, lastSuccessfulSnapshotAt: Date(), now: Date()) == nil)
    }

    @Test func stalenessCaption_reflectsRelativeAgeWhenStale() {
        let now = Date(timeIntervalSince1970: 10_000)
        let lastSeen = now.addingTimeInterval(-2 * 3600)
        #expect(RemoteSessionRowView.stalenessCaption(
            health: .stale, lastSuccessfulSnapshotAt: lastSeen, now: now) == "as of 2h ago")
    }

    @Test func stalenessCaption_justNowOmitsTheTrailingAgo() {
        let now = Date(timeIntervalSince1970: 10_000)
        let lastSeen = now.addingTimeInterval(-5)
        #expect(RemoteSessionRowView.stalenessCaption(
            health: .error, lastSuccessfulSnapshotAt: lastSeen, now: now) == "as of just now")
    }

    @Test func stalenessCaption_rendersForNeedsAuthHealthToo() {
        let now = Date(timeIntervalSince1970: 10_000)
        let lastSeen = now.addingTimeInterval(-5 * 60)
        #expect(RemoteSessionRowView.stalenessCaption(
            health: .needsAuth, lastSuccessfulSnapshotAt: lastSeen, now: now) == "as of 5m ago")
    }

    @Test func providerIssueSummaryShowsBoundedErrorAndLastGoodAge() {
        let now = Date(timeIntervalSince1970: 10_000)
        let provider = status(
            health: .stale, errorMessage: "Inventory response was truncated",
            lastSuccess: now.addingTimeInterval(-2 * 3600))
        #expect(RemoteProviderStatusPresentation.issueSummary(provider, now: now)
                == "Inventory response was truncated · last good 2h ago")
    }

    @Test func providerIssueSummarySaysWhenNoSuccessfulSnapshotExists() {
        let provider = status(health: .error, errorMessage: "Provider failed")
        #expect(RemoteProviderStatusPresentation.issueSummary(provider)
                == "Provider failed · no successful snapshot yet")
    }

    @Test func providerIssueSummaryIsNilWhenHealthy() {
        #expect(RemoteProviderStatusPresentation.issueSummary(status(health: .ok)) == nil)
    }

    // MARK: - AppState.remoteUnreadType(kind:exitCode:)

    @Test func remoteUnreadType_waitingInputIsAttentionNeeded() {
        #expect(AppState.remoteUnreadType(kind: "waiting_input", exitCode: nil) == .attentionNeeded)
    }

    @Test func remoteUnreadType_exitedWithNonzeroCodeIsError() {
        #expect(AppState.remoteUnreadType(kind: "exited", exitCode: 1) == .error)
    }

    @Test func remoteUnreadType_exitedWithZeroCodeIsResponseComplete() {
        #expect(AppState.remoteUnreadType(kind: "exited", exitCode: 0) == .responseComplete)
    }

    @Test func remoteUnreadType_exitedWithUnknownCodeIsResponseComplete() {
        #expect(AppState.remoteUnreadType(kind: "exited", exitCode: nil) == .responseComplete)
    }

    @Test func remoteUnreadType_unrecognizedKindIsNil() {
        #expect(AppState.remoteUnreadType(kind: "idle", exitCode: nil) == nil)
    }

    // MARK: - RemoteSessionRowView.suffixIndicator(agentState:unreadType:) — steady-state mapping + severity merge

    @Test func suffixIndicator_workingIsWorking() {
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .working, unreadType: nil) == .working)
    }

    /// The steady-state divergence: `waitingInput` maps to `.attention` on
    /// every call, purely from `agentState` — there is no edge/latch here,
    /// unlike the `unreadByRemoteSession` bookkeeping (which is edge-
    /// triggered and clears on select). Calling this twice in a row for the
    /// same still-waiting session must keep returning `.attention`.
    @Test func suffixIndicator_waitingInputIsAttentionSteadily() {
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .waitingInput, unreadType: nil) == .attention)
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .waitingInput, unreadType: nil) == .attention)
    }

    @Test func suffixIndicator_idleIsNil() {
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .idle, unreadType: nil) == nil)
    }

    @Test func suffixIndicator_unknownIsNil() {
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .unknown, unreadType: nil) == nil)
    }

    @Test func suffixIndicator_exitedWithNoUnreadIsNil() {
        // `.exited` agentState alone produces no suffix glyph — the exited/gone
        // presentation is secondary-toned text + a caption, not a suffix icon —
        // UNLESS the unread entry says otherwise (see the nonzero-exit test below).
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .exited, unreadType: nil) == nil)
    }

    // MARK: - severity merge (unread entry vs. steady agentState)

    /// The bug this merge fixes: a nonzero exit records `.error` in
    /// `unreadByRemoteSession`, but `agentState` is `.exited` (no steady
    /// mapping) — without folding the unread entry in, the suffix would be
    /// nil and the loudest case would render as the quietest row.
    @Test func suffixIndicator_erroredUnreadShowsErrorEvenWithNoSteadySignal() {
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .exited, unreadType: .error) == .error)
    }

    /// Error (severity 4) beats the steady attention mapping (severity 3) —
    /// `RowStatusIndicator.suffix`'s existing precedence, not a new ladder.
    @Test func suffixIndicator_erroredUnreadBeatsSteadyWaitingInput() {
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .waitingInput, unreadType: .error) == .error)
    }

    /// A lower-severity unread entry (`.responseComplete`, severity 1) must
    /// not mask a still-waiting steady state (severity 3 via `.attentionNeeded`).
    @Test func suffixIndicator_steadyWaitingInputBeatsLowerSeverityUnread() {
        #expect(RemoteSessionRowView.suffixIndicator(agentState: .waitingInput, unreadType: .responseComplete) == .attention)
    }

    // MARK: - RemoteSessionRowView.higherSeverity(_:_:)

    @Test func higherSeverity_bothNilIsNil() {
        #expect(RemoteSessionRowView.higherSeverity(nil, nil) == nil)
    }

    @Test func higherSeverity_onlyFirstIsFirst() {
        #expect(RemoteSessionRowView.higherSeverity(.error, nil) == .error)
    }

    @Test func higherSeverity_onlySecondIsSecond() {
        #expect(RemoteSessionRowView.higherSeverity(nil, .attentionNeeded) == .attentionNeeded)
    }

    @Test func higherSeverity_picksHigherOfTwo() {
        #expect(RemoteSessionRowView.higherSeverity(.responseComplete, .error) == .error)
        #expect(RemoteSessionRowView.higherSeverity(.error, .responseComplete) == .error)
    }

    // MARK: - AppState.remoteSectionVisible(providers:)

    @Test func remoteSectionVisible_falseWhenNoProviders() {
        #expect(AppState.remoteSectionVisible(providers: []) == false)
    }

    @Test func remoteSectionVisible_trueWhenAtLeastOneProvider() {
        let provider = RemoteProviderStatus(
            config: RemoteProviderConfig(name: "acme", exec: "/usr/bin/true"),
            describe: nil, health: .ok,
            errorMessage: nil, remediationLabel: nil, remediationCommand: nil
        )
        #expect(AppState.remoteSectionVisible(providers: [provider]) == true)
    }
}
