import Combine
import Foundation
import Testing
@testable import TBDApp
import TBDShared

// Tier 1, except the "Hydration gap" section, which is tier 2: those tests
// observe an unstructured `Task` (`reconcileTabs` schedules `loadTabStates` in
// one), which is real concurrency, not virtual time. They await that `Task`'s
// completion directly (`settleHydration`) — no wall-clock deadline is involved
// anywhere in this file. Everything else is a pure in-process AppState state
// machine.
//
// The one RPC these paths make (`listTabs`) is driven through the
// `tabStatesFetcher` injectable-closure seam other AppState tests already use
// (`daemonCapabilitiesFetcher`, `panelImportTrigger`, ...), so nothing touches
// the network or `~/tbd`.
//
// Regression coverage for "a new worktree opens on its Notes tab": the daemon
// appends the note LAST in tab order, so every `?? 0` / `min(idx, count - 1)`
// fallback in the app resolved a missing or stale selection to Notes.

@MainActor
@Suite("Active tab resolution")
struct ActiveTabResolutionTests {

    // MARK: - Fixtures

    /// Runs `body` against a fresh `AppState` backed by a throwaway defaults
    /// suite (never the developer's real `TBDApp.plist`), torn down afterwards.
    private func withState(_ body: (AppState) -> Void) {
        let suiteName = "ActiveTabResolutionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(makeState(defaults))
    }

    private func withState(_ body: (AppState) async -> Void) async {
        let suiteName = "ActiveTabResolutionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await body(makeState(defaults))
    }

    private func makeState(_ defaults: UserDefaults) -> AppState {
        let state = AppState(userDefaults: defaults)
        // Nothing here should reach a daemon unless the test opts in.
        state.tabStatesFetcher = { _ in
            Issue.record("unexpected listTabs fetch")
            return TabListResponse(tabs: [], order: [], activeTabID: nil)
        }
        return state
    }

    private func terminal(_ id: UUID, worktreeID: UUID, label: String) -> Terminal {
        Terminal(
            id: id,
            worktreeID: worktreeID,
            tmuxWindowID: "@\(label)",
            tmuxPaneID: "%\(label)",
            label: label,
            kind: .shell
        )
    }

    private func terminalTab(_ id: UUID, label: String? = nil) -> TBDShared.Tab {
        TBDShared.Tab(id: id, content: .terminal(terminalID: id), label: label)
    }

    private func noteTab(_ id: UUID) -> TBDShared.Tab {
        TBDShared.Tab(id: id, content: .note(noteID: id), label: nil)
    }

    // MARK: - Resolver defaults

    @Test("nothing selected resolves to the agent tab, never the trailing note")
    func unselectedWorktreeResolvesToAgentNotNote() {
        withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let note = UUID()
            state.tabs[worktreeID] = [terminalTab(claude, label: "Claude"), noteTab(note)]

            #expect(state.activeTabIndices[worktreeID] == nil)
            #expect(state.resolvedActiveTabIndex(worktreeID: worktreeID) == 0)
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == claude)
        }
    }

    @Test("a note-only worktree still shows its note at index 0")
    func noteOnlyWorktreeResolvesToTheNote() {
        withState { state in
            let worktreeID = UUID()
            let note = UUID()
            state.tabs[worktreeID] = [noteTab(note)]

            #expect(state.resolvedActiveTabIndex(worktreeID: worktreeID) == 0)
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == note)
        }
    }

    @Test("no tabs resolves to 0 and yields no tab")
    func emptyWorktreeResolvesToZero() {
        withState { state in
            let worktreeID = UUID()

            #expect(state.resolvedActiveTabIndex(worktreeID: worktreeID) == 0)
            #expect(state.resolvedActiveTab(worktreeID: worktreeID) == nil)
        }
    }

    @Test("an in-range selection is returned verbatim, note tab or not")
    func inRangeSelectionIsNeverOverridden() {
        withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let note = UUID()
            state.tabs[worktreeID] = [terminalTab(claude), noteTab(note)]
            state.activeTabIndices[worktreeID] = 1

            #expect(state.resolvedActiveTabIndex(worktreeID: worktreeID) == 1)
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == note)
        }
    }

    // MARK: - Stale index

    @Test("a stale out-of-range index falls forward to the first non-note tab")
    func staleIndexResolvesToFirstNonNoteTab() {
        withState { state in
            let worktreeID = UUID()
            let leadingNote = UUID()
            let claude = UUID()
            let trailingNote = UUID()
            // A leading note proves the fallback is "first NON-NOTE", not "first".
            state.tabs[worktreeID] = [noteTab(leadingNote), terminalTab(claude), noteTab(trailingNote)]
            state.activeTabIndices[worktreeID] = 7  // stale — the array used to be longer

            #expect(state.resolvedActiveTabIndex(worktreeID: worktreeID) == 1)
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == claude)
        }
    }

    /// The nastier half of a stale index: a mutation that GROWS the array puts
    /// it back in range, so anything that re-derives the selection after the
    /// mutation pins an arbitrary tab — and the resolver then honours that pin
    /// as deliberate, which is the exact bug class this change removes.
    @Test("a stale index that lands back in range is not pinned by reconcileTabs")
    func staleIndexIsNotPinnedByReconcileTabs() {
        withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let note = UUID()
            let arrivals = (0..<6).map { _ in UUID() }
            state.tabs[worktreeID] = [terminalTab(claude, label: "Claude"), noteTab(note)]
            state.tabStateHydratedWorktreeIDs.insert(worktreeID)
            // Out of range now (2 tabs), back in range once the array grows to 8.
            state.activeTabIndices[worktreeID] = 5

            state.reconcileTabs(
                worktreeID: worktreeID,
                terminals: ([claude] + arrivals).map {
                    terminal($0, worktreeID: worktreeID, label: "t")
                }
            )

            #expect(state.activeTabIndices[worktreeID] == nil,
                    "a stale index must be cleared, never re-bound to whatever slid into it")
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == claude)
        }
    }

    @Test("a stale index that lands back in range is not pinned by reconcileNoteTabs")
    func staleIndexIsNotPinnedByReconcileNoteTabs() {
        withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let noteIDs = (0..<4).map { _ in UUID() }
            state.tabs[worktreeID] = [terminalTab(claude, label: "Claude")]
            // Out of range now (1 tab), back in range once the notes arrive.
            state.activeTabIndices[worktreeID] = 3

            state.reconcileNoteTabs(
                worktreeID: worktreeID,
                notes: noteIDs.map { Note(id: $0, worktreeID: worktreeID, title: "n") }
            )

            #expect(state.activeTabIndices[worktreeID] == nil,
                    "a stale index must be cleared, never re-bound to an arriving note")
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == claude)
        }
    }

    // MARK: - Close

    /// `[claude, shell, note]` with `claude` deliberately selected — the shape
    /// from the bug report. Closing the background `shell` used to slide the
    /// selection one tab right, onto Notes.
    private func withCloseFixture(
        activeIndex: Int,
        close closeIndex: Int,
        _ assertions: (AppState, _ worktreeID: UUID, _ ids: (claude: UUID, shell: UUID, note: UUID)) -> Void
    ) {
        withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let shell = UUID()
            let note = UUID()
            state.tabs[worktreeID] = [
                terminalTab(claude, label: "Claude"),
                terminalTab(shell, label: "shell"),
                noteTab(note),
            ]
            state.activeTabIndices[worktreeID] = activeIndex

            state.closeTab(worktreeID: worktreeID, index: closeIndex)

            assertions(state, worktreeID, (claude, shell, note))
        }
    }

    @Test("closing a background tab after the active one leaves the selection put")
    func closingTrailingBackgroundTabKeepsSelection() {
        withCloseFixture(activeIndex: 0, close: 1) { state, worktreeID, ids in
            #expect(state.tabs[worktreeID]?.map(\.id) == [ids.claude, ids.note])
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == ids.claude,
                    "closing a background tab must never move the user off the tab they were on")
        }
    }

    /// Deliberately on the note, closing the leading tab: the clamp would have
    /// answered `min(0, 1) == 0` and dropped the user on `shell`.
    @Test("closing a background tab before the active one follows it by identity")
    func closingLeadingBackgroundTabFollowsSelectionByIdentity() {
        withCloseFixture(activeIndex: 2, close: 0) { state, worktreeID, ids in
            #expect(state.tabs[worktreeID]?.map(\.id) == [ids.shell, ids.note])
            #expect(state.activeTabIndices[worktreeID] == 1, "the index must shift with the tab")
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == ids.note)
        }
    }

    @Test("closing the active tab moves the selection to the tab that takes its slot")
    func closingActiveTabMovesToNeighbour() {
        withCloseFixture(activeIndex: 1, close: 1) { state, worktreeID, ids in
            #expect(state.tabs[worktreeID]?.map(\.id) == [ids.claude, ids.note])
            #expect(state.activeTabIndices[worktreeID] == 1)
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == ids.note)
        }
    }

    @Test("closing the trailing active tab clamps onto the new last tab")
    func closingTrailingActiveTabClampsToLast() {
        withCloseFixture(activeIndex: 2, close: 2) { state, worktreeID, ids in
            #expect(state.tabs[worktreeID]?.map(\.id) == [ids.claude, ids.shell])
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == ids.shell)
        }
    }

    /// Closing a worktree's ONLY tab: there is nothing left for the selection
    /// to point at, so the entry must be removed rather than pinned to 0. A
    /// leftover 0 is back in range the instant one tab reappears, and
    /// `resolvedActiveTabIndex` honours an in-range index as deliberate — which
    /// is how a re-created worktree ends up on whatever tab arrives first.
    @Test("closing a worktree's only tab clears its selection entry")
    func closingTheLastTabClearsTheSelectionEntry() {
        withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            state.tabs[worktreeID] = [terminalTab(claude, label: "Claude")]
            state.activeTabIndices[worktreeID] = 0

            state.closeTab(worktreeID: worktreeID, index: 0)

            #expect(state.tabs[worktreeID]?.isEmpty == true)
            #expect(state.activeTabIndices[worktreeID] == nil,
                    "an emptied worktree must hold no selection, not a stale 0")
            #expect(state.resolvedActiveTab(worktreeID: worktreeID) == nil)
        }
    }

    /// Cmd-W goes through `focusedTabCloseContext`, and nothing resyncs that
    /// context when the user switches tabs *within* a worktree — so it can name
    /// a tab that is no longer the active one. That close is a BACKGROUND
    /// close: the user must stay on the tab they were actually looking at. The
    /// old unconditional clamp answered `min(0, 1) == 0` here and dropped them
    /// on `shell`.
    @Test("closing via a stale focus context leaves the selection where the user was")
    func closeFocusedTabWithStaleContextKeepsTheUsersTab() {
        withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let shell = UUID()
            let note = UUID()
            state.tabs[worktreeID] = [
                terminalTab(claude, label: "Claude"),
                terminalTab(shell, label: "shell"),
                noteTab(note),
            ]
            // The user moved to Notes; the focus context still names claude.
            state.activeTabIndices[worktreeID] = 2
            state.focusedTabCloseContext = .init(worktreeID: worktreeID, tabID: claude)

            state.closeFocusedTab()

            #expect(state.tabs[worktreeID]?.map(\.id) == [shell, note])
            #expect(state.activeTabIndices[worktreeID] == 1, "the index must shift with the tab")
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == note,
                    "a stale focus context must not slide the user off their tab")
            #expect(state.focusedTabCloseContext == nil,
                    "the consumed context must be cleared with the tab it named")
        }
    }

    // MARK: - Auto-close of the `setup` tab

    /// `[claude, setup, note] -> [claude, note]`, the shape produced on every
    /// worktree create while `auto_close_setup_enabled` is on.
    private func runSetupAutoClose(
        startingOn startIndex: Int?,
        _ assertions: (AppState, _ worktreeID: UUID, _ claude: UUID, _ note: UUID) -> Void
    ) {
        withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let setup = UUID()
            let note = UUID()
            state.tabs[worktreeID] = [
                terminalTab(claude, label: "Claude"),
                terminalTab(setup, label: "setup"),
                noteTab(note),
            ]
            state.worktreeTabOrders[worktreeID] = [claude, setup, note]
            // Already hydrated, so reconcileTabs schedules no tab-state re-fetch.
            state.tabStateHydratedWorktreeIDs.insert(worktreeID)
            if let startIndex { state.activeTabIndices[worktreeID] = startIndex }

            state.reconcileTabs(
                worktreeID: worktreeID,
                terminals: [terminal(claude, worktreeID: worktreeID, label: "Claude")]
            )

            #expect(state.tabs[worktreeID]?.map(\.id) == [claude, note])
            assertions(state, worktreeID, claude, note)
        }
    }

    @Test("removing the setup tab while on claude keeps the selection on claude")
    func setupAutoCloseKeepsSelectionOnClaude() {
        runSetupAutoClose(startingOn: 0) { state, worktreeID, claude, _ in
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == claude)
        }
    }

    @Test("removing the setup tab while on setup falls back to claude, not the note")
    func setupAutoCloseFromSetupFallsBackToClaude() {
        runSetupAutoClose(startingOn: 1) { state, worktreeID, claude, _ in
            #expect(state.activeTabIndices[worktreeID] == nil,
                    "the removed tab's index must be cleared, not left stale")
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == claude)
        }
    }

    @Test("removing the setup tab with nothing selected still resolves to claude")
    func setupAutoCloseWithNoSelectionResolvesToClaude() {
        runSetupAutoClose(startingOn: nil) { state, worktreeID, claude, _ in
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == claude)
        }
    }

    // MARK: - Deliberate note selections survive reconciles

    @Test("an explicit note selection survives a reconcile that adds and removes tabs")
    func explicitNoteSelectionSurvivesReconcileTabs() {
        withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let setup = UUID()
            let note = UUID()
            let newShell = UUID()
            state.tabs[worktreeID] = [terminalTab(claude), terminalTab(setup), noteTab(note)]
            state.worktreeTabOrders[worktreeID] = [claude, setup, note]
            state.tabStateHydratedWorktreeIDs.insert(worktreeID)
            state.activeTabIndices[worktreeID] = 2  // the user deliberately opened Notes

            // setup disappears and a brand new shell appears in the same poll.
            state.reconcileTabs(worktreeID: worktreeID, terminals: [
                terminal(claude, worktreeID: worktreeID, label: "Claude"),
                terminal(newShell, worktreeID: worktreeID, label: "shell"),
            ])

            #expect(state.tabs[worktreeID]?.map(\.id) == [claude, note, newShell])
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == note,
                    "a deliberate note selection must never be overridden")
        }
    }

    @Test("appending a note tab never steals the selection")
    func reconcileNoteTabsDoesNotStealSelection() {
        withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let setup = UUID()
            let note = UUID()
            state.tabs[worktreeID] = [terminalTab(claude), terminalTab(setup)]
            state.activeTabIndices[worktreeID] = 1  // on setup

            state.reconcileNoteTabs(
                worktreeID: worktreeID,
                notes: [Note(id: note, worktreeID: worktreeID, title: "Notes")]
            )

            #expect(state.tabs[worktreeID]?.map(\.id) == [claude, setup, note])
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == setup)
        }
    }

    @Test("an explicit note selection survives a note reconcile that drops another note")
    func explicitNoteSelectionSurvivesNoteReconcile() {
        withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let deletedNote = UUID()
            let keptNote = UUID()
            state.tabs[worktreeID] = [terminalTab(claude), noteTab(deletedNote), noteTab(keptNote)]
            state.activeTabIndices[worktreeID] = 2  // on the kept note

            state.reconcileNoteTabs(
                worktreeID: worktreeID,
                notes: [Note(id: keptNote, worktreeID: worktreeID, title: "Kept")]
            )

            #expect(state.tabs[worktreeID]?.map(\.id) == [claude, keptNote])
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == keptNote)
        }
    }

    // MARK: - Hydration gap

    @Test("an empty listTabs response is not hydration; a later one lands on claude")
    func emptyTabStateResponseIsRetriedUntilTheDaemonHasWritten() async {
        await withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let setup = UUID()
            let note = UUID()
            // In-memory append order from the terminal list — NOT the daemon's order.
            state.tabs[worktreeID] = [
                terminalTab(setup, label: "setup"),
                terminalTab(claude, label: "Claude"),
                noteTab(note),
            ]

            var responses = [
                // Poll landed after the terminal rows existed but before the
                // daemon persisted tab order / active tab.
                TabListResponse(tabs: [], order: [], activeTabID: nil),
                TabListResponse(tabs: [], order: [claude, setup, note], activeTabID: claude),
            ]
            var fetchCount = 0
            state.tabStatesFetcher = { _ in
                fetchCount += 1
                guard !responses.isEmpty else {
                    return TabListResponse(tabs: [], order: [], activeTabID: nil)
                }
                return responses.removeFirst()
            }

            await state.loadTabStates(worktreeID: worktreeID)
            #expect(fetchCount == 1)
            #expect(state.tabStateHydratedWorktreeIDs.contains(worktreeID) == false,
                    "an empty response must not latch the worktree as loaded")

            await state.loadTabStates(worktreeID: worktreeID)
            #expect(fetchCount == 2)
            #expect(state.tabStateHydratedWorktreeIDs.contains(worktreeID))
            #expect(state.tabs[worktreeID]?.map(\.id) == [claude, setup, note])
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == claude,
                    "the daemon's persisted active tab must win once it exists")
        }
    }

    /// Tier 2 — awaits the unstructured `Task` `reconcileTabs` schedules. Uses
    /// the whole attempt budget: one empty response, then a hydrating one on
    /// the last attempt the cap allows.
    @Test("reconcileTabs re-fetches tab state until hydrated, then stops")
    func reconcileTabsRetriesTabStateFetchUntilHydrated() async {
        await withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            var fetchCount = 0
            var hydrated = false
            state.tabStatesFetcher = { _ in
                fetchCount += 1
                return hydrated
                    ? TabListResponse(tabs: [], order: [claude], activeTabID: claude)
                    : TabListResponse(tabs: [], order: [], activeTabID: nil)
            }
            let claudeTerminal = terminal(claude, worktreeID: worktreeID, label: "Claude")
            // Awaiting the fetch to land (not merely to start) keeps the
            // in-flight dedup from swallowing the next reconcile's attempt.
            @MainActor func reconcileAndSettle() async {
                state.reconcileTabs(worktreeID: worktreeID, terminals: [claudeTerminal])
                await settleHydration(state, worktreeID: worktreeID)
            }

            await reconcileAndSettle()
            #expect(fetchCount == 1)

            // Still unhydrated: a later reconcile must try again.
            await reconcileAndSettle()
            #expect(fetchCount == 2, "an empty response must not latch the worktree as hydrated")

            // The daemon has written now — one more reconcile hydrates...
            hydrated = true
            await reconcileAndSettle()
            #expect(state.tabStateHydratedWorktreeIDs.contains(worktreeID))
            let settled = fetchCount

            // ...and every reconcile after that is silent: no poll storm. Each
            // round drains whatever it armed, so a re-fetch would land inside
            // the loop and show up in the count below rather than racing it.
            await reconcileAndSettle()
            await reconcileAndSettle()
            #expect(fetchCount == settled, "a hydrated worktree must not re-fetch tab state")
        }
    }

    /// A retry that changes nothing must also *publish* nothing: every write to
    /// an `@Published` dictionary fires a full `AppState.objectWillChange`, and
    /// this path is on a repeat timer by construction.
    @Test("a repeat fetch that changes nothing publishes nothing")
    func idempotentTabStateFetchDoesNotRepublish() async {
        await withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let note = UUID()
            state.tabs[worktreeID] = [terminalTab(claude, label: "Claude"), noteTab(note)]
            state.tabStatesFetcher = { _ in
                TabListResponse(tabs: [], order: [claude, note], activeTabID: claude)
            }

            await state.loadTabStates(worktreeID: worktreeID)

            var publishes = 0
            let token = state.objectWillChange.sink { _ in publishes += 1 }
            defer { token.cancel() }

            await state.loadTabStates(worktreeID: worktreeID)

            #expect(publishes == 0,
                    "an identical response must not fan out an objectWillChange")
        }
    }

    /// Tier 2 — the retry is scheduled in an unstructured `Task`, awaited
    /// through its handle. End-to-end version of the gap: the app has the tabs but
    /// the daemon has not written yet, and the retry is what lands the
    /// selection on the agent.
    @Test("the hydration gap closes: a retry lands the selection on the agent tab")
    func reconcileTabsRetryLandsSelectionOnTheAgentTab() async {
        await withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            let setup = UUID()
            let note = UUID()
            state.tabs[worktreeID] = [noteTab(note)]
            var hydrated = false
            var fetchCount = 0
            state.tabStatesFetcher = { _ in
                fetchCount += 1
                return hydrated
                    ? TabListResponse(tabs: [], order: [claude, setup, note], activeTabID: claude)
                    : TabListResponse(tabs: [], order: [], activeTabID: nil)
            }
            // In-memory append order from the terminal list — NOT the daemon's.
            let terminals = [
                terminal(setup, worktreeID: worktreeID, label: "setup"),
                terminal(claude, worktreeID: worktreeID, label: "Claude"),
            ]

            state.reconcileTabs(worktreeID: worktreeID, terminals: terminals)
            await settleHydration(state, worktreeID: worktreeID)
            #expect(fetchCount == 1, "the mid-create reconcile must have fetched once")
            #expect(state.tabStateHydratedWorktreeIDs.contains(worktreeID) == false,
                    "an empty response must not latch the worktree as hydrated")

            // The daemon has written now; the next reconcile must try again.
            hydrated = true
            state.reconcileTabs(worktreeID: worktreeID, terminals: terminals)
            await settleHydration(state, worktreeID: worktreeID)
            #expect(state.tabStateHydratedWorktreeIDs.contains(worktreeID),
                    "the retry must latch once the daemon's answer carries content")

            #expect(state.tabs[worktreeID]?.map(\.id) == [claude, setup, note])
            #expect(state.resolvedActiveTab(worktreeID: worktreeID)?.id == claude,
                    "the daemon's persisted active tab must win once it exists")
        }
    }

    /// Tier 2 — same shape. 4 of 101 live non-archived worktrees have neither a
    /// stored tab order nor an active tab, and `main` rows stay that way for
    /// good. Their `listTabs` answer is indistinguishable from the mid-create
    /// one, so the retry has to give up on its own.
    @Test("a permanently-empty worktree stops re-fetching once the attempt cap is spent")
    func permanentlyEmptyWorktreeStopsRefetching() async {
        await withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            var fetchCount = 0
            state.tabStatesFetcher = { _ in
                fetchCount += 1
                return TabListResponse(tabs: [], order: [], activeTabID: nil)
            }
            let claudeTerminal = terminal(claude, worktreeID: worktreeID, label: "Claude")

            // Each reconcile is allowed to finish its fetch before the next one,
            // so this measures the attempt cap and not the in-flight dedup.
            for _ in 0..<AppState.maxTabStateHydrationAttempts {
                state.reconcileTabs(worktreeID: worktreeID, terminals: [claudeTerminal])
                await settleHydration(state, worktreeID: worktreeID)
            }
            #expect(fetchCount == AppState.maxTabStateHydrationAttempts)
            #expect(state.tabStateHydratedWorktreeIDs.contains(worktreeID) == false)

            // `reconcileTabs` runs on every terminal-list change, and a working
            // agent flips `activityState` constantly — the count must stop here.
            let settled = fetchCount
            for _ in 0..<5 {
                state.reconcileTabs(worktreeID: worktreeID, terminals: [claudeTerminal])
                await settleHydration(state, worktreeID: worktreeID)
            }
            #expect(fetchCount == settled,
                    "an empty-forever worktree must stop polling, not re-fire on every reconcile")
        }
    }

    /// Tier 2 — the failing half of the cap. `handleConnectionError` only
    /// clears `isConnected` for `.daemonNotRunning` / `.connectionFailed`; a
    /// decode failure, an RPC rejection or a timeout leaves the app connected
    /// and the ~2s poll running, so `refreshWorktrees` -> `reconcileTabs` keeps
    /// re-driving this path. A blanket attempt refund therefore meant a
    /// throwing fetch never consumed budget and re-fired `listTabs` every poll,
    /// per affected worktree, forever — a daemon RPC storm this repo has
    /// already shipped once.
    @Test("a persistently failing listTabs stops re-firing once the attempt cap is spent")
    func persistentFetchErrorStopsRefetching() async {
        await withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            state.isConnected = true
            var fetchCount = 0
            state.tabStatesFetcher = { _ in
                fetchCount += 1
                throw DaemonClientError.invalidResponse
            }
            let claudeTerminal = terminal(claude, worktreeID: worktreeID, label: "Claude")
            @MainActor func reconcileAndSettle() async {
                state.reconcileTabs(worktreeID: worktreeID, terminals: [claudeTerminal])
                await settleHydration(state, worktreeID: worktreeID)
            }

            for _ in 0..<AppState.maxTabStateHydrationAttempts { await reconcileAndSettle() }
            #expect(fetchCount == AppState.maxTabStateHydrationAttempts)
            #expect(state.isConnected,
                    "a non-disconnect error must leave the poll running, which is why the budget has to bite")

            let settled = fetchCount
            for _ in 0..<5 { await reconcileAndSettle() }
            #expect(fetchCount == settled,
                    "a worktree whose listTabs always fails must stop re-firing the RPC")
        }
    }

    /// The other side of that asymmetry: a disconnect says nothing about
    /// whether the daemon has written yet, and the poll that would retry is
    /// stopped anyway — so it is refunded, and the worktree is not stranded
    /// unhydrated for the rest of the session once the daemon comes back.
    @Test("a disconnect refunds its attempt and keeps the worktree eligible")
    func disconnectErrorRefundsTheHydrationAttempt() async {
        await withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            state.isConnected = true
            var fetchCount = 0
            state.tabStatesFetcher = { _ in
                fetchCount += 1
                throw DaemonClientError.connectionFailed("socket went away")
            }
            let claudeTerminal = terminal(claude, worktreeID: worktreeID, label: "Claude")
            @MainActor func reconcileAndSettle() async {
                state.reconcileTabs(worktreeID: worktreeID, terminals: [claudeTerminal])
                await settleHydration(state, worktreeID: worktreeID)
            }

            // Deliberately more rounds than the cap: none of them may be spent.
            let rounds = AppState.maxTabStateHydrationAttempts + 3
            for _ in 0..<rounds { await reconcileAndSettle() }

            #expect(fetchCount == rounds,
                    "a transient disconnect must not burn the hydration budget")
            #expect(state.tabStateFetchAttempts[worktreeID] == 0)
            #expect(state.isConnected == false)
        }
    }

    /// Tier 2 — the old gate used a bare `Task {}` with no dedup, so reconciles
    /// arriving back-to-back (a terminal-list change per activity flip) each
    /// stacked their own in-flight `listTabs`.
    @Test("overlapping reconciles never stack tab-state fetches for one worktree")
    func overlappingReconcilesDedupeTheTabStateFetch() async {
        await withState { state in
            let worktreeID = UUID()
            let claude = UUID()
            var fetchCount = 0
            state.tabStatesFetcher = { _ in
                fetchCount += 1
                return TabListResponse(tabs: [], order: [], activeTabID: nil)
            }
            let claudeTerminal = terminal(claude, worktreeID: worktreeID, label: "Claude")

            // Three reconciles with no suspension between them: the scheduled
            // Task has not run yet, so only the first may be allowed to arm.
            state.reconcileTabs(worktreeID: worktreeID, terminals: [claudeTerminal])
            state.reconcileTabs(worktreeID: worktreeID, terminals: [claudeTerminal])
            state.reconcileTabs(worktreeID: worktreeID, terminals: [claudeTerminal])
            // `settleHydration` drains until nothing is armed, so a broken
            // dedup shows up as a count of 3 here rather than as a race.
            await settleHydration(state, worktreeID: worktreeID)

            #expect(fetchCount == 1, "overlapping reconciles must share one in-flight fetch")
        }
    }

    /// Await the hydration work `reconcileTabs` schedules, until none is armed.
    ///
    /// `scheduleTabStateHydration` stores its unstructured `Task`, so the test
    /// can await THAT rather than watch wall time for its side effects. This is
    /// a completion signal, not a deadline: no budget to blow, so an
    /// arbitrarily loaded machine makes the test slower and never red.
    ///
    /// The previous shape — polling `tabStateFetchesInFlight` every 5 ms
    /// against a 30 s `ContinuousClock` deadline — measured the whole process's
    /// contention for the (single, shared) main actor rather than this
    /// worktree's fetch, and blew its budget on the full parallel pass while
    /// sibling no-op tests in this same suite were themselves taking 25-45 s to
    /// get a turn. It also added ~6000 main-actor wakeups per waiting test to
    /// the congestion it was losing to.
    ///
    /// The loop drains rather than awaiting once, so a regression that armed
    /// several overlapping fetches is still fully settled before the assertion.
    /// Nothing arms a fetch except `reconcileTabs`, so it terminates.
    private func settleHydration(_ state: AppState, worktreeID: UUID) async {
        while let fetch = state.tabStateFetchTasks[worktreeID] {
            await fetch.value
        }
    }
}
