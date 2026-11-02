import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1 for the pure parts — the style, the line geometry and its fade, and
// the outline's and the dock's rules for each row's part in each line and for
// the active lines — checked directly. The outline's and the dock's wiring
// runs through controllers mounted offscreen: the pointer is driven through
// the hover tracker's own entry points, the selection through `AppState` and
// through the outline's `selectRowIndexes`, as a click lands.

/// The native sidebar's guide lines: one per parent, fading in under its
/// icon and branching to each child in a rounded turn; hairlines at rest, the
/// focused group's line at full strength, and the highlight tint over a
/// highlight.
@MainActor
@Suite("Sidebar guide lines")
struct SidebarGuideLineTests {
    typealias Style = SidebarGuideLine.Style

    static let bounds = NSRect(x: 0, y: 0, width: 300, height: 28)

    // MARK: Style

    /// Every strength and width the lines draw with.
    @Test func shippedValues() {
        let expected = SidebarGuideLine.Alphas(rest: 0.12, active: 0.24, restOnHighlight: 0.30,
                                               activeOnHighlight: 0.55)
        #expect(SidebarGuideLine.alphas == expected)
        #expect(SidebarGuideLine.highlightWhiteMix.light == 0.53)
        #expect(SidebarGuideLine.highlightWhiteMix.dark == 0.53)
        #expect(SidebarGuideLine.restPixelWidth == 1)
        #expect(SidebarGuideLine.activeWidth == 1)
        #expect(SidebarGuideLine.defaultBackingScale == 2)
    }

    /// Rest and active, on a plain row and on a highlighted one: grey, then
    /// the highlight tint, each at its own alpha; a hairline at rest, a point
    /// when active.
    @Test func styleForEachState() {
        let states: [(active: Bool, highlight: Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        let retina = states.map {
            SidebarGuideLine.style(isActive: $0.active, isOnHighlight: $0.highlight, backingScale: 2)
        }
        let expectedRetina = [
            Style(color: .secondaryLabel, alpha: 0.12, width: 0.5),
            Style(color: .secondaryLabel, alpha: 0.24, width: 1),
            Style(color: .highlightTint, alpha: 0.30, width: 0.5),
            Style(color: .highlightTint, alpha: 0.55, width: 1),
        ]
        #expect(retina == expectedRetina)

        // At 1x the hairline is a whole point; the active line stays one.
        let standard = states.map {
            SidebarGuideLine.style(isActive: $0.active, isOnHighlight: $0.highlight, backingScale: 1)
        }
        let expectedStandard = [
            Style(color: .secondaryLabel, alpha: 0.12, width: 1),
            Style(color: .secondaryLabel, alpha: 0.24, width: 1),
            Style(color: .highlightTint, alpha: 0.30, width: 1),
            Style(color: .highlightTint, alpha: 0.55, width: 1),
        ]
        #expect(standard == expectedStandard)
    }

    /// The white mix is `c * (1 - f) + f` per component: 0 keeps the input,
    /// 1 is white.
    @Test func mixTowardWhite() {
        let input = (r: CGFloat(37) / 255, g: CGFloat(127) / 255, b: CGFloat(1))
        let mixed = SidebarGuideLine.mixedTowardWhite(input, fraction: 0.53)
        let expectedR = CGFloat(37) / 255 * 0.47 + 0.53
        let expectedG = CGFloat(127) / 255 * 0.47 + 0.53
        #expect(abs(mixed.r - expectedR) < 1e-9)
        #expect(abs(mixed.g - expectedG) < 1e-9)
        #expect(abs(mixed.b - 1) < 1e-9)

        let none = SidebarGuideLine.mixedTowardWhite(input, fraction: 0)
        #expect(abs(none.r - input.r) < 1e-9)
        #expect(abs(none.g - input.g) < 1e-9)
        #expect(abs(none.b - input.b) < 1e-9)

        let white = SidebarGuideLine.mixedTowardWhite(input, fraction: 1)
        #expect(abs(white.r - 1) < 1e-9)
        #expect(abs(white.g - 1) < 1e-9)
        #expect(abs(white.b - 1) < 1e-9)
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

    // MARK: Shape

    typealias Guide = SidebarGuideLine.Guide
    typealias Pieces = SidebarGuideLine.Pieces
    typealias Turn = SidebarGuideLine.Turn
    typealias Fade = SidebarGuideLine.Fade
    typealias Run = SidebarGuideLine.Run

    static let rest = SidebarGuideLine.style(isActive: false, isOnHighlight: false, backingScale: 2)
    static let active = SidebarGuideLine.style(isActive: true, isOnHighlight: false, backingScale: 2)

    /// Every constant the lines' shape draws with.
    @Test func shapeValues() {
        #expect(SidebarNativeMetrics.guideLineOffset == 6)
        #expect(SidebarGuideLine.iconHalfHeight == 6)
        #expect(SidebarGuideLine.stubGap == 2)
        #expect(SidebarGuideLine.fadeLength == 12)
        #expect(SidebarGuideLine.fadeStopCount == 9)
        #expect(SidebarGuideLine.branchRadius == 4)
        #expect(SidebarGuideLine.tickInset == 3)
    }

    /// The pieces of the line under x 26 that a 28 pt row draws at 2x, for a
    /// child whose content starts at 36, so its tick ends at 33.
    static func pieces(_ role: SidebarGuideLine.Role, style: Style = SidebarGuideLineTests.rest, fadeStart: CGFloat? = nil,
                       height: CGFloat = 28, fadeLength: CGFloat = SidebarGuideLine.fadeLength) -> Pieces? {
        SidebarGuideLine.pieces(role: role, x: 26, tickEnd: 33, fadeStart: fadeStart, style: style,
                                in: NSRect(x: 0, y: 0, width: 300, height: height), backingScale: 2,
                                fadeLength: fadeLength)
    }

    /// Each part a row can draw: a passing line the full height; a branch
    /// the full height with its quarter turn of 4 pt on the row's centre and
    /// its tick out to the child's content less 3 pt; the last child's line
    /// from the top into its turn, and nothing below; the parent's stub from
    /// 2 pt under its icon to the bottom, fading in.
    @Test func piecesForEachRole() {
        let fullHeight = NSRect(x: 26, y: 0, width: 0.5, height: 28)
        let expectedPassing = Pieces(vertical: fullHeight, turn: nil, fade: nil, style: Self.rest)
        #expect(Self.pieces(.passing) == expectedPassing)

        let branchTurn = Turn(lineX: 26.25, startY: 10.25, tickY: 14.25, endX: 33, radius: 4, width: 0.5)
        let expectedBranch = Pieces(vertical: fullHeight, turn: branchTurn, fade: nil, style: Self.rest)
        #expect(Self.pieces(.branch) == expectedBranch)
        #expect(branchTurn.turnY == 10.25)

        let lastTurn = Turn(lineX: 26.25, startY: 0, tickY: 14.25, endX: 33, radius: 4, width: 0.5)
        let expectedLast = Pieces(vertical: nil, turn: lastTurn, fade: nil, style: Self.rest)
        #expect(Self.pieces(.last) == expectedLast)

        let stubRect = NSRect(x: 26, y: 22, width: 0.5, height: 6)
        let stubFade = Fade(rect: stubRect, start: 22, length: 12)
        let expectedStub = Pieces(vertical: stubRect, turn: nil, fade: stubFade, style: Self.rest)
        #expect(Self.pieces(.stub) == expectedStub)

        // A point-wide active line: the turn's stroke stays half a width
        // inside the line's edges and the tick's.
        let activeTurn = Turn(lineX: 26.5, startY: 10.5, tickY: 14.5, endX: 33, radius: 4, width: 1)
        let activeRect = NSRect(x: 26, y: 0, width: 1, height: 28)
        let expectedActive = Pieces(vertical: activeRect, turn: activeTurn, fade: nil, style: Self.active)
        #expect(Self.pieces(.branch, style: Self.active) == expectedActive)

        // A tick that would end inside the turn runs to the turn's end.
        let short = SidebarGuideLine.pieces(role: .branch, x: 26, tickEnd: 20, fadeStart: nil, style: Self.rest,
                                            in: Self.bounds, backingScale: 2)
        #expect(short?.turn?.endX == 30.25)

        // A line with no alpha draws nothing.
        let hidden = SidebarGuideLine.style(isActive: false, isOnHighlight: false, backingScale: 2, alphas: .none)
        #expect(Self.pieces(.passing, style: hidden) == nil)
    }

    /// The line's left edge and the tick's top edge sit on device-pixel
    /// boundaries at 1x and 2x — an x or a centre off the grid moves left or
    /// up onto it — so every edge covers whole pixels.
    @Test func piecesAlignToDevicePixels() throws {
        let oddRow = NSRect(x: 0, y: 0, width: 300, height: 27)
        let retinaStyle = SidebarGuideLine.style(isActive: false, isOnHighlight: false, backingScale: 2)
        let standardStyle = SidebarGuideLine.style(isActive: false, isOnHighlight: false, backingScale: 1)
        let retina = try #require(SidebarGuideLine.pieces(
            role: .branch, x: 28.75, tickEnd: 40, fadeStart: nil, style: retinaStyle, in: oddRow, backingScale: 2))
        let standard = try #require(SidebarGuideLine.pieces(
            role: .branch, x: 28.75, tickEnd: 40, fadeStart: nil, style: standardStyle, in: oddRow, backingScale: 1))
        let expectedRetina = Pieces(
            vertical: NSRect(x: 28.5, y: 0, width: 0.5, height: 27),
            turn: Turn(lineX: 28.75, startY: 9.75, tickY: 13.75, endX: 40, radius: 4, width: 0.5),
            fade: nil, style: retinaStyle)
        let expectedStandard = Pieces(
            vertical: NSRect(x: 28, y: 0, width: 1, height: 27),
            turn: Turn(lineX: 28.5, startY: 9.5, tickY: 13.5, endX: 40, radius: 4, width: 1),
            fade: nil, style: standardStyle)
        #expect(retina == expectedRetina)
        #expect(standard == expectedStandard)

        let retinaEdges = Self.pixelEdges(retina, scale: 2)
        let standardEdges = Self.pixelEdges(standard, scale: 1)
        let wholeRetina = retinaEdges.map { $0.rounded() }
        let wholeStandard = standardEdges.map { $0.rounded() }
        #expect(retinaEdges == wholeRetina, "An edge falls inside a device pixel at 2x: \(retinaEdges)")
        #expect(standardEdges == wholeStandard, "An edge falls inside a device pixel at 1x: \(standardEdges)")
    }

    /// The line's left and right edges and the tick's top and bottom edges,
    /// in device pixels.
    static func pixelEdges(_ pieces: Pieces, scale: CGFloat) -> [CGFloat] {
        var edges: [CGFloat] = []
        if let vertical = pieces.vertical {
            edges += [vertical.minX * scale, vertical.maxX * scale]
        }
        if let turn = pieces.turn {
            let half = turn.width / 2
            edges += [(turn.lineX - half) * scale, (turn.lineX + half) * scale,
                      (turn.tickY - half) * scale, (turn.tickY + half) * scale]
        }
        return edges
    }

    /// The fade runs 12 pt from clear where the stub starts. A 28 pt
    /// parent's stub holds the first 6 pt and its first child's top the
    /// other 6; a 36 pt parent's stub holds 10, leaving 2. An only child
    /// carries the fade into the line that ends in its turn. A later child, a
    /// fade spent above the row, and a fade of length 0 draw no fade.
    @Test func fadeRunsFromTheStubIntoTheFirstChild() throws {
        #expect(SidebarGuideLine.stubStart(rowHeight: 28) == 22)
        #expect(SidebarGuideLine.continuedFadeStart(ownerHeight: 28) == -6)
        #expect(SidebarGuideLine.stubStart(rowHeight: 36) == 26)
        #expect(SidebarGuideLine.continuedFadeStart(ownerHeight: 36) == -10)

        let stubFade = try #require(Self.pieces(.stub)?.fade)
        #expect(stubFade.startFraction == 0)
        #expect(stubFade.endFraction == 0.5)

        let child = try #require(Self.pieces(.branch, fadeStart: -6))
        let childFade = Fade(rect: NSRect(x: 26, y: 0, width: 7, height: 6), start: -6, length: 12)
        let fullHeight = NSRect(x: 26, y: 0, width: 0.5, height: 28)
        #expect(child.fade == childFade)
        #expect(child.vertical == fullHeight)
        #expect(childFade.startFraction == 0.5)
        #expect(childFade.endFraction == 1)

        let tallStub = try #require(Self.pieces(.stub, height: 36))
        let tallStubRect = NSRect(x: 26, y: 26, width: 0.5, height: 10)
        let tallStubFade = Fade(rect: tallStubRect, start: 26, length: 12)
        #expect(tallStub.vertical == tallStubRect)
        #expect(tallStub.fade == tallStubFade)
        #expect(tallStubFade.startFraction == 0)
        #expect(abs(tallStubFade.endFraction - 10.0 / 12.0) < 1e-9)

        let tallChildFade = try #require(Self.pieces(.branch, fadeStart: -10)?.fade)
        let expectedTallChild = Fade(rect: NSRect(x: 26, y: 0, width: 7, height: 2), start: -10, length: 12)
        #expect(tallChildFade == expectedTallChild)
        #expect(abs(tallChildFade.startFraction - 10.0 / 12.0) < 1e-9)
        #expect(tallChildFade.endFraction == 1)

        let only = try #require(Self.pieces(.last, fadeStart: -6))
        #expect(only.fade == childFade)
        #expect(only.turn?.startY == 0)

        #expect(Self.pieces(.branch)?.fade == nil, "A later child carries no fade")
        #expect(Self.pieces(.branch, fadeStart: -12)?.fade == nil, "A fade spent above the row draws none in it")
        let unfadedStub = Self.pieces(.stub, fadeLength: 0)
        let stubRect = NSRect(x: 26, y: 22, width: 0.5, height: 6)
        #expect(unfadedStub?.fade == nil)
        #expect(unfadedStub?.vertical == stubRect)
        #expect(Self.pieces(.branch, fadeStart: -6, fadeLength: 0)?.fade == nil)
    }

    /// The fade's gradient samples smoothstep at nine even stops, clear to
    /// opaque.
    @Test func fadeFollowsSmoothstep() {
        let stops = SidebarGuideLine.fadeStops()
        let locations = stops.map(\.location)
        let alphas = stops.map(\.alpha)
        let expectedLocations: [CGFloat] = [0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875, 1]
        let expectedAlphas: [CGFloat] = [0, 0.04296875, 0.15625, 0.31640625, 0.5, 0.68359375, 0.84375,
                                         0.95703125, 1]
        #expect(locations == expectedLocations)
        #expect(alphas.count == expectedAlphas.count)
        let deviation = zip(alphas, expectedAlphas).map { abs($0 - $1) }.max() ?? 1
        #expect(deviation < 1e-9, "The fade's alphas are \(alphas)")
        #expect(SidebarGuideLine.smoothstep(-1) == 0)
        #expect(SidebarGuideLine.smoothstep(2) == 1)
        #expect(SidebarGuideLine.fadeGradient() != nil)
    }

    /// The turn's stroke runs down the line from its start, turns, and ends
    /// at the tick's end on the tick's centreline.
    @Test func turnPathRunsDownTurnsAndTicks() {
        let branch = Turn(lineX: 26.25, startY: 10.25, tickY: 14.25, endX: 33, radius: 4, width: 0.5)
        let last = Turn(lineX: 26.25, startY: 0, tickY: 14.25, endX: 33, radius: 4, width: 0.5)
        let branchPath = SidebarGuideLine.turnPath(branch)
        let lastPath = SidebarGuideLine.turnPath(last)
        let tickEnd = CGPoint(x: 33, y: 14.25)
        #expect(branchPath.currentPoint == tickEnd)
        #expect(lastPath.currentPoint == tickEnd)
        let branchBox = branchPath.boundingBoxOfPath
        let lastBox = lastPath.boundingBoxOfPath
        let expectedBranchBox = NSRect(x: 26.25, y: 10.25, width: 6.75, height: 4)
        let expectedLastBox = NSRect(x: 26.25, y: 0, width: 6.75, height: 14.25)
        #expect(Self.isClose(branchBox, expectedBranchBox), "The branch's turn spans \(branchBox)")
        #expect(Self.isClose(lastBox, expectedLastBox), "The last child's turn spans \(lastBox)")
    }

    static func isClose(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        let tolerance: CGFloat = 1e-6
        return abs(lhs.minX - rhs.minX) < tolerance && abs(lhs.minY - rhs.minY) < tolerance
            && abs(lhs.width - rhs.width) < tolerance && abs(lhs.height - rhs.height) < tolerance
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

    /// A run on the owner's first child carries the fade from the owner's
    /// row height; every other run carries none.
    @Test func guidesCarryTheFadeOnTheFirstChild() {
        let owner = SidebarNodeID.worktree(SidebarTreeDiffTests.uuid(1))
        let other = SidebarNodeID.worktree(SidebarTreeDiffTests.uuid(2))
        let runs = [Run(owner: other, level: 0, role: .passing, continuesFade: false),
                    Run(owner: owner, level: 1, role: .last, continuesFade: true)]
        let guides = SidebarGuideLine.guides(for: runs) { $0 == owner ? 36 : nil }
        let expected = [Guide(level: 0, role: .passing), Guide(level: 1, role: .last, fadeStart: -10)]
        #expect(guides == expected)
    }

    /// The row view draws grey on a plain row and the nest target, accent on
    /// a hovered or selected one, the active lines at full strength, its own
    /// line last, and leaves out the line the pin sits on.
    @Test func rowViewStylesItsLines() {
        let rowView = SidebarRowView(frame: Self.bounds)
        rowView.appearance = NSAppearance(named: .aqua)
        let rowInset = SidebarNativeMetrics.rowContentInset(chevronBeforeTitle: false)
        let guides = [Guide(level: 0, role: .passing), Guide(level: 1, role: .last)]
        let base = SidebarRowView.Configuration(contentOrigin: rowInset, level: 2, guides: guides, activeGuides: [1])
        let rest = SidebarGuideLine.style(isActive: false, isOnHighlight: false, backingScale: 2)
        let active = SidebarGuideLine.style(isActive: true, isOnHighlight: false, backingScale: 2)
        let restAccent = SidebarGuideLine.style(isActive: false, isOnHighlight: true, backingScale: 2)
        let activeAccent = SidebarGuideLine.style(isActive: true, isOnHighlight: true, backingScale: 2)
        let grey = [rest, active]
        let accent = [restAccent, activeAccent]

        rowView.configuration = base
        let plainXs = Self.lineLefts(rowView)
        let expectedXs: [CGFloat] = [26, 42]
        #expect(plainXs == expectedXs)
        #expect(rowView.guideLineXs == expectedXs)
        #expect(rowView.tickEndX == 49)
        #expect(Self.styles(rowView) == grey, "A plain row draws grey lines")

        rowView.configuration.isHovered = true
        #expect(Self.styles(rowView) == accent, "A hovered row draws tinted lines")

        rowView.configuration.isHovered = false
        rowView.configuration.isSelectedByModel = true
        #expect(Self.styles(rowView) == accent, "A row its model selects draws tinted lines")

        rowView.configuration.isSelectedByModel = false
        rowView.isSelected = true
        #expect(Self.styles(rowView) == accent, "A row the list selects draws tinted lines")

        rowView.isSelected = false
        rowView.configuration.isNestTarget = true
        #expect(Self.styles(rowView) == grey, "The nest target keeps grey lines")

        // The row's own line starts last, at its own level, in its own
        // strength.
        rowView.configuration = base
        rowView.configuration.drawsStub = true
        let stubbedXs = Self.lineLefts(rowView)
        let expectedStubbedXs: [CGFloat] = [26, 42, 58]
        #expect(stubbedXs == expectedStubbedXs)
        let restingStub = [rest, active, rest]
        #expect(Self.styles(rowView) == restingStub)
        rowView.configuration.isStubActive = true
        let activeStub = [rest, active, active]
        #expect(Self.styles(rowView) == activeStub)

        // The pin sits on the line a level up: that one leaves the row, the
        // line two levels up and the row's own stay.
        rowView.configuration.showsPinGap = true
        let gappedXs = Self.lineLefts(rowView)
        let expectedGappedXs: [CGFloat] = [26, 58]
        #expect(gappedXs == expectedGappedXs, "The pin breaks only the line under it")

        let hidden = rowView.guidePieces(backingScale: 2, alphas: .none)
        #expect(hidden.isEmpty)
    }

    static func styles(_ rowView: SidebarRowView) -> [Style] {
        rowView.guidePieces(backingScale: 2).map(\.style)
    }

    /// The left edge of each line the row draws, in order.
    static func lineLefts(_ rowView: SidebarRowView) -> [CGFloat] {
        rowView.guidePieces(backingScale: 2).map { pieces in
            if let vertical = pieces.vertical { return vertical.minX }
            if let turn = pieces.turn { return turn.lineX - turn.width / 2 }
            return -1
        }
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

    /// Each row's part in each worktree line above it, and whether it starts
    /// its own. A group under a worktree, and every row in it, draw none of
    /// that worktree's line, which ends at its last worktree child; a row
    /// whose only child is a group, open or closed, starts no line.
    @Test func treeShapeRule() {
        let fixture = Self.ruleTree()
        let tree = fixture.tree
        func id(_ name: String) -> SidebarNodeID { fixture.id(name) }
        func run(_ owner: String, _ role: SidebarGuideLine.Role, fade: Bool = false) -> Run {
            Run(owner: id(owner), level: 0, role: role, continuesFade: fade)
        }
        let names = ["parent", "first", "grandchild", "second", "remoteGroup", "remoteChild", "session", "leaf",
                     "shelved", "shelvedChild", "outer", "inner", "deep"]
        let runs = names.map { tree.guideRuns(of: id($0)) }
        let expected: [[Run]] = [
            [], // parent: its own line starts here
            [run("parent", .branch, fade: true)], // the first child carries the fade on
            [run("parent", .passing), run("first", .last, fade: true)], // parent's line passes by
            [run("parent", .last)], // the last worktree child, though a group follows it
            [], // the group draws none of parent's line
            [], // nor does a row in it
            [], // nor a session
            [], [], [], // top-level rows, and a row in a closed group
            [], // outer: its own line starts here
            [run("outer", .last, fade: true)], // an only child
            [], // under a group, and under outer's last child
        ]
        #expect(runs == expected)
        let starts = names.map { tree.startsGuide(id($0)) }
        let expectedStarts = [true, true, false, false, false, false, false, false, false, false, true, false, false]
        #expect(starts == expectedStarts)

        // A line from further up passes a group and the rows inside it:
        // acme ▸ top ▸ (middle ▸ Remote ▸ (inside, session), after).
        let uuids = (200...204).map { SidebarTreeDiffTests.uuid($0) }
        let group = SidebarGroupID(owner: .parent(uuids[1]), kind: .remote)
        let crossing = SidebarTree(roots: [
            SidebarDropPolicyTests.repo(SidebarTreeDiffTests.uuid(210), [
                SidebarDropPolicyTests.row(uuids[0], home: nil, [
                    SidebarDropPolicyTests.row(uuids[1], home: nil, [
                        SidebarDropPolicyTests.group(group, [
                            SidebarDropPolicyTests.row(uuids[2], home: nil), SidebarDropPolicyTests.session(uuids[3]),
                        ]),
                    ]),
                    SidebarDropPolicyTests.row(uuids[4], home: nil),
                ]),
            ]),
        ])
        let top = SidebarNodeID.worktree(uuids[0])
        let middle = SidebarNodeID.worktree(uuids[1])
        let crossed: [SidebarNodeID] = [middle, .group(group), .worktree(uuids[2]), .remoteSession(uuids[3]),
                                        .worktree(uuids[4])]
        let crossingRuns = crossed.map { crossing.guideRuns(of: $0) }
        let passing = Run(owner: top, level: 0, role: .passing, continuesFade: false)
        let expectedCrossing: [[Run]] = [
            [Run(owner: top, level: 0, role: .branch, continuesFade: true)],
            [passing], [passing], [passing],
            [Run(owner: top, level: 0, role: .last, continuesFade: false)],
        ]
        #expect(crossingRuns == expectedCrossing)
        #expect(crossing.startsGuide(top))
        #expect(!crossing.startsGuide(middle), "A row whose only child is a group starts no line")
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

        // The selected row draws its line in the highlight tint; its sibling
        // keeps grey, for its parent's line and for the start of its own.
        let secondView = try #require(h.rowView(.worktree(f.second.id), make: true) as? SidebarRowView)
        let firstView = try #require(h.rowView(.worktree(f.first.id), make: true) as? SidebarRowView)
        let secondColors = secondView.guidePieces(backingScale: 2).map(\.style.color)
        let firstColors = firstView.guidePieces(backingScale: 2).map(\.style.color)
        let accent: [SidebarGuideLine.ColorRole] = [.highlightTint]
        let grey: [SidebarGuideLine.ColorRole] = [.secondaryLabel, .secondaryLabel]
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

    // MARK: The outline's shape

    /// p ▸ (c1 ▸ g1, c2, c3 ▸ g3); solo ▸ only; other, in one repo.
    struct ShapeFixture {
        let p: Worktree, c1: Worktree, g1: Worktree, c2: Worktree, c3: Worktree, g3: Worktree
        let solo: Worktree, only: Worktree, other: Worktree

        var all: [Worktree] { [p, c1, g1, c2, c3, g3, solo, only, other] }
        var rows: [SidebarNodeID] { all.map { .worktree($0.id) } }
        var names: [UUID: String] {
            Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.name) })
        }
    }

    static func mountShape(_ h: OutlineHarness) -> ShapeFixture {
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let p = SidebarOutlineControllerTests.row("p", repo, order: 0)
        let c1 = SidebarOutlineControllerTests.row("c1", repo, parent: p.id, order: 0)
        let g1 = SidebarOutlineControllerTests.row("g1", repo, parent: c1.id, order: 0)
        let c2 = SidebarOutlineControllerTests.row("c2", repo, parent: p.id, order: 1)
        let c3 = SidebarOutlineControllerTests.row("c3", repo, parent: p.id, order: 2)
        let g3 = SidebarOutlineControllerTests.row("g3", repo, parent: c3.id, order: 0)
        let solo = SidebarOutlineControllerTests.row("solo", repo, order: 1)
        let only = SidebarOutlineControllerTests.row("only", repo, parent: solo.id, order: 0)
        let other = SidebarOutlineControllerTests.row("other", repo, order: 2)
        let fixture = ShapeFixture(p: p, c1: c1, g1: g1, c2: c2, c3: c3, g3: g3, solo: solo, only: only, other: other)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: fixture.all]
        h.controller.selectionModifiers = { [] }
        h.mount()
        return fixture
    }

    /// Each fixture row's row view configuration, in `ids` order.
    static func configurations(_ ids: [SidebarNodeID], in h: OutlineHarness,
                               _ names: [UUID: String]) throws -> [SidebarRowView.Configuration] {
        var result: [SidebarRowView.Configuration] = []
        for id in ids {
            let view = try #require(h.rowView(id, make: true) as? SidebarRowView,
                                    "No row view for \(id): \(h.evidence(names).rawValue)")
            result.append(view.configuration)
        }
        return result
    }

    /// The left edge of each line `id`'s row draws, in order.
    static func lineLefts(_ id: SidebarNodeID, in h: OutlineHarness) throws -> [CGFloat] {
        let view = try #require(h.rowView(id, make: true) as? SidebarRowView, "No row view for \(id)")
        return lineLefts(view)
    }

    /// A parent with three children: the first carries the fade on, the
    /// middle branches, the last ends the line. A grandchild before the last
    /// child draws the parent's line passing; the last child's own child
    /// draws none of it. An only child is first and last at once, and a leaf
    /// starts no line.
    @Test func outlineRowsDrawTheirPartsOfEachLine() throws {
        let h = OutlineHarness("guides.shape")
        defer { h.tearDown() }
        let f = Self.mountShape(h)
        let names = f.names
        let configurations = try Self.configurations(f.rows, in: h, names)
        let levels = configurations.map(\.level)
        let guides = configurations.map(\.guides)
        let stubs = configurations.map(\.drawsStub)
        let fade = SidebarGuideLine.continuedFadeStart(ownerHeight: WorktreeRowView.rowHeight)
        #expect(fade == -6)
        let expectedLevels = [0, 1, 2, 1, 1, 2, 0, 1, 0]
        let expectedGuides: [[Guide]] = [
            [], // p
            [Guide(level: 0, role: .branch, fadeStart: fade)], // c1, the first child
            [Guide(level: 0, role: .passing), Guide(level: 1, role: .last, fadeStart: fade)], // g1
            [Guide(level: 0, role: .branch)], // c2, a middle child
            [Guide(level: 0, role: .last)], // c3, the last child
            [Guide(level: 1, role: .last, fadeStart: fade)], // g3, under the last child
            [], // solo
            [Guide(level: 0, role: .last, fadeStart: fade)], // only, an only child
            [], // other, a leaf
        ]
        let expectedStubs = [true, true, false, false, true, false, true, false, false]
        #expect(levels == expectedLevels, h.evidence(names))
        #expect(guides == expectedGuides, h.evidence(names))
        #expect(stubs == expectedStubs, h.evidence(names))

        // At rest no line is active, the stubs included; hovering a child
        // lights its parent's stub, and no other.
        let restingStubs = configurations.map(\.isStubActive)
        let noneLit = [false, false, false, false, false, false, false, false, false]
        #expect(restingStubs == noneLit, h.evidence(names))
        let tracker = try #require(h.controller.hoverTracker)
        let c2Point = try #require(SidebarInteractionTests.windowPoint(of: .worktree(f.c2.id), in: h))
        tracker.pointerMoved(toWindowPoint: c2Point)
        try #require(h.controller.hoverState.row == .worktree(f.c2.id), h.evidence(names))
        let hovered = try Self.configurations(f.rows, in: h, names).map(\.isStubActive)
        let pLit = [true, false, false, false, false, false, false, false, false]
        #expect(hovered == pLit, h.evidence(names))
    }

    /// The gutter pin is centred on the line a level up — the parent's — so
    /// a row showing it leaves that line out; a line further up and the
    /// row's own line stay. A row without the pin draws them all.
    @Test func pinBreaksOnlyTheLineUnderIt() throws {
        let h = OutlineHarness("guides.pin")
        defer { h.tearDown() }
        let f = Self.mountShape(h)
        let names = f.names
        let p = SidebarNodeID.worktree(f.p.id)
        let c1 = SidebarNodeID.worktree(f.c1.id)
        let g1 = SidebarNodeID.worktree(f.g1.id)
        let pConfigurations = try Self.configurations([p], in: h, names)
        let origin = try #require(pConfigurations.first?.contentOrigin)
        let pLine = origin + 6
        let c1Line = origin + 22

        // At rest no pin shows.
        let restingG1 = try Self.lineLefts(g1, in: h)
        let restingC1 = try Self.lineLefts(c1, in: h)
        let bothLines = [pLine, c1Line]
        #expect(restingG1 == bothLines, h.evidence(names))
        #expect(restingC1 == bothLines, h.evidence(names))

        let tracker = try #require(h.controller.hoverTracker)
        let steps: [(row: SidebarNodeID, lines: [CGFloat], label: String)] = [
            (g1, [pLine], "the pin breaks c1's line on g1 and leaves p's"),
            (c1, [c1Line], "the pin breaks p's line on c1 and leaves c1's own"),
            (p, [pLine], "a top-level row's pin sits on no line"),
        ]
        for step in steps {
            let point = try #require(SidebarInteractionTests.windowPoint(of: step.row, in: h), h.evidence(names))
            tracker.pointerMoved(toWindowPoint: point)
            try #require(h.controller.hoverState.row == step.row, h.evidence(names))
            let stepConfigurations = try Self.configurations([step.row], in: h, names)
            let gap = try #require(stepConfigurations.first?.showsPinGap)
            #expect(gap, "\(step.label): \(h.evidence(names).rawValue)")
            let lines = try Self.lineLefts(step.row, in: h)
            #expect(lines == step.lines, "\(step.label): \(h.evidence(names).rawValue)")
        }
    }

    /// With workflow groups, a worktree's Remote group and the rows in it
    /// draw none of the worktree's line, which ends at its last worktree
    /// child. Without a worktree child, its only child the group, the row
    /// starts no line, the group open or closed.
    @Test func groupsUnderAWorktreeDrawNoneOfItsLine() throws {
        let h = OutlineHarness("guides.groups")
        defer { h.tearDown() }
        h.defaults.set(true, forKey: AppState.sidebarWorkflowGroupsKey)
        let fleet = SidebarTreeBuilderTests.makeFleet(in: h.state)
        let parentRemote = SidebarGroupID(owner: .parent(fleet.working.id), kind: .remote)
        h.state.expandedSidebarGroups = [parentRemote]
        h.mount()
        let names = [fleet.working.id: "working", fleet.localChild.id: "local child", fleet.worker.id: "worker"]
        let working = SidebarNodeID.worktree(fleet.working.id)
        let worker = SidebarNodeID.worktree(fleet.worker.id)
        let ids: [SidebarNodeID] = [working, .worktree(fleet.localChild.id), .group(parentRemote), worker]
        try #require(h.row(worker) >= 0, "The worker must show in the open Remote group: \(h.evidence(names).rawValue)")

        let configurations = try Self.configurations(ids, in: h, names)
        let levels = configurations.map(\.level)
        let guides = configurations.map(\.guides)
        let stubs = configurations.map(\.drawsStub)
        let fade = SidebarGuideLine.continuedFadeStart(ownerHeight: WorktreeRowView.rowHeight)
        let expectedLevels = [0, 1, 1, 2]
        let expectedGuides: [[Guide]] = [[], [Guide(level: 0, role: .last, fadeStart: fade)], [], []]
        let expectedStubs = [true, false, false, false]
        #expect(levels == expectedLevels, h.evidence(names))
        #expect(guides == expectedGuides, h.evidence(names))
        #expect(stubs == expectedStubs, h.evidence(names))

        // The local child goes: the group is the row's only child.
        h.state.worktrees[fleet.repoID]?.removeAll { $0.id == fleet.localChild.id }
        h.controller.flushPendingRebuild()
        let open = try Self.configurations([working, worker], in: h, names)
        let openStubs = open.map(\.drawsStub)
        let openGuides = open.map(\.guides)
        let neither = [false, false]
        let noGuides: [[Guide]] = [[], []]
        #expect(openStubs == neither, h.evidence(names))
        #expect(openGuides == noGuides, h.evidence(names))

        h.state.expandedSidebarGroups = []
        h.controller.flushPendingRebuild()
        let closedConfigurations = try Self.configurations([working], in: h, names)
        let closed = try #require(closedConfigurations.first)
        #expect(!closed.drawsStub, h.evidence(names))
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

    /// The dock's shape from its preorder rows: the outline's roles, levels
    /// from depths, the fade on a parent's first child, and nothing of a
    /// line below its last child.
    @Test func dockShapeRule() {
        let ids = (1...7).map { SidebarTreeDiffTests.uuid($0) }
        let a = SidebarNodeID.worktree(ids[0])
        let a1 = SidebarNodeID.worktree(ids[1])
        let a1x = SidebarNodeID.worktree(ids[2])
        let a2 = SidebarNodeID.worktree(ids[3])
        let b = SidebarNodeID.worktree(ids[4])
        let lane = SidebarNodeID.remoteSession(ids[5])
        let a2x = SidebarNodeID.worktree(ids[6])
        func row(_ id: SidebarNodeID, _ depth: Int) -> DockRow {
            DockRow(id: id, kind: .worktree(SidebarCellTests.worktree(name: "row")), depth: depth)
        }
        let rows = [row(a, 0), row(a1, 1), row(a1x, 2), row(a2, 1), row(b, 0),
                    DockRow(id: lane, kind: .remoteSession(SidebarCellTests.session(title: "lane")), depth: 0)]
        let runs = rows.indices.map { DockTableController.guideRuns(ofRow: $0, in: rows) }
        let expected: [[Run]] = [
            [],
            [Run(owner: a, level: 0, role: .branch, continuesFade: true)],
            [Run(owner: a, level: 0, role: .passing, continuesFade: false),
             Run(owner: a1, level: 1, role: .last, continuesFade: true)],
            [Run(owner: a, level: 0, role: .last, continuesFade: false)],
            [],
            [],
        ]
        #expect(runs == expected)
        let starts = rows.indices.map { DockTableController.startsGuide(ofRow: $0, in: rows) }
        let expectedStarts = [true, true, false, false, false, false]
        #expect(starts == expectedStarts)

        // The last child's own child draws nothing of the root's line.
        let tail = [row(a, 0), row(a1, 1), row(a2, 1), row(a2x, 2)]
        let tailRuns = DockTableController.guideRuns(ofRow: 3, in: tail)
        let expectedTail = [Run(owner: a2, level: 1, role: .last, continuesFade: true)]
        #expect(tailRuns == expectedTail)
    }

    /// The dock's row views draw their parts: the open root starts its line,
    /// its children branch and end it, a grandchild draws it passing. A
    /// pinned root whose subtree is closed starts no line; selecting it opens
    /// the subtree, and the line starts.
    @Test func dockRowsDrawTheirPartsOfEachLine() throws {
        let h = GuideDockHarness("guides.dockShape")
        defer { h.tearDown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        var a = SidebarOutlineControllerTests.row("a", repo, order: 0)
        a.pinnedAt = Date(timeIntervalSince1970: 1_700_000_000)
        a.pinSortOrder = 0
        let a1 = SidebarOutlineControllerTests.row("a1", repo, parent: a.id, order: 0)
        let a1x = SidebarOutlineControllerTests.row("a1x", repo, parent: a1.id, order: 0)
        let a2 = SidebarOutlineControllerTests.row("a2", repo, parent: a.id, order: 1)
        var b = SidebarOutlineControllerTests.row("b", repo, order: 1)
        b.pinnedAt = Date(timeIntervalSince1970: 1_700_000_100)
        b.pinSortOrder = 1
        let b1 = SidebarOutlineControllerTests.row("b1", repo, parent: b.id, order: 0)
        h.state.repos = [repo]
        h.state.worktrees = [repo.id: [a, a1, a1x, a2, b, b1]]
        h.state.selectedWorktreeIDs = [a.id]
        h.mount()
        let rows: [SidebarNodeID] = [a, a1, a1x, a2, b].map { .worktree($0.id) }
        let dockIDs = h.dock.rows.map(\.id)
        try #require(dockIDs == rows, "The dock shows \(dockIDs)")

        let configurations = try h.configurations(rows)
        let levels = configurations.map(\.level)
        let guides = configurations.map(\.guides)
        let stubs = configurations.map(\.drawsStub)
        let fade = SidebarGuideLine.continuedFadeStart(ownerHeight: WorktreeRowView.rowHeight)
        let expectedLevels = [0, 1, 2, 1, 0]
        let expectedGuides: [[Guide]] = [
            [],
            [Guide(level: 0, role: .branch, fadeStart: fade)],
            [Guide(level: 0, role: .passing), Guide(level: 1, role: .last, fadeStart: fade)],
            [Guide(level: 0, role: .last)],
            [],
        ]
        let expectedStubs = [true, true, false, false, false]
        #expect(levels == expectedLevels)
        #expect(guides == expectedGuides)
        #expect(stubs == expectedStubs, "A root whose subtree is closed starts no line")

        // Selecting b closes a's subtree and opens b's: a's line goes, b's
        // starts, and its only child ends it.
        h.state.selectedWorktreeIDs = [b.id]
        h.flush()
        let opened: [SidebarNodeID] = [a, b, b1].map { .worktree($0.id) }
        let openedIDs = h.dock.rows.map(\.id)
        try #require(openedIDs == opened, "The dock shows \(openedIDs)")
        let reopened = try h.configurations(opened)
        let reopenedStubs = reopened.map(\.drawsStub)
        let reopenedGuides = reopened.map(\.guides)
        let expectedReopenedStubs = [false, true, false]
        let expectedReopenedGuides: [[Guide]] = [[], [], [Guide(level: 0, role: .last, fadeStart: fade)]]
        #expect(reopenedStubs == expectedReopenedStubs)
        #expect(reopenedGuides == expectedReopenedGuides)
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

    /// Each row's row view configuration, in `ids` order.
    func configurations(_ ids: [SidebarNodeID]) throws -> [SidebarRowView.Configuration] {
        host?.layout()
        var result: [SidebarRowView.Configuration] = []
        for id in ids {
            let index = row(id)
            let view = try #require(dock.table.rowView(atRow: index, makeIfNecessary: true) as? SidebarRowView,
                                    "No dock row view for \(id) at \(index)")
            result.append(view.configuration)
        }
        return result
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
