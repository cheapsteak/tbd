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

private typealias F = ReducerFixture

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
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.b, F.file("/b"))],
                activePanelID: F.a, recency: [F.a, F.b]),
            operation: .open(content: F.file("/b"), newPanel: false),
            after: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.b, F.file("/b"))],
                activePanelID: F.b, recency: [F.b, F.a])),
        OpenReuseRow(
            name: "newPanel true still selects an exact match",
            before: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.b, F.file("/b"))],
                activePanelID: F.a, recency: [F.a, F.b]),
            operation: .open(content: F.file("/b"), newPanel: true),
            after: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.b, F.file("/b"))],
                activePanelID: F.b, recency: [F.b, F.a])),
        OpenReuseRow(
            name: "the active panel is navigated when it is the same kind",
            before: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.b, F.file("/b"))],
                activePanelID: F.a, recency: [F.a, F.b]),
            operation: .open(content: F.file("/c"), newPanel: false),
            after: SideRegion(
                panels: [F.panel(F.a, entries: [F.file("/c"), F.file("/a")]),
                         F.panel(F.b, F.file("/b"))],
                activePanelID: F.a, recency: [F.a, F.b])),
        OpenReuseRow(
            name: "an active panel of another kind gives way to the most recent same-kind panel",
            // A comes first in the strip, B first in recency: B is reused.
            before: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.w, F.web("/w")),
                         F.panel(F.b, F.file("/b"))],
                activePanelID: F.w, recency: [F.w, F.b, F.a]),
            operation: .open(content: F.file("/c"), newPanel: false),
            after: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.w, F.web("/w")),
                         F.panel(F.b, entries: [F.file("/c"), F.file("/b")])],
                activePanelID: F.b, recency: [F.b, F.w, F.a])),
        OpenReuseRow(
            name: "with no panel of the kind a new panel goes right after the active one",
            before: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.b, F.file("/b"))],
                activePanelID: F.a, recency: [F.a, F.b]),
            operation: .open(content: F.web("/w"), newPanel: false),
            after: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.fresh, F.web("/w")),
                         F.panel(F.b, F.file("/b"))],
                activePanelID: F.fresh, recency: [F.fresh, F.a, F.b])),
        OpenReuseRow(
            name: "an empty region gets its first panel",
            before: .empty,
            operation: .open(content: F.note(1), newPanel: false),
            after: SideRegion(
                panels: [F.panel(F.fresh, F.note(1))],
                activePanelID: F.fresh, recency: [F.fresh])),
        OpenReuseRow(
            name: "a transcript never reuses a transcript panel",
            before: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.t, F.transcript(F.terminal1))],
                activePanelID: F.t, recency: [F.t, F.a]),
            operation: .open(content: F.transcript(F.terminal2), newPanel: false),
            after: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.t, F.transcript(F.terminal1)),
                         F.panel(F.fresh, F.transcript(F.terminal2))],
                activePanelID: F.fresh, recency: [F.fresh, F.t, F.a])),
        OpenReuseRow(
            name: "newPanel true creates although a same-kind panel is active",
            before: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.b, F.file("/b"))],
                activePanelID: F.a, recency: [F.a, F.b]),
            operation: .open(content: F.file("/c"), newPanel: true),
            after: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.fresh, F.file("/c")),
                         F.panel(F.b, F.file("/b"))],
                activePanelID: F.fresh, recency: [F.fresh, F.a, F.b])),
        OpenReuseRow(
            name: "a file never lands in the active transcript panel",
            before: SideRegion(
                panels: [F.panel(F.t, F.transcript(F.terminal1))],
                activePanelID: F.t, recency: [F.t]),
            operation: .open(content: F.file("/a"), newPanel: false),
            after: SideRegion(
                panels: [F.panel(F.t, F.transcript(F.terminal1)), F.panel(F.fresh, F.file("/a"))],
                activePanelID: F.fresh, recency: [F.fresh, F.t])),
        OpenReuseRow(
            name: "a file passes over the active transcript to the file panel behind it",
            before: SideRegion(
                panels: [F.panel(F.a, F.file("/a")), F.panel(F.t, F.transcript(F.terminal1))],
                activePanelID: F.t, recency: [F.t, F.a]),
            operation: .open(content: F.file("/b"), newPanel: false),
            after: SideRegion(
                panels: [F.panel(F.a, entries: [F.file("/b"), F.file("/a")]),
                         F.panel(F.t, F.transcript(F.terminal1))],
                activePanelID: F.a, recency: [F.a, F.t])),
    ]
}

@Suite("PanelSurfaceReducerTests")
struct PanelSurfaceReducerTests {
    private func apply(
        _ operation: PanelOperation, to side: SideRegion
    ) throws -> WorkspaceTabSurface {
        try PanelSurfaceReducer.apply(operation, to: F.surface(side), makeID: { F.fresh })
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
        let contents = [F.transcript(F.terminal1), F.file("/a")]
        for content in contents {
            for newPanel in [false, true] {
                var nextID = 0
                let makeID: () -> UUID = {
                    nextID += 1
                    return ReducerFixture.id(nextID)
                }
                let once = try PanelSurfaceReducer.apply(
                    .open(content: content, newPanel: newPanel), to: F.surface(.empty), makeID: makeID)
                let twice = try PanelSurfaceReducer.apply(
                    .open(content: content, newPanel: newPanel), to: once, makeID: makeID)
                let expected = SideRegion(
                    panels: [F.panel(F.id(1), content)],
                    activePanelID: F.id(1), recency: [F.id(1)])
                #expect(twice.side == expected, "\(content) newPanel \(newPanel)")
                #expect(twice.revision == 2)
            }
        }
    }

    @Test func openClearsCollapsed() throws {
        let side = SideRegion(
            panels: [F.panel(F.a, F.file("/a")), F.panel(F.t, F.transcript(F.terminal1))],
            activePanelID: F.a, recency: [F.a, F.t], collapsed: true)
        let paths: [(String, PanelContent)] = [
            ("exact match", F.transcript(F.terminal1)),
            ("reuse", F.file("/b")),
            ("new panel", F.web("/w")),
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
            panels: [F.panel(F.a, F.file("/a")), F.panel(F.b, F.file("/b")), F.panel(F.c, F.file("/c"))],
            activePanelID: F.a, recency: [F.a, F.b, F.c], collapsed: true, width: 0.3)
        let out = try apply(.select(panelID: F.c), to: side)
        #expect(out.side == SideRegion(
            panels: side.panels, activePanelID: F.c, recency: [F.c, F.a, F.b],
            collapsed: false, width: 0.3))
    }

    @Test func selectingTheActivePanelShowsACollapsedRegion() throws {
        let side = SideRegion(
            panels: [F.panel(F.a, F.file("/a"))],
            activePanelID: F.a, recency: [F.a], collapsed: true)
        let out = try apply(.select(panelID: F.a), to: side)
        #expect(out.side == SideRegion(
            panels: side.panels, activePanelID: F.a, recency: [F.a], collapsed: false))
    }

    // MARK: - close

    /// Strip order A, B, C; recency A, C, B — so "most recent" and "next in
    /// the strip" disagree.
    private var threePanels: SideRegion {
        SideRegion(
            panels: [F.panel(F.a, F.file("/a")), F.panel(F.b, F.file("/b")), F.panel(F.c, F.file("/c"))],
            activePanelID: F.a, recency: [F.a, F.c, F.b])
    }

    @Test func closeActivePicksMostRecent() throws {
        let out = try apply(.close(panelID: F.a), to: threePanels)
        #expect(out.side == SideRegion(
            panels: [F.panel(F.b, F.file("/b")), F.panel(F.c, F.file("/c"))],
            activePanelID: F.c, recency: [F.c, F.b]))
    }

    @Test func closeInactiveKeepsActive() throws {
        let out = try apply(.close(panelID: F.b), to: threePanels)
        #expect(out.side == SideRegion(
            panels: [F.panel(F.a, F.file("/a")), F.panel(F.c, F.file("/c"))],
            activePanelID: F.a, recency: [F.a, F.c]))
    }

    @Test func closeLastLeavesEmptyRegion() throws {
        let side = SideRegion(
            panels: [F.panel(F.a, entries: [F.file("/b"), F.file("/a")])],
            activePanelID: F.a, recency: [F.a], width: 0.3)
        let out = try apply(.close(panelID: F.a), to: side)
        #expect(out.side == SideRegion(width: 0.3))
        #expect(!out.side.isVisible)
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    // MARK: - navigate

    @Test func navigateRejectsKindChange() throws {
        let side = SideRegion(
            panels: [F.panel(F.a, F.file("/a")), F.panel(F.t, F.transcript(F.terminal1))],
            activePanelID: F.a, recency: [F.a, F.t])
        #expect(throws: PanelOperationError.kindMismatch(panelID: F.a, expected: .file, actual: .web)) {
            _ = try apply(.navigate(panelID: F.a, destination: F.web("/w")), to: side)
        }
        #expect(throws: PanelOperationError.kindMismatch(
            panelID: F.t, expected: .transcript, actual: .file)) {
            _ = try apply(.navigate(panelID: F.t, destination: F.file("/b")), to: side)
        }
    }

    @Test func navigateRecordsHistoryAndLeavesSelectionAlone() throws {
        let side = SideRegion(
            panels: [F.panel(F.a, F.file("/a")), F.panel(F.b, F.file("/b"))],
            activePanelID: F.a, recency: [F.a, F.b], collapsed: true)
        let out = try apply(.navigate(panelID: F.b, destination: F.file("/c")), to: side)
        #expect(out.side == SideRegion(
            panels: [F.panel(F.a, F.file("/a")), F.panel(F.b, entries: [F.file("/c"), F.file("/b")])],
            activePanelID: F.a, recency: [F.a, F.b], collapsed: true))
    }

    @Test func navigateToTheCurrentContentIsANoOpThatBumpsRevision() throws {
        let side = SideRegion(
            panels: [F.panel(F.a, F.file("/a"))], activePanelID: F.a, recency: [F.a])
        let out = try apply(.navigate(panelID: F.a, destination: F.file("/a")), to: side)
        #expect(out.side == side)
        #expect(out.revision == 1)
    }

    /// A transcript has one view per workspace tab: pointing a second panel at
    /// a transcript another panel shows selects that panel instead.
    @Test func navigateOntoATranscriptShownElsewhereSelectsThatPanel() throws {
        let side = SideRegion(
            panels: [F.panel(F.t, F.transcript(F.terminal1)), F.panel(F.c, F.transcript(F.terminal2))],
            activePanelID: F.t, recency: [F.t, F.c], collapsed: true)
        let out = try apply(.navigate(panelID: F.t, destination: F.transcript(F.terminal2)), to: side)
        #expect(out.side == SideRegion(
            panels: side.panels, activePanelID: F.c, recency: [F.c, F.t], collapsed: false))
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    // MARK: - history

    @Test func historyBackForwardJumpMoveCursorOnly() throws {
        let entries = [F.file("/c"), F.file("/b"), F.file("/a")]
        // A is inactive and the region collapsed: history must not select.
        let side = SideRegion(
            panels: [F.panel(F.b, F.file("/z")), F.panel(F.a, entries: entries)],
            activePanelID: F.b, recency: [F.b, F.a], collapsed: true)

        let back = try apply(.history(panelID: F.a, action: .back), to: side)
        #expect(back.side.panel(id: F.a) == F.panel(F.a, entries: entries, cursor: 1))
        #expect(back.side.panel(id: F.a)?.content == F.file("/b"))

        let forward = try PanelSurfaceReducer.apply(
            .history(panelID: F.a, action: .forward), to: back)
        #expect(forward.side.panel(id: F.a) == F.panel(F.a, entries: entries, cursor: 0))

        let jump = try PanelSurfaceReducer.apply(
            .history(panelID: F.a, action: .jump(index: 2)), to: forward)
        #expect(jump.side.panel(id: F.a) == F.panel(F.a, entries: entries, cursor: 2))
        #expect(jump.side.panel(id: F.a)?.content == F.file("/a"))

        for out in [back, forward, jump] {
            #expect(out.side.panels.map(\.id) == [F.b, F.a])
            #expect(out.side.panel(id: F.b) == side.panel(id: F.b))
            #expect(out.side.activePanelID == F.b)
            #expect(out.side.recency == [F.b, F.a])
            #expect(out.side.collapsed)
        }
        #expect(jump.revision == 3)
    }

    @Test func historyUnavailableAtEnds() throws {
        let entries = [F.file("/c"), F.file("/b"), F.file("/a")]
        let atNewest = SideRegion(
            panels: [F.panel(F.a, entries: entries, cursor: 0)], activePanelID: F.a, recency: [F.a])
        let atOldest = SideRegion(
            panels: [F.panel(F.a, entries: entries, cursor: 2)], activePanelID: F.a, recency: [F.a])
        let single = SideRegion(
            panels: [F.panel(F.a, F.file("/a"))], activePanelID: F.a, recency: [F.a])

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
            #expect(throws: PanelOperationError.historyUnavailable(F.a), "\(action)") {
                _ = try apply(.history(panelID: F.a, action: action), to: side)
            }
        }
    }

    @Test func historyOntoATranscriptShownElsewhereSelectsThatPanel() throws {
        // T went from terminal 1 to terminal 2; C now shows terminal 1.
        let side = SideRegion(
            panels: [F.panel(F.t, entries: [F.transcript(F.terminal2), F.transcript(F.terminal1)]),
                     F.panel(F.c, F.transcript(F.terminal1))],
            activePanelID: F.t, recency: [F.t, F.c])
        let out = try apply(.history(panelID: F.t, action: .back), to: side)
        #expect(out.side == SideRegion(
            panels: side.panels, activePanelID: F.c, recency: [F.c, F.t]))
        #expect(PanelSurfaceValidator.violations(in: out).isEmpty)
    }

    @Test func historyOnAMalformedHistoryIsUnavailable() throws {
        // Decoded data only; the reducer must refuse rather than trap on the
        // out-of-range cursor.
        let side = SideRegion(
            panels: [F.panel(F.a, entries: [F.file("/b"), F.file("/a")], cursor: 5)],
            activePanelID: F.a, recency: [F.a])
        for action in [PanelHistoryAction.back, .forward, .jump(index: 0)] {
            #expect(throws: PanelOperationError.historyUnavailable(F.a), "\(action)") {
                _ = try apply(.history(panelID: F.a, action: action), to: side)
            }
        }
        #expect(throws: PanelOperationError.historyUnavailable(F.a)) {
            _ = try apply(.navigate(panelID: F.a, destination: F.file("/c")), to: side)
        }
    }

    // MARK: - setCollapsed and resize

    @Test func setCollapsedTouchesOnlyCollapsed() throws {
        let side = SideRegion(
            panels: [F.panel(F.a, F.file("/a"))], activePanelID: F.a, recency: [F.a], width: 0.3)
        let hidden = try apply(.setCollapsed(true), to: side)
        #expect(hidden.side == SideRegion(
            panels: side.panels, activePanelID: F.a, recency: [F.a], collapsed: true, width: 0.3))
        let shown = try PanelSurfaceReducer.apply(.setCollapsed(false), to: hidden)
        #expect(shown.side == side)
    }

    @Test func resizeRejectsNonFiniteAndOutOfRange() throws {
        let side = SideRegion(
            panels: [F.panel(F.a, F.file("/a"))], activePanelID: F.a, recency: [F.a])

        // NaN never equals itself, so its payload is matched by case.
        let nanError = #expect(throws: PanelOperationError.self) {
            _ = try apply(.resize(width: .nan), to: side)
        }
        if case .invalidWidth(let width)? = nanError {
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
            panels: [F.panel(F.a, F.file("/a"))], activePanelID: F.a, recency: [F.a])
        let ghost = F.id(404)
        let operations: [PanelOperation] = [
            .navigate(panelID: ghost, destination: F.file("/b")),
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
            panels: [F.panel(F.a, entries: [F.file("/b"), F.file("/a")]), F.panel(F.c, F.web("/c"))],
            activePanelID: F.a, recency: [F.a, F.c])
        let start = F.surface(side, revision: 41)
        let operations: [PanelOperation] = [
            .open(content: F.file("/b"), newPanel: false),      // exact match
            .open(content: F.file("/d"), newPanel: false),      // reuse
            .open(content: F.note(1), newPanel: false),         // new panel
            .navigate(panelID: F.a, destination: F.file("/b")), // no-op navigation
            .navigate(panelID: F.a, destination: F.file("/e")),
            .history(panelID: F.a, action: .back),
            .select(panelID: F.a),                              // already active
            .select(panelID: F.c),
            .close(panelID: F.c),
            .setCollapsed(true),
            .setCollapsed(false),                               // already shown
            .resize(width: 0.25),
        ]
        // Each applies to `start`, not to the previous result.
        for operation in operations {
            let out = try PanelSurfaceReducer.apply(operation, to: start, makeID: { F.fresh })
            #expect(out.revision == 42, "\(operation)")
        }
    }

    @Test func aThrowLeavesTheCallersSurfaceUnchanged() throws {
        let side = SideRegion(
            panels: [F.panel(F.a, F.file("/a"))], activePanelID: F.a, recency: [F.a])
        let surface = F.surface(side, revision: 7)
        let copy = surface
        #expect(throws: PanelOperationError.self) {
            _ = try PanelSurfaceReducer.apply(
                .navigate(panelID: F.a, destination: F.web("/w")), to: surface)
        }
        #expect(surface == copy)
    }
}
