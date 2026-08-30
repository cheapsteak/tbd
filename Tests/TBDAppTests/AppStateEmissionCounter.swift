import Foundation
import TestSupport
import Testing
@testable import TBDApp

// Tier 1: deterministic, in-process state only. No sleeps, no subprocesses,
// no `~/tbd`.

// MARK: - The instrument

/// Counts observer notifications from every tracked property of `state` across
/// `body` — the object-wide emission count.
///
/// `AppState` is `@Observable`, so there is no `objectWillChange` to subscribe
/// to: notification is per-property, and a consumer hears only about the
/// properties it read. To keep measuring the *object-wide* rate this file was
/// built around, ``AppStateEmissionTracker`` arms a `withObservationTracking`
/// whose `apply` closure reads all of `AppState`'s tracked stored properties,
/// so any one of them firing is a notification this counter hears.
///
/// Two sharp edges of the primitive it is built on:
///
/// - **`onChange` is one-shot.** It must re-arm after every fire or the counter
///   silently stops at 1. The re-arm here is *synchronous*, inside the callback,
///   because these tests write several properties back-to-back within one
///   synchronous call and a hop to a later turn would drop everything in
///   between.
/// - **`onChange` fires in `willSet` position**, before the write commits. That
///   is irrelevant to a counter, which never reads the new value.
///
/// The subtlety this whole file exists to expose mostly survives the migration:
/// Observation notifies on **assignment**, not on change. A guard inside a
/// property's `didSet` suppresses the downstream work but not the notification.
/// To spare a render pass, the equality guard has to sit at the *assignment
/// site*. What per-property tracking changed is *who* pays for a redundant
/// notification — every reader of that one property, rather than every view
/// observing the object — not whether one is sent.
///
/// The one carve-out, because reading the paragraph above without it leads
/// straight to a wrong conclusion about the counts in
/// `AppStatePublishFrequencyTests`: Swift 6.2's macro *does* drop the
/// notification for a whole-property assignment of an equal value when the
/// property's type is `Equatable`. It does not do so for anything reached
/// through `_modify` — `dict[k] = v`, `rows[i].field = x`, `set.insert(…)` —
/// nor for a property whose type is not `Equatable`.
/// ``AppStateObservationContractTests`` pins both halves of that rule.
///
/// ``AppStateTrackedPropertyCoverageTests`` pins the read list against the
/// class, so a property added to `AppState` without being added here fails a
/// test rather than quietly going uncounted.
@MainActor
final class AppStateEmissionTracker {
    private let state: AppState
    private var isLive = true
    private(set) var count = 0

    init(_ state: AppState) {
        self.state = state
        arm()
    }

    /// Stop counting. Idempotent, and required on the way out of a measurement
    /// so a later emission from an unrelated test cannot be attributed to this
    /// one — the Observation equivalent of cancelling a Combine subscription.
    func stop() {
        isLive = false
    }

    private func arm() {
        withObservationTracking {
            Self.readAllTrackedProperties(of: state)
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isLive else { return }
                self.count += 1
                self.arm()
            }
        }
    }

    /// Every tracked stored property of `AppState`, read once, so that
    /// `withObservationTracking` registers a dependency on all of them.
    ///
    /// Deliberately reads only *stored* properties: a computed one such as
    /// `allWorktrees` would fill a memo cache as a side effect of measuring.
    static func readAllTrackedProperties(of state: AppState) {
        _ = state.repos
        _ = state.worktrees
        _ = state.scratchWorktrees
        _ = state.terminals
        _ = state.notes
        _ = state.focusedTabCloseContext
        _ = state.unreadByWorktree
        _ = state.unreadByRemoteSession
        _ = state.unreadTerminals
        _ = state.selectedWorktreeIDs
        _ = state.selectionOrder
        _ = state.repoDetailReveal
        _ = state.selectedRepoID
        _ = state.pendingRepoDetailTab
        _ = state.selectedScratchSection
        _ = state.selectedRemoteProvider
        _ = state.selectedRemoteSession
        _ = state.remoteSessionRequestedTab
        _ = state.canGoBack
        _ = state.canGoForward
        _ = state.archivedWorktrees
        _ = state.archivedScratchWorktrees
        _ = state.archivedWorktreesHasMore
        _ = state.isLoadingMoreArchived
        _ = state.archivedSearchQuery
        _ = state.archivedSearchResults
        _ = state.archivedSearchFailed
        _ = state.isLoadingMoreArchivedSearch
        _ = state.reapRecords
        _ = state.remoteProviders
        _ = state.remoteSessions
        _ = state.remoteSessionDisplayNames
        _ = state.highlightedArchivedWorktreeID
        _ = state.activeToast
        _ = state.pendingScrollToWorktreeID
        _ = state.isInitialStateLoaded
        _ = state.dockRatio
        _ = state.skipAccountPicker
        _ = state.mainAreaSize
        _ = state.isConnected
        _ = state.layouts
        _ = state.gridLayouts
        _ = state.paneHistories
        _ = state.tabs
        _ = state.activeTabIndices
        _ = state.worktreeTabOrders
        _ = state.draggingTabID
        _ = state.repoFilter
        _ = state.pendingWorktreeIDs
        _ = state.suspendingTerminalIDs
        _ = state.suspendingSnapshots
        _ = state.editingWorktreeID
        _ = state.isRenamingWorktree
        _ = state.prStatuses
        _ = state.prObservations
        _ = state.prBindings
        _ = state.prDetachedCounts
        _ = state.modelProfiles
        _ = state.defaultProfileID
        _ = state.codexUsage
        _ = state.isLoadingCodexUsage
        _ = state.primaryAgentPreference
        _ = state.globalEnvOverrides
        _ = state.globalRemoteCreateDefaults
        _ = state.autoArchiveOnMergeDefault
        _ = state.autoHibernateOnMergeDefault
        _ = state.gcEnabled
        _ = state.autoCreateNotesEnabled
        _ = state.nightwatchMode
        _ = state.autoHibernateEnabled
        _ = state.hibernateIdleMinutes
        _ = state.supervisionEnabled
        _ = state.autoResumeOnLimitReset
        _ = state.autoResumeOnApiError
        _ = state.dismissedProxyWarnings
        _ = state.daemonBuildMismatchMessage
        _ = state.daemonBuildMismatchDismissed
        _ = state.controlModeAttachedPanes
        _ = state.controlModeFailingInputPanes
        _ = state.historyActiveWorktrees
        _ = state.historyLoadStates
        _ = state.selectedSessionIDs
        _ = state.sessionTranscripts
        _ = state.sessionTranscriptLoading
        _ = state.pendingQuestions
        _ = state.closedTerminalHistories
        _ = state.selectedClosedTerminalIDs
        _ = state.closedTerminalContents
        _ = state.recentlyVisitedWorktreeIDs
        _ = state.recentWorktreeIDs
        _ = state.recentlyAttachedRemoteSessions
        _ = state.explicitlyDetachedRemoteSessions
        _ = state.pendingReconnectRemoteSessions
        _ = state.selectedArchivedWorktreeIDs
        _ = state.selectedReapRecordIDs
        _ = state.revivingArchived
        _ = state.alertMessage
        _ = state.alertIsError
        _ = state.tmuxExecutableResolution
        _ = state.savedTmuxExecutablePath
        _ = state.isTmuxLocationPromptPresented
        _ = state.daemonCapabilities
        _ = state.queuedPromptTarget
        _ = state.parkedPromptReadback
        _ = state.parkedPromptDeliveryInFlight
    }

    /// The read list above, as data, for the coverage test.
    static let trackedPropertyNames: Set<String> = [
        "repos",
        "worktrees",
        "scratchWorktrees",
        "terminals",
        "notes",
        "focusedTabCloseContext",
        "unreadByWorktree",
        "unreadByRemoteSession",
        "unreadTerminals",
        "selectedWorktreeIDs",
        "selectionOrder",
        "repoDetailReveal",
        "selectedRepoID",
        "pendingRepoDetailTab",
        "selectedScratchSection",
        "selectedRemoteProvider",
        "selectedRemoteSession",
        "remoteSessionRequestedTab",
        "canGoBack",
        "canGoForward",
        "archivedWorktrees",
        "archivedScratchWorktrees",
        "archivedWorktreesHasMore",
        "isLoadingMoreArchived",
        "archivedSearchQuery",
        "archivedSearchResults",
        "archivedSearchFailed",
        "isLoadingMoreArchivedSearch",
        "reapRecords",
        "remoteProviders",
        "remoteSessions",
        "remoteSessionDisplayNames",
        "highlightedArchivedWorktreeID",
        "activeToast",
        "pendingScrollToWorktreeID",
        "isInitialStateLoaded",
        "dockRatio",
        "skipAccountPicker",
        "mainAreaSize",
        "isConnected",
        "layouts",
        "gridLayouts",
        "paneHistories",
        "tabs",
        "activeTabIndices",
        "worktreeTabOrders",
        "draggingTabID",
        "repoFilter",
        "pendingWorktreeIDs",
        "suspendingTerminalIDs",
        "suspendingSnapshots",
        "editingWorktreeID",
        "isRenamingWorktree",
        "prStatuses",
        "prObservations",
        "prBindings",
        "prDetachedCounts",
        "modelProfiles",
        "defaultProfileID",
        "codexUsage",
        "isLoadingCodexUsage",
        "primaryAgentPreference",
        "globalEnvOverrides",
        "globalRemoteCreateDefaults",
        "autoArchiveOnMergeDefault",
        "autoHibernateOnMergeDefault",
        "gcEnabled",
        "autoCreateNotesEnabled",
        "nightwatchMode",
        "autoHibernateEnabled",
        "hibernateIdleMinutes",
        "supervisionEnabled",
        "autoResumeOnLimitReset",
        "autoResumeOnApiError",
        "dismissedProxyWarnings",
        "daemonBuildMismatchMessage",
        "daemonBuildMismatchDismissed",
        "controlModeAttachedPanes",
        "controlModeFailingInputPanes",
        "historyActiveWorktrees",
        "historyLoadStates",
        "selectedSessionIDs",
        "sessionTranscripts",
        "sessionTranscriptLoading",
        "pendingQuestions",
        "closedTerminalHistories",
        "selectedClosedTerminalIDs",
        "closedTerminalContents",
        "recentlyVisitedWorktreeIDs",
        "recentWorktreeIDs",
        "recentlyAttachedRemoteSessions",
        "explicitlyDetachedRemoteSessions",
        "pendingReconnectRemoteSessions",
        "selectedArchivedWorktreeIDs",
        "selectedReapRecordIDs",
        "revivingArchived",
        "alertMessage",
        "alertIsError",
        "tmuxExecutableResolution",
        "savedTmuxExecutablePath",
        "isTmuxLocationPromptPresented",
        "daemonCapabilities",
        "queuedPromptTarget",
        "parkedPromptReadback",
        "parkedPromptDeliveryInFlight",
    ]
}

/// Counts observer notifications from `state` across `body`.
///
/// The tracker is live for exactly the closure's duration and stopped on the
/// way out.
@MainActor
func countEmissions(of state: AppState, during body: () -> Void) -> Int {
    let tracker = AppStateEmissionTracker(state)
    defer { tracker.stop() }
    body()
    return tracker.count
}

/// `async` twin of ``countEmissions(of:during:)``, for driving a production path
/// that suspends. Same contract: the tracker is live for the whole operation,
/// including across every suspension point inside it.
///
/// Deliberately a separate argument label rather than an overload. A trailing
/// closure that happens to be synchronous binds to whichever overload the
/// compiler prefers, and picking the sync one for an `async` body would silently
/// stop counting at the first `await` — a miscount that looks exactly like a
/// well-behaved property.
@MainActor
func countEmissions(of state: AppState, duringAsync body: () async -> Void) async -> Int {
    let tracker = AppStateEmissionTracker(state)
    defer { tracker.stop() }
    await body()
    return tracker.count
}

// MARK: - Fixtures

/// `AppState` against a throwaway `UserDefaults` suite. `UserDefaults.standard`
/// on this unbundled executable is the developer's real `TBDApp.plist` — see
/// the root `CLAUDE.md`. Mirrors `AppStateDerivedCacheTests.withState`.
@MainActor
func withEmissionState(_ body: (AppState) -> Void) {
    let defaultsSuite = TestDefaultsSuite("AppStateEmissions")
    defer { defaultsSuite.tearDown() }
    let defaults = defaultsSuite.defaults
    body(AppState(userDefaults: defaults))
}
