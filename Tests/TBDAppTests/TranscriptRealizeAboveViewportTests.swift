import AppKit
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Rows realized above the transcript viewport, driven headlessly in
/// `TableTranscriptScene`.
///
/// A row is not only realized when it scrolls on screen. An accessibility
/// client that asks a cell for its size builds the cell's row view through
/// `rowView(atRow:makeIfNecessary:)`, and a dictation app does that for every
/// row of the transcript, far above the viewport. Each of those rows that
/// carried an estimate is measured and corrected as it realizes, and because
/// the estimate is calibrated to sit under the measurement, the rows above the
/// reader grow. What the reader sees must not move when they do.
@Suite("Rows realized above the transcript viewport")
@MainActor
struct TranscriptRealizeAboveViewportTests {
    /// Exchanges that end in a card, then exchanges that do not: 30 rows of
    /// the first and 40 of the second, so the bottom window the open measures
    /// exactly is all prose and every card sits above it, carrying an estimate.
    private static let cardExchanges = 10
    private static let proseExchanges = 20

    /// An AskUserQuestion card whose question wraps. Prose rows estimate to
    /// within a line of their measurement, often exactly, but this card the
    /// estimator under-reserves by construction (`card/askUserQuestion-wrapping`
    /// in `TranscriptEstimatorAccuracyTests`, 36pt at the calibrated text size),
    /// so every one of them grows when it realizes.
    private static let wrappingAskCardJSON =
        #"{"questions":[{"question":"This question is deliberately very long indeed, so long that it must wrap across at least three separate lines inside the card at either of the column widths the transcript pane is ever laid out at, which is the shape a count-based model cannot see.","header":"Sizing","multiSelect":false,"options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}"#

    /// Rounds of a prompt "p-i" and a reply "a-i", the first `cardExchanges`
    /// of them followed by an answered AskUserQuestion card "ask-i".
    private static func conversation() -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        for index in 0..<(cardExchanges + proseExchanges) {
            items.append(.userPrompt(id: "p-\(index)", text: "Prompt \(index)", timestamp: nil))
            items.append(.assistantText(
                id: "a-\(index)",
                text: String(
                    repeating: "A reply sentence whose prose wraps across the column. ",
                    count: 4 + index % 5),
                timestamp: nil,
                usage: nil))
            guard index < cardExchanges else { continue }
            items.append(.toolCall(
                id: "ask-\(index)",
                name: "AskUserQuestion",
                inputJSON: wrappingAskCardJSON,
                inputTruncatedTo: nil,
                result: ToolResult(text: "A", truncatedTo: nil, isError: false),
                subagent: nil,
                timestamp: nil))
        }
        return items
    }

    /// Parks prompt 12, a few rows into the bottom window, 40pt below the
    /// viewport top: every card lies above the viewport, and most of them
    /// beyond the rows AppKit realizes around it.
    private static func parkMidTranscript(_ scene: TableTranscriptScene) throws {
        let promptRow = scene.coordinator.nodes.firstIndex { $0.id == "p-12" }
        let parkRow = try #require(promptRow)
        scene.park(row: parkRow, below: 40)
        try #require(scene.gapToBottom > 120,
                     Comment(rawValue: "precondition: the viewport is clear of the tail-follow threshold "
                         + "(gap \(scene.gapToBottom) pt)"))
    }

    /// The first visible row, required to have rows above it.
    private static func firstVisibleRow(_ scene: TableTranscriptScene) throws -> Int {
        let first = scene.tableView.rows(in: scene.scrollView.contentView.documentVisibleRect).location
        try #require(first != NSNotFound && first > 0,
                     Comment(rawValue: "precondition: rows lie above the viewport (first visible \(first))"))
        return first
    }

    /// Sizes every cell above `firstVisible` the way an accessibility client
    /// does: `-[NSTableViewCellMockElement accessibilitySizeAttribute]` builds
    /// the row view, which asks the delegate for the cell.
    private static func realizeRows(above firstVisible: Int, in scene: TableTranscriptScene) {
        for row in 0..<firstVisible {
            _ = scene.tableView.rowView(atRow: row, makeIfNecessary: true)
        }
    }

    /// Lets AppKit lay the corrected rows out, runs anything deferred, and
    /// brings the table to a fixed point.
    private static func settleRealized(_ scene: TableTranscriptScene) async {
        scene.tableView.layoutSubtreeIfNeeded()
        await drainMainQueue()
        scene.settle()
    }

    /// The rows above `firstVisible` whose height changed by more than half a
    /// point since `heightsBefore`, and by how much in all.
    private static func corrections(
        above firstVisible: Int, in scene: TableTranscriptScene, since heightsBefore: [CGFloat]
    ) -> (rows: Int, points: CGFloat) {
        var rows = 0
        var points: CGFloat = 0
        for row in 0..<firstVisible {
            let change = abs(scene.tableView.rect(ofRow: row).height - heightsBefore[row])
            if change > 0.5 {
                rows += 1
                points += change
            }
        }
        return (rows, points)
    }

    /// Run at the end of the transcript, where the field report came from and
    /// where the document must grow before the clip can follow, and parked
    /// mid-transcript, where the clip has room to move at once.
    @Test("realizing the rows above the viewport, as accessibility does, keeps the view still",
          arguments: [true, false])
    func realizingRowsAboveKeepsTheViewStill(atBottom: Bool) async throws {
        let suite = TestDefaultsSuite("table-realize-above")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        let appState = AppState(userDefaults: defaults)

        let items = Self.conversation()
        let scene = try TableTranscriptScene.primedAtEnd(items: items, appState: appState)
        defer { withExtendedLifetime(scene.coordinator) {} }
        let tableView = scene.tableView
        let clip = scene.scrollView.contentView
        if atBottom {
            try #require(scene.gapToBottom <= 1,
                         Comment(rawValue: "precondition: the pane opened at the bottom (gap \(scene.gapToBottom) pt)"))
        } else {
            try Self.parkMidTranscript(scene)
        }

        let firstVisible = try Self.firstVisibleRow(scene)
        let nodes = scene.coordinator.nodes
        var estimatedAbove: [Int] = []
        for row in 0..<firstVisible where scene.coordinator.cachedExactHeight(for: nodes[row]) == nil {
            estimatedAbove.append(row)
        }
        try #require(estimatedAbove.count >= 6,
                     Comment(rawValue: "precondition: rows above the viewport carry estimates "
                         + "(\(estimatedAbove.count) of \(firstVisible))"))
        let offsetBefore = scene.screenOffset(ofRow: firstVisible)
        let gapBefore = scene.gapToBottom
        let heightsBefore = (0..<firstVisible).map { tableView.rect(ofRow: $0).height }

        Self.realizeRows(above: firstVisible, in: scene)
        await Self.settleRealized(scene)

        var unrealized: [Int] = []
        for row in estimatedAbove where scene.coordinator.cachedExactHeight(for: nodes[row]) == nil {
            unrealized.append(row)
        }
        try #require(unrealized.isEmpty,
                     Comment(rawValue: "rowView(atRow:makeIfNecessary:) did not realize rows \(unrealized)"))
        // Not vacuous: the rows above changed height, by more than the
        // tolerance below, so holding the view took something.
        let corrected = Self.corrections(above: firstVisible, in: scene, since: heightsBefore)
        try #require(corrected.rows > 0 && corrected.points > 2,
                     Comment(rawValue: "precondition: realizing corrected the rows above the viewport "
                         + "(\(corrected.rows) rows, \(corrected.points) pt)"))

        let firstVisibleAfter = tableView.rows(in: clip.documentVisibleRect).location
        #expect(firstVisibleAfter == firstVisible,
                Comment(rawValue: "the first visible row moved from \(firstVisible) to \(firstVisibleAfter) "
                    + "as \(corrected.rows) rows above it corrected by \(corrected.points) pt; "
                    + scene.heldReaderMoveNote))
        let offsetAfter = scene.screenOffset(ofRow: firstVisible)
        #expect(abs(offsetAfter - offsetBefore) <= 0.5,
                Comment(rawValue: "row \(firstVisible) moved on screen from \(offsetBefore) to \(offsetAfter) pt "
                    + "as \(corrected.rows) rows above it corrected by \(corrected.points) pt; "
                    + scene.heldReaderMoveNote))
        let gapAfter = scene.gapToBottom
        #expect(abs(gapAfter - gapBefore) <= 0.5,
                Comment(rawValue: "the distance from the bottom moved from \(gapBefore) to \(gapAfter) pt"
                    + (atBottom ? ", so a viewport at the bottom left it" : "")))
    }
}
