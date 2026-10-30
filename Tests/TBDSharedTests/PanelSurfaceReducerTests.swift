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

    static func surface(_ side: SideRegion, revision: UInt64 = 0) -> WorkspaceTabSurface {
        WorkspaceTabSurface(
            id: id(900), worktreeID: id(901),
            primary: .terminal(terminalID: id(902)), side: side, revision: revision)
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
            operation: .open(content: Fixture.note(1), newPanel: false),
            after: SideRegion(
                panels: [Fixture.panel(Fixture.fresh, Fixture.note(1))],
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
            .open(content: Fixture.note(1), newPanel: false),         // new panel
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
}
