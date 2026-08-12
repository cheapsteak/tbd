import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Tier 1. The pure client-side half of archived-worktree search: the substring
/// match that backs the preview shown while the daemon's SQL answer is still in
/// flight. Kept semantically identical to `WorktreeStore.list(nameQuery:)` so
/// the preview is a subset of the daemon's answer, not a different question.
@Suite("Archived worktree search filter")
struct ArchivedWorktreeSearchFilterTests {
    private func worktree(name: String, displayName: String) -> Worktree {
        Worktree(
            repoID: UUID(),
            name: name,
            displayName: displayName,
            branch: "tbd/\(name)",
            path: "/tmp/\(name)",
            status: .archived,
            tmuxServer: "srv"
        )
    }

    @Test("an empty or whitespace-only query matches everything")
    func emptyQueryMatchesEverything() {
        let wt = worktree(name: "curious-wolverine", displayName: "Curious Wolverine")
        #expect(ArchivedWorktreeSearchFilter.matches(wt, query: ""))
        #expect(ArchivedWorktreeSearchFilter.matches(wt, query: "   "))
    }

    @Test("matches the folder name, case-insensitively")
    func matchesFolderName() {
        let wt = worktree(name: "curious-wolverine", displayName: "Renamed")
        #expect(ArchivedWorktreeSearchFilter.matches(wt, query: "wolverine"))
        #expect(ArchivedWorktreeSearchFilter.matches(wt, query: "WOLVERINE"))
    }

    @Test("matches the display name even when the folder name does not")
    func matchesDisplayName() {
        let wt = worktree(name: "aaa-bbb", displayName: "Search Rail")
        #expect(ArchivedWorktreeSearchFilter.matches(wt, query: "rail"))
        #expect(!ArchivedWorktreeSearchFilter.matches(wt, query: "zzz"))
    }

    @Test("substring, not prefix")
    func matchesMidStringSubstring() {
        let wt = worktree(name: "tbd-archived-search", displayName: "tbd-archived-search")
        #expect(ArchivedWorktreeSearchFilter.matches(wt, query: "archiv"))
    }

    @Test("the query is trimmed before matching")
    func queryIsTrimmed() {
        let wt = worktree(name: "curious-wolverine", displayName: "Curious Wolverine")
        #expect(ArchivedWorktreeSearchFilter.matches(wt, query: "  wolverine  "))
    }

    @Test("a non-matching query matches neither name")
    func nonMatchingQuery() {
        let wt = worktree(name: "curious-wolverine", displayName: "Curious Wolverine")
        #expect(!ArchivedWorktreeSearchFilter.matches(wt, query: "otter"))
    }
}

/// Tier 1. Which row set the archived list renders for a given query, given
/// the query the results in hand actually answer.
///
/// The `.clientPreview` case for a *mismatched* results-query is a regression
/// test: the results and their query used to live in separate `AppState` dicts,
/// and the in-flight query was stamped before the RPC while the rows were
/// replaced after it. For that whole window the view believed the previous
/// query's rows were the settled answer for the new one — and since daemon
/// results are not re-filtered client-side, it displayed rows that do not match
/// what the user typed. Typing appeared not to narrow the list.
@Suite("Archived search display decision")
struct ArchivedSearchDisplayTests {
    @Test("no query shows every loaded row, whatever results are held")
    func emptyQueryIsUnfiltered() {
        #expect(ArchivedSearchDisplay.decide(query: "", resultsQuery: nil) == .unfiltered)
        #expect(ArchivedSearchDisplay.decide(query: "   ", resultsQuery: "abc") == .unfiltered)
    }

    @Test("results answering exactly this query are the row set")
    func matchingResultsQueryUsesDaemonResults() {
        #expect(ArchivedSearchDisplay.decide(query: "abc", resultsQuery: "abc") == .daemonResults)
        // The stored query is already trimmed; the typed one may not be.
        #expect(ArchivedSearchDisplay.decide(query: "  abc ", resultsQuery: "abc") == .daemonResults)
    }

    @Test("results answering a DIFFERENT query fall back to the client-side preview")
    func staleResultsQueryFallsBackToPreview() {
        // The exact stale-results defect: "abc" answered, "abcd" now typed.
        #expect(ArchivedSearchDisplay.decide(query: "abcd", resultsQuery: "abc") == .clientPreview)
        // And the reverse (user deleted a character).
        #expect(ArchivedSearchDisplay.decide(query: "abc", resultsQuery: "abcd") == .clientPreview)
    }

    @Test("no results at all fall back to the client-side preview")
    func noResultsFallsBackToPreview() {
        #expect(ArchivedSearchDisplay.decide(query: "abc", resultsQuery: nil) == .clientPreview)
    }
}

/// Tier 1. The full truth table for what the list area renders.
///
/// The bug this pins: an empty *client-side preview* was rendered as a
/// definitive "No matches". The preview filters only the loaded page, so it is
/// legitimately empty whenever the user is searching for an archive older than
/// the first 50 — the feature's entire purpose. And because each keystroke
/// restarts the 250 ms debounce, that state persists for as long as the user is
/// typing, not for the ~150 ms the RPC takes: they read "No matches" the whole
/// time they type the word.
@Suite("Archived search list state")
struct ArchivedSearchListStateTests {
    private func state(
        _ decision: ArchivedSearchDisplay.Decision,
        failed: Bool = false,
        rows: Bool
    ) -> ArchivedSearchDisplay.ListState {
        ArchivedSearchDisplay.listState(
            decision: decision, searchFailed: failed, hasVisibleRows: rows
        )
    }

    /// The reported bug. Asserted twice — the positive contract, and explicitly
    /// that it is NOT the verdict it used to render.
    @Test("an unsettled query with an empty preview is Searching, not No matches")
    func unsettledEmptyPreviewIsSearching() {
        let result = state(.clientPreview, failed: false, rows: false)
        #expect(result == .searching)
        #expect(result != .noMatches, "an unsettled preview must never read as a verdict")
    }

    /// No answer is coming, so a spinner would run forever. The inline
    /// "Search failed" note carries the explanation instead.
    @Test("a FAILED search with an empty preview is No matches, never a spinner")
    func failedSearchIsNoMatchesNotSpinner() {
        #expect(state(.clientPreview, failed: true, rows: false) == .noMatches)
    }

    @Test("the daemon's own empty answer is a genuine No matches")
    func daemonEmptyAnswerIsNoMatches() {
        #expect(state(.daemonResults, rows: false) == .noMatches)
        // `searchFailed` is irrelevant once a settled answer exists.
        #expect(state(.daemonResults, failed: true, rows: false) == .noMatches)
    }

    /// Regression guard for the pre-existing behaviour: with no query at all,
    /// an empty list means `hideEmpty` is hiding everything — that must keep
    /// its "Show all" verdict rather than becoming an endless spinner.
    @Test("no query with an empty list stays No matches, not Searching")
    func unfilteredEmptyIsNoMatches() {
        #expect(state(.unfiltered, rows: false) == .noMatches)
        #expect(state(.unfiltered, failed: true, rows: false) == .noMatches)
    }

    @Test("any decision with visible rows renders the rows")
    func visibleRowsAlwaysRender() {
        for decision: ArchivedSearchDisplay.Decision in [.unfiltered, .daemonResults, .clientPreview] {
            for failed in [true, false] {
                #expect(state(decision, failed: failed, rows: true) == .rows,
                        "decision \(decision), failed \(failed) must render rows")
            }
        }
    }
}

/// Tier 1. Regression coverage for the second archived row source.
///
/// Search results are rows the daemon matched in pages `archivedWorktrees`
/// never loaded. Every lookup written against the loaded pages alone silently
/// fails for them — which made Revive a no-op (no RPC, no alert, just a
/// `logger.warning`) on exactly the row a user searched to find, and made
/// `ensureArchivedSelectionValid` judge a search-only selection stale and
/// re-point the detail pane on the next refresh.
///
/// `AppState` constructs safely here: `init` skips its auto-connect under the
/// test harness (see `AppStateTestModeGuardTests`), and none of the methods
/// exercised below issue an RPC.
@MainActor
@Suite("Archived snapshot resolution")
struct ArchivedSnapshotResolutionTests {
    private func makeState() -> (AppState, String) {
        let suiteName = "TBDAppTests.ArchivedSnapshots.\(UUID().uuidString)"
        return (AppState(userDefaults: UserDefaults(suiteName: suiteName)!), suiteName)
    }

    private func worktree(repoID: UUID?, name: String) -> Worktree {
        Worktree(
            repoID: repoID, name: name, displayName: name, branch: "tbd/\(name)",
            path: "/tmp/\(name)", status: .archived, tmuxServer: "srv"
        )
    }

    // MARK: the pure union

    @Test("the union carries rows that exist only in the search results")
    func unionIncludesSearchOnlyRows() {
        let loaded = worktree(repoID: UUID(), name: "loaded")
        let searchOnly = worktree(repoID: UUID(), name: "search-only")
        let merged = AppState.mergeArchivedSnapshots(
            loaded: [loaded], searchResults: [searchOnly]
        )
        #expect(merged.map(\.id) == [loaded.id, searchOnly.id])
    }

    @Test("a row in both sources appears once, taking the loaded copy")
    func unionDedupesPreferringLoaded() {
        let repoID = UUID()
        var loaded = worktree(repoID: repoID, name: "shared")
        loaded.displayName = "fresh"
        var stale = loaded
        stale.displayName = "stale"

        let merged = AppState.mergeArchivedSnapshots(loaded: [loaded], searchResults: [stale])
        #expect(merged.count == 1)
        #expect(merged.first?.displayName == "fresh")
    }

    @Test("either source may be empty")
    func unionHandlesEmptySources() {
        let only = worktree(repoID: UUID(), name: "only")
        #expect(AppState.mergeArchivedSnapshots(loaded: [], searchResults: [only]).map(\.id) == [only.id])
        #expect(AppState.mergeArchivedSnapshots(loaded: [only], searchResults: []).map(\.id) == [only.id])
        #expect(AppState.mergeArchivedSnapshots(loaded: [], searchResults: []).isEmpty)
    }

    // MARK: the lookup the revive paths use

    /// The Finding-1 regression: this is the exact resolution both
    /// `reviveWorktree` and `reviveWithSession` guard on. Against
    /// `archivedWorktrees` alone it returned nil and the revive silently
    /// no-opped.
    @Test("archivedSnapshot resolves a row present only in the search results")
    func archivedSnapshotResolvesSearchOnlyRow() {
        let (state, suite) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let repoID = UUID()
        let loaded = worktree(repoID: repoID, name: "loaded")
        let searchOnly = worktree(repoID: repoID, name: "search-only")

        state.archivedWorktrees[repoID] = [loaded]
        state.archivedSearchResults[repoID] = ArchivedSearchResults(
            query: "search", worktrees: [searchOnly], hasMore: false
        )

        #expect(state.archivedSnapshot(id: searchOnly.id)?.id == searchOnly.id)
        #expect(state.archivedSnapshot(id: loaded.id)?.id == loaded.id)
        #expect(state.archivedSnapshot(id: UUID()) == nil)
    }

    /// A selection on a search-only row must survive selection maintenance.
    /// This branch early-returns, so no `fetchSessions` RPC is issued.
    @Test("ensureArchivedSelectionValid keeps a selection on a search-only row")
    func selectionOnSearchOnlyRowSurvives() {
        let (state, suite) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let repoID = UUID()
        let loaded = worktree(repoID: repoID, name: "loaded")
        let searchOnly = worktree(repoID: repoID, name: "search-only")

        state.archivedWorktrees[repoID] = [loaded]
        state.archivedSearchResults[repoID] = ArchivedSearchResults(
            query: "search", worktrees: [searchOnly], hasMore: false
        )
        state.selectArchivedWorktree(searchOnly.id, repoID: repoID)

        state.ensureArchivedSelectionValid(repoID: repoID)
        #expect(state.selectedArchivedWorktreeIDs[repoID] == searchOnly.id,
                "a search-only selection is legitimate and must not be re-pointed")
    }
}

/// Tier 1. Regression coverage for the page-preserving refresh arithmetic
/// shared by `refreshArchivedWorktrees` and `refreshArchivedSearch`.
///
/// The Finding-2 defect was that the search re-run refetched page 0 and
/// replaced the stored results, collapsing Load More–accumulated pages. Both
/// refreshes now derive their fetch size and `hasMore` from this one type; what
/// is covered here is that arithmetic, not the RPC wiring (`AppState.daemonClient`
/// has no injection seam, so the wiring itself is not reachable in a unit test).
@Suite("Archived refresh plan")
struct ArchivedRefreshPlanTests {
    private let pageSize = 50

    @Test("a first-time refresh fetches exactly one page")
    func firstRefreshFetchesOnePage() {
        let plan = ArchivedRefreshPlan(currentCount: 0, pageSize: pageSize)
        #expect(plan.fetchCount == 50)
        #expect(plan.knownExhausted == false)
        #expect(plan.hasMore(fetched: 50))
        #expect(!plan.hasMore(fetched: 12))
    }

    /// The invariant the search re-run was missing: with 150 rows already
    /// pulled in, a refresh must ask for all 150, not the first 50.
    @Test("a refresh preserves already-loaded pages")
    func refreshPreservesLoadedPages() {
        let plan = ArchivedRefreshPlan(currentCount: 150, pageSize: pageSize)
        #expect(plan.fetchCount == 150)
        #expect(plan.knownExhausted == false)
        #expect(plan.hasMore(fetched: 150))
    }

    /// A partial last page proves the server has nothing more, so the larger
    /// refetch returning fewer rows than it asked for must not re-arm
    /// "Load More".
    @Test("a partial page is known-exhausted and never re-arms Load More")
    func partialPageIsKnownExhausted() {
        let plan = ArchivedRefreshPlan(currentCount: 73, pageSize: pageSize)
        #expect(plan.fetchCount == 73)
        #expect(plan.knownExhausted)
        #expect(!plan.hasMore(fetched: 73))
        #expect(!plan.hasMore(fetched: 100))
    }
}

/// Tier 1. Debounce contract for the archived search field: a burst of
/// keystrokes must cost one RPC, not one per character. Entirely virtual time —
/// see `Tests/CLAUDE.md` "Clock and date seams".
///
/// The clock is `EventDrivenTestClock`, whose arming signal is emitted from
/// inside the same critical section that registers the sleeper, so
/// `advanceWhenArmed` is not a megaYield-driven probe that a saturated process
/// can starve — the failure this suite reproduced under full-suite load. Its
/// `advance` does no yielding, so every *positive* assertion awaits
/// `fired.next()`: advancing resumes the sleeper's continuation, it does not
/// run the resumed task's next statement. Design:
/// `docs/specs/2026-08-11-event-driven-test-clock-design.md`.
///
/// `.serialized` is retained as cheap isolation between four tests that each
/// build their own debouncer; it is no longer load-bearing for the handshake.
@MainActor
@Suite("Archived search debounce", .clockDriven, .serialized)
struct SearchQueryDebouncerTests {
    private static let interval = Duration.milliseconds(250)

    /// Hands the main actor back for a few real turns so a fire that *would*
    /// land gets the chance to before a negative assertion reads the recorder.
    /// One-sided by nature: it can only ever false-pass, exactly as the old
    /// synchronous read after a megaYielding `advance` could.
    private static func settle() async {
        for _ in 0..<3 { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("a burst within one window collapses to a single fire with the last value")
    func burstCollapsesToLastValue() async {
        let clock = EventDrivenTestClock()
        let debouncer = SearchQueryDebouncer(interval: Self.interval, clock: clock)
        let fired = FireRecorder<String>()

        debouncer.schedule("w") { [fired] in fired.record($0) }
        debouncer.schedule("wo") { [fired] in fired.record($0) }
        debouncer.schedule("wolv") { [fired] in fired.record($0) }

        await clock.advanceWhenArmed(by: Self.interval)
        #expect(await fired.next() == "wolv")
        #expect(fired.values == ["wolv"])
    }

    @Test("nothing fires until the full interval has elapsed")
    func firesOnTheBoundary() async {
        let clock = EventDrivenTestClock()
        let debouncer = SearchQueryDebouncer(interval: Self.interval, clock: clock)
        let fired = FireRecorder<String>()

        debouncer.schedule("wolv") { [fired] in fired.record($0) }

        await clock.advanceWhenArmed(by: Self.interval - .milliseconds(1))
        await Self.settle()
        #expect(fired.values.isEmpty, "one millisecond short of the window must not fire")

        await clock.advance(by: .milliseconds(1))
        #expect(await fired.next() == "wolv")
    }

    @Test("cancel() drops a pending fire")
    func cancelDropsPendingFire() async {
        let clock = EventDrivenTestClock()
        let debouncer = SearchQueryDebouncer(interval: Self.interval, clock: clock)
        let fired = FireRecorder<String>()

        debouncer.schedule("wolv") { [fired] in fired.record($0) }
        await clock.advanceWhenArmed(by: .milliseconds(100))

        debouncer.cancel()
        await clock.advance(by: Self.interval)
        await Self.settle()
        #expect(fired.values.isEmpty, "a cancelled query must never reach the daemon")
    }

    @Test("queries separated by a full window fire twice, in order")
    func separatedQueriesFireTwice() async {
        let clock = EventDrivenTestClock()
        let debouncer = SearchQueryDebouncer(interval: Self.interval, clock: clock)
        let fired = FireRecorder<String>()

        debouncer.schedule("wolv") { [fired] in fired.record($0) }
        await clock.advanceWhenArmed(by: Self.interval)
        #expect(await fired.next() == "wolv")

        debouncer.schedule("otter") { [fired] in fired.record($0) }
        await clock.advanceWhenArmed(by: Self.interval)
        #expect(await fired.next() == "otter")
        #expect(fired.values == ["wolv", "otter"])
    }
}
