import AppKit
import Foundation
import SwiftUI
import Testing
import TBDShared
@testable import TBDApp
import TestSupport

// Tier 1: values, and an in-memory `AppState` on a test defaults suite. No
// window and no waits.

/// Each pane's tab strip in the window's toolbar row: the shared choice of
/// whether the detail area draws a worktree's tab bar, the toolbar items each
/// choice gives, the row's metrics and the main row's width rule. Spec:
/// docs/specs/2026-11-02-tabs-in-toolbar-design.md, "Testing".
@MainActor
@Suite("Tabs in the toolbar")
struct TabsInToolbarTests {
    private typealias ItemID = MainToolbarItemID

    // MARK: - The chrome

    /// The geometry the toolbar controller measures is written only when it
    /// changes, and read back as written.
    @Test func theChromeTakesTheMeasuredGeometry() {
        let chrome = WindowChromeState()
        #expect(chrome.topSafeAreaInset == 0)
        #expect(chrome.leadingItemTrailingEdge == nil)
        chrome.update(topSafeAreaInset: 52, leadingItemTrailingEdge: -120)
        #expect(chrome.topSafeAreaInset == 52)
        #expect(chrome.leadingItemTrailingEdge == -120)
        chrome.update(topSafeAreaInset: 66, leadingItemTrailingEdge: nil)
        #expect(chrome.topSafeAreaInset == 66)
        #expect(chrome.leadingItemTrailingEdge == nil)
    }

    // MARK: - The row's metrics

    /// The row is the toolbar's height, as the content pane's top safe-area
    /// inset reads it, whatever that is; only an unmeasured inset falls back
    /// to `TabRowMetrics.height`.
    @Test func theRowIsTheTopSafeAreaInsetTall() {
        let owners = MainTabRowMetrics.height(topSafeAreaInset: 52)
        #expect(owners == 52)
        let probe = MainTabRowMetrics.height(topSafeAreaInset: 66)
        #expect(probe == 66)
        let unmeasured = MainTabRowMetrics.height(topSafeAreaInset: 0)
        #expect(unmeasured == TabRowMetrics.height)
    }

    /// The main row starts 8 pt past the toolbar's leading item while that
    /// item reaches over the main pane, and 16 pt in while it does not.
    @Test func theRowClearsTheLeadingItemOnlyWhileItSitsOverThePane() {
        let unmeasured = MainTabRowMetrics.leadingInset(leadingItemTrailingEdge: nil)
        #expect(unmeasured == MainTabRowMetrics.shownSidebarInset)
        let sidebarShown = MainTabRowMetrics.leadingInset(leadingItemTrailingEdge: -120)
        #expect(sidebarShown == MainTabRowMetrics.shownSidebarInset)
        let atTheEdge = MainTabRowMetrics.leadingInset(leadingItemTrailingEdge: 0)
        #expect(atTheEdge == MainTabRowMetrics.shownSidebarInset)
        let sidebarCollapsed = MainTabRowMetrics.leadingInset(leadingItemTrailingEdge: 176)
        #expect(sidebarCollapsed == 184)
    }

    /// Both rows' pills: the active one at 7.5%, a hovered one at 4.5%, and
    /// the rest unfilled, 28 pt tall with a 7 pt radius, 2 pt apart.
    @Test func pillsFillTheActiveAndTheHoveredTab() {
        let active = MainTabRowMetrics.pillOpacity(isActive: true, isHovering: false)
        #expect(active == 0.075)
        let activeHovered = MainTabRowMetrics.pillOpacity(isActive: true, isHovering: true)
        #expect(activeHovered == 0.075)
        let hovered = MainTabRowMetrics.pillOpacity(isActive: false, isHovering: true)
        #expect(hovered == 0.045)
        let resting = MainTabRowMetrics.pillOpacity(isActive: false, isHovering: false)
        #expect(resting == 0)
        #expect(MainTabRowMetrics.pillHeight == 28)
        #expect(MainTabRowMetrics.pillCornerRadius == 7)
        #expect(MainTabRowMetrics.pillSpacing == 2)
        #expect(MainTabRowMetrics.pillToAddSpacing == 4)
    }

    // MARK: - Overflow

    @Test func everythingFits() {
        let widths = MainTabRowWidths.make(titleIdeal: 160, tabsIdeal: 200, fixed: 100, available: 600)
        #expect(widths == MainTabRowWidths(title: 160, tabs: 200))
    }

    /// Short of room, the title gives way and the tabs keep their width.
    @Test func theTitleShrinksAndTheTabsKeepTheirWidth() {
        let widths = MainTabRowWidths.make(titleIdeal: 160, tabsIdeal: 200, fixed: 100, available: 440)
        #expect(widths == MainTabRowWidths(title: 140, tabs: 200))
    }

    /// With the title at its 110 pt floor, the tabs take what is left, less
    /// than their ideal width, and scroll.
    @Test func atItsFloorTheTitleStopsAndTheTabsScroll() {
        let widths = MainTabRowWidths.make(titleIdeal: 160, tabsIdeal: 200, fixed: 100, available: 380)
        #expect(widths == MainTabRowWidths(title: 110, tabs: 170))
        #expect(MainTabRowMetrics.titleFloor == 110)
    }

    /// A title narrower than the floor keeps its own width, roomy or short.
    @Test func aTitleNarrowerThanTheFloorNeverGrows() {
        let roomy = MainTabRowWidths.make(titleIdeal: 60, tabsIdeal: 200, fixed: 100, available: 600)
        #expect(roomy == MainTabRowWidths(title: 60, tabs: 200))
        let short = MainTabRowWidths.make(titleIdeal: 60, tabsIdeal: 200, fixed: 100, available: 250)
        #expect(short == MainTabRowWidths(title: 60, tabs: 90))
    }

    /// A row with no room left gives the tabs nothing and no width is ever
    /// negative.
    @Test func noRoomLeavesNothingNegative() {
        let widths = MainTabRowWidths.make(titleIdeal: 160, tabsIdeal: 200, fixed: 100, available: 50)
        #expect(widths == MainTabRowWidths(title: 110, tabs: 0))
    }

    /// The layout's parts sit left to right: the title column at the row's
    /// leading edge, the tabs 14 pt after it, the drag gap taking the spare
    /// width, and the trailing items at the row's end. The gap's ideal width
    /// is ignored, and the row's ideal width holds the gap at its minimum.
    @Test func theLayoutPlacesItsPartsLeftToRight() {
        typealias Slot = MainTabRowLayout.Slot
        let ideals: [CGFloat] = [150, 200, 999, 60]
        let slots = MainTabRowLayout.slots(idealWidths: ideals, available: 600)
        let expected: [Slot] = [
            Slot(x: 0, width: 150),
            Slot(x: 164, width: 200),
            Slot(x: 364, width: 176),
            Slot(x: 540, width: 60),
        ]
        #expect(slots == expected)
        let ideal = MainTabRowLayout.idealWidth(idealWidths: ideals)
        #expect(ideal == 448)
    }

    /// Short of room, the title shrinks to its floor, the tabs take the rest
    /// but the gap's minimum, and the gap keeps 24 pt.
    @Test func theLayoutKeepsTheMinimumGapAsTheRowRunsShort() {
        let slots = MainTabRowLayout.slots(idealWidths: [150, 200, 0, 60], available: 400)
        let title = slots[MainTabRowLayout.Part.title.rawValue]
        let tabs = slots[MainTabRowLayout.Part.tabs.rawValue]
        let gap = slots[MainTabRowLayout.Part.gap.rawValue]
        let trailing = slots[MainTabRowLayout.Part.trailing.rawValue]
        #expect(title.x == 0)
        #expect(title.width == 110)
        #expect(tabs.width == 192)
        #expect(gap.width == MainTabRowMetrics.minimumDragGap)
        let trailingEnd = trailing.x + trailing.width
        #expect(trailingEnd == 400)
    }

    /// The side strip's tabs take their ideal width while it fits, and the
    /// drag gap the rest; past that the tabs take it all and scroll.
    @Test func theSideStripsGapTakesTheWidthAfterTheTabs() {
        let fits = TabsThenDragGapLayout.widths(tabsIdeal: 120, available: 300)
        #expect(fits.tabs == 120)
        #expect(fits.gap == 180)
        let overflows = TabsThenDragGapLayout.widths(tabsIdeal: 400, available: 300)
        #expect(overflows.tabs == 300)
        #expect(overflows.gap == 0)
    }

    /// The gap's view moves the window; it is the only view the rows give
    /// that answer.
    @Test func theDragGapMovesTheWindow() {
        let gap = WindowDragGapView(frame: NSRect(x: 0, y: 0, width: 40, height: 52))
        #expect(gap.mouseDownCanMoveWindow)
        #expect(gap.isOpaque == false)
        #expect(gap.identifier == WindowDragGapView.viewIdentifier)
    }

    // MARK: - The title column

    /// The title line's sizes, which the row's title column and the
    /// toolbar's title item both draw from: the title in 14 pt, the project
    /// name in 11 pt, 6 pt apart, and the notes symbol at the toolbar's 13 pt.
    @Test func theTitleLineTakesTheToolbarTitlesSizes() {
        #expect(WorktreeTitleMetrics.titleFontSize == 14)
        #expect(WorktreeTitleMetrics.projectFontSize == 11)
        #expect(WorktreeTitleMetrics.spacing == 6)
        #expect(WorktreeTitleMetrics.notesSymbolSize == 13)
    }

    /// The toolbar's inline cluster keeps the notes button's toolbar style,
    /// the default.
    @Test func theToolbarsNotesButtonKeepsItsStyle() {
        let style = WorktreeNotesButton(worktree: Self.titleWorktree(repoID: UUID())).style
        #expect(style == .toolbar)
    }

    /// The row's notes button, in its inline style, is the toolbar's size:
    /// its symbol draws at the size the toolbar's hosting view gives the
    /// toolbar style's.
    @Test func theRowsNotesButtonIsTheToolbarsSize() {
        let worktree = Self.titleWorktree(repoID: UUID())
        let inline = NSHostingView(rootView: WorktreeNotesButton(worktree: worktree, style: .inline)).fittingSize
        let toolbar = NSHostingView(rootView: WorktreeNotesButton(worktree: worktree)).fittingSize
        #expect(inline.width > 0)
        let widthGap = abs(inline.width - toolbar.width)
        let heightGap = abs(inline.height - toolbar.height)
        #expect(widthGap < 0.5)
        #expect(heightGap < 0.5)
    }

    /// The title column is one line with or without a project: a project
    /// leaves it as tall as a scratch space's, and widens it by the project
    /// name's menu and one spacing.
    @Test func theTitleColumnIsOneLine() {
        withTestDefaults("TabsInToolbarTests.titleColumn") { defaults in
            let state = AppState(userDefaults: defaults)
            let repo = Repo(path: "/tmp/acme", displayName: "acme")
            let worktree = Self.titleWorktree(repoID: repo.id)
            let withProject = NSHostingView(rootView: WorktreeTitleColumn(
                appState: state, worktree: worktree, repoName: "acme")).fittingSize
            let scratch = NSHostingView(rootView: WorktreeTitleColumn(
                appState: state, worktree: worktree, repoName: nil)).fittingSize
            let projectMenu = NSHostingView(rootView: WorktreeTitleMenus.repoMenu(
                appState: state, worktree: worktree
            ) {
                Text("acme")
                    .font(WorktreeTitleMetrics.projectFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }).fittingSize
            #expect(scratch.height > 0)
            #expect(projectMenu.width > 0)
            #expect(withProject.height == scratch.height)
            let added = withProject.width - scratch.width
            let expectedAdded = projectMenu.width + WorktreeTitleMetrics.spacing
            let addedGap = abs(added - expectedAdded)
            #expect(addedGap < 2, "a project added \(added) pt, expected \(expectedAdded) pt")
        }
    }

    /// The row's title column and the toolbar's title item draw the same
    /// line, with a project and without: the same width and height.
    @Test func theRowsTitleColumnMatchesTheToolbarsTitle() {
        withTestDefaults("TabsInToolbarTests.titleMatchesToolbar") { defaults in
            let state = AppState(userDefaults: defaults)
            let repo = Repo(path: "/tmp/acme", displayName: "acme")
            let worktree = Self.titleWorktree(repoID: repo.id)
            for repoName in ["acme", nil] as [String?] {
                let row = NSHostingView(rootView: WorktreeTitleColumn(
                    appState: state, worktree: worktree, repoName: repoName)).fittingSize
                let toolbar = NSHostingView(rootView: WorktreeTitleView(
                    appState: state, worktree: worktree, repoName: repoName)).fittingSize
                #expect(row.width > 0)
                let widthGap = abs(row.width - toolbar.width)
                let heightGap = abs(row.height - toolbar.height)
                #expect(widthGap < 1, "row \(row), toolbar \(toolbar), project \(repoName ?? "none")")
                #expect(heightGap < 1, "row \(row), toolbar \(toolbar), project \(repoName ?? "none")")
            }
        }
    }

    // MARK: - The shared choice

    /// Every kind of selection gives one answer to "does the detail area
    /// draw a worktree's tab bar": only one worktree the app finds does.
    @Test func onlyOneFoundWorktreeShowsATabBar() {
        let id = UUID()
        let found: (UUID) -> Bool = { _ in true }
        let missing: (UUID) -> Bool = { _ in false }
        func other(_ content: MainDetailContent) -> () -> MainDetailContent { { content } }

        let remote = MainDetailContent.resolve(targetTab: .remote, other: other(.worktree(id)))
        #expect(remote == .remoteSession)
        let remoteShows = remote.showsWorktreeTabBar(worktreeExists: found)
        #expect(remoteShows == false)
        let desk = MainDetailContent.resolve(targetTab: .providerDesk, other: other(.worktree(id)))
        #expect(desk == .providerDesk)
        let deskShows = desk.showsWorktreeTabBar(worktreeExists: found)
        #expect(deskShows == false)

        let cases: [(MainDetailContent, Bool)] = [
            (.disconnected, false), (.scratchSection, false), (.noRepositories, false),
            (.repo(id), false), (.nothingSelected, false), (.multipleWorktrees, false),
            (.worktree(id), true),
        ]
        for (content, shows) in cases {
            let resolved = MainDetailContent.resolve(targetTab: .other, other: other(content))
            #expect(resolved == content)
            let resolvedShows = resolved.showsWorktreeTabBar(worktreeExists: found)
            #expect(resolvedShows == shows)
        }
        let notFound = MainDetailContent.worktree(id).showsWorktreeTabBar(worktreeExists: missing)
        #expect(notFound == false)

        let order = MainDetailContent.otherTab(
            isConnected: true, scratchSectionSelected: false, hasRepositories: true,
            selectedRepoID: id, selectedWorktreeIDs: [UUID()])
        #expect(order == .repo(id))
        let disconnected = MainDetailContent.otherTab(
            isConnected: false, scratchSectionSelected: true, hasRepositories: true,
            selectedRepoID: nil, selectedWorktreeIDs: [id])
        #expect(disconnected == .disconnected)
        let several = MainDetailContent.worktreeSelection([id, UUID()])
        #expect(several == .multipleWorktrees)
        let one = MainDetailContent.worktreeSelection([id])
        #expect(one == .worktree(id))
        let none = MainDetailContent.worktreeSelection([])
        #expect(none == .nothingSelected)
    }

    /// The toolbar's `panesDrawTopRow` and the panes' agree for every kind of
    /// selection, and both are on exactly when the detail area shows
    /// `SingleWorktreeView` for a worktree it finds.
    @Test func theToolbarAndTheDetailAreaAgree() {
        for scenario in Scenario.allCases {
            withTestDefaults("TabsInToolbarTests.agree") { defaults in
                let state = Self.state(defaults: defaults)
                scenario.apply(to: state)

                let toolbar = MainToolbarSnapshot.make(from: state)
                    .layoutState(sidebarCollapsed: false).panesDrawTopRow
                let panes = state.showsWorktreeTabBar
                var drawsSingleWorktree = false
                if case .worktree(let id) = MainDetailContent.current(in: state) {
                    drawsSingleWorktree = state.findWorktree(id: id) != nil
                }
                #expect(toolbar == panes, "\(scenario)")
                #expect(panes == drawsSingleWorktree, "\(scenario)")
                let tabBarScenario = scenario == .oneWorktree
                #expect(drawsSingleWorktree == tabBarScenario, "\(scenario)")
            }
        }
    }

    /// The kinds of selection the detail area tells apart.
    enum Scenario: CaseIterable {
        case disconnected, nothingSelected, repo, scratchSection
        case oneWorktree, missingWorktree, twoWorktrees
        case remoteSession, providerDesk

        @MainActor
        func apply(to state: AppState) {
            let worktrees = state.worktrees.values.flatMap { $0 }
            if self != .disconnected {
                state.isConnected = true
            }
            switch self {
            case .disconnected:
                state.selectedWorktreeIDs = [worktrees[0].id]
            case .nothingSelected:
                break
            case .repo:
                state.selectedRepoID = state.repos[0].id
            case .scratchSection:
                state.selectedScratchSection = true
            case .oneWorktree:
                state.selectedWorktreeIDs = [worktrees[0].id]
            case .missingWorktree:
                state.selectedWorktreeIDs = [UUID()]
            case .twoWorktrees:
                state.selectedWorktreeIDs = Set(worktrees.map(\.id))
            case .remoteSession:
                state.selectedRemoteSession = RemoteSessionSelection(provider: "acme", sessionID: "s1")
            case .providerDesk:
                state.selectedRemoteProvider = "acme"
            }
        }
    }

    // MARK: - Toolbar items

    /// With a worktree's tab bar showing, the list ends at the tracking
    /// separator, with the sidebar shown and collapsed.
    @Test func withATabBarTheListEndsAtTheSeparator() {
        let shown = MainToolbarLayout.identifiers(
            for: Self.snapshot(tabBar: true).layoutState(sidebarCollapsed: false))
        let expectedShown: [NSToolbarItem.Identifier] = [
            ItemID.leadingButtons, .flexibleSpace, ItemID.repoFilter, ItemID.sidebarSeparator,
        ]
        #expect(shown == expectedShown)
        let collapsed = MainToolbarLayout.identifiers(
            for: Self.snapshot(tabBar: true).layoutState(sidebarCollapsed: true))
        let expectedCollapsed: [NSToolbarItem.Identifier] = [ItemID.leadingButtons, ItemID.sidebarSeparator]
        #expect(collapsed == expectedCollapsed)
    }

    /// On any other page, the title cluster follows the tracking separator.
    @Test func elsewhereTheTitleFollowsTheSeparator() {
        for collapsed in [false, true] {
            let list = MainToolbarLayout.identifiers(
                for: Self.snapshot(tabBar: false).layoutState(sidebarCollapsed: collapsed))
            let separator = list.firstIndex(of: ItemID.sidebarSeparator) ?? -1
            let next = list.dropFirst(separator + 1).first
            #expect(next == ItemID.title)
        }
    }

    /// A remote session's page draws no tab bar, so its Transcript, Reconnect
    /// and Stop follow the title and the flexible space, with the sidebar
    /// shown and collapsed.
    @Test func aRemoteSessionKeepsItsButtonsAfterTheTitle() {
        var snapshot = Self.snapshot(tabBar: false)
        snapshot.remote = RemotePresentation(
            showsTranscript: true, showsReconnect: true, showsStop: true, transcriptShown: false)
        let afterTheSeparator: [NSToolbarItem.Identifier] = [
            ItemID.title, .flexibleSpace, ItemID.remoteTranscript, ItemID.remoteReconnect, ItemID.remoteStop,
        ]
        for collapsed in [false, true] {
            let list = MainToolbarLayout.identifiers(for: snapshot.layoutState(sidebarCollapsed: collapsed))
            let separator = list.firstIndex(of: ItemID.sidebarSeparator) ?? -1
            let rest = Array(list.dropFirst(separator + 1))
            #expect(rest == afterTheSeparator)
        }
    }

    /// The snapshot reads whether a worktree's tab bar shows from the shared
    /// choice.
    @Test func theSnapshotReadsTheTabBar() {
        withTestDefaults("TabsInToolbarTests.snapshot") { defaults in
            let state = Self.state(defaults: defaults)
            let unselected = MainToolbarSnapshot.make(from: state)
            #expect(unselected.showsWorktreeTabBar == false)
            let unselectedDraws = unselected.layoutState(sidebarCollapsed: false).panesDrawTopRow
            #expect(unselectedDraws == false)

            state.isConnected = true
            let worktreeID = state.worktrees.values.flatMap { $0 }[0].id
            state.selectedWorktreeIDs = [worktreeID]
            let selected = MainToolbarSnapshot.make(from: state)
            #expect(selected.showsWorktreeTabBar)
            #expect(selected != unselected)
            let selectedDraws = selected.layoutState(sidebarCollapsed: false).panesDrawTopRow
            #expect(selectedDraws)
        }
    }

    // MARK: - Helpers

    /// An `AppState` on `defaults` holding one repo with two worktrees.
    private static func state(defaults: UserDefaults) -> AppState {
        let state = AppState(userDefaults: defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        state.repos = [repo]
        state.worktrees = [repo.id: [
            Worktree(repoID: repo.id, name: "feature", displayName: "feature", branch: "feature",
                     path: "/tmp/acme-feature", tmuxServer: "acme"),
            Worktree(repoID: repo.id, name: "fix", displayName: "fix", branch: "fix",
                     path: "/tmp/acme-fix", tmuxServer: "acme"),
        ]]
        return state
    }

    /// The worktree the title-column tests name, in the repo `repoID`.
    private static func titleWorktree(repoID: UUID) -> Worktree {
        Worktree(
            repoID: repoID, name: "feature", displayName: "feature", branch: "feature",
            path: "/tmp/acme-feature", tmuxServer: "acme")
    }

    private static func filter() -> RepoFilterPresentation {
        RepoFilterPresentation(
            options: [.init(id: nil, title: "All Repos")], selected: nil, selectedIsKnown: true,
            hiddenRepoCount: 0, showsHiddenRepos: false)
    }

    private static func snapshot(tabBar: Bool) -> MainToolbarSnapshot {
        MainToolbarSnapshot(
            canGoBack: false, canGoForward: false, filter: filter(),
            remote: nil, title: "feature", showsWorktreeTabBar: tabBar)
    }
}
