import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1 for the pure parts — the style, the line geometry and the two
// active-ancestor rules — checked directly. The outline's and the dock's
// wiring runs through controllers mounted offscreen: the pointer is driven
// through the hover tracker's own entry points, the selection through
// `AppState` and through the outline's `selectRowIndexes`, as a click lands.

/// The native sidebar's guide lines: hairlines at rest, the focused group's
/// line at full strength, and the accent colour over a highlight.
@MainActor
@Suite("Sidebar guide lines")
struct SidebarGuideLineTests {
    typealias Style = SidebarGuideLine.Style
    typealias Segment = SidebarGuideLine.Segment

    static let bounds = NSRect(x: 0, y: 0, width: 300, height: 28)

    // MARK: Style

    /// Every strength and width the lines draw with.
    @Test func shippedValues() {
        let expected = SidebarGuideLine.Alphas(rest: 0.12, active: 0.25, restOnHighlight: 0.30,
                                               activeOnHighlight: 0.55)
        #expect(SidebarGuideLine.alphas == expected)
        #expect(SidebarGuideLine.restPixelWidth == 1)
        #expect(SidebarGuideLine.activeWidth == 1)
        #expect(SidebarGuideLine.activeOnHighlightPixelWidth == 1)
        #expect(SidebarGuideLine.defaultBackingScale == 2)
    }

    /// Rest and active, on a plain row and on a highlighted one: grey, then
    /// the accent colour, each at its own alpha; a hairline at rest, a point
    /// when active on a plain row, a hairline when active on a highlighted one.
    @Test func styleForEachState() {
        let states: [(active: Bool, highlight: Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        let retina = states.map {
            SidebarGuideLine.style(isActive: $0.active, isOnHighlight: $0.highlight, backingScale: 2)
        }
        let expectedRetina = [
            Style(color: .secondaryLabel, alpha: 0.12, width: 0.5),
            Style(color: .secondaryLabel, alpha: 0.25, width: 1),
            Style(color: .accent, alpha: 0.30, width: 0.5),
            Style(color: .accent, alpha: 0.55, width: 0.5),
        ]
        #expect(retina == expectedRetina)

        // At 1x the hairline is a whole point; the active line stays one.
        let standard = states.map {
            SidebarGuideLine.style(isActive: $0.active, isOnHighlight: $0.highlight, backingScale: 1)
        }
        let expectedStandard = [
            Style(color: .secondaryLabel, alpha: 0.12, width: 1),
            Style(color: .secondaryLabel, alpha: 0.25, width: 1),
            Style(color: .accent, alpha: 0.30, width: 1),
            Style(color: .accent, alpha: 0.55, width: 1),
        ]
        #expect(standard == expectedStandard)
    }

    /// A resting line is one device pixel wide at each scale, and a scale no
    /// window or screen supplied reads as 2x.
    @Test func restingLineIsOneDevicePixel() {
        let scales: [CGFloat] = [1, 2, 0]
        let widths = scales.map {
            SidebarGuideLine.style(isActive: false, isOnHighlight: false, backingScale: $0).width
        }
        let expected: [CGFloat] = [1, 0.5, 0.5]
        #expect(widths == expected)
    }

    // MARK: Lines

    /// Each line runs the row's full height from its x, so a whole-point x
    /// and a whole-pixel width cover whole pixels; an x off the pixel grid
    /// moves left onto it rather than straddling two pixels.
    @Test func linesCoverWholeDevicePixels() {
        let rest = SidebarGuideLine.style(isActive: false, isOnHighlight: false, backingScale: 2)
        let active = SidebarGuideLine.style(isActive: true, isOnHighlight: false, backingScale: 2)
        let segments = SidebarGuideLine.segments(xs: [28, 44], active: [1], gap: nil, isOnHighlight: false,
                                                 in: Self.bounds, backingScale: 2)
        let expected = [
            Segment(rect: NSRect(x: 28, y: 0, width: 0.5, height: 28), style: rest),
            Segment(rect: NSRect(x: 44, y: 0, width: 1, height: 28), style: active),
        ]
        #expect(segments == expected)
        let pixelEdges = segments.flatMap { [$0.rect.minX * 2, $0.rect.maxX * 2] }
        let wholeEdges = pixelEdges.map { $0.rounded() }
        #expect(pixelEdges == wholeEdges, "A line edge falls inside a device pixel: \(pixelEdges)")

        let offGridRetina = SidebarGuideLine.segments(xs: [28.75], active: [], gap: nil, isOnHighlight: false,
                                                      in: Self.bounds, backingScale: 2)
        let offGridStandard = SidebarGuideLine.segments(xs: [28.75], active: [], gap: nil, isOnHighlight: false,
                                                        in: Self.bounds, backingScale: 1)
        let retinaRects = offGridRetina.map(\.rect)
        let standardRects = offGridStandard.map(\.rect)
        let expectedRetina = [NSRect(x: 28.5, y: 0, width: 0.5, height: 28)]
        let expectedStandard = [NSRect(x: 28, y: 0, width: 1, height: 28)]
        #expect(retinaRects == expectedRetina)
        #expect(standardRects == expectedStandard)
    }

    /// An active line on a highlighted row is one device pixel wide: 0.5 pt
    /// at 2x, whole-pixel aligned; a plain row's active line stays 1 pt.
    @Test func activeLineOnHighlightIsAHairline() {
        let activeAccent = SidebarGuideLine.style(isActive: true, isOnHighlight: true, backingScale: 2)
        let restAccent = SidebarGuideLine.style(isActive: false, isOnHighlight: true, backingScale: 2)
        let segments = SidebarGuideLine.segments(xs: [28, 44], active: [1], gap: nil, isOnHighlight: true,
                                                 in: Self.bounds, backingScale: 2)
        let expected = [
            Segment(rect: NSRect(x: 28, y: 0, width: 0.5, height: 28), style: restAccent),
            Segment(rect: NSRect(x: 44, y: 0, width: 0.5, height: 28), style: activeAccent),
        ]
        #expect(segments == expected)
    }

    /// The gap leaves out its one line, and `Alphas.none` leaves out every
    /// line: the comparison without guide lines.
    @Test func gapAndNoneLeaveLinesOut() {
        let gapped = SidebarGuideLine.segments(xs: [28, 44], active: [0, 1], gap: 1, isOnHighlight: false,
                                               in: Self.bounds, backingScale: 2)
        let gappedXs = gapped.map(\.rect.minX)
        let outermostOnly: [CGFloat] = [28]
        #expect(gappedXs == outermostOnly)

        let none = SidebarGuideLine.segments(xs: [28, 44], active: [0], gap: nil, isOnHighlight: true,
                                             in: Self.bounds, backingScale: 2, alphas: .none)
        #expect(none.isEmpty)
    }

    /// The indices of a row's line owners that are active.
    @Test func activeIndicesMarkTheActiveOwners() {
        let ancestors = ["outer", "middle", "inner"]
        let both = SidebarGuideLine.activeIndices(of: ancestors, active: ["outer", "inner", "elsewhere"])
        let neither = SidebarGuideLine.activeIndices(of: ancestors, active: ["elsewhere"])
        let empty = SidebarGuideLine.activeIndices(of: ancestors, active: [])
        let outerAndInner: IndexSet = [0, 2]
        #expect(both == outerAndInner)
        #expect(neither.isEmpty)
        #expect(empty.isEmpty)
    }

    /// The row view draws grey on a plain row and the nest target, accent on
    /// a hovered or selected one, the active line at full strength, and
    /// breaks the nearest ancestor's line for the pin.
    @Test func rowViewStylesItsLines() {
        let rowView = SidebarRowView(frame: Self.bounds)
        rowView.appearance = NSAppearance(named: .aqua)
        let rowInset = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: false)
        let base = SidebarRowView.Configuration(contentOrigin: rowInset, guideCount: 2, activeGuides: [1])
        let rest = SidebarGuideLine.style(isActive: false, isOnHighlight: false, backingScale: 2)
        let active = SidebarGuideLine.style(isActive: true, isOnHighlight: false, backingScale: 2)
        let restAccent = SidebarGuideLine.style(isActive: false, isOnHighlight: true, backingScale: 2)
        let activeAccent = SidebarGuideLine.style(isActive: true, isOnHighlight: true, backingScale: 2)
        let grey = [rest, active]
        let accent = [restAccent, activeAccent]

        rowView.configuration = base
        let plainXs = rowView.guideSegments(backingScale: 2).map(\.rect.minX)
        let expectedXs: [CGFloat] = [28, 44]
        #expect(plainXs == expectedXs)
        #expect(Self.styles(rowView) == grey, "A plain row draws grey lines")

        rowView.configuration.isHovered = true
        #expect(Self.styles(rowView) == accent, "A hovered row draws accent lines")

        rowView.configuration.isHovered = false
        rowView.configuration.isSelectedByModel = true
        #expect(Self.styles(rowView) == accent, "A row its model selects draws accent lines")

        rowView.configuration.isSelectedByModel = false
        rowView.isSelected = true
        #expect(Self.styles(rowView) == accent, "A row the list selects draws accent lines")

        rowView.isSelected = false
        rowView.configuration.isNestTarget = true
        #expect(Self.styles(rowView) == grey, "The nest target keeps grey lines")

        rowView.configuration = base
        rowView.configuration.showsPinGap = true
        let gappedXs = rowView.guideSegments(backingScale: 2).map(\.rect.minX)
        let outermostOnly: [CGFloat] = [28]
        #expect(gappedXs == outermostOnly, "The pin breaks the nearest ancestor's line")

        let hidden = rowView.guideSegments(backingScale: 2, alphas: .none)
        #expect(hidden.isEmpty)
    }

    static func styles(_ rowView: SidebarRowView) -> [Style] {
        rowView.guideSegments(backingScale: 2).map(\.style)
    }

    // MARK: The outline's rule

    /// The tree in `activeAncestorRule`, by name.
    struct RuleTree {
        let tree: SidebarTree
        let ids: [String: SidebarNodeID]

        func id(_ name: String) -> SidebarNodeID { ids[name] ?? .scratchPrompt }
    }

    /// acme ▸ parent ▸ (first ▸ grandchild, second, Remote ▸ (remoteChild,
    /// session)); leaf; shelved ▸ collapsed group ▸ shelvedChild; outer ▸
    /// inner ▸ collapsed group ▸ deep.
    static func ruleTree() -> RuleTree {
        let names = ["parent", "first", "grandchild", "second", "remoteChild", "session", "leaf", "shelved",
                     "shelvedChild", "outer", "inner", "deep"]
        let uuids = Dictionary(uniqueKeysWithValues: names.enumerated().map { index, name in
            (name, SidebarTreeDiffTests.uuid(index + 1))
        })
        func uuid(_ name: String) -> UUID { uuids[name] ?? UUID() }
        func row(_ name: String, _ children: [SidebarNode] = []) -> SidebarNode {
            SidebarDropPolicyTests.row(uuid(name), home: nil, children)
        }
        let repoID = SidebarTreeDiffTests.uuid(100)
        let remote = SidebarGroupID(owner: .parent(uuid("parent")), kind: .remote)
        let shelf = SidebarGroupID(owner: .parent(uuid("shelved")), kind: .exited)
        let innerShelf = SidebarGroupID(owner: .parent(uuid("inner")), kind: .exited)
        let roots = [
            SidebarDropPolicyTests.repo(repoID, [
                row("parent", [
                    row("first", [row("grandchild")]),
                    row("second"),
                    SidebarDropPolicyTests.group(remote, [
                        row("remoteChild"), SidebarDropPolicyTests.session(uuid("session")),
                    ]),
                ]),
                row("leaf"),
                row("shelved", [Self.collapsedGroup(shelf, [row("shelvedChild")])]),
                row("outer", [row("inner", [Self.collapsedGroup(innerShelf, [row("deep")])])]),
            ]),
        ]
        var ids: [String: SidebarNodeID] = [:]
        for name in names {
            ids[name] = name == "session" ? .remoteSession(uuid(name)) : .worktree(uuid(name))
        }
        ids["repo"] = .repoHeader(repoID)
        ids["remoteGroup"] = .group(remote)
        return RuleTree(tree: SidebarTree(roots: roots), ids: ids)
    }

    static func collapsedGroup(_ id: SidebarGroupID, _ children: [SidebarNode]) -> SidebarNode {
        SidebarNode(id: .group(id), kind: .groupHeader(SidebarCellTests.group()), children: children,
                    isExpanded: false)
    }

    /// Each focus row's active ancestor: a parent showing worktree rows
    /// lights its own line, any other worktree row its nearest worktree
    /// ancestor's, and the rest nothing.
    @Test func activeAncestorRule() {
        let fixture = Self.ruleTree()
        let tree = fixture.tree
        func id(_ name: String) -> SidebarNodeID { fixture.id(name) }

        let focus = ["second", "grandchild", "first", "parent", "remoteChild", "leaf", "shelved", "inner",
                     "shelvedChild", "deep", "repo", "session", "remoteGroup"]
        let lit = focus.map { tree.activeGuideAncestor(of: id($0)) }
        let expected: [SidebarNodeID?] = [
            id("parent"), // a leaf lights its parent's line
            id("first"), // so does a grandchild
            id("first"), // a parent showing a child lights its own
            id("parent"), // ... at the top level too
            id("parent"), // a row in an expanded group lights its worktree parent's, past the group
            nil, // a top-level leaf lights nothing
            nil, // a top-level row whose only child sits in a collapsed group shows none, so nothing
            id("outer"), // a nested one lights its own parent's
            id("shelved"), // a hidden row's rule still names its parent; the set skips it
            id("inner"),
            nil, nil, nil, // a header, a remote session and a group header light nothing
        ]
        #expect(lit == expected)
        let unknown = tree.activeGuideAncestor(of: .worktree(SidebarTreeDiffTests.uuid(999)))
        #expect(unknown == nil)

        // The owners of each row's lines, outermost first, past groups.
        let grandchildOwners = tree.worktreeAncestors(of: id("grandchild"))
        let remoteChildOwners = tree.worktreeAncestors(of: id("remoteChild"))
        let deepOwners = tree.worktreeAncestors(of: id("deep"))
        let parentOwners = tree.worktreeAncestors(of: id("parent"))
        let expectedGrandchildOwners = [id("parent"), id("first")]
        let expectedRemoteChildOwners = [id("parent")]
        let expectedDeepOwners = [id("outer"), id("inner")]
        #expect(grandchildOwners == expectedGrandchildOwners)
        #expect(remoteChildOwners == expectedRemoteChildOwners)
        #expect(deepOwners == expectedDeepOwners)
        #expect(parentOwners.isEmpty)

        // The set skips a focus row the outline does not show.
        let shown = ["second", "grandchild", "shelvedChild", "deep", "session"].map(id)
        let active = tree.activeGuideAncestors(of: shown)
        let parentAndFirst: Set<SidebarNodeID> = [id("parent"), id("first")]
        #expect(active == parentAndFirst)
        #expect(tree.isShown(id("remoteChild")))
        #expect(!tree.isShown(id("shelvedChild")))
        #expect(!tree.isShown(.worktree(SidebarTreeDiffTests.uuid(999))))
    }

    // MARK: The outline

    /// parent ▸ (first ▸ grandchild, second); other, in one repo.
    struct OutlineFixture {
        let parent: Worktree
        let first: Worktree
        let grandchild: Worktree
        let second: Worktree
        let other: Worktree

        var rows: [SidebarNodeID] {
            [parent, first, grandchild, second, other].map { .worktree($0.id) }
        }

        var names: [UUID: String] {
            [parent.id: "parent", first.id: "first", grandchild.id: "grandchild", second.id: "second",
             other.id: "other"]
        }
    }

    static func mountOutline(_ h: OutlineHarness) -> OutlineFixture {
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = SidebarOutlineControllerTests.row("parent", repo, order: 0)
        let first = SidebarOutlineControllerTests.row("first", repo, parent: parent.id, order: 0)
        let grandchild = SidebarOutlineControllerTests.row("grandchild", repo, parent: first.id, order: 0)
        let second = SidebarOutlineControllerTests.row("second", repo, parent: parent.id, order: 1)
        let other = SidebarOutlineControllerTests.row("other", repo, order: 1)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [parent, first, grandchild, second, other]]
        h.controller.selectionModifiers = { [] }
        h.mount()
        return OutlineFixture(parent: parent, first: first, grandchild: grandchild, second: second, other: other)
    }

    /// Each row's active guide lines, in `ids` order.
    static func activeGuides(_ ids: [SidebarNodeID], in h: OutlineHarness) throws -> [IndexSet] {
        var result: [IndexSet] = []
        for id in ids {
            let view = try #require(h.rowView(id, make: true) as? SidebarRowView, "No row view for \(id)")
            result.append(view.configuration.activeGuides)
        }
        return result
    }

    // Each fixture row's active lines — parent, first, grandchild, second,
    // other — with nothing focused, with parent's group focused, and with
    // first's.
    static let noneActive: [IndexSet] = [[], [], [], [], []]
    static let parentGroupActive: [IndexSet] = [[], [0], [0], [0], []]
    static let firstGroupActive: [IndexSet] = [[], [], [1], [], []]

    /// Hovering a child lights its parent's line on every row of the
    /// parent's subtree and on no other; hovering the parent lights the same
    /// line; moving the pointer moves it, and leaving puts it out.
    @Test func hoverLightsTheHoveredRowsGroup() throws {
        let h = OutlineHarness("guides.hover")
        defer { h.tearDown() }
        let f = Self.mountOutline(h)
        let names = f.names
        var guideCounts: [Int] = []
        for id in f.rows {
            let view = try #require(h.rowView(id, make: true) as? SidebarRowView, h.evidence(names))
            guideCounts.append(view.configuration.guideCount)
        }
        let expectedCounts = [0, 1, 2, 1, 0]
        #expect(guideCounts == expectedCounts, h.evidence(names))

        // No pointer, no selection: every line at rest.
        let resting = try Self.activeGuides(f.rows, in: h)
        #expect(resting == Self.noneActive, h.evidence(names))
        #expect(h.controller.activeGuideAncestors.isEmpty)

        let tracker = try #require(h.controller.hoverTracker)
        let steps: [(hovered: Worktree, active: Set<SidebarNodeID>, lines: [IndexSet], label: String)] = [
            (f.second, [.worktree(f.parent.id)], Self.parentGroupActive, "a child lights its parent's line"),
            (f.parent, [.worktree(f.parent.id)], Self.parentGroupActive, "a parent lights the line down its children"),
            (f.first, [.worktree(f.first.id)], Self.firstGroupActive, "a nested parent lights its own"),
            (f.grandchild, [.worktree(f.first.id)], Self.firstGroupActive, "a grandchild lights its parent's"),
            (f.other, [], Self.noneActive, "a top-level leaf lights nothing"),
        ]
        for step in steps {
            let id = SidebarNodeID.worktree(step.hovered.id)
            let point = try #require(SidebarInteractionTests.windowPoint(of: id, in: h), h.evidence(names))
            tracker.pointerMoved(toWindowPoint: point)
            try #require(h.controller.hoverState.row == id, h.evidence(names))
            #expect(h.controller.activeGuideAncestors == step.active, "\(step.label): \(h.evidence(names).rawValue)")
            let lines = try Self.activeGuides(f.rows, in: h)
            #expect(lines == step.lines, "\(step.label): \(h.evidence(names).rawValue)")
        }

        // Back over a child, then out of the list: the line goes out.
        let secondPoint = try #require(SidebarInteractionTests.windowPoint(of: .worktree(f.second.id), in: h))
        tracker.pointerMoved(toWindowPoint: secondPoint)
        let relit = try Self.activeGuides(f.rows, in: h)
        #expect(relit == Self.parentGroupActive, h.evidence(names))
        tracker.pointerExited()
        #expect(h.controller.hoverState.row == nil)
        let exited = try Self.activeGuides(f.rows, in: h)
        #expect(exited == Self.noneActive, "A line stayed lit after the pointer left: \(h.evidence(names).rawValue)")
        #expect(h.controller.activeGuideAncestors.isEmpty)
    }

    /// A selected row lights its group's line with no pointer anywhere,
    /// whether `AppState` or a click selects it; a new selection moves the
    /// line; and hover and selection each light their own group at once.
    @Test func selectionLightsTheSelectedRowsGroup() throws {
        let h = OutlineHarness("guides.selection")
        defer { h.tearDown() }
        let f = Self.mountOutline(h)
        let names = f.names
        let resting = try Self.activeGuides(f.rows, in: h)
        #expect(resting == Self.noneActive, h.evidence(names))

        // Selected through `AppState`: the apply lights the line.
        h.state.selectedWorktreeIDs = [f.second.id]
        h.controller.flushPendingRebuild()
        try #require(h.controller.hoverState.row == nil)
        let secondSelected = try Self.activeGuides(f.rows, in: h)
        #expect(secondSelected == Self.parentGroupActive, h.evidence(names))
        let parentGroup: Set<SidebarNodeID> = [.worktree(f.parent.id)]
        #expect(h.controller.activeGuideAncestors == parentGroup, h.evidence(names))

        // The selected row draws its line in the accent colour; its sibling
        // keeps grey.
        let secondView = try #require(h.rowView(.worktree(f.second.id), make: true) as? SidebarRowView)
        let firstView = try #require(h.rowView(.worktree(f.first.id), make: true) as? SidebarRowView)
        let secondColors = secondView.guideSegments(backingScale: 2).map(\.style.color)
        let firstColors = firstView.guideSegments(backingScale: 2).map(\.style.color)
        let accent: [SidebarGuideLine.ColorRole] = [.accent]
        let grey: [SidebarGuideLine.ColorRole] = [.secondaryLabel]
        #expect(secondColors == accent, h.rowViewEvidence(.worktree(f.second.id), captured: secondView, names))
        #expect(firstColors == grey, h.rowViewEvidence(.worktree(f.first.id), captured: firstView, names))

        // A new selection moves the line.
        h.state.selectedWorktreeIDs = [f.grandchild.id]
        h.controller.flushPendingRebuild()
        let grandchildSelected = try Self.activeGuides(f.rows, in: h)
        #expect(grandchildSelected == Self.firstGroupActive, h.evidence(names))

        // A top-level leaf lights nothing.
        h.state.selectedWorktreeIDs = [f.other.id]
        h.controller.flushPendingRebuild()
        let otherSelected = try Self.activeGuides(f.rows, in: h)
        #expect(otherSelected == Self.noneActive, h.evidence(names))

        // A click lights it at once, before any rebuild runs.
        h.outline.selectRowIndexes(IndexSet(integer: h.row(.worktree(f.second.id))), byExtendingSelection: false)
        #expect(h.state.selectedWorktreeIDs == [f.second.id], h.evidence(names))
        let clicked = try Self.activeGuides(f.rows, in: h)
        #expect(clicked == Self.parentGroupActive, h.evidence(names))
        h.outline.selectRowIndexes(IndexSet(), byExtendingSelection: false)
        #expect(h.state.selectedWorktreeIDs.isEmpty, h.evidence(names))
        let cleared = try Self.activeGuides(f.rows, in: h)
        #expect(cleared == Self.noneActive, h.evidence(names))

        // A selected grandchild and a hovered sibling of its parent: the
        // grandchild's row carries both lit lines.
        h.state.selectedWorktreeIDs = [f.grandchild.id]
        h.controller.flushPendingRebuild()
        let tracker = try #require(h.controller.hoverTracker)
        let secondPoint = try #require(SidebarInteractionTests.windowPoint(of: .worktree(f.second.id), in: h))
        tracker.pointerMoved(toWindowPoint: secondPoint)
        try #require(h.controller.hoverState.row == .worktree(f.second.id), h.evidence(names))
        let both = try Self.activeGuides(f.rows, in: h)
        let bothActive: [IndexSet] = [[], [0], [0, 1], [0], []]
        #expect(both == bothActive, h.evidence(names))
        let bothGroups: Set<SidebarNodeID> = [.worktree(f.parent.id), .worktree(f.first.id)]
        #expect(h.controller.activeGuideAncestors == bothGroups, h.evidence(names))

        // The pointer leaves: the selection's line stays.
        tracker.pointerExited()
        let selectionOnly = try Self.activeGuides(f.rows, in: h)
        #expect(selectionOnly == Self.firstGroupActive, h.evidence(names))
    }

    // MARK: The dock

    /// The dock's rows are a preorder walk with depths: a row's owners are
    /// the nearest rows above it a level up, and the outline's rule applies
    /// to them.
    @Test func dockRule() {
        let ids = (1...6).map { SidebarTreeDiffTests.uuid($0) }
        let a = SidebarNodeID.worktree(ids[0])
        let a1 = SidebarNodeID.worktree(ids[1])
        let a1x = SidebarNodeID.worktree(ids[2])
        let a2 = SidebarNodeID.worktree(ids[3])
        let b = SidebarNodeID.worktree(ids[4])
        let lane = SidebarNodeID.remoteSession(ids[5])
        func row(_ id: SidebarNodeID, _ depth: Int) -> DockRow {
            DockRow(id: id, kind: .worktree(SidebarCellTests.worktree(name: "row")), depth: depth)
        }
        let rows = [row(a, 0), row(a1, 1), row(a1x, 2), row(a2, 1), row(b, 0),
                    DockRow(id: lane, kind: .remoteSession(SidebarCellTests.session(title: "lane")), depth: 0)]

        let owners = rows.indices.map { DockTableController.guideAncestors(ofRow: $0, in: rows) }
        let expectedOwners: [[SidebarNodeID]] = [[], [a], [a, a1], [a], [], []]
        #expect(owners == expectedOwners)

        let lit = rows.indices.map { DockTableController.activeGuideAncestor(ofRow: $0, in: rows) }
        // A root with its subtree open, a child with its own, a leaf and its
        // sibling, a closed root, a remote pin.
        let expectedLit: [SidebarNodeID?] = [a, a1, a1, a, nil, nil]
        #expect(lit == expectedLit)

        let focused = DockTableController.activeGuideAncestors(in: rows, hovered: a2, selected: [ids[2]])
        let aAndA1: Set<SidebarNodeID> = [a, a1]
        #expect(focused == aAndA1)
        let unfocused = DockTableController.activeGuideAncestors(in: rows, hovered: nil, selected: [])
        #expect(unfocused.isEmpty)
        let remoteHovered = DockTableController.activeGuideAncestors(in: rows, hovered: lane, selected: [ids[4]])
        #expect(remoteHovered.isEmpty)
    }

    /// The dock lights the selected row's group and the hovered row's, and
    /// puts the hover's out when the pointer leaves.
    @Test func dockLightsTheFocusedGroup() throws {
        let h = GuideDockHarness("guides.dock")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        var a = SidebarOutlineControllerTests.row("a", repo, order: 0)
        a.pinnedAt = Date(timeIntervalSince1970: 1_700_000_000)
        a.pinSortOrder = 0
        let a1 = SidebarOutlineControllerTests.row("a1", repo, parent: a.id, order: 0)
        let a1x = SidebarOutlineControllerTests.row("a1x", repo, parent: a1.id, order: 0)
        let a2 = SidebarOutlineControllerTests.row("a2", repo, parent: a.id, order: 1)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [a, a1, a1x, a2]]
        h.state.selectedWorktreeIDs = [a.id]
        h.mount()
        let rows: [SidebarNodeID] = [a, a1, a1x, a2].map { .worktree($0.id) }
        let dockIDs = h.dock.rows.map(\.id)
        try #require(dockIDs == rows, "The dock shows \(dockIDs)")

        // The selected root has its subtree open: its line lights.
        let rootSelected = try h.activeGuides(rows)
        let rootGroup: [IndexSet] = [[], [0], [0], [0]]
        #expect(rootSelected == rootGroup)

        // A selected grandchild lights its parent's.
        h.state.selectedWorktreeIDs = [a1x.id]
        h.flush()
        let grandchildSelected = try h.activeGuides(rows)
        let childGroup: [IndexSet] = [[], [], [1], []]
        #expect(grandchildSelected == childGroup)

        // Hovering the root's other child lights the root's line too.
        let tracker = try #require(h.dock.hoverTracker)
        let point = try #require(h.windowCenter(of: .worktree(a2.id)))
        tracker.pointerMoved(toWindowPoint: point)
        try #require(h.dock.hoverState.row == .worktree(a2.id), "The dock hovers \(String(describing: h.dock.hoverState.row))")
        let hovered = try h.activeGuides(rows)
        let both: [IndexSet] = [[], [0], [0, 1], [0]]
        #expect(hovered == both)

        tracker.pointerExited()
        let exited = try h.activeGuides(rows)
        #expect(exited == childGroup)
    }
}

/// The sidebar's container, mounted offscreen, for its dock: the shape
/// `DockTableControllerTests` mounts it in.
@MainActor
private final class GuideDockHarness {
    let suite: TestDefaultsSuite
    let state: AppState
    let container: SidebarContainerController
    private(set) var host: OffscreenAppKitHost?

    var dock: DockTableController { container.dockController }

    init(_ label: String) {
        suite = TestDefaultsSuite("SidebarGuideLineTests.\(label)")
        state = AppState(userDefaults: suite.defaults)
        container = SidebarContainerController(appState: state, defaults: suite.defaults)
    }

    func mount(size: NSSize = NSSize(width: 320, height: 600)) {
        host = OffscreenAppKitHost(controller: container, size: size)
        flush()
    }

    /// Runs both lists' pending rebuilds, then lays the window out.
    func flush() {
        container.outlineController.flushPendingRebuild()
        dock.flushPendingRebuild()
        host?.layout()
    }

    func tearDown() {
        host?.tearDown()
        suite.tearDown()
    }

    func row(_ id: SidebarNodeID) -> Int {
        dock.rows.firstIndex { $0.id == id } ?? -1
    }

    func windowCenter(of id: SidebarNodeID) -> NSPoint? {
        let index = row(id)
        guard index >= 0 else { return nil }
        let rect = dock.table.rect(ofRow: index)
        return dock.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    /// Each row's active guide lines, in `ids` order.
    func activeGuides(_ ids: [SidebarNodeID]) throws -> [IndexSet] {
        host?.layout()
        var result: [IndexSet] = []
        for id in ids {
            let index = row(id)
            let view = try #require(dock.table.rowView(atRow: index, makeIfNecessary: true) as? SidebarRowView,
                                    "No dock row view for \(id) at \(index)")
            result.append(view.configuration.activeGuides)
        }
        return result
    }
}
