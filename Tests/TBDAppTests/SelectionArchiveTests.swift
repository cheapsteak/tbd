import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: in-process state only. The bulk run's archive call is a fake, so no
// test reaches a daemon, and none shows a modal.

// MARK: - Fixtures

/// A worktree row. `remote` makes it a lane on the `acme` provider.
private func row(_ name: String, repoID: UUID?, id: UUID = UUID(), parent: UUID? = nil,
                 order: Int = 0, status: WorktreeStatus = .active, remote: String? = nil) -> Worktree {
    let location = remote.map { WorktreeLocation.remote(provider: "acme", sessionID: $0) } ?? .local
    return Worktree(id: id, repoID: repoID, name: name, displayName: name, branch: "feature",
                    path: location.storagePath ?? "/tmp/acme-\(name)", status: status, tmuxServer: "acme",
                    sortOrder: order, parentWorktreeID: parent, location: location)
}

/// The `acme` provider, answering `describe` with no capabilities.
private func acmeProvider() -> RemoteProviderStatus {
    RemoteProviderStatus(config: .init(name: "acme", exec: "/bin/false"), describe: nil,
                         health: .ok, errorMessage: nil, remediationLabel: nil,
                         remediationCommand: nil, lastSuccessfulSnapshotAt: Date())
}

/// The targets an Archive Selection item carries, or nil for any other item.
private func archiveSelectionTargets(_ item: RowActionMenu.Item) -> [UUID]? {
    guard case let .action(action) = item, case let .archiveSelection(targetIDs) = action.kind else { return nil }
    return targetIDs
}

/// The one Archive Selection item a menu in selection mode is.
private func archiveSelectionMenu(_ targetIDs: [UUID]) -> [RowActionMenu.Item] {
    let enabled = !targetIDs.isEmpty
    return [.action(.init(
        kind: .archiveSelection(targetIDs: targetIDs),
        title: RowActionMenu.archiveSelectionLabel,
        role: .destructive,
        isEnabled: enabled,
        disabledHelp: enabled ? nil : RowActionMenu.archiveSelectionNothingArchivableHelp
    ))]
}

// MARK: - Pure decisions

@Suite("SelectionArchive — decisions")
struct SelectionArchiveDecisionTests {
    // MARK: Selection mode

    @Test func aRowInATwoRowSelectionActsOnTheSelection() {
        let a = UUID(), b = UUID()
        let selected: Set<UUID> = [a, b]
        let acts = SelectionArchive.actsOnSelection(rowID: a, selectedIDs: selected)
        #expect(acts)
    }

    @Test func aRowOutsideTheSelectionActsOnItself() {
        let a = UUID(), b = UUID(), outside = UUID()
        let selected: Set<UUID> = [a, b]
        let acts = SelectionArchive.actsOnSelection(rowID: outside, selectedIDs: selected)
        #expect(!acts)
    }

    @Test func theOnlySelectedRowActsOnItself() {
        let a = UUID()
        let selected: Set<UUID> = [a]
        let acts = SelectionArchive.actsOnSelection(rowID: a, selectedIDs: selected)
        #expect(!acts)
    }

    // MARK: Eligibility

    @Test func anActiveLocalRowIsArchivable() {
        let id = UUID()
        let selected: Set<UUID> = [id]
        let archivable = SelectionArchive.isArchivable(SelectionArchive.Candidate(id: id), selectedIDs: selected)
        #expect(archivable)
    }

    /// Only these three are excluded; a failed row's own Archive is enabled,
    /// so it can go with the selection too.
    @Test func mainCreatingAndArchivedRowsAreNotArchivable() {
        for status: WorktreeStatus in [.main, .creating, .archived] {
            let id = UUID()
            let selected: Set<UUID> = [id]
            let candidate = SelectionArchive.Candidate(id: id, status: status)
            let archivable = SelectionArchive.isArchivable(candidate, selectedIDs: selected)
            #expect(!archivable)
        }
        let failed = UUID()
        let selected: Set<UUID> = [failed]
        let candidate = SelectionArchive.Candidate(id: failed, status: .failed)
        let archivable = SelectionArchive.isArchivable(candidate, selectedIDs: selected)
        #expect(archivable)
    }

    @Test func aRemoteLaneWhoseProviderCannotArchiveIsNotArchivable() {
        let id = UUID()
        let selected: Set<UUID> = [id]
        let lane = SelectionArchive.Candidate(
            id: id, location: .remote(provider: "acme", sessionID: "s1"), providerCapabilities: ["stop"])
        let archivable = SelectionArchive.isArchivable(lane, selectedIDs: selected)
        #expect(!archivable)
    }

    @Test func aRemoteLaneWhoseProviderCanArchiveIsArchivable() {
        let id = UUID()
        let selected: Set<UUID> = [id]
        let lane = SelectionArchive.Candidate(
            id: id, location: .remote(provider: "acme", sessionID: "s1"), providerCapabilities: ["archive"])
        let archivable = SelectionArchive.isArchivable(lane, selectedIDs: selected)
        #expect(archivable)
    }

    /// The same exemptions the row's own Archive makes: the daemon files a
    /// gone lane, and one whose provider is retired, row-only.
    @Test func goneAndRetiredLanesAreExemptFromTheCapabilityGate() {
        let gone = UUID(), retired = UUID()
        let selected: Set<UUID> = [gone, retired]
        let goneLane = SelectionArchive.Candidate(
            id: gone, location: .remote(provider: "acme", sessionID: "s1"), isGone: true)
        let retiredLane = SelectionArchive.Candidate(
            id: retired, location: .remote(provider: "acme", sessionID: "s2"), providerRetired: true)
        let goneArchivable = SelectionArchive.isArchivable(goneLane, selectedIDs: selected)
        let retiredArchivable = SelectionArchive.isArchivable(retiredLane, selectedIDs: selected)
        #expect(goneArchivable)
        #expect(retiredArchivable)
    }

    @Test func aRowWithAnActiveChildOutsideTheSelectionIsNotArchivable() {
        let parent = UUID(), child = UUID(), other = UUID()
        let selected: Set<UUID> = [parent, other]
        let candidate = SelectionArchive.Candidate(id: parent, activeChildIDs: [child])
        let archivable = SelectionArchive.isArchivable(candidate, selectedIDs: selected)
        #expect(!archivable)
    }

    @Test func aRowWhoseActiveChildrenAreAllSelectedIsArchivable() {
        let parent = UUID(), first = UUID(), second = UUID()
        let selected: Set<UUID> = [parent, first, second]
        let candidate = SelectionArchive.Candidate(id: parent, activeChildIDs: [first, second])
        let archivable = SelectionArchive.isArchivable(candidate, selectedIDs: selected)
        #expect(archivable)
    }

    // MARK: Run order

    @Test func descendantsComeBeforeTheirAncestorsAndSidebarOrderIsKept() {
        let repo = UUID()
        let parent = row("parent", repoID: repo, order: 0)
        let first = row("first", repoID: repo, parent: parent.id, order: 0)
        let grandchild = row("grandchild", repoID: repo, parent: first.id)
        let second = row("second", repoID: repo, parent: parent.id, order: 1)
        let sibling = row("sibling", repoID: repo, order: 1)
        let order = SelectionArchive.childrenFirst([parent, first, grandchild, second, sibling])
        let expected = [grandchild.id, first.id, second.id, parent.id, sibling.id]
        #expect(order == expected)
    }

    @Test func aRowWhoseParentIsNotListedIsARoot() {
        let repo = UUID()
        let before = row("before", repoID: repo)
        let orphan = row("orphan", repoID: repo, parent: UUID())
        let after = row("after", repoID: repo)
        let order = SelectionArchive.childrenFirst([before, orphan, after])
        let expected = [before.id, orphan.id, after.id]
        #expect(order == expected)
    }

    @Test func aChildListedBeforeItsParentStillComesFirst() {
        let repo = UUID()
        let parent = row("parent", repoID: repo)
        let child = row("child", repoID: repo, parent: parent.id)
        let order = SelectionArchive.childrenFirst([parent, child])
        let reversed = SelectionArchive.childrenFirst([child, parent])
        let expected = [child.id, parent.id]
        #expect(order == expected)
        #expect(reversed == expected)
    }

    @Test func aLoopingParentChainStillReturnsEveryRowOnce() {
        let repo = UUID()
        let aID = UUID(), bID = UUID()
        let a = row("a", repoID: repo, id: aID, parent: bID)
        let b = row("b", repoID: repo, id: bID, parent: aID)
        let free = row("free", repoID: repo)
        let order = SelectionArchive.childrenFirst([a, b, free, a])
        let expected: Set<UUID> = [aID, bID, free.id]
        #expect(order.count == 3)
        #expect(Set(order) == expected)
    }

    @Test func targetsSkipRowsThatCannotGoAndFollowTheRunOrder() {
        let a = UUID(), main = UUID(), c = UUID()
        let candidates = [
            SelectionArchive.Candidate(id: a),
            SelectionArchive.Candidate(id: main, status: .main),
            SelectionArchive.Candidate(id: c),
        ]
        let selected: Set<UUID> = [a, main, c]
        let targets = SelectionArchive.targets(candidates, selectedIDs: selected, runOrder: [c, main, a])
        let expected = [c, a]
        #expect(targets == expected)
    }

    @Test func anArchivableRowTheRunOrderDoesNotListGoesLast() {
        let listed = UUID(), unlisted = UUID()
        let candidates = [SelectionArchive.Candidate(id: unlisted), SelectionArchive.Candidate(id: listed)]
        let selected: Set<UUID> = [listed, unlisted]
        let targets = SelectionArchive.targets(candidates, selectedIDs: selected, runOrder: [listed])
        let expected = [listed, unlisted]
        #expect(targets == expected)
    }

    // MARK: Routing

    @Test func noTargetsRouteNowhere() {
        let route = SelectionArchive.route([])
        #expect(route == .nothing)
    }

    @Test func oneTargetTakesTheSingleRowArchive() {
        let id = UUID()
        let route = SelectionArchive.route([id])
        #expect(route == .single(id))
    }

    @Test func severalTargetsTakeTheBulkRun() {
        let ids = [UUID(), UUID()]
        let route = SelectionArchive.route(ids)
        #expect(route == .bulk(ids))
    }

    // MARK: The summary

    @Test func aRefusalIsTheDaemonsSentenceOnOneLine() {
        let refusal = """
            acme-wt has 1 uncommitted change(s) that archiving would delete:
              ?? notes.md
            Commit or remove them first.
            """
        let error = DaemonClientError.rpcError(refusal, code: RPCErrorCode.worktreeArchiveUncommitted.rawValue)
        let reason = SelectionArchive.failureReason(error)
        #expect(reason == "acme-wt has 1 uncommitted change(s) that archiving would delete: ?? notes.md Commit or remove them first.")
        #expect(!reason.hasPrefix("RPC error:"))
    }

    @Test func anotherErrorIsItsDescription() {
        let reason = SelectionArchive.failureReason(DaemonClientError.daemonNotRunning)
        #expect(reason == "TBD daemon is not running")
    }

    @Test func theSummaryCountsThenListsEachFailure() {
        let failures = [
            SelectionArchive.Failure(name: "acme-a", reason: "Its agent is still working."),
            SelectionArchive.Failure(name: "acme-b", reason: "TBD daemon is not running"),
        ]
        let text = SelectionArchive.summary(archived: 1, attempted: 3, failures: failures)
        #expect(text == "Archived 1 of 3 worktrees.\n\nacme-a: Its agent is still working.\nacme-b: TBD daemon is not running")
    }

    @Test func oneAttemptReadsInTheSingular() {
        let failures = [SelectionArchive.Failure(name: "acme-a", reason: "Refused.")]
        let text = SelectionArchive.summary(archived: 0, attempted: 1, failures: failures)
        #expect(text == "Archived 0 of 1 worktree.\n\nacme-a: Refused.")
    }
}

// MARK: - Both surfaces, built from live AppState

/// Through `RowActionMenuActions` with `followsSelection` on, as the SwiftUI
/// `SidebarContextMenu` and the native `SidebarMenus` both build it, and
/// through `SidebarMenus` itself for the native outline and dock. The
/// selection lives in `AppState.selectedWorktreeIDs`, which both native
/// tables sync into.
@MainActor
@Suite("Archive Selection — built from live AppState")
struct ArchiveSelectionCallSiteTests {
    /// A repo with its main row, a parent and its child, a sibling, and a row
    /// still creating.
    private struct Fixture {
        let repo: Repo
        let main: Worktree
        let parent: Worktree
        let child: Worktree
        let sibling: Worktree
        let creating: Worktree
    }

    private func withState(_ body: (AppState, UserDefaults, Fixture) throws -> Void) throws {
        let suite = TestDefaultsSuite("TBDAppTests.ArchiveSelectionCallSite")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("parent", repoID: repo.id, order: 0)
        let fixture = Fixture(
            repo: repo,
            main: row("acme", repoID: repo.id, status: .main),
            parent: parent,
            child: row("child", repoID: repo.id, parent: parent.id),
            sibling: row("sibling", repoID: repo.id, order: 1),
            creating: row("creating", repoID: repo.id, order: 2, status: .creating))
        state.repos = [repo]
        state.worktrees = [repo.id: [fixture.main, fixture.parent, fixture.child, fixture.sibling, fixture.creating]]
        try body(state, suite.defaults, fixture)
    }

    /// Every Archive Selection item's targets in `items`; empty when the list
    /// has none.
    private func archiveSelectionItems(_ items: [RowActionMenu.Item]) -> [[UUID]] {
        items.compactMap { archiveSelectionTargets($0) }
    }

    /// The menu `SidebarContextMenu` and `SidebarMenus` build for a row.
    private func rowMenu(_ state: AppState, _ worktree: Worktree) -> RowActionMenuActions {
        RowActionMenuActions(appState: state, worktree: worktree, onRename: {}, followsSelection: true)
    }

    /// The toolbar title's menu for a row, which does not follow the selection.
    private func titleMenu(_ state: AppState, _ worktree: Worktree) -> RowActionMenuActions {
        RowActionMenuActions(appState: state, worktree: worktree, onRename: {})
    }

    @Test("right-click inside a selection: Archive Selection alone, its targets children first")
    func insideASelection() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.parent.id, f.child.id, f.sibling.id]
            let actions = rowMenu(state, f.sibling)
            #expect(actions.actsOnSelection)
            let items = actions.items()
            let expected = archiveSelectionMenu([f.child.id, f.parent.id, f.sibling.id])
            #expect(items == expected)
        }
    }

    @Test("right-click inside a selection where nothing is archivable: the one item, disabled")
    func insideASelectionWithNothingArchivable() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.main.id, f.creating.id]
            let items = rowMenu(state, f.main).items()
            let expected = archiveSelectionMenu([])
            #expect(items == expected)
        }
    }

    @Test("right-click outside the selection: the row's own menu, and the selection is untouched")
    func outsideTheSelection() throws {
        try withState { state, _, f in
            let selection: Set<UUID> = [f.parent.id, f.child.id]
            state.selectedWorktreeIDs = selection
            let actions = rowMenu(state, f.sibling)
            #expect(!actions.actsOnSelection)
            let items = actions.items()
            let ownMenu = titleMenu(state, f.sibling).items()
            #expect(items == ownMenu)
            let selectionItems = archiveSelectionItems(items)
            #expect(selectionItems.isEmpty)
            let archiveTitles = items.compactMap { item -> String? in
                guard case let .action(action) = item, action.kind == .archive else { return nil }
                return action.title
            }
            let expectedTitles = ["Archive"]
            #expect(archiveTitles == expectedTitles)
            #expect(state.selectedWorktreeIDs == selection)
        }
    }

    @Test("right-click on the only selected row: the row's own menu")
    func aSingleSelection() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.sibling.id]
            let actions = rowMenu(state, f.sibling)
            #expect(!actions.actsOnSelection)
            let items = actions.items()
            let ownMenu = titleMenu(state, f.sibling).items()
            #expect(items == ownMenu)
            let selectionItems = archiveSelectionItems(items)
            #expect(selectionItems.isEmpty)
        }
    }

    /// The gate's other branch: a menu that does not follow the selection,
    /// the toolbar title's, stays the row's own inside a selection.
    @Test("a menu that does not follow the selection keeps the row's own items inside one")
    func aMenuThatDoesNotFollowTheSelection() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.parent.id, f.child.id, f.sibling.id]
            let actions = titleMenu(state, f.sibling)
            #expect(!actions.actsOnSelection)
            let items = actions.items()
            let selectionItems = archiveSelectionItems(items)
            #expect(selectionItems.isEmpty)
            #expect(items.count > 1)
        }
    }

    @Test("a parent whose active child is not selected is skipped")
    func aParentWithAnUnselectedChildIsSkipped() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.parent.id, f.sibling.id]
            let items = rowMenu(state, f.parent).items()
            let expected = archiveSelectionMenu([f.sibling.id])
            #expect(items == expected)
        }
    }

    @Test("a remote lane whose provider cannot archive is skipped")
    func aLaneWhoseProviderCannotArchiveIsSkipped() throws {
        try withState { state, _, f in
            let lane = row("lane", repoID: f.repo.id, order: 3, remote: "s1")
            state.worktrees[f.repo.id, default: []].append(lane)
            state.remoteProviders = [acmeProvider()]
            state.selectedWorktreeIDs = [lane.id, f.sibling.id]
            let items = rowMenu(state, lane).items()
            let expected = archiveSelectionMenu([f.sibling.id])
            #expect(items == expected)
        }
    }

    @Test("a scratch row goes with the selection, first, as the Scratch section is")
    func aScratchRowIsATarget() throws {
        try withState { state, _, f in
            let scratch = row("scratch", repoID: nil)
            state.scratchWorktrees = [scratch]
            state.selectedWorktreeIDs = [f.sibling.id, scratch.id]
            let items = rowMenu(state, scratch).items()
            let expected = archiveSelectionMenu([scratch.id, f.sibling.id])
            #expect(items == expected)
        }
    }

    /// One archivable row in a larger selection takes the single-row path,
    /// prompts included, through the same decision the run makes.
    @Test("one archivable row in the selection routes to the single-row archive")
    func oneArchivableRowRoutesSingle() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.main.id, f.sibling.id]
            let items = rowMenu(state, f.main).items()
            let found = archiveSelectionItems(items)
            let targets = try #require(found.first)
            let expectedTargets = [f.sibling.id]
            #expect(targets == expectedTargets)
            let route = SelectionArchive.route(targets)
            #expect(route == .single(f.sibling.id))
        }
    }

    // MARK: The native sidebar and dock

    private static func titles(of menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private static func title(of item: RowActionMenu.Item) -> String {
        switch item {
        case .action(let action): action.title
        case .divider: "—"
        case .caption(let text): text
        }
    }

    @Test("the native menu is Archive Selection alone inside a selection, with no create items")
    func nativeMenuInsideASelection() throws {
        try withState { state, defaults, f in
            state.remoteProviders = [acmeProvider()]
            state.selectedWorktreeIDs = [f.parent.id, f.child.id]
            let menus = SidebarMenus(appState: state, defaults: defaults, host: nil)
            let tree = SidebarTreeBuilder.build(
                state, options: SidebarBuildOptions(defaults: defaults), directoryExists: { _ in true })
            let node = try #require(tree.node(.worktree(f.child.id)))
            let menu = try #require(menus.menu(for: node))
            let shown = Self.titles(of: menu)
            let expected = [RowActionMenu.archiveSelectionLabel]
            #expect(shown == expected)
            let item = try #require(menu.items.first)
            #expect(item.isEnabled)
        }
    }

    @Test("the native menu outside the selection is the row's own, with its create items")
    func nativeMenuOutsideTheSelection() throws {
        try withState { state, defaults, f in
            state.remoteProviders = [acmeProvider()]
            state.selectedWorktreeIDs = [f.parent.id, f.child.id]
            let menus = SidebarMenus(appState: state, defaults: defaults, host: nil)
            let tree = SidebarTreeBuilder.build(
                state, options: SidebarBuildOptions(defaults: defaults), directoryExists: { _ in true })
            let node = try #require(tree.node(.worktree(f.sibling.id)))
            let menu = try #require(menus.menu(for: node))
            let shown = Self.titles(of: menu)
            let expected = titleMenu(state, f.sibling).items().map { Self.title(of: $0) }
                + ["—", "New Remote Session…"]
            #expect(shown == expected)
            #expect(!shown.contains(RowActionMenu.archiveSelectionLabel))
        }
    }

    @Test("the native menu is disabled when nothing selected is archivable")
    func nativeMenuWithNothingArchivable() throws {
        try withState { state, defaults, f in
            state.selectedWorktreeIDs = [f.main.id, f.creating.id]
            let menus = SidebarMenus(appState: state, defaults: defaults, host: nil)
            let tree = SidebarTreeBuilder.build(
                state, options: SidebarBuildOptions(defaults: defaults), directoryExists: { _ in true })
            let node = try #require(tree.node(.worktree(f.main.id)))
            let menu = try #require(menus.menu(for: node))
            let shown = Self.titles(of: menu)
            let expected = [RowActionMenu.archiveSelectionLabel]
            #expect(shown == expected)
            let item = try #require(menu.items.first)
            #expect(!item.isEnabled)
            #expect(item.toolTip == RowActionMenu.archiveSelectionNothingArchivableHelp)
        }
    }
}

// MARK: - The bulk run

/// `archiveInBulk` with a fake archive call. The fake is the run's only way
/// to archive, and it takes no flags, so a prompt accepted on the run's
/// behalf would show up as a second call for the same row.
@MainActor
@Suite("Archive Selection — bulk run")
struct ArchiveSelectionBulkRunTests {
    /// Records each archive call, failing the rows it was told to.
    @MainActor
    final class FakeArchiver {
        var calls: [UUID] = []
        var failures: [UUID: any Error] = [:]

        func archive(_ worktree: Worktree) throws {
            calls.append(worktree.id)
            if let error = failures[worktree.id] { throw error }
        }
    }

    private func makeState() -> (AppState, () -> Void) {
        let suite = TestDefaultsSuite("TBDAppTests.ArchiveSelectionBulkRun")
        let state = AppState(userDefaults: suite.defaults)
        return (state, { suite.tearDown() })
    }

    @Test("every row is tried children first, failures make one summary, and nothing is retried")
    func aMixOfSuccessesAndRefusals() async {
        let (state, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("acme-parent", repoID: repo.id, order: 0)
        let child = row("acme-child", repoID: repo.id, parent: parent.id)
        let guarded = row("acme-guarded", repoID: repo.id, order: 1)
        let dirty = row("acme-dirty", repoID: repo.id, order: 2)
        state.repos = [repo]
        state.worktrees = [repo.id: [parent, child, guarded, dirty]]
        state.selectedWorktreeIDs = [parent.id, child.id, guarded.id, dirty.id]

        let targets = state.selectionArchiveTargets()
        let runOrder = [child.id, parent.id, guarded.id, dirty.id]
        #expect(targets == runOrder)

        // The two refusals the single-row path answers with a prompt.
        let fake = FakeArchiver()
        fake.failures[guarded.id] = DaemonClientError.rpcError(
            "Its agent is still working.", code: RPCErrorCode.remoteLaneArchiveGuarded.rawValue)
        fake.failures[dirty.id] = DaemonClientError.rpcError(
            "acme-dirty has 1 uncommitted change(s) that archiving would delete:\n  ?? notes.md\nCommit or remove them first.",
            code: RPCErrorCode.worktreeArchiveUncommitted.rawValue)

        await state.archiveInBulk(targets) { try fake.archive($0) }

        #expect(fake.calls == runOrder)
        let summary = """
            Archived 2 of 4 worktrees.

            acme-guarded: Its agent is still working.
            acme-dirty: acme-dirty has 1 uncommitted change(s) that archiving would delete: ?? notes.md Commit or remove them first.
            """
        #expect(state.alertMessage == summary)
        #expect(state.alertIsError)

        // The successes got the single-row path's settlement; the failures stay.
        let remaining = Set((state.worktrees[repo.id] ?? []).map(\.id))
        let failed: Set<UUID> = [guarded.id, dirty.id]
        #expect(remaining == failed)
        #expect(state.selectedWorktreeIDs == failed)
        #expect(state.recentlyArchivedWorktreeIDs[child.id] != nil)
        #expect(state.recentlyArchivedWorktreeIDs[parent.id] != nil)
        #expect(state.recentlyArchivedWorktreeIDs[guarded.id] == nil)
    }

    @Test("when every row goes, there is no alert")
    func allSucceed() async {
        let (state, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: repo.id, order: 0)
        let second = row("acme-second", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [first, second]]

        let fake = FakeArchiver()
        let targets = [first.id, second.id]
        await state.archiveInBulk(targets) { try fake.archive($0) }

        #expect(fake.calls == targets)
        #expect(state.alertMessage == nil)
        #expect(state.worktrees[repo.id]?.isEmpty == true)
    }

    @Test("a row gone before its turn is not attempted, and the summary counts only what was")
    func aRowGoneBeforeItsTurnIsNotAttempted() async {
        let (state, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: repo.id, order: 0)
        let second = row("acme-second", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [first, second]]

        let fake = FakeArchiver()
        fake.failures[second.id] = DaemonClientError.rpcError("Refused.", code: nil)
        let gone = UUID()
        await state.archiveInBulk([first.id, gone, second.id]) { try fake.archive($0) }

        let attempted = [first.id, second.id]
        #expect(fake.calls == attempted)
        #expect(state.alertMessage == "Archived 1 of 2 worktrees.\n\nacme-second: Refused.")
    }

    @Test("a dropped connection goes through handleConnectionError and into the summary")
    func aConnectionFailureIsHandledAndReported() async {
        let (state, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: repo.id, order: 0)
        let second = row("acme-second", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [first, second]]
        state.isConnected = true

        let fake = FakeArchiver()
        fake.failures[first.id] = DaemonClientError.daemonNotRunning
        fake.failures[second.id] = DaemonClientError.daemonNotRunning
        await state.archiveInBulk([first.id, second.id]) { try fake.archive($0) }

        #expect(!state.isConnected)
        let summary = """
            Archived 0 of 2 worktrees.

            acme-first: TBD daemon is not running
            acme-second: TBD daemon is not running
            """
        #expect(state.alertMessage == summary)
    }
}
