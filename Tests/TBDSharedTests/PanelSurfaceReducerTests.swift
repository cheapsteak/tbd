import Foundation
import Testing
@testable import TBDShared

/// Fixed IDs and content, so an expected side region can be written out in
/// full and compared with `==` — over-reporting fails as well as
/// under-reporting.
enum ReducerFixture {
    static func id(_ n: Int) -> UUID {
        let digits = String(n)
        let padding = String(repeating: "0", count: 12 - digits.count)
        return UUID(uuidString: "00000000-0000-0000-0000-" + padding + digits)!
    }

    // Panel IDs.
    static let a = id(1)
    static let b = id(2)
    static let c = id(3)
    static let t = id(4)
    static let w = id(5)
    // Worktree panel IDs.
    static let n1 = id(6)
    static let n2 = id(7)
    static let ch = id(8)
    /// What `makeID` hands the reducer in the table rows.
    static let fresh = id(99)

    // Terminal IDs (transcript content).
    static let terminal1 = id(51)
    static let terminal2 = id(52)

    static func file(_ path: String) -> PanelContent { .file(FileReference(path: path)) }
    static func web(_ path: String) -> PanelContent {
        .web(URL(string: "https://example.com\(path)")!)
    }
    static func note(_ n: Int) -> PanelContent { .note(noteID: id(700 + n)) }
    static func transcript(_ terminalID: UUID) -> PanelContent { .transcript(terminalID: terminalID) }

    static func panel(_ id: PanelID, _ content: PanelContent) -> ViewerPanel {
        ViewerPanel(id: id, content: content)
    }

    /// A panel whose history holds `entries` with the cursor on `cursor`.
    static func panel(_ id: PanelID, entries: [PanelContent], cursor: Int = 0) -> ViewerPanel {
        ViewerPanel(id: id, history: PanelHistory(entries: entries, cursor: cursor))
    }

    /// A worktree panel showing note `n` (the note `note(n)` names).
    static func notePanel(_ id: PanelID, _ n: Int) -> WorktreePanel {
        WorktreePanel(id: id, content: .note(noteID: Self.id(700 + n)))
    }

    static func changesPanel(_ id: PanelID) -> WorktreePanel {
        WorktreePanel(id: id, content: .changes)
    }

    static func surface(
        _ side: SideRegion, worktreePanels: [WorktreePanel] = [], revision: UInt64 = 0
    ) -> WorkspaceTabSurface {
        WorkspaceTabSurface(
            id: id(900), worktreeID: id(901),
            primary: .terminal(terminalID: id(902)), side: side,
            worktreePanels: worktreePanels, revision: revision)
    }
}

private typealias Fixture = ReducerFixture

/// One path through `open`'s reuse rule (spec "Operations").
struct OpenReuseRow: Sendable, CustomTestStringConvertible {
    let name: String
    let before: SideRegion
    let operation: PanelOperation
    let after: SideRegion
    var testDescription: String { name }
}

extension OpenReuseRow {
    /// One row per path: exact match, active same-kind reuse, most-recent
    /// same-kind reuse, new panel, transcript, `newPanel`, and kind fencing.
    static let all: [OpenReuseRow] = [
        OpenReuseRow(
            name: "an exact match is selected, not the active same-kind panel navigated",
            before: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))],
                activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b]),
            operation: .open(content: Fixture.file("/b"), newPanel: false),
            after: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))],
                activePanelID: Fixture.b, recency: [Fixture.b, Fixture.a])),
        OpenReuseRow(
            name: "newPanel true still selects an exact match",
            before: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))],
                activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b]),
            operation: .open(content: Fixture.file("/b"), newPanel: true),
            after: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))],
                activePanelID: Fixture.b, recency: [Fixture.b, Fixture.a])),
        OpenReuseRow(
            name: "the active panel is navigated when it is the same kind",
            before: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))],
                activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b]),
            operation: .open(content: Fixture.file("/c"), newPanel: false),
            after: SideRegion(
                panels: [Fixture.panel(Fixture.a, entries: [Fixture.file("/c"), Fixture.file("/a")]),
                         Fixture.panel(Fixture.b, Fixture.file("/b"))],
                activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b])),
        OpenReuseRow(
            name: "an active panel of another kind gives way to the most recent same-kind panel",
            // A comes first in the strip, B first in recency: B is reused.
            before: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.w, Fixture.web("/w")),
                         Fixture.panel(Fixture.b, Fixture.file("/b"))],
                activePanelID: Fixture.w, recency: [Fixture.w, Fixture.b, Fixture.a]),
            operation: .open(content: Fixture.file("/c"), newPanel: false),
            after: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.w, Fixture.web("/w")),
                         Fixture.panel(Fixture.b, entries: [Fixture.file("/c"), Fixture.file("/b")])],
                activePanelID: Fixture.b, recency: [Fixture.b, Fixture.w, Fixture.a])),
        OpenReuseRow(
            name: "with no panel of the kind a new panel goes right after the active one",
            before: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))],
                activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b]),
            operation: .open(content: Fixture.web("/w"), newPanel: false),
            after: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.fresh, Fixture.web("/w")),
                         Fixture.panel(Fixture.b, Fixture.file("/b"))],
                activePanelID: Fixture.fresh, recency: [Fixture.fresh, Fixture.a, Fixture.b])),
        OpenReuseRow(
            name: "an empty region gets its first panel",
            before: .empty,
            operation: .open(content: Fixture.web("/w"), newPanel: false),
            after: SideRegion(
                panels: [Fixture.panel(Fixture.fresh, Fixture.web("/w"))],
                activePanelID: Fixture.fresh, recency: [Fixture.fresh])),
        OpenReuseRow(
            name: "a transcript never reuses a transcript panel",
            before: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1))],
                activePanelID: Fixture.t, recency: [Fixture.t, Fixture.a]),
            operation: .open(content: Fixture.transcript(Fixture.terminal2), newPanel: false),
            after: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1)),
                         Fixture.panel(Fixture.fresh, Fixture.transcript(Fixture.terminal2))],
                activePanelID: Fixture.fresh, recency: [Fixture.fresh, Fixture.t, Fixture.a])),
        OpenReuseRow(
            name: "newPanel true creates although a same-kind panel is active",
            before: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))],
                activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b]),
            operation: .open(content: Fixture.file("/c"), newPanel: true),
            after: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.fresh, Fixture.file("/c")),
                         Fixture.panel(Fixture.b, Fixture.file("/b"))],
                activePanelID: Fixture.fresh, recency: [Fixture.fresh, Fixture.a, Fixture.b])),
        OpenReuseRow(
            name: "a file never lands in the active transcript panel",
            before: SideRegion(
                panels: [Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1))],
                activePanelID: Fixture.t, recency: [Fixture.t]),
            operation: .open(content: Fixture.file("/a"), newPanel: false),
            after: SideRegion(
                panels: [Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1)), Fixture.panel(Fixture.fresh, Fixture.file("/a"))],
                activePanelID: Fixture.fresh, recency: [Fixture.fresh, Fixture.t])),
        OpenReuseRow(
            name: "a file passes over the active transcript to the file panel behind it",
            before: SideRegion(
                panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1))],
                activePanelID: Fixture.t, recency: [Fixture.t, Fixture.a]),
            operation: .open(content: Fixture.file("/b"), newPanel: false),
            after: SideRegion(
                panels: [Fixture.panel(Fixture.a, entries: [Fixture.file("/b"), Fixture.file("/a")]),
                         Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1))],
                activePanelID: Fixture.a, recency: [Fixture.a, Fixture.t])),
    ]
}

@Suite("PanelSurfaceReducerTests")
struct PanelSurfaceReducerTests {
    private func apply(
        _ operation: PanelOperation, to side: SideRegion
    ) throws -> WorkspaceTabSurface {
        try PanelSurfaceReducer.apply(operation, to: Fixture.surface(side), makeID: { Fixture.fresh })
    }

    // MARK: - open

    @Test(arguments: OpenReuseRow.all)
    func openReuseRule(row: OpenReuseRow) throws {
        let out = try apply(row.operation, to: row.before)
        #expect(out.side == row.after)
        #expect(out.revision == 1)
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    @Test func openingTheSameContentTwiceKeepsOnePanel() throws {
        // The transcript button can send `open` twice before the first reply
        // is adopted; the second must select, not add a second view.
        let contents = [Fixture.transcript(Fixture.terminal1), Fixture.file("/a")]
        for content in contents {
            for newPanel in [false, true] {
                var nextID = 0
                let makeID: () -> UUID = {
                    nextID += 1
                    return ReducerFixture.id(nextID)
                }
                let once = try PanelSurfaceReducer.apply(
                    .open(content: content, newPanel: newPanel), to: Fixture.surface(SideRegion.empty), makeID: makeID)
                let twice = try PanelSurfaceReducer.apply(
                    .open(content: content, newPanel: newPanel), to: once, makeID: makeID)
                let expected = SideRegion(
                    panels: [Fixture.panel(Fixture.id(1), content)],
                    activePanelID: Fixture.id(1), recency: [Fixture.id(1)])
                #expect(twice.side == expected, "\(content) newPanel \(newPanel)")
                #expect(twice.revision == 2)
            }
        }
    }

    @Test func openClearsCollapsed() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1))],
            activePanelID: Fixture.a, recency: [Fixture.a, Fixture.t], collapsed: true)
        let paths: [(String, PanelContent)] = [
            ("exact match", Fixture.transcript(Fixture.terminal1)),
            ("reuse", Fixture.file("/b")),
            ("new panel", Fixture.web("/w")),
        ]
        for (path, content) in paths {
            let out = try apply(.open(content: content, newPanel: false), to: side)
            #expect(!out.side.collapsed, "\(path)")
            #expect(out.side.isVisible, "\(path)")
            let active = try #require(out.side.activePanelID)
            #expect(out.side.panel(id: active)?.content == content, "\(path)")
        }
    }

    // MARK: - select

    @Test func selectMovesThePanelToTheFrontAndClearsCollapsed() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b")), Fixture.panel(Fixture.c, Fixture.file("/c"))],
            activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b, Fixture.c], collapsed: true, width: 0.3)
        let out = try apply(.select(panelID: Fixture.c), to: side)
        #expect(out.side == SideRegion(
            panels: side.panels, activePanelID: Fixture.c, recency: [Fixture.c, Fixture.a, Fixture.b],
            collapsed: false, width: 0.3))
    }

    @Test func selectingTheActivePanelShowsACollapsedRegion() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))],
            activePanelID: Fixture.a, recency: [Fixture.a], collapsed: true)
        let out = try apply(.select(panelID: Fixture.a), to: side)
        #expect(out.side == SideRegion(
            panels: side.panels, activePanelID: Fixture.a, recency: [Fixture.a], collapsed: false))
    }

    // MARK: - close

    /// Strip order A, B, C; recency A, C, B — so "most recent" and "next in
    /// the strip" disagree.
    private var threePanels: SideRegion {
        SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b")), Fixture.panel(Fixture.c, Fixture.file("/c"))],
            activePanelID: Fixture.a, recency: [Fixture.a, Fixture.c, Fixture.b])
    }

    @Test func closeActivePicksMostRecent() throws {
        let out = try apply(.close(panelID: Fixture.a), to: threePanels)
        #expect(out.side == SideRegion(
            panels: [Fixture.panel(Fixture.b, Fixture.file("/b")), Fixture.panel(Fixture.c, Fixture.file("/c"))],
            activePanelID: Fixture.c, recency: [Fixture.c, Fixture.b]))
    }

    @Test func closeInactiveKeepsActive() throws {
        let out = try apply(.close(panelID: Fixture.b), to: threePanels)
        #expect(out.side == SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.c, Fixture.file("/c"))],
            activePanelID: Fixture.a, recency: [Fixture.a, Fixture.c]))
    }

    /// With no worktree panels, closing the last panel leaves the region
    /// empty, which hides it, and changes no collapse.
    @Test func closeLastLeavesEmptyRegion() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, entries: [Fixture.file("/b"), Fixture.file("/a")])],
            activePanelID: Fixture.a, recency: [Fixture.a], width: 0.3)
        let out = try apply(.close(panelID: Fixture.a), to: side)
        #expect(out.side == SideRegion(width: 0.3))
        #expect(!out.side.isVisible)
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    // MARK: - navigate

    @Test func navigateRejectsKindChange() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1))],
            activePanelID: Fixture.a, recency: [Fixture.a, Fixture.t])
        #expect(throws: PanelOperationError.kindMismatch(panelID: Fixture.a, expected: .file, actual: .web)) {
            _ = try apply(.navigate(panelID: Fixture.a, destination: Fixture.web("/w")), to: side)
        }
        #expect(throws: PanelOperationError.kindMismatch(
            panelID: Fixture.t, expected: .transcript, actual: .file)) {
            _ = try apply(.navigate(panelID: Fixture.t, destination: Fixture.file("/b")), to: side)
        }
    }

    @Test func navigateRecordsHistoryAndLeavesSelectionAlone() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))],
            activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b], collapsed: true)
        let out = try apply(.navigate(panelID: Fixture.b, destination: Fixture.file("/c")), to: side)
        #expect(out.side == SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, entries: [Fixture.file("/c"), Fixture.file("/b")])],
            activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b], collapsed: true))
    }

    @Test func navigateToTheCurrentContentIsANoOpThatBumpsRevision() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))], activePanelID: Fixture.a, recency: [Fixture.a])
        let out = try apply(.navigate(panelID: Fixture.a, destination: Fixture.file("/a")), to: side)
        #expect(out.side == side)
        #expect(out.revision == 1)
    }

    /// A transcript has one view per workspace tab: pointing a second panel at
    /// a transcript another panel shows selects that panel instead.
    @Test func navigateOntoATranscriptShownElsewhereSelectsThatPanel() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1)), Fixture.panel(Fixture.c, Fixture.transcript(Fixture.terminal2))],
            activePanelID: Fixture.t, recency: [Fixture.t, Fixture.c], collapsed: true)
        let out = try apply(.navigate(panelID: Fixture.t, destination: Fixture.transcript(Fixture.terminal2)), to: side)
        #expect(out.side == SideRegion(
            panels: side.panels, activePanelID: Fixture.c, recency: [Fixture.c, Fixture.t], collapsed: false))
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    // MARK: - history

    @Test func historyBackForwardJumpMoveCursorOnly() throws {
        let entries = [Fixture.file("/c"), Fixture.file("/b"), Fixture.file("/a")]
        // A is inactive and the region collapsed: history must not select.
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.b, Fixture.file("/z")), Fixture.panel(Fixture.a, entries: entries)],
            activePanelID: Fixture.b, recency: [Fixture.b, Fixture.a], collapsed: true)

        let back = try apply(.history(panelID: Fixture.a, action: .back), to: side)
        #expect(back.side.panel(id: Fixture.a) == Fixture.panel(Fixture.a, entries: entries, cursor: 1))
        #expect(back.side.panel(id: Fixture.a)?.content == Fixture.file("/b"))

        let forward = try PanelSurfaceReducer.apply(
            .history(panelID: Fixture.a, action: .forward), to: back)
        #expect(forward.side.panel(id: Fixture.a) == Fixture.panel(Fixture.a, entries: entries, cursor: 0))

        let jump = try PanelSurfaceReducer.apply(
            .history(panelID: Fixture.a, action: .jump(index: 2)), to: forward)
        #expect(jump.side.panel(id: Fixture.a) == Fixture.panel(Fixture.a, entries: entries, cursor: 2))
        #expect(jump.side.panel(id: Fixture.a)?.content == Fixture.file("/a"))

        for out in [back, forward, jump] {
            #expect(out.side.panels.map(\ViewerPanel.id) == [Fixture.b, Fixture.a])
            #expect(out.side.panel(id: Fixture.b) == side.panel(id: Fixture.b))
            #expect(out.side.activePanelID == Fixture.b)
            #expect(out.side.recency == [Fixture.b, Fixture.a])
            #expect(out.side.collapsed)
        }
        #expect(jump.revision == 3)
    }

    @Test func historyUnavailableAtEnds() throws {
        let entries = [Fixture.file("/c"), Fixture.file("/b"), Fixture.file("/a")]
        let atNewest = SideRegion(
            panels: [Fixture.panel(Fixture.a, entries: entries, cursor: 0)], activePanelID: Fixture.a, recency: [Fixture.a])
        let atOldest = SideRegion(
            panels: [Fixture.panel(Fixture.a, entries: entries, cursor: 2)], activePanelID: Fixture.a, recency: [Fixture.a])
        let single = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))], activePanelID: Fixture.a, recency: [Fixture.a])

        let unavailable: [(SideRegion, PanelHistoryAction)] = [
            (atNewest, .forward),
            (atOldest, .back),
            (single, .back),
            (single, .forward),
            (atNewest, .jump(index: 0)),   // already there
            (atNewest, .jump(index: 3)),   // past the end
            (atNewest, .jump(index: -1)),  // before the start
        ]
        for (side, action) in unavailable {
            #expect(throws: PanelOperationError.historyUnavailable(Fixture.a), "\(action)") {
                _ = try apply(.history(panelID: Fixture.a, action: action), to: side)
            }
        }
    }

    @Test func historyOntoATranscriptShownElsewhereSelectsThatPanel() throws {
        // T went from terminal 1 to terminal 2; C now shows terminal 1.
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.t, entries: [Fixture.transcript(Fixture.terminal2), Fixture.transcript(Fixture.terminal1)]),
                     Fixture.panel(Fixture.c, Fixture.transcript(Fixture.terminal1))],
            activePanelID: Fixture.t, recency: [Fixture.t, Fixture.c])
        let out = try apply(.history(panelID: Fixture.t, action: .back), to: side)
        #expect(out.side == SideRegion(
            panels: side.panels, activePanelID: Fixture.c, recency: [Fixture.c, Fixture.t]))
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    @Test func historyOnAMalformedHistoryIsUnavailable() throws {
        // Decoded data only; the reducer must refuse rather than trap on the
        // out-of-range cursor.
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, entries: [Fixture.file("/b"), Fixture.file("/a")], cursor: 5)],
            activePanelID: Fixture.a, recency: [Fixture.a])
        for action in [PanelHistoryAction.back, .forward, .jump(index: 0)] {
            #expect(throws: PanelOperationError.historyUnavailable(Fixture.a), "\(action)") {
                _ = try apply(.history(panelID: Fixture.a, action: action), to: side)
            }
        }
        #expect(throws: PanelOperationError.historyUnavailable(Fixture.a)) {
            _ = try apply(.navigate(panelID: Fixture.a, destination: Fixture.file("/c")), to: side)
        }
    }

    // MARK: - setCollapsed and resize

    @Test func setCollapsedTouchesOnlyCollapsed() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))], activePanelID: Fixture.a, recency: [Fixture.a], width: 0.3)
        let hidden = try apply(.setCollapsed(true), to: side)
        #expect(hidden.side == SideRegion(
            panels: side.panels, activePanelID: Fixture.a, recency: [Fixture.a], collapsed: true, width: 0.3))
        let shown = try PanelSurfaceReducer.apply(.setCollapsed(false), to: hidden)
        #expect(shown.side == side)
    }

    @Test func resizeRejectsNonFiniteAndOutOfRange() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))], activePanelID: Fixture.a, recency: [Fixture.a])

        // NaN never equals itself, so its payload is matched by case.
        let nanError = #expect(throws: PanelOperationError.self) {
            _ = try apply(.resize(width: .nan), to: side)
        }
        if case PanelOperationError.invalidWidth(let width)? = nanError {
            #expect(width.isNaN)
        } else {
            Issue.record("expected invalidWidth(nan), got \(String(describing: nanError))")
        }

        let rejected: [Double] = [.infinity, -.infinity, 0.05, 0.95]
        for width in rejected {
            #expect(throws: PanelOperationError.invalidWidth(width)) {
                _ = try apply(.resize(width: width), to: side)
            }
        }

        let accepted: [Double] = [0.1, 0.9]
        for width in accepted {
            let out = try apply(.resize(width: width), to: side)
            #expect(out.side.width == width)
            #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
        }
    }

    // MARK: - Errors and revision

    @Test func unknownPanelThrowsPanelNotFound() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))], activePanelID: Fixture.a, recency: [Fixture.a])
        let ghost = Fixture.id(404)
        let operations: [PanelOperation] = [
            .navigate(panelID: ghost, destination: Fixture.file("/b")),
            .history(panelID: ghost, action: .back),
            .select(panelID: ghost),
            .close(panelID: ghost),
        ]
        for operation in operations {
            #expect(throws: PanelOperationError.panelNotFound(ghost), "\(operation)") {
                _ = try apply(operation, to: side)
            }
        }
    }

    @Test func everyApplyBumpsRevision() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, entries: [Fixture.file("/b"), Fixture.file("/a")]), Fixture.panel(Fixture.c, Fixture.web("/c"))],
            activePanelID: Fixture.a, recency: [Fixture.a, Fixture.c])
        let start = Fixture.surface(side, revision: 41)
        let operations: [PanelOperation] = [
            .open(content: Fixture.file("/b"), newPanel: false),      // exact match
            .open(content: Fixture.file("/d"), newPanel: false),      // reuse
            .open(content: Fixture.transcript(Fixture.terminal1), newPanel: false), // new panel
            .open(content: Fixture.note(1), newPanel: false),         // new worktree panel
            .open(content: .changes, newPanel: true),                 // new worktree panel
            .navigate(panelID: Fixture.a, destination: Fixture.file("/b")), // no-op navigation
            .navigate(panelID: Fixture.a, destination: Fixture.file("/e")),
            .history(panelID: Fixture.a, action: .back),
            .select(panelID: Fixture.a),                              // already active
            .select(panelID: Fixture.c),
            .close(panelID: Fixture.c),
            .setCollapsed(true),
            .setCollapsed(false),                               // already shown
            .resize(width: 0.25),
        ]
        // Each applies to `start`, not to the previous result.
        for operation in operations {
            let out = try PanelSurfaceReducer.apply(operation, to: start, makeID: { Fixture.fresh })
            #expect(out.revision == 42, "\(operation)")
        }
    }

    @Test func aThrowLeavesTheCallersSurfaceUnchanged() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))], activePanelID: Fixture.a, recency: [Fixture.a])
        let surface = Fixture.surface(side, revision: 7)
        let copy = surface
        #expect(throws: PanelOperationError.self) {
            _ = try PanelSurfaceReducer.apply(
                .navigate(panelID: Fixture.a, destination: Fixture.web("/w")), to: surface)
        }
        #expect(surface == copy)
    }

    // MARK: - Worktree panels

    private func applySurface(
        _ operation: PanelOperation, to surface: WorkspaceTabSurface
    ) throws -> WorkspaceTabSurface {
        try PanelSurfaceReducer.apply(operation, to: surface, makeID: { Fixture.fresh })
    }

    @Test func openNoteAppendsWorktreePanelAndSelects() throws {
        // A collapsed region with one own panel, and a Changes panel already
        // in the worktree: the note's panel goes after it.
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))],
            activePanelID: Fixture.a, recency: [Fixture.a], collapsed: true, width: 0.3)
        let start = Fixture.surface(side, worktreePanels: [Fixture.changesPanel(Fixture.ch)])
        // `newPanel` plays no part in opening worktree content.
        for newPanel in [false, true] {
            let out = try applySurface(.open(content: Fixture.note(1), newPanel: newPanel), to: start)

            let expectedPanels = [Fixture.changesPanel(Fixture.ch), Fixture.notePanel(Fixture.fresh, 1)]
            #expect(out.worktreePanels == expectedPanels, "newPanel \(newPanel)")
            #expect(out.side == SideRegion(
                panels: side.panels, activePanelID: Fixture.fresh, recency: [Fixture.a],
                collapsed: false, width: 0.3), "newPanel \(newPanel)")
            #expect(out.revision == 1)
            #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
        }
    }

    @Test func openExistingWorktreeContentSelects() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))],
            activePanelID: Fixture.a, recency: [Fixture.a], collapsed: true)
        let worktreePanels = [Fixture.notePanel(Fixture.n1, 1), Fixture.changesPanel(Fixture.ch)]
        let start = Fixture.surface(side, worktreePanels: worktreePanels)

        let note = try applySurface(.open(content: Fixture.note(1), newPanel: false), to: start)
        #expect(note.worktreePanels == worktreePanels)
        #expect(note.side == SideRegion(
            panels: side.panels, activePanelID: Fixture.n1, recency: [Fixture.a], collapsed: false))

        let changes = try applySurface(.open(content: .changes, newPanel: true), to: start)
        #expect(changes.worktreePanels == worktreePanels)
        #expect(changes.side == SideRegion(
            panels: side.panels, activePanelID: Fixture.ch, recency: [Fixture.a], collapsed: false))

        // Opening the same note twice from nothing keeps one panel, whatever
        // the second open's `newPanel`.
        var nextID = 0
        let makeID: () -> UUID = {
            nextID += 1
            return ReducerFixture.id(nextID)
        }
        let once = try PanelSurfaceReducer.apply(
            .open(content: Fixture.note(2), newPanel: false), to: Fixture.surface(.empty), makeID: makeID)
        let twice = try PanelSurfaceReducer.apply(
            .open(content: Fixture.note(2), newPanel: true), to: once, makeID: makeID)
        #expect(twice.worktreePanels == [Fixture.notePanel(Fixture.id(1), 2)])
        #expect(twice.side == SideRegion(activePanelID: Fixture.id(1)))
        #expect(PanelSurfaceValidator.violations(in: twice).isEmpty)
    }

    @Test func selectWorktreePanelKeepsRecency() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))],
            activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b], collapsed: true, width: 0.3)
        let worktreePanels = [Fixture.notePanel(Fixture.n1, 1)]
        let out = try applySurface(
            .select(panelID: Fixture.n1), to: Fixture.surface(side, worktreePanels: worktreePanels))
        #expect(out.side == SideRegion(
            panels: side.panels, activePanelID: Fixture.n1, recency: [Fixture.a, Fixture.b],
            collapsed: false, width: 0.3))
        #expect(out.worktreePanels == worktreePanels)
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    @Test func closeWorktreePanelFallsBackToRecencyThenWorktreePanels() throws {
        // Own panels: the most recent one comes forward.
        let withOwn = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))],
            activePanelID: Fixture.n1, recency: [Fixture.b, Fixture.a])
        let ownOut = try applySurface(
            .close(panelID: Fixture.n1),
            to: Fixture.surface(
                withOwn, worktreePanels: [Fixture.notePanel(Fixture.n1, 1), Fixture.changesPanel(Fixture.ch)]))
        #expect(ownOut.worktreePanels == [Fixture.changesPanel(Fixture.ch)])
        #expect(ownOut.side == SideRegion(
            panels: withOwn.panels, activePanelID: Fixture.b, recency: [Fixture.b, Fixture.a]))
        #expect(PanelSurfaceValidator.violations(in: ownOut).isEmpty)

        // No own panels: the first remaining worktree panel comes forward.
        let worktreeOnly = SideRegion(activePanelID: Fixture.n2)
        let worktreeOut = try applySurface(
            .close(panelID: Fixture.n2),
            to: Fixture.surface(worktreeOnly, worktreePanels: [
                Fixture.notePanel(Fixture.n1, 1), Fixture.notePanel(Fixture.n2, 2), Fixture.changesPanel(Fixture.ch),
            ]))
        let remaining = [Fixture.notePanel(Fixture.n1, 1), Fixture.changesPanel(Fixture.ch)]
        #expect(worktreeOut.worktreePanels == remaining)
        #expect(worktreeOut.side == SideRegion(activePanelID: Fixture.n1))
        #expect(PanelSurfaceValidator.violations(in: worktreeOut).isEmpty)

        // None left: nothing is in front, and the region hides.
        let last = try applySurface(
            .close(panelID: Fixture.n1),
            to: Fixture.surface(SideRegion(activePanelID: Fixture.n1), worktreePanels: [Fixture.notePanel(Fixture.n1, 1)]))
        #expect(last.worktreePanels.isEmpty)
        #expect(last.side == .empty)
        #expect(!last.isSideVisible)
        #expect(PanelSurfaceValidator.violations(in: last).isEmpty)

        // A worktree panel closed behind an own panel leaves the front alone.
        let behind = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))], activePanelID: Fixture.a, recency: [Fixture.a])
        let behindOut = try applySurface(
            .close(panelID: Fixture.n1),
            to: Fixture.surface(behind, worktreePanels: [Fixture.notePanel(Fixture.n1, 1)]))
        #expect(behindOut.worktreePanels.isEmpty)
        #expect(behindOut.side == behind)
    }

    /// Closing the tab's last own panel while it is in front fronts the
    /// first worktree panel and collapses the region, so the region hides
    /// rather than stay open on the worktree's note.
    @Test func closeLastOwnPanelInFrontCollapsesOntoWorktreePanel() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1))],
            activePanelID: Fixture.t, recency: [Fixture.t], width: 0.3)
        let worktreePanels = [Fixture.notePanel(Fixture.n1, 1), Fixture.changesPanel(Fixture.ch)]
        let out = try applySurface(
            .close(panelID: Fixture.t), to: Fixture.surface(side, worktreePanels: worktreePanels))
        #expect(out.side == SideRegion(activePanelID: Fixture.n1, collapsed: true, width: 0.3))
        #expect(out.worktreePanels == worktreePanels)
        #expect(!out.isSideVisible)
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    /// Only closing the last own panel in front collapses. Closing the last
    /// own panel behind a worktree panel, closing the own panel in front
    /// while another own panel remains, and closing a worktree panel each
    /// leave `collapsed` as it was.
    @Test(arguments: [false, true])
    func closeLeavesCollapseAloneUnlessLastOwnPanelInFront(collapsed: Bool) throws {
        let worktreePanels = [Fixture.notePanel(Fixture.n1, 1), Fixture.changesPanel(Fixture.ch)]

        // The last own panel, behind the note's worktree panel.
        let behind = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))],
            activePanelID: Fixture.n1, recency: [Fixture.a], collapsed: collapsed)
        let behindOut = try applySurface(
            .close(panelID: Fixture.a), to: Fixture.surface(behind, worktreePanels: worktreePanels))
        #expect(behindOut.side == SideRegion(activePanelID: Fixture.n1, collapsed: collapsed))
        #expect(behindOut.worktreePanels == worktreePanels)
        #expect(PanelSurfaceValidator.violations(in: behindOut).isEmpty)

        // The own panel in front, with another own panel left.
        let withAnother = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))],
            activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b], collapsed: collapsed)
        let withAnotherOut = try applySurface(
            .close(panelID: Fixture.a), to: Fixture.surface(withAnother, worktreePanels: worktreePanels))
        #expect(withAnotherOut.side == SideRegion(
            panels: [Fixture.panel(Fixture.b, Fixture.file("/b"))],
            activePanelID: Fixture.b, recency: [Fixture.b], collapsed: collapsed))
        #expect(PanelSurfaceValidator.violations(in: withAnotherOut).isEmpty)

        // A worktree panel in front, with no own panels.
        let worktreeOnly = SideRegion(activePanelID: Fixture.n1, collapsed: collapsed)
        let worktreeOut = try applySurface(
            .close(panelID: Fixture.n1), to: Fixture.surface(worktreeOnly, worktreePanels: worktreePanels))
        #expect(worktreeOut.side == SideRegion(activePanelID: Fixture.ch, collapsed: collapsed))
        let remaining = [Fixture.changesPanel(Fixture.ch)]
        #expect(worktreeOut.worktreePanels == remaining)
        #expect(PanelSurfaceValidator.violations(in: worktreeOut).isEmpty)
    }

    @Test func historyAndNavigateOnWorktreePanelRefused() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))], activePanelID: Fixture.n1, recency: [Fixture.a])
        let surface = Fixture.surface(side, worktreePanels: [Fixture.notePanel(Fixture.n1, 1)])
        let actions: [PanelHistoryAction] = [.back, .forward, .jump(index: 0)]
        for action in actions {
            #expect(throws: PanelOperationError.worktreePanelHasNoHistory(Fixture.n1), "\(action)") {
                _ = try applySurface(.history(panelID: Fixture.n1, action: action), to: surface)
            }
        }
        #expect(throws: PanelOperationError.worktreePanelHasNoHistory(Fixture.n1)) {
            _ = try applySurface(.navigate(panelID: Fixture.n1, destination: Fixture.note(2)), to: surface)
        }
    }

    @Test func navigateOwnPanelToNoteIsKindMismatch() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a"))], activePanelID: Fixture.a, recency: [Fixture.a])
        #expect(throws: PanelOperationError.kindMismatch(panelID: Fixture.a, expected: .file, actual: .note)) {
            _ = try apply(.navigate(panelID: Fixture.a, destination: Fixture.note(1)), to: side)
        }
        #expect(throws: PanelOperationError.kindMismatch(panelID: Fixture.a, expected: .file, actual: .changes)) {
            _ = try apply(.navigate(panelID: Fixture.a, destination: .changes), to: side)
        }
    }

    @Test func ownPanelOpenedWhileWorktreePanelInFrontGoesFirst() throws {
        let side = SideRegion(
            panels: [Fixture.panel(Fixture.a, Fixture.file("/a")),
                     Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1))],
            activePanelID: Fixture.n1, recency: [Fixture.a, Fixture.t])
        let worktreePanels = [Fixture.notePanel(Fixture.n1, 1)]
        let start = Fixture.surface(side, worktreePanels: worktreePanels)

        let created = try applySurface(.open(content: Fixture.web("/w"), newPanel: false), to: start)
        let expectedPanels: [ViewerPanel] = [Fixture.panel(Fixture.fresh, Fixture.web("/w"))] + side.panels
        #expect(created.side == SideRegion(
            panels: expectedPanels,
            activePanelID: Fixture.fresh, recency: [Fixture.fresh, Fixture.a, Fixture.t]))
        #expect(created.worktreePanels == worktreePanels)
        #expect(PanelSurfaceValidator.violations(in: created).isEmpty)

        // Reuse passes over the worktree panel in front to the most recent
        // own panel of the kind.
        let reused = try applySurface(.open(content: Fixture.file("/b"), newPanel: false), to: start)
        #expect(reused.side == SideRegion(
            panels: [Fixture.panel(Fixture.a, entries: [Fixture.file("/b"), Fixture.file("/a")]),
                     Fixture.panel(Fixture.t, Fixture.transcript(Fixture.terminal1))],
            activePanelID: Fixture.a, recency: [Fixture.a, Fixture.t]))
    }

    @Test func adoptingRepairsFront() {
        let ownPanels = [Fixture.panel(Fixture.a, Fixture.file("/a")), Fixture.panel(Fixture.b, Fixture.file("/b"))]
        let note = Fixture.notePanel(Fixture.n1, 1)
        let changes = Fixture.changesPanel(Fixture.ch)

        // The front's panel left the list: the most recent own panel comes
        // forward, and collapse and revision stay as they were.
        let withOwn = Fixture.surface(
            SideRegion(panels: ownPanels, activePanelID: Fixture.n1, recency: [Fixture.b, Fixture.a], collapsed: true),
            worktreePanels: [note, changes], revision: 5)
        let ownOut = PanelSurfaceReducer.adopting([changes], into: withOwn)
        #expect(ownOut.worktreePanels == [changes])
        #expect(ownOut.side == SideRegion(
            panels: ownPanels, activePanelID: Fixture.b, recency: [Fixture.b, Fixture.a], collapsed: true))
        #expect(ownOut.revision == 5)
        #expect(PanelSurfaceValidator.violations(in: ownOut).isEmpty)

        // With no own panels, the list's first panel comes forward; with an
        // empty list, nothing does.
        let worktreeOnly = Fixture.surface(SideRegion(activePanelID: Fixture.n1), worktreePanels: [note, changes])
        let firstOut = PanelSurfaceReducer.adopting([changes], into: worktreeOnly)
        #expect(firstOut.side.activePanelID == Fixture.ch)
        #expect(PanelSurfaceValidator.violations(in: firstOut).isEmpty)
        let emptyOut = PanelSurfaceReducer.adopting([], into: worktreeOnly)
        #expect(emptyOut.side.activePanelID == nil)
        #expect(PanelSurfaceValidator.violations(in: emptyOut).isEmpty)

        // Nothing in front and a list to show: its first panel comes forward.
        let nothing = Fixture.surface(.empty)
        let shownOut = PanelSurfaceReducer.adopting([note, changes], into: nothing)
        #expect(shownOut.side == SideRegion(activePanelID: Fixture.n1))
        #expect(PanelSurfaceValidator.violations(in: shownOut).isEmpty)

        // A front that still names a panel is kept, of either kind.
        let ownFront = Fixture.surface(
            SideRegion(panels: ownPanels, activePanelID: Fixture.a, recency: [Fixture.a, Fixture.b]),
            worktreePanels: [note])
        #expect(PanelSurfaceReducer.adopting([changes], into: ownFront).side == ownFront.side)
        let worktreeFront = Fixture.surface(
            SideRegion(panels: ownPanels, activePanelID: Fixture.n1, recency: [Fixture.a, Fixture.b]),
            worktreePanels: [note])
        #expect(PanelSurfaceReducer.adopting([changes, note], into: worktreeFront).side == worktreeFront.side)
    }
}
