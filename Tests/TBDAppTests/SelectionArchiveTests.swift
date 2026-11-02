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

    // MARK: Eligibility, row by row

    @Test func anActiveLocalRowCanArchiveItself() {
        let canGo = SelectionArchive.canArchiveItself(SelectionArchive.Candidate(id: UUID()))
        #expect(canGo)
    }

    /// Only these three are excluded; a failed row's own Archive is enabled,
    /// so it can go with the selection too.
    @Test func mainCreatingAndArchivedRowsCannotArchiveThemselves() {
        for status: WorktreeStatus in [.main, .creating, .archived] {
            let candidate = SelectionArchive.Candidate(id: UUID(), status: status)
            let canGo = SelectionArchive.canArchiveItself(candidate)
            #expect(!canGo)
        }
        let failed = SelectionArchive.Candidate(id: UUID(), status: .failed)
        let failedCanGo = SelectionArchive.canArchiveItself(failed)
        #expect(failedCanGo)
    }

    @Test func aRemoteLaneWhoseProviderCannotArchiveCannotArchiveItself() {
        let lane = SelectionArchive.Candidate(
            id: UUID(), location: .remote(provider: "acme", sessionID: "s1"), providerCapabilities: ["stop"])
        let canGo = SelectionArchive.canArchiveItself(lane)
        #expect(!canGo)
    }

    @Test func aRemoteLaneWhoseProviderCanArchiveCanArchiveItself() {
        let lane = SelectionArchive.Candidate(
            id: UUID(), location: .remote(provider: "acme", sessionID: "s1"), providerCapabilities: ["archive"])
        let canGo = SelectionArchive.canArchiveItself(lane)
        #expect(canGo)
    }

    /// The same exemptions the row's own Archive makes: the daemon files a
    /// gone lane, and one whose provider is retired, row-only.
    @Test func goneAndRetiredLanesAreExemptFromTheCapabilityGate() {
        let goneLane = SelectionArchive.Candidate(
            id: UUID(), location: .remote(provider: "acme", sessionID: "s1"), isGone: true)
        let retiredLane = SelectionArchive.Candidate(
            id: UUID(), location: .remote(provider: "acme", sessionID: "s2"), providerRetired: true)
        let goneCanGo = SelectionArchive.canArchiveItself(goneLane)
        let retiredCanGo = SelectionArchive.canArchiveItself(retiredLane)
        #expect(goneCanGo)
        #expect(retiredCanGo)
    }

    // MARK: Eligibility, bottom up

    @Test func aRowWithAnActiveChildOutsideTheSelectionIsNotArchivable() {
        let parent = UUID(), child = UUID(), other = UUID()
        let candidates = [
            SelectionArchive.Candidate(id: parent, activeChildIDs: [child]),
            SelectionArchive.Candidate(id: other),
        ]
        let targets = SelectionArchive.targets(candidates, runOrder: [child, parent, other])
        let expected = [other]
        #expect(targets == expected)
    }

    @Test func aParentAndItsArchivableChildrenAreAllTargetsChildrenFirst() {
        let parent = UUID(), first = UUID(), second = UUID()
        let candidates = [
            SelectionArchive.Candidate(id: parent, activeChildIDs: [first, second]),
            SelectionArchive.Candidate(id: first),
            SelectionArchive.Candidate(id: second),
        ]
        let targets = SelectionArchive.targets(candidates, runOrder: [first, second, parent])
        let expected = [first, second, parent]
        #expect(targets == expected)
    }

    /// A selected child that cannot go holds its parent back, as an
    /// unselected one does: the daemon would refuse the parent for it.
    @Test func aSelectedChildThatCannotGoHoldsBackItsParent() {
        let creatingChild = SelectionArchive.Candidate(id: UUID(), status: .creating)
        let laneChild = SelectionArchive.Candidate(
            id: UUID(), location: .remote(provider: "acme", sessionID: "s1"), providerCapabilities: [])
        for child in [creatingChild, laneChild] {
            let parent = SelectionArchive.Candidate(id: UUID(), activeChildIDs: [child.id])
            let sibling = SelectionArchive.Candidate(id: UUID())
            let targets = SelectionArchive.targets(
                [parent, child, sibling], runOrder: [child.id, parent.id, sibling.id])
            let expected = [sibling.id]
            #expect(targets == expected)
        }
    }

    @Test func aThreeLevelChainGoesWholeOrIsHeldBackFromTheBottom() {
        let grandchildID = UUID(), childID = UUID(), parentID = UUID()
        let runOrder = [grandchildID, childID, parentID]
        let child = SelectionArchive.Candidate(id: childID, activeChildIDs: [grandchildID])
        let parent = SelectionArchive.Candidate(id: parentID, activeChildIDs: [childID])

        // Every row can go: the whole chain, deepest first.
        let whole = SelectionArchive.targets(
            [parent, SelectionArchive.Candidate(id: grandchildID), child], runOrder: runOrder)
        #expect(whole == runOrder)

        // The grandchild is still creating: it holds back the child, which
        // holds back the parent.
        let creating = SelectionArchive.targets(
            [parent, SelectionArchive.Candidate(id: grandchildID, status: .creating), child], runOrder: runOrder)
        #expect(creating.isEmpty)

        // The grandchild is not selected: the same.
        let unselected = SelectionArchive.targets([parent, child], runOrder: runOrder)
        #expect(unselected.isEmpty)
    }

    @Test func aLoopingParentChainHoldsBackEveryRowInIt() {
        let a = UUID(), b = UUID(), free = UUID()
        let candidates = [
            SelectionArchive.Candidate(id: a, activeChildIDs: [b]),
            SelectionArchive.Candidate(id: b, activeChildIDs: [a]),
            SelectionArchive.Candidate(id: free),
        ]
        let targets = SelectionArchive.targets(candidates, runOrder: [a, b, free])
        let expected = [free]
        #expect(targets == expected)
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
        let targets = SelectionArchive.targets(candidates, runOrder: [c, main, a])
        let expected = [c, a]
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

    /// The first line says what is wrong; the file list after it is left
    /// out, and the colon that introduced it becomes a full stop. The text is
    /// `UncommittedArchiveRefusal.evaluate`'s for one dirty file.
    @Test func aRefusalIsTheFirstLineOfTheDaemonsSentence() {
        let refusal = """
            acme-wt has 1 uncommitted change(s) that archiving would delete:
              ?? notes.md
            Commit or remove them first.
            """
        let error = DaemonClientError.rpcError(refusal, code: RPCErrorCode.worktreeArchiveUncommitted.rawValue)
        let reason = SelectionArchive.failureReason(error)
        #expect(reason == "acme-wt has 1 uncommitted change(s) that archiving would delete.")
        #expect(!reason.hasPrefix("RPC error:"))
    }

    @Test func blankLinesBeforeTheFirstSentenceAreSkipped() {
        let error = DaemonClientError.rpcError("\n   \nCannot archive acme-lane: its agent is working.\nMore.", code: nil)
        let reason = SelectionArchive.failureReason(error)
        #expect(reason == "Cannot archive acme-lane: its agent is working.")
    }

    @Test func anotherErrorIsItsDescription() {
        let reason = SelectionArchive.failureReason(DaemonClientError.daemonNotRunning)
        #expect(reason == "TBD daemon is not running")
    }

    @Test func aReasonAtTheCharacterLimitIsKeptWhole() {
        let line = String(repeating: "x", count: SelectionArchive.reasonCharacterLimit)
        let reason = SelectionArchive.failureReason(DaemonClientError.rpcError(line, code: nil))
        #expect(reason == line)
    }

    @Test func aReasonOneCharacterOverTheLimitIsCutToEndInAnEllipsis() {
        let limit = SelectionArchive.reasonCharacterLimit
        let line = String(repeating: "x", count: limit + 1)
        let reason = SelectionArchive.failureReason(DaemonClientError.rpcError(line, code: nil))
        let expected = String(repeating: "x", count: limit - 1) + "…"
        #expect(reason == expected)
        #expect(reason.count == limit)
    }

    @Test func theSummaryCountsThenListsEachFailure() {
        let failures = [
            SelectionArchive.Failure(name: "acme-a", reason: "Its agent is still working."),
            SelectionArchive.Failure(name: "acme-b", reason: "TBD daemon is not running"),
        ]
        let text = SelectionArchive.summary(archived: 1, total: 3, failures: failures)
        #expect(text == "Archived 1 of 3 worktrees.\n\nacme-a: Its agent is still working.\nacme-b: TBD daemon is not running")
    }

    @Test func oneRowReadsInTheSingular() {
        let failures = [SelectionArchive.Failure(name: "acme-a", reason: "Refused.")]
        let text = SelectionArchive.summary(archived: 0, total: 1, failures: failures)
        #expect(text == "Archived 0 of 1 worktree.\n\nacme-a: Refused.")
    }

    private static func failures(_ count: Int) -> [SelectionArchive.Failure] {
        (1...count).map { SelectionArchive.Failure(name: "acme-\($0)", reason: "Refused.") }
    }

    @Test func aSummaryAtTheLineLimitListsEveryFailure() {
        let limit = SelectionArchive.summaryFailureLineLimit
        let text = SelectionArchive.summary(archived: 0, total: limit, failures: Self.failures(limit))
        let lines = text.components(separatedBy: "\n")
        let expected: [String] = ["Archived 0 of \(limit) worktrees.", ""] + (1...limit).map { "acme-\($0): Refused." }
        #expect(lines == expected)
    }

    @Test func aSummaryOneOverTheLineLimitCountsTheRestOnOneLine() {
        let limit = SelectionArchive.summaryFailureLineLimit
        let total = limit + 1
        let text = SelectionArchive.summary(archived: 0, total: total, failures: Self.failures(total))
        let lines = text.components(separatedBy: "\n")
        let expected: [String] = ["Archived 0 of \(total) worktrees.", ""]
            + (1...limit).map { "acme-\($0): Refused." }
            + ["…and 1 more."]
        #expect(lines == expected)
    }

    @Test func rowsNotAttemptedShareOneClosingLine() {
        let failures = [SelectionArchive.Failure(name: "acme-a", reason: "TBD daemon is not running")]
        let text = SelectionArchive.summary(archived: 1, total: 5, failures: failures, notAttempted: 3)
        let expected = """
            Archived 1 of 5 worktrees.

            acme-a: TBD daemon is not running
            3 more not attempted: lost the connection to the daemon.
            """
        #expect(text == expected)
    }

    @Test func aHeldBackRowNamesTheNestedWorktreeThatStayed() {
        let reason = SelectionArchive.nestedNotArchivedReason("acme-child")
        #expect(reason == "Not archived, because its nested worktree \"acme-child\" was not archived.")
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

    /// A menu acting on the selection derives none of the row's own facts:
    /// its context is the selection and every other field's default, even
    /// for a row whose own context would set many of them.
    @Test("inside a selection the context carries the selection alone")
    func insideASelectionTheContextIsTheSelectionAlone() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.parent.id, f.child.id, f.sibling.id]
            let context = rowMenu(state, f.parent).context()
            let expected = RowActionMenu.Context(
                selection: .init(archiveTargetIDs: [f.child.id, f.parent.id, f.sibling.id]))
            #expect(context == expected)
            // The gate's other branch: the same row outside a selection
            // derives its own facts.
            state.selectedWorktreeIDs = [f.parent.id]
            let own = rowMenu(state, f.parent).context()
            #expect(own.selection == nil)
            #expect(own.hasActiveChildren)
            #expect(own.branch == f.parent.branch)
        }
    }

    @Test("a parent whose selected child is still creating is skipped")
    func aParentWithACreatingChildIsSkipped() throws {
        try withState { state, _, f in
            let creatingChild = row("creating-child", repoID: f.repo.id, parent: f.sibling.id, status: .creating)
            state.worktrees[f.repo.id, default: []].append(creatingChild)
            state.selectedWorktreeIDs = [f.sibling.id, creatingChild.id, f.parent.id, f.child.id]
            let items = rowMenu(state, f.sibling).items()
            let expected = archiveSelectionMenu([f.child.id, f.parent.id])
            #expect(items == expected)
        }
    }

    /// Why `SelectionArchive.targets` needs no branch for a candidate the run
    /// order leaves out: the run order lists every row `findWorktree(id:)`
    /// resolves, including the ones the sidebar walk skips.
    @Test("the run order lists every row a selected ID can resolve to, once")
    func theRunOrderListsEveryResolvableRow() throws {
        try withState { state, _, f in
            let failed = row("failed", repoID: f.repo.id, order: 4, status: .failed)
            let underFailed = row("under-failed", repoID: f.repo.id, parent: failed.id)
            state.worktrees[f.repo.id, default: []] += [failed, underFailed]
            state.scratchWorktrees = [row("scratch", repoID: nil)]
            let order = state.selectionArchiveRunOrder
            let resolvable = state.allWorktrees.map(\.id)
            let orderSet = Set(order)
            let resolvableSet = Set(resolvable)
            #expect(order.count == resolvable.count)
            #expect(orderSet == resolvableSet)
            for id in resolvable {
                let found = state.findWorktree(id: id)
                #expect(found != nil)
            }
            let failedIndex = try #require(order.firstIndex(of: failed.id))
            let childIndex = try #require(order.firstIndex(of: underFailed.id))
            #expect(childIndex < failedIndex)
        }
    }

    // MARK: The archive shortcut

    /// With one row selected the shortcut keeps its old rule: the lane goes
    /// to `archiveWorktree(id:)`, and the daemon's refusal comes back as that
    /// path's alert.
    @Test("the shortcut sends one selected lane its provider cannot archive to the single-row archive")
    func theShortcutSendsOneSelectedLaneAnyway() throws {
        try withState { state, _, f in
            let lane = row("lane", repoID: f.repo.id, order: 3, remote: "s1")
            state.worktrees[f.repo.id, default: []].append(lane)
            state.remoteProviders = [acmeProvider()]
            state.selectedWorktreeIDs = [lane.id]
            #expect(state.archiveShortcutRoute() == .single(lane.id))
            // Selected with another row that cannot go, it is held to the
            // selection's rules, and nothing can go.
            state.selectedWorktreeIDs = [lane.id, f.main.id]
            #expect(state.archiveShortcutRoute() == .beep)
        }
    }

    @Test("the shortcut beeps for two or more selected rows of which none can go")
    func theShortcutBeepsWhenNothingSelectedCanGo() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.main.id, f.creating.id]
            #expect(state.archiveShortcutRoute() == .beep)
            state.selectedWorktreeIDs = [UUID(), UUID()]
            #expect(state.archiveShortcutRoute() == .beep)
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
        /// `selectionArchiveInFlight` as each call saw it, for the tests
        /// that record it.
        var inFlightSeen: [Bool] = []

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
            acme-dirty: acme-dirty has 1 uncommitted change(s) that archiving would delete.
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
        #expect(!state.selectionArchiveInFlight)
        await state.archiveInBulk(targets) { worktree in
            try fake.archive(worktree)
            fake.inFlightSeen.append(state.selectionArchiveInFlight)
        }

        #expect(fake.calls == targets)
        #expect(state.alertMessage == nil)
        #expect(state.worktrees[repo.id]?.isEmpty == true)
        // The run held the in-flight flag throughout and let it go at the end.
        let seen = [true, true]
        #expect(fake.inFlightSeen == seen)
        #expect(!state.selectionArchiveInFlight)
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

    @Test("a refused child holds back its parent, which is not sent to the daemon")
    func aRefusedChildHoldsBackItsParent() async {
        let (state, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("acme-parent", repoID: repo.id, order: 0)
        let child = row("acme-child", repoID: repo.id, parent: parent.id)
        let sibling = row("acme-sibling", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [parent, child, sibling]]

        let fake = FakeArchiver()
        fake.failures[child.id] = DaemonClientError.rpcError("Refused.", code: nil)
        await state.archiveInBulk([child.id, parent.id, sibling.id]) { try fake.archive($0) }

        let sent = [child.id, sibling.id]
        #expect(fake.calls == sent)
        let summary = """
            Archived 1 of 3 worktrees.

            acme-child: Refused.
            acme-parent: Not archived, because its nested worktree "acme-child" was not archived.
            """
        #expect(state.alertMessage == summary)
        let remaining = Set((state.worktrees[repo.id] ?? []).map(\.id))
        let kept: Set<UUID> = [parent.id, child.id]
        #expect(remaining == kept)
    }

    @Test("a refused grandchild holds back the whole chain above it, each naming the row below")
    func aRefusedGrandchildHoldsBackTheChain() async {
        let (state, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("acme-parent", repoID: repo.id)
        let child = row("acme-child", repoID: repo.id, parent: parent.id)
        let grandchild = row("acme-grandchild", repoID: repo.id, parent: child.id)
        state.repos = [repo]
        state.worktrees = [repo.id: [parent, child, grandchild]]

        let fake = FakeArchiver()
        fake.failures[grandchild.id] = DaemonClientError.rpcError("Refused.", code: nil)
        await state.archiveInBulk([grandchild.id, child.id, parent.id]) { try fake.archive($0) }

        let sent = [grandchild.id]
        #expect(fake.calls == sent)
        let summary = """
            Archived 0 of 3 worktrees.

            acme-grandchild: Refused.
            acme-child: Not archived, because its nested worktree "acme-grandchild" was not archived.
            acme-parent: Not archived, because its nested worktree "acme-child" was not archived.
            """
        #expect(state.alertMessage == summary)
    }

    @Test("a dropped connection stops the run, and the rows left share one line")
    func aConnectionFailureStopsTheRun() async {
        let (state, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: repo.id, order: 0)
        let second = row("acme-second", repoID: repo.id, order: 1)
        let third = row("acme-third", repoID: repo.id, order: 2)
        let fourth = row("acme-fourth", repoID: repo.id, order: 3)
        state.repos = [repo]
        state.worktrees = [repo.id: [first, second, third, fourth]]
        state.isConnected = true

        let fake = FakeArchiver()
        fake.failures[second.id] = DaemonClientError.daemonNotRunning
        // A row gone before the run reaches it is not counted among the rows
        // left, as it is not counted when the run does reach it.
        let gone = UUID()
        await state.archiveInBulk([first.id, second.id, third.id, gone, fourth.id]) { try fake.archive($0) }

        let sent = [first.id, second.id]
        #expect(fake.calls == sent)
        #expect(!state.isConnected)
        let summary = """
            Archived 1 of 4 worktrees.

            acme-second: TBD daemon is not running
            2 more not attempted: lost the connection to the daemon.
            """
        #expect(state.alertMessage == summary)
    }

    /// The other branch: a refusal that is not a lost connection leaves the
    /// run going, and a lost connection on the last row leaves nothing to
    /// count.
    @Test("a refusal does not stop the run, and a lost connection on the last row adds no line")
    func aRefusalDoesNotStopTheRun() async {
        let (state, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: repo.id, order: 0)
        let second = row("acme-second", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [first, second]]

        let fake = FakeArchiver()
        fake.failures[first.id] = DaemonClientError.rpcError("Refused.", code: nil)
        fake.failures[second.id] = DaemonClientError.connectionFailed("socket closed")
        await state.archiveInBulk([first.id, second.id]) { try fake.archive($0) }

        let sent = [first.id, second.id]
        #expect(fake.calls == sent)
        let summary = """
            Archived 0 of 2 worktrees.

            acme-first: Refused.
            acme-second: Connection failed: socket closed
            """
        #expect(state.alertMessage == summary)
    }

    /// The row menu and the shortcut, or the shortcut twice: a bulk trigger
    /// while a run is in progress archives nothing.
    @Test("a bulk trigger during a run starts nothing")
    func aBulkTriggerDuringARunStartsNothing() async {
        let (state, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: repo.id, order: 0)
        let second = row("acme-second", repoID: repo.id, order: 1)
        let other = row("acme-other", repoID: repo.id, order: 2)
        state.repos = [repo]
        state.worktrees = [repo.id: [first, second, other]]

        let fake = FakeArchiver()
        let nested = FakeArchiver()
        let firstID = first.id
        let otherID = other.id
        await state.archiveInBulk([first.id, second.id]) { worktree in
            try fake.archive(worktree)
            if worktree.id == firstID {
                await state.archiveInBulk([otherID]) { try nested.archive($0) }
            }
        }

        let sent = [first.id, second.id]
        #expect(fake.calls == sent)
        #expect(nested.calls.isEmpty)
        #expect(state.findWorktree(id: other.id) != nil)
        #expect(!state.selectionArchiveInFlight)
    }

    @Test("a trigger while a run holds the flag archives nothing and leaves the flag set")
    func aTriggerWhileTheFlagIsSetArchivesNothing() async {
        let (state, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: repo.id)
        state.repos = [repo]
        state.worktrees = [repo.id: [first]]
        state.selectionArchiveInFlight = true

        let fake = FakeArchiver()
        await state.archiveInBulk([first.id]) { try fake.archive($0) }

        #expect(fake.calls.isEmpty)
        #expect(state.selectionArchiveInFlight)
        #expect(state.alertMessage == nil)
        #expect(state.findWorktree(id: first.id) != nil)
    }
}
