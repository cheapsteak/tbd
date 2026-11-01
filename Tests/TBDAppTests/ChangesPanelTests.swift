import Foundation
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

// Tier 1: deterministic, in-process state only (see `PanelTabsTestSupport`).
// Every operation goes through the stubbed `panel.apply` seam; no socket
// opens, and every `AppState` and `UserDefaults` is a throwaway suite's.

/// The Changes list as a side-panel tab (side panel notes and Changes spec,
/// "Changes", "⌘⇧E"): what a file click sends, ⌘⇧E's three states and its
/// target, the strip's refresh control, and the retired column's keys.
@Suite("Changes panel")
@MainActor
struct ChangesPanelTests {
    private typealias Fixture = PanelTabsFixture

    // MARK: - Fixtures

    private static func surface(
        tabID: UUID = UUID(), worktreeID: UUID = UUID(),
        worktreePanels: [WorktreePanel], active: PanelID?, collapsed: Bool = false
    ) -> WorkspaceTabSurface {
        WorkspaceTabSurface(
            id: tabID, worktreeID: worktreeID,
            primary: .terminal(terminalID: tabID),
            side: SideRegion(panels: [], activePanelID: active, recency: [], collapsed: collapsed),
            worktreePanels: worktreePanels,
            revision: 1)
    }

    private static func worktree(id: UUID, repoID: UUID) -> Worktree {
        Worktree(
            id: id, repoID: repoID, name: "wt-\(id.uuidString.prefix(8))",
            displayName: "Worktree \(id.uuidString.prefix(8))", branch: "main",
            path: "/tmp/acme/\(id.uuidString.prefix(8))", status: .active, tmuxServer: "acme-server")
    }

    /// One local worktree, selected, holding `tabs`, with `activeIndex` the
    /// selected tab. Its tabs are not marked ready, so no tab sync is
    /// scheduled behind the test's back.
    private static func selectWorktree(
        _ state: AppState, tabs: [TBDShared.Tab], activeIndex: Int = 0
    ) -> UUID {
        let repoID = UUID()
        let worktreeID = UUID()
        state.worktrees[repoID] = [Self.worktree(id: worktreeID, repoID: repoID)]
        state.tabs[worktreeID] = tabs
        state.activeTabIndices[worktreeID] = activeIndex
        state.selectedWorktreeIDs = [worktreeID]
        return worktreeID
    }

    private static func localWorktree() throws -> LocalWorktree {
        try #require(LocalWorktree(Self.worktree(id: UUID(), repoID: UUID())))
    }

    /// A Changes list holding one changed, unstaged file at `path`.
    private static func snapshot(unstaged path: String) -> ChangesSnapshot {
        ChangesSnapshot(
            statuses: [GitFileStatus(path: path, indexStatus: " ", workingStatus: "M")], branch: [])
    }

    private static func unstagedPaths(_ snapshot: ChangesSnapshot?) -> [String] {
        snapshot?.unstaged.map { $0.path } ?? []
    }

    // MARK: - A file click

    @Test("a click on a file opens it, by absolute path, where the reuse rule places it")
    func fileClickOpensFileInSidePanel() {
        let operation = ChangesPanelClick.operation(
            worktreePath: "/tmp/acme/wt", relativePath: "Sources/App/main.swift", shift: false)
        let expected: PanelOperation = .open(
            content: .file(FileReference(path: "/tmp/acme/wt/Sources/App/main.swift")), newPanel: false)
        #expect(operation == expected)
    }

    @Test("a Shift-click on a file opens it in a new panel")
    func shiftClickAddsNewPanel() {
        let operation = ChangesPanelClick.operation(
            worktreePath: "/tmp/acme/wt", relativePath: "README.md", shift: true)
        let expected: PanelOperation = .open(
            content: .file(FileReference(path: "/tmp/acme/wt/README.md")), newPanel: true)
        #expect(operation == expected)
    }

    // MARK: - ⌘⇧E's decision

    @Test("⌘⇧E opens Changes when none shows it, selects it when hidden, and closes it when in front")
    func changesToggleDecisionThreeStates() {
        let note = WorktreePanel(id: UUID(), content: .note(noteID: UUID()))
        let changes = WorktreePanel(id: UUID(), content: .changes)

        // No surface known, or no Changes panel: open one.
        #expect(PaneActions.changesToggleDecision(surface: nil) == .open)
        #expect(PaneActions.changesToggleDecision(
            surface: Self.surface(worktreePanels: [note], active: note.id)) == .open)

        // Open but behind another panel: select it.
        #expect(PaneActions.changesToggleDecision(
            surface: Self.surface(worktreePanels: [note, changes], active: note.id))
            == .select(changes.id))

        // In front of a collapsed region: select it, which expands the region.
        #expect(PaneActions.changesToggleDecision(
            surface: Self.surface(worktreePanels: [changes], active: changes.id, collapsed: true))
            == .select(changes.id))

        // In front and visible: close it.
        #expect(PaneActions.changesToggleDecision(
            surface: Self.surface(worktreePanels: [note, changes], active: changes.id))
            == .close(changes.id))
    }

    @Test("each decision sends its operation, an open showing the content it is handed")
    func toggleDecisionOperations() {
        let panelID = UUID()
        let opensChanges: PanelOperation = .open(content: .changes, newPanel: false)
        let selectsPanel: PanelOperation = .select(panelID: panelID)
        let closesPanel: PanelOperation = .close(panelID: panelID)

        #expect(PanelToggleDecision.open.operation(opening: .changes) == opensChanges)
        #expect(PanelToggleDecision.select(panelID).operation(opening: .changes) == selectsPanel)
        #expect(PanelToggleDecision.close(panelID).operation(opening: .changes) == closesPanel)
    }

    // MARK: - ⌘⇧E's target

    @Test("⌘⇧E with no worktree selected, or several, sends nothing")
    func toggleChangesPanelWithoutTargetDoesNothing() async {
        await Fixture.withState { state in
            let envelopes = Fixture.collectEnvelopes(
                state, replying: Self.surface(worktreePanels: [], active: nil))
            let syncs = Fixture.collectSyncs(state)

            // No selection.
            state.toggleChangesPanel()
            await Fixture.drainMainActor()
            #expect(envelopes.envelopes.isEmpty)

            // Two worktrees selected, each with a surface: no single target.
            let tab = Fixture.terminalTab()
            let worktreeID = Self.selectWorktree(state, tabs: [tab])
            let otherTab = Fixture.terminalTab()
            let otherID = Self.selectWorktree(state, tabs: [otherTab])
            state.panelSurfaces = [
                worktreeID: [tab.id: Self.surface(
                    tabID: tab.id, worktreeID: worktreeID, worktreePanels: [], active: nil)],
                otherID: [otherTab.id: Self.surface(
                    tabID: otherTab.id, worktreeID: otherID, worktreePanels: [], active: nil)],
            ]
            state.selectedWorktreeIDs = [worktreeID, otherID]
            state.toggleChangesPanel()
            await Fixture.drainMainActor()
            #expect(envelopes.envelopes.isEmpty)
            #expect(syncs.sent.isEmpty, "nothing flushes a tab sync for a toggle that sends nothing")
        }
    }

    @Test("⌘⇧E on a daemon-path tab with no surface yet opens Changes, as ◫ does")
    func toggleChangesPanelWithoutSurfaceOpensChanges() async throws {
        try await Fixture.withState { state in
            let tab = Fixture.terminalTab()
            let worktreeID = Self.selectWorktree(state, tabs: [tab])
            let renderPath = state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id)
            try #require(renderPath == .daemon(nil), "precondition: the tab is on the daemon path with no surface")
            let envelopes = Fixture.collectEnvelopes(
                state, replying: Self.surface(
                    tabID: tab.id, worktreeID: worktreeID, worktreePanels: [], active: nil))

            state.toggleChangesPanel()
            await Fixture.drainMainActor()

            let opening = try Fixture.single(envelopes.envelopes)
            let expectedOpen: PanelOperation = .open(content: .changes, newPanel: false)
            #expect(opening.operation == expectedOpen)
            #expect(opening.worktreeID == worktreeID)
            #expect(opening.tabID == tab.id)
            #expect(opening.baseRevision == nil, "the copy held no surface, so no revision")
        }
    }

    @Test("⌘⇧E on a tab that renders legacy sends nothing and beeps")
    func toggleChangesPanelOnLegacyTabBeeps() async throws {
        try await Fixture.withState { state in
            // The fixture's `panel.apply` and `panel.syncTabs` record an issue
            // if either is reached.
            let beeps = PanelEventLog()
            state.refusalBeep = { @MainActor in beeps.record("beep") }
            let tab = Fixture.terminalTab()
            let worktreeID = Self.selectWorktree(state, tabs: [tab])
            state.panelSyncSkippedTabIDs = [tab.id]
            let renderPath = state.workspaceRenderPath(worktreeID: worktreeID, tabID: tab.id)
            try #require(renderPath == .legacy, "precondition: the last sync skipped the tab")

            state.toggleChangesPanel()
            await Fixture.drainMainActor()

            let expectedBeeps: [String] = ["beep"]
            #expect(beeps.events == expectedBeeps)
        }
    }

    @Test("⌘⇧E sends its decision to the selected worktree's active tab")
    func toggleChangesPanelSendsDecisionToActiveTab() async throws {
        try await Fixture.withState { state in
            let first = Fixture.terminalTab()
            let second = Fixture.terminalTab()
            let worktreeID = Self.selectWorktree(state, tabs: [first, second], activeIndex: 1)
            let changes = WorktreePanel(id: UUID(), content: .changes)
            let withoutChanges = Self.surface(
                tabID: second.id, worktreeID: worktreeID, worktreePanels: [], active: nil)
            let changesInFront = Self.surface(
                tabID: second.id, worktreeID: worktreeID, worktreePanels: [changes], active: changes.id)
            let firstSurface = Self.surface(
                tabID: first.id, worktreeID: worktreeID, worktreePanels: [], active: nil)

            // No Changes panel: open one, on the active tab, not the first.
            state.panelSurfaces = [worktreeID: [first.id: firstSurface, second.id: withoutChanges]]
            let opens = Fixture.collectEnvelopes(state, replying: withoutChanges)
            state.toggleChangesPanel()
            await Fixture.drainMainActor()
            let opening = try Fixture.single(opens.envelopes)
            let expectedOpen: PanelOperation = .open(content: .changes, newPanel: false)
            #expect(opening.operation == expectedOpen)
            #expect(opening.worktreeID == worktreeID)
            #expect(opening.tabID == second.id)

            // The Changes panel in front of a visible region: close it.
            state.panelSurfaces = [worktreeID: [first.id: firstSurface, second.id: changesInFront]]
            let closes = Fixture.collectEnvelopes(state, replying: changesInFront)
            state.toggleChangesPanel()
            await Fixture.drainMainActor()
            let closing = try Fixture.single(closes.envelopes)
            let expectedClose: PanelOperation = .close(panelID: changes.id)
            #expect(closing.operation == expectedClose)
            #expect(closing.tabID == second.id)
        }
    }

    // MARK: - The refresh control

    @Test("the Changes list's control is refresh, whatever the other inputs say")
    func changesViewerControlIsRefresh() {
        let refresh: PaneChromeControl? = .refresh
        #expect(PaneChromeControl.viewerControl(
            for: .changes, canRender: false, showingSource: false, copied: false) == refresh)
        #expect(PaneChromeControl.viewerControl(
            for: .changes, canRender: true, showingSource: true, copied: true) == refresh)
    }

    @Test("refresh bumps the refresh count, and no other control does")
    func refreshControlBumpsCount() {
        let state = PaneChromeState(pasteboard: { _ in Issue.record("unexpected pasteboard write") })

        state.perform(.renderToggle(showingSource: false), contentURL: nil)
        state.perform(.copyAddress(copied: false), contentURL: nil)
        state.perform(.transcript(isOn: true), contentURL: nil)
        #expect(state.refreshCount == 0)

        state.perform(.refresh, contentURL: nil)
        state.perform(.refresh, contentURL: nil)
        #expect(state.refreshCount == 2)
        #expect(!state.didCopyAddress)
        #expect(state.showSourceCode, "only the one render toggle flipped it")
    }

    @Test("the refresh control draws an arrow in the button style's own colour")
    func refreshControlAppearance() {
        let refresh = PaneChromeControl.refresh
        #expect(refresh.systemImage == "arrow.clockwise")
        #expect(refresh.help == "Refresh")
        #expect(refresh.tint == nil)
    }

    @Test("the loading flag stays up until the latest load ends, whichever order loads end in")
    func refreshFlagFollowsLatestLoad() {
        let chrome = PaneChromeState(pasteboard: { _ in Issue.record("unexpected pasteboard write") })
        #expect(!chrome.isRefreshing)

        // A refresh supersedes a load that ends after the newer one began.
        let superseded = chrome.beginRefresh()
        #expect(chrome.isRefreshing)
        let latest = chrome.beginRefresh()
        chrome.endRefresh(superseded)
        #expect(chrome.isRefreshing, "the superseded load leaves the flag to the one still running")
        chrome.endRefresh(latest)
        #expect(!chrome.isRefreshing)

        // The latest load ends first; the superseded one ending later changes nothing.
        let older = chrome.beginRefresh()
        let newer = chrome.beginRefresh()
        chrome.endRefresh(newer)
        #expect(!chrome.isRefreshing)
        chrome.endRefresh(older)
        #expect(!chrome.isRefreshing)
    }

    // MARK: - The Changes cache

    @Test("a list made while a load runs starts from the worktree's last loaded list")
    func cachedSnapshotShowsBeforeLoadCompletes() async throws {
        try await Fixture.withState { state in
            let worktree = try Self.localWorktree()
            let gate = PanelCallGate()
            let loads = PanelEventLog()
            let first = Self.snapshot(unstaged: "first.swift")
            let second = Self.snapshot(unstaged: "second.swift")
            state.changesLoader = { @MainActor _, _ in
                loads.record("load")
                guard loads.events.count > 1 else { return first }
                await gate.wait()
                return second
            }
            let cachedBeforeLoad = state.changesSnapshot(worktreeID: worktree.id) != nil
            #expect(!cachedBeforeLoad, "nothing loaded yet")
            _ = await state.loadChangesSnapshot(worktree: worktree)

            // The list comes to the front again: its own load is in flight,
            // and the cache still holds the first load's list for it to show.
            let reload = Task { @MainActor in await state.loadChangesSnapshot(worktree: worktree) }
            await Fixture.drainMainActor()
            try #require(gate.isHolding, "precondition: the second load is in flight")
            let shownWhileLoading = Self.unstagedPaths(state.changesSnapshot(worktreeID: worktree.id))
            let expectedWhileLoading: [String] = ["first.swift"]
            #expect(shownWhileLoading == expectedWhileLoading)

            gate.release()
            _ = await reload.value
            let shownAfter = Self.unstagedPaths(state.changesSnapshot(worktreeID: worktree.id))
            let expectedAfter: [String] = ["second.swift"]
            #expect(shownAfter == expectedAfter, "the finished load replaces the cached list")
        }
    }

    @Test("a load cancelled before it returns stores nothing, so a newer load's list stays")
    func cancelledLoadKeepsNewerSnapshot() async throws {
        try await Fixture.withState { state in
            let worktree = try Self.localWorktree()
            let gate = PanelCallGate()
            let loads = PanelEventLog()
            let older = Self.snapshot(unstaged: "older.swift")
            let newer = Self.snapshot(unstaged: "newer.swift")
            state.changesLoader = { @MainActor _, _ in
                loads.record("load")
                guard loads.events.count == 1 else { return newer }
                await gate.wait()
                return older
            }
            let superseded = Task { @MainActor in await state.loadChangesSnapshot(worktree: worktree) }
            await Fixture.drainMainActor()
            try #require(gate.isHolding, "precondition: the first load is in flight")

            // A refresh cancels the first load and runs a newer one, which
            // lands before the first one's git reads return.
            superseded.cancel()
            let newest = await state.loadChangesSnapshot(worktree: worktree)
            gate.release()
            let supersededResult = await superseded.value

            let supersededReturnedList = supersededResult != nil
            #expect(!supersededReturnedList, "the cancelled load hands the list nothing to show")
            let expected: [String] = ["newer.swift"]
            let returned = Self.unstagedPaths(newest)
            let stored = Self.unstagedPaths(state.changesSnapshot(worktreeID: worktree.id))
            #expect(returned == expected)
            #expect(stored == expected)
        }
    }

    @Test("archiving a worktree drops its cached Changes list")
    func archiveForgetsChangesSnapshot() async throws {
        try await Fixture.withState { state in
            let repoID = UUID()
            let row = Self.worktree(id: UUID(), repoID: repoID)
            state.worktrees[repoID] = [row]
            let worktree = try #require(LocalWorktree(row))
            let loaded = Self.snapshot(unstaged: "a.swift")
            state.changesLoader = { @MainActor _, _ in loaded }
            _ = await state.loadChangesSnapshot(worktree: worktree)
            let cachedBeforeArchive = state.changesSnapshot(worktreeID: worktree.id) != nil
            try #require(cachedBeforeArchive, "precondition: a list is cached")

            state.removeArchivedWorktreeFromState(id: worktree.id)

            let cachedAfterArchive = state.changesSnapshot(worktreeID: worktree.id) != nil
            #expect(!cachedAfterArchive)
        }
    }

    // MARK: - The retired column's keys

    @Test("the retired column's keys are removed, and nothing else")
    func retiredFilePanelKeysAreRemoved() {
        withTestDefaults("ChangesPanelTests.retiredKeys") { defaults in
            defaults.set(false, forKey: "filePanel.isVisible")
            defaults.set(320.0, forKey: "filePanel.width")
            defaults.set("kept", forKey: "acme.unrelated")

            RetiredFilePanelDefaults.remove(from: defaults)

            #expect(defaults.object(forKey: "filePanel.isVisible") == nil)
            #expect(defaults.object(forKey: "filePanel.width") == nil)
            #expect(defaults.string(forKey: "acme.unrelated") == "kept")
        }
    }

    @Test("launching removes the retired column's keys")
    func launchRemovesRetiredFilePanelKeys() {
        let suite = TestDefaultsSuite("ChangesPanelTests.launch")
        defer { suite.tearDown() }
        suite.defaults.set(true, forKey: "filePanel.isVisible")
        suite.defaults.set(280.0, forKey: "filePanel.width")

        _ = AppState(userDefaults: suite.defaults)

        for key in RetiredFilePanelDefaults.keys {
            #expect(suite.defaults.object(forKey: key) == nil, "\(key)")
        }
    }
}
