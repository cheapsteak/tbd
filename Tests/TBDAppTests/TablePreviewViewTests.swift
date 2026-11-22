import AppKit
import Testing
import TestSupport
@testable import TBDApp

/// A borderless window far off every display, never ordered front, whose
/// content view holds one 600 × 400 `TableHostView`.
@MainActor
private final class TablePreviewScene {
    let window: NSWindow
    let host: TableHostView

    init() {
        // Enough of an application for AppKit to have an app object at all.
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let host = TableHostView()
        host.frame = content.bounds
        content.addSubview(host)
        self.window = window
        self.host = host
    }

    func tearDown() {
        window.contentView = nil
        window.close()
    }
}

/// The cell the host's delegate makes for `row` and `column`, asked for
/// directly rather than through the table's own layout.
@MainActor
private func tablePreviewCell(in host: TableHostView, row: Int, column: Int) -> NSTableCellView? {
    let columns = host.tableView.tableColumns
    guard columns.indices.contains(column) else { return nil }
    return host.tableView(host.tableView, viewFor: columns[column], row: row) as? NSTableCellView
}

@MainActor
private func tablePreviewCellText(in host: TableHostView, row: Int, column: Int) -> String? {
    tablePreviewCell(in: host, row: row, column: column)?.textField?.stringValue
}

@MainActor
private func tablePreviewTitles(of host: TableHostView) -> [String] {
    host.tableView.tableColumns.map(\.title)
}

@MainActor
private func tablePreviewRowCount(of host: TableHostView) -> Int {
    host.numberOfRows(in: host.tableView)
}

private let peopleTable = DelimitedTable(
    titles: ["name", "age"],
    rows: [["Ada", "36"], ["Linus", "54"], ["Grace", "85"]],
    columnCount: 2,
    stoppedAtLimit: false)

/// `TableHostView` in an offscreen window: the header row gives the columns,
/// cells show their values on one line, and a rewrite with the same columns
/// keeps the widths the user set.
@MainActor
@Suite("TablePreviewView", .fastPassBounded)
struct TablePreviewViewTests {
    @Test func columnsAreTheHeaderRow() {
        let scene = TablePreviewScene()
        defer { scene.tearDown() }

        scene.host.show(peopleTable)

        let titles = tablePreviewTitles(of: scene.host)
        #expect(titles == ["name", "age"])
        let identifiers = scene.host.tableView.tableColumns.map { $0.identifier.rawValue }
        #expect(identifiers == ["col0", "col1"])
        #expect(tablePreviewRowCount(of: scene.host) == 3)
    }

    @Test func cellShowsItsValue() {
        let scene = TablePreviewScene()
        defer { scene.tearDown() }

        scene.host.show(peopleTable)

        #expect(tablePreviewCellText(in: scene.host, row: 1, column: 0) == "Linus")
        #expect(tablePreviewCellText(in: scene.host, row: 2, column: 1) == "85")
    }

    @Test func lineBreakShowsReturnSymbol() {
        #expect(TableHostView.displayString("a\nb\r\nc\rd") == "a↵b↵c↵d")
        #expect(TableHostView.displayString("no break") == "no break")

        let scene = TablePreviewScene()
        defer { scene.tearDown() }
        scene.host.show(DelimitedTable(
            titles: ["note"], rows: [["one\ntwo"]], columnCount: 1, stoppedAtLimit: false))

        #expect(tablePreviewCellText(in: scene.host, row: 0, column: 0) == "one↵two")
    }

    @Test func longValueIsCut() {
        let shown = TableHostView.displayString(String(repeating: "x", count: 5_000))
        #expect(shown == String(repeating: "x", count: 1_000) + "…")
        // A line break inside the kept part still shows as the return symbol.
        let withBreak = TableHostView.displayString(String(repeating: "x", count: 999) + "\nyz")
        #expect(withBreak == String(repeating: "x", count: 999) + "↵…")

        let scene = TablePreviewScene()
        defer { scene.tearDown() }
        scene.host.show(DelimitedTable(
            titles: ["blob"], rows: [[String(repeating: "y", count: 5_000)]], columnCount: 1,
            stoppedAtLimit: false))

        let cellText = tablePreviewCellText(in: scene.host, row: 0, column: 0)
        #expect(cellText == String(repeating: "y", count: 1_000) + "…")
    }

    @Test func valueAtTheLimitIsWhole() {
        let value = String(repeating: "x", count: 1_000)
        #expect(TableHostView.maxDisplayedCharacters == 1_000)
        #expect(TableHostView.displayString(value) == value)
    }

    /// The rows measured shrink so that rows × columns stays within the
    /// measuring budget, and never below one row.
    @Test func sampledRowsShrinkForWideTables() {
        #expect(TableHostView.sampledRowCount(columnCount: 2) == 200)
        #expect(TableHostView.sampledRowCount(columnCount: 1_000) == 20)
        #expect(TableHostView.sampledRowCount(columnCount: 100_000) == 1)
    }

    @Test func cellBeyondShortRowIsEmpty() {
        let scene = TablePreviewScene()
        defer { scene.tearDown() }

        // The parser keeps a short row's own length, so the host must not
        // index past it.
        scene.host.show(DelimitedTable(
            titles: ["a", "b"], rows: [["x"]], columnCount: 2, stoppedAtLimit: false))

        #expect(tablePreviewCellText(in: scene.host, row: 0, column: 0) == "x")
        #expect(tablePreviewCellText(in: scene.host, row: 0, column: 1) == "")
    }

    @Test func rewriteWithSameTitlesKeepsColumnWidth() throws {
        let scene = TablePreviewScene()
        defer { scene.tearDown() }
        scene.host.show(peopleTable)
        let first = try #require(scene.host.tableView.tableColumns.first)
        // The measured width is far from 200, so a rebuild would show.
        #expect(first.width < 200)

        first.width = 200
        scene.host.show(DelimitedTable(
            titles: ["name", "age"], rows: [["Ada", "37"]], columnCount: 2, stoppedAtLimit: false))

        let width = scene.host.tableView.tableColumns.first?.width
        #expect(width == 200)
        #expect(tablePreviewRowCount(of: scene.host) == 1)
        #expect(tablePreviewCellText(in: scene.host, row: 0, column: 1) == "37")
    }

    @Test func newTitlesRebuildColumns() {
        let scene = TablePreviewScene()
        defer { scene.tearDown() }
        scene.host.show(peopleTable)

        scene.host.show(DelimitedTable(
            titles: ["a", "b", "c"], rows: [["1", "2", "3"]], columnCount: 3, stoppedAtLimit: false))

        let titles = tablePreviewTitles(of: scene.host)
        #expect(titles == ["a", "b", "c"])
        #expect(tablePreviewCellText(in: scene.host, row: 0, column: 2) == "3")
    }

    @Test func sameCountNewTitlesRebuildColumns() throws {
        let scene = TablePreviewScene()
        defer { scene.tearDown() }
        scene.host.show(peopleTable)
        let first = try #require(scene.host.tableView.tableColumns.first)
        first.width = 200

        scene.host.show(DelimitedTable(
            titles: ["city", "zip"], rows: [["Oslo", "0150"]], columnCount: 2, stoppedAtLimit: false))

        let titles = tablePreviewTitles(of: scene.host)
        #expect(titles == ["city", "zip"])
        let width = scene.host.tableView.tableColumns.first?.width
        #expect(width != 200)
    }

    @Test func columnWidthsAreClamped() {
        let table = DelimitedTable(
            titles: ["a", "b", "c", "d"],
            rows: [[
                "x",
                String(repeating: "w", count: 500),
                String(repeating: "w", count: 100),
                "0123456789012345",
            ]],
            columnCount: 4,
            stoppedAtLimit: false)

        let widths = TableHostView.columnWidths(for: table)

        #expect(widths.count == 4)
        #expect(widths.first == TableHostView.minColumnWidth)
        #expect(widths.dropFirst().first == TableHostView.maxColumnWidth)
        #expect(widths.dropFirst(2).first == TableHostView.maxColumnWidth)
        let measured = widths.last ?? 0
        #expect(measured > TableHostView.minColumnWidth)
        #expect(measured < TableHostView.maxColumnWidth)

        let scene = TablePreviewScene()
        defer { scene.tearDown() }
        scene.host.show(table)
        let shownFirst = scene.host.tableView.tableColumns.first?.width
        #expect(shownFirst == TableHostView.minColumnWidth)
    }

    /// With `lastColumnOnlyAutoresizingStyle`, only a column that carries
    /// `.autoresizingMask` takes the width the others leave.
    @Test func onlyTheLastColumnAutoresizes() {
        let scene = TablePreviewScene()
        defer { scene.tearDown() }

        scene.host.show(peopleTable)

        let masks = scene.host.tableView.tableColumns.map { $0.resizingMask }
        let expected: [NSTableColumn.ResizingOptions] = [
            .userResizingMask,
            [.userResizingMask, .autoresizingMask],
        ]
        #expect(masks == expected)
    }

    /// `TablePreviewView` hands the host a table only when `loadID` changes,
    /// so a SwiftUI update with the same load leaves the rows alone. The
    /// positive control gets exactly the negative's window.
    @Test func representableShowsOnlyANewLoad() async throws {
        let mount = OffscreenHost(
            root: TablePreviewView(table: peopleTable, loadID: 1),
            size: NSSize(width: 600, height: 400))
        defer { mount.tearDown() }
        let mounted = await mount.settle { mount.descendants(TableHostView.self).count == 1 }
        try #require(mounted, "the table host never mounted")
        let host = try #require(mount.descendants(TableHostView.self).first)
        #expect(tablePreviewRowCount(of: host) == 3)
        let oneRow = DelimitedTable(
            titles: ["name", "age"], rows: [["Ada", "37"]], columnCount: 2, stoppedAtLimit: false)

        mount.hostingView.rootView = TablePreviewView(table: oneRow, loadID: 1)
        mount.hostingView.layoutSubtreeIfNeeded()
        await mount.pump(times: 5)
        #expect(tablePreviewRowCount(of: host) == 3)

        mount.hostingView.rootView = TablePreviewView(table: oneRow, loadID: 2)
        mount.hostingView.layoutSubtreeIfNeeded()
        await mount.pump(times: 5)
        #expect(tablePreviewRowCount(of: host) == 1)
    }

    @Test func cellsUseFixedWidthDigits() {
        let scene = TablePreviewScene()
        defer { scene.tearDown() }

        scene.host.show(peopleTable)

        let font = tablePreviewCell(in: scene.host, row: 0, column: 1)?.textField?.font
        #expect(font == TableHostView.cellFont)
        #expect(TableHostView.cellFont.pointSize == 12)
    }
}
