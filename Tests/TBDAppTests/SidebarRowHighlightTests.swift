import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// The geometry and colour are pure functions, checked for the shipped shape
// and for the inset rounded one without flipping a constant. The header and
// dock behaviour runs through the outline harness, mounted offscreen; the
// pointer is driven through the hover tracker's own entry points. The pixels
// each state paints are `SidebarCellTests.rowViewDrawsHighlightForEachState`'s.

/// The native sidebar's row highlight: one shape for every row, the alpha each
/// hover and selection state draws at in each appearance, selected runs that
/// merge into one band, content that clears the highlight's edges, and the
/// selected and hovered repo and provider headers.
@MainActor
@Suite("Sidebar row highlight")
struct SidebarRowHighlightTests {
    static let bounds = NSRect(x: 0, y: 0, width: 300, height: 28)

    // MARK: Shape

    /// Rows at every depth, a header and a dock row share one highlight, edge
    /// to edge, while their guide lines keep their depths.
    @Test func everyRowSharesOneHighlightRect() {
        let rowInset = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: false)
        typealias Configuration = SidebarRowView.Configuration
        let dockInset = DockTableController.rowInset
        typealias Guide = SidebarGuideLine.Guide
        let child = [Guide(level: 0, role: .last)]
        let grandchild = [Guide(level: 0, role: .passing), Guide(level: 1, role: .last)]
        let inGroup = [Guide(level: 1, role: .last)]
        let configurations: [(label: String, configuration: Configuration, guides: [CGFloat])] = [
            ("depth 0", Configuration(contentOrigin: rowInset), []),
            ("depth 1", Configuration(contentOrigin: rowInset, level: 1, guides: child), [26]),
            ("depth 2", Configuration(contentOrigin: rowInset, level: 2, guides: grandchild), [26, 42]),
            ("depth 2 in a group", Configuration(contentOrigin: rowInset, level: 2, guides: inGroup), [42]),
            ("selected header", Configuration(contentOrigin: rowInset, isSelectedByModel: true), []),
            ("dock depth 2", Configuration(contentOrigin: dockInset, level: 2, guides: grandchild), [26, 42]),
        ]
        let edgeToEdge = NSRect(x: 0, y: 0, width: 300, height: 28)
        for (label, configuration, guides) in configurations {
            let rowView = SidebarRowView(frame: Self.bounds)
            rowView.configuration = configuration
            let rect = rowView.highlightRect
            #expect(rect == edgeToEdge, "The \(label) row's highlight is \(rect)")
            let lines = rowView.guideLineXs
            #expect(lines == guides, "The \(label) row's guide lines are at \(lines)")
        }
        #expect(SidebarRowHighlight.horizontalInset == 0)
        #expect(SidebarRowHighlight.cornerRadius == 0)

        // The inset shape reads only the bounds too.
        let inset = SidebarRowHighlight.highlightRect(in: Self.bounds, inset: 8)
        let insetExpected = NSRect(x: 8, y: 0, width: 284, height: 28)
        #expect(inset == insetExpected)
    }

    /// Content starts at least `minimumContentGap` inside the highlight's
    /// leading edge, edge to edge and inset; inset, the cells also end that
    /// far inside its trailing edge. Edge to edge moves nothing, and an inset
    /// moves headers and rows together.
    @Test func contentClearsTheHighlightsEdges() {
        let gap = SidebarRowHighlight.minimumContentGap
        #expect(gap == 6)
        for inset: CGFloat in [SidebarRowHighlight.horizontalInset, 8] {
            let highlight = SidebarRowHighlight.highlightRect(in: Self.bounds, inset: inset)
            let origins: [(label: String, x: CGFloat)] = [
                ("header", SidebarNativeMetrics.headerInset(highlightInset: inset)),
                ("row, chevron after the title",
                 SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: false, highlightInset: inset)),
                ("row, chevron before the title",
                 SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: true, highlightInset: inset)),
            ]
            for (label, x) in origins {
                #expect(highlight.minX + gap <= x, "At inset \(inset) the \(label) content starts at \(x)")
            }
            guard inset > 0 else { continue }
            let cellEnd = Self.bounds.maxX - SidebarNativeMetrics.trailingCellInset(highlightInset: inset)
            #expect(cellEnd <= highlight.maxX - gap, "At inset \(inset) a cell ends at \(cellEnd)")
        }
        // The shipped shape: the dock's rows too.
        let shippedEdge = SidebarRowHighlight.horizontalInset + gap
        #expect(shippedEdge <= DockTableController.rowInset)

        // Edge to edge, every column stays where it is.
        #expect(SidebarNativeMetrics.headerContentInset == 6)
        #expect(SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: false) == 20)
        #expect(SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: true) == 40)
        #expect(DockTableController.rowInset == 20)
        #expect(SidebarNativeMetrics.trailingCellInset() == 0)
        // Inset 8, headers and rows move 8 together; cells end 14 short.
        #expect(SidebarNativeMetrics.headerInset(highlightInset: 8) == 14)
        #expect(SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: false, highlightInset: 8) == 28)
        #expect(SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: true, highlightInset: 8) == 48)
        #expect(SidebarNativeMetrics.trailingCellInset(highlightInset: 8) == 14)
    }

    /// A selected row rounds only the ends no selected row adjoins; an
    /// unselected one is its own shape.
    @Test func selectedRunsRoundOnlyTheirOuterEnds() {
        let alone = SidebarRowHighlight.roundedEnds(isSelected: true, isPreviousRowSelected: false,
                                                    isNextRowSelected: false)
        let first = SidebarRowHighlight.roundedEnds(isSelected: true, isPreviousRowSelected: false,
                                                    isNextRowSelected: true)
        let middle = SidebarRowHighlight.roundedEnds(isSelected: true, isPreviousRowSelected: true,
                                                     isNextRowSelected: true)
        let last = SidebarRowHighlight.roundedEnds(isSelected: true, isPreviousRowSelected: true,
                                                   isNextRowSelected: false)
        let hoveredBesideSelection = SidebarRowHighlight.roundedEnds(
            isSelected: false, isPreviousRowSelected: true, isNextRowSelected: true)
        #expect(alone == .both)
        #expect(first == .top)
        #expect(middle.isEmpty)
        #expect(last == .bottom)
        #expect(hoveredBesideSelection == .both)
    }

    /// The path rounds exactly the ends it is asked to, with the top at
    /// `minY` in a flipped row view; at radius 0 it is the plain rectangle.
    @Test func pathRoundsOnlyTheNamedEnds() {
        // Whether each corner is filled: top left, top right, bottom left,
        // bottom right.
        let alone = Self.filledCorners(.both)
        let first = Self.filledCorners(.top)
        let middle = Self.filledCorners([])
        let last = Self.filledCorners(.bottom)
        let square = Self.filledCorners(.both, radius: 0)
        let noCorner = [false, false, false, false]
        let squareBottom = [false, false, true, true]
        let squareTop = [true, true, false, false]
        let everyCorner = [true, true, true, true]
        #expect(alone == noCorner)
        #expect(first == squareBottom)
        #expect(middle == everyCorner)
        #expect(last == squareTop)
        #expect(square == everyCorner)
        let squareBounds = SidebarRowHighlight.path(in: Self.bounds, radius: 0, roundedEnds: .both,
                                                    isFlipped: true).bounds
        #expect(squareBounds == Self.bounds)
    }

    /// Whether the path for `ends` fills a point 1 pt inside each corner of
    /// `bounds`: top left, top right, bottom left, bottom right, with the top
    /// at `minY` as in a row view.
    static func filledCorners(_ ends: SidebarRowHighlight.RoundedEnds, radius: CGFloat = 6) -> [Bool] {
        let path = SidebarRowHighlight.path(in: bounds, radius: radius, roundedEnds: ends, isFlipped: true)
        let points = [NSPoint(x: 1, y: 1), NSPoint(x: 299, y: 1), NSPoint(x: 1, y: 27), NSPoint(x: 299, y: 27)]
        return points.map { path.contains($0) }
    }

    // MARK: Colour

    /// The alpha for each state, in each appearance: none, hovered, selected,
    /// selected and hovered.
    @Test func alphaFollowsStateAndAppearance() {
        let states: [(selected: Bool, hovered: Bool)] = [(false, false), (false, true), (true, false), (true, true)]
        let light = states.map { SidebarRowHighlight.alpha(isSelected: $0.selected, isHovered: $0.hovered, isDark: false) }
        let dark = states.map { SidebarRowHighlight.alpha(isSelected: $0.selected, isHovered: $0.hovered, isDark: true) }
        let expectedLight: [CGFloat?] = [nil, 0.075, 0.20, 0.28]
        let expectedDark: [CGFloat?] = [nil, 0.11, 0.20, 0.29]
        #expect(light == expectedLight)
        #expect(dark == expectedDark)
    }

    /// The row view draws selected when the list selects it or its model
    /// does, darkens only while hovered, and takes the alpha of its own
    /// appearance.
    @Test func rowViewResolvesItsState() {
        let rowView = SidebarRowView(frame: Self.bounds)
        rowView.appearance = NSAppearance(named: .aqua)
        #expect(!rowView.drawsSelected)
        let none = rowView.highlightAlpha
        #expect(none == nil)

        rowView.isSelected = true
        #expect(rowView.drawsSelected, "The list's selection draws")
        let listSelected = rowView.highlightAlpha
        #expect(listSelected == SidebarRowHighlight.light.selected)

        rowView.isSelected = false
        rowView.configuration.isSelectedByModel = true
        #expect(rowView.drawsSelected, "A header its model selects draws")
        rowView.configuration.isHovered = true
        let selectedHovered = rowView.highlightAlpha
        #expect(selectedHovered == SidebarRowHighlight.light.selectedHovered)

        rowView.configuration.isSelectedByModel = false
        rowView.appearance = NSAppearance(named: .darkAqua)
        #expect(!rowView.drawsSelected)
        let darkHovered = rowView.highlightAlpha
        #expect(darkHovered == SidebarRowHighlight.dark.hovered)
    }

    /// A group header's click only opens or closes it, so it draws no hover;
    /// every row whose click selects something does.
    @Test func groupHeadersDrawNoHover() {
        let header = SectionHeaderModel(title: "acme", isExpanded: true, isHidden: false, isMissing: false,
                                        isSelected: false)
        #expect(!SidebarOutlineController.showsHoverHighlight(.groupHeader(SidebarCellTests.group())))
        #expect(SidebarOutlineController.showsHoverHighlight(.repoHeader(header)))
        #expect(SidebarOutlineController.showsHoverHighlight(.scratchHeader(header)))
        #expect(SidebarOutlineController.showsHoverHighlight(.scratchPrompt))
        #expect(SidebarOutlineController.showsHoverHighlight(.worktree(SidebarCellTests.worktree(name: "work"))))
    }

    // MARK: Headers

    /// `selectedRepoID` reaches the repo header's row view through a rebuild,
    /// on the view the outline already shows; the pointer's row draws the
    /// hover, and nothing else does.
    @Test func repoHeaderDrawsSelectionAndHover() throws {
        let h = OutlineHarness("highlight.repoHeader")
        defer { h.tearDown() }
        let acme = Repo(path: "/tmp/acme", displayName: "acme")
        let other = Repo(path: "/tmp/acme-other", displayName: "other")
        let work = SidebarOutlineControllerTests.row("work", acme)
        let elsewhere = SidebarOutlineControllerTests.row("elsewhere", other)
        h.state.repos = [acme, other]
        h.state.worktrees = [acme.id: [work], other.id: [elsewhere]]
        h.mount()
        let header = SidebarNodeID.repoHeader(acme.id)
        let otherHeader = SidebarNodeID.repoHeader(other.id)
        let row = SidebarNodeID.worktree(work.id)
        let names = [work.id: "work", elsewhere.id: "elsewhere"]

        // No repo selected: no header draws selected.
        let headerView = try #require(h.rowView(header, make: true) as? SidebarRowView, h.evidence(names))
        let otherView = try #require(h.rowView(otherHeader, make: true) as? SidebarRowView, h.evidence(names))
        #expect(!headerView.configuration.isSelectedByModel)
        #expect(!headerView.drawsSelected)
        #expect(!otherView.configuration.isSelectedByModel)

        // Selecting the repo reconfigures its header's view in place.
        h.state.selectedRepoID = acme.id
        h.controller.flushPendingRebuild()
        let selected = try #require(h.rowView(header, make: false) as? SidebarRowView, h.evidence(names))
        #expect(selected === headerView, "The header's view was replaced rather than reconfigured")
        #expect(selected.configuration.isSelectedByModel, h.rowViewEvidence(header, captured: headerView, names))
        #expect(selected.drawsSelected)
        #expect(!otherView.configuration.isSelectedByModel, "Another repo's header draws selected")

        // Selecting the other repo moves it.
        h.state.selectedRepoID = other.id
        h.controller.flushPendingRebuild()
        #expect(!headerView.configuration.isSelectedByModel, h.rowViewEvidence(header, captured: headerView, names))
        #expect(otherView.configuration.isSelectedByModel, h.rowViewEvidence(otherHeader, captured: otherView, names))
        h.state.selectedRepoID = nil
        h.controller.flushPendingRebuild()
        #expect(!otherView.configuration.isSelectedByModel)

        // Hover follows the pointer's row, header or not.
        let tracker = try #require(h.controller.hoverTracker)
        let rowView = try #require(h.rowView(row, make: true) as? SidebarRowView, h.evidence(names))
        let headerPoint = try #require(SidebarInteractionTests.windowPoint(of: header, in: h))
        let rowPoint = try #require(SidebarInteractionTests.windowPoint(of: row, in: h))
        tracker.pointerMoved(toWindowPoint: headerPoint)
        try #require(h.controller.hoverState.row == header, h.evidence(names))
        #expect(headerView.configuration.isHovered)
        #expect(!rowView.configuration.isHovered)
        #expect(!otherView.configuration.isHovered)

        tracker.pointerMoved(toWindowPoint: rowPoint)
        try #require(h.controller.hoverState.row == row, h.evidence(names))
        #expect(!headerView.configuration.isHovered, "The header kept its hover after the pointer left it")
        #expect(rowView.configuration.isHovered)

        tracker.pointerExited()
        #expect(!headerView.configuration.isHovered)
        #expect(!rowView.configuration.isHovered)
    }

    /// `selectedRemoteProvider` draws its provider header selected, through
    /// the same path.
    @Test func providerHeaderDrawsSelectedWhileItsProviderIs() throws {
        let h = OutlineHarness("highlight.providerHeader")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [SidebarOutlineControllerTests.row("work", repo)]]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.state.remoteSessions = [SidebarGroupFixtures.session("lane")]
        h.mount()
        let header = SidebarNodeID.providerHeader("acme")

        let headerView = try #require(h.rowView(header, make: true) as? SidebarRowView, h.evidence())
        #expect(!headerView.configuration.isSelectedByModel)

        h.state.selectRemoteProvider("acme")
        h.controller.flushPendingRebuild()
        #expect(headerView.configuration.isSelectedByModel, h.rowViewEvidence(header, captured: headerView))
        #expect(headerView.drawsSelected)

        h.state.selectedRemoteProvider = nil
        h.controller.flushPendingRebuild()
        #expect(!headerView.configuration.isSelectedByModel, h.rowViewEvidence(header, captured: headerView))
    }
}
