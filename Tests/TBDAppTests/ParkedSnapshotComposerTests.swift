import Foundation
import Testing
@testable import TBDApp

/// The parked pane's in-grid hibernate notice: `ParkedSnapshotComposer`
/// composes the frozen snapshot with a truecolor indigo notice BLOCK as its
/// last `blockRows` (3) rows — a ▄ half-row of indigo, the text row (white
/// on indigo), a ▀ half-row — consuming the same number of trailing content
/// rows (the frozen status bar + input-box chrome) so the pane never
/// shifts. Every branch of the pure compose function is exercised here
/// without SwiftUI, in the same fixture style as
/// `HibernatedBannerModelTests`.
@Suite("Parked snapshot composer")
struct ParkedSnapshotComposerTests {
    private let message = "Hibernated — click anywhere in the pane to resume"
    private let bgSGR = ParkedSnapshotComposer.barBackgroundSGR
    private let fgSGR = ParkedSnapshotComposer.barForegroundSGR
    private let padFgSGR = ParkedSnapshotComposer.paddingForegroundSGR
    private let reset = ParkedSnapshotComposer.sgrReset
    private let blockRows = ParkedSnapshotComposer.blockRows

    private func compose(_ snapshot: String?, columns: Int = 80) -> String {
        ParkedSnapshotComposer.compose(snapshot: snapshot, message: message, columns: columns)
    }

    /// Visible text: everything with SGR escape sequences stripped.
    private func visibleText(of composed: String) -> String {
        composed.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private func lines(of composed: String) -> [String] {
        composed.components(separatedBy: "\n")
    }

    /// The text row — the middle row of the trailing notice block.
    private func textRow(of composed: String) -> String {
        let all = lines(of: composed)
        return all[all.count - 2]
    }

    // MARK: - Colors

    /// The bar colors are the indigo family the deleted SwiftUI banner used:
    /// truecolor systemIndigo background (88/86/214), pure white foreground
    /// — and the padding rows draw the SAME indigo as a foreground.
    @Test func colorsAreSystemIndigoOnWhite() {
        #expect(bgSGR == "\u{1B}[48;2;88;86;214m")
        #expect(fgSGR == "\u{1B}[38;2;255;255;255m")
        #expect(padFgSGR == "\u{1B}[38;2;88;86;214m")
        let composed = compose(nil)
        #expect(composed.contains(bgSGR))
        #expect(composed.contains(fgSGR))
        #expect(composed.contains(padFgSGR))
    }

    // MARK: - Block shape

    /// The notice is a 3-row block: half-row padding, text row, half-row
    /// padding — the height matches the `blockRows` constant.
    @Test func blockIsThreeRows() {
        #expect(blockRows == 3)
        let composed = compose(nil)
        let rows = lines(of: composed)
        #expect(rows.count == blockRows)
        #expect(rows[1].contains(message))
        #expect(!rows[0].contains(message))
        #expect(!rows[2].contains(message))
    }

    /// The padding rows are HALF rows of indigo: full-width runs of the
    /// half-block glyphs (▄ above the bar, ▀ below), drawn as indigo
    /// FOREGROUND on the default background — no background SGR, so only
    /// half the cell height is colored.
    @Test func paddingRowsAreIndigoHalfBlocksOnDefaultBackground() {
        let composed = compose(nil, columns: 60)
        let rows = lines(of: composed)
        #expect(visibleText(of: rows[0]) == String(repeating: "▄", count: 60))
        #expect(visibleText(of: rows[2]) == String(repeating: "▀", count: 60))
        for row in [rows[0], rows[2]] {
            #expect(row.contains(padFgSGR))
            #expect(!row.contains(bgSGR))
            #expect(row.hasSuffix(reset))
        }
    }

    /// The text row leads with the two-space inset then the moon glyph,
    /// inside the colored bar.
    @Test func textRowHasTwoSpaceInsetBeforeMoonGlyph() {
        let composed = compose(nil)
        #expect(visibleText(of: textRow(of: composed)).hasPrefix("  ☾ "))
    }

    // MARK: - Snapshot line handling (drop = blockRows)

    /// Multi-line snapshot → the last `blockRows` content lines (status bar
    /// + input-box chrome) are dropped, earlier lines intact, and the block
    /// forms the new last rows — total row count unchanged (zero shift).
    @Test func multiLineSnapshotReplacesLastThreeContentLines() {
        let composed = compose("line one\nline two\nchrome a\nchrome b\nstatus bar")
        let rows = lines(of: composed)
        #expect(rows.count == 5)
        #expect(rows[0] == "line one")
        #expect(rows[1] == "line two")
        #expect(!composed.contains("chrome a"))
        #expect(!composed.contains("chrome b"))
        #expect(!composed.contains("status bar"))
        #expect(rows[3].contains(message))
    }

    /// Trailing whitespace-only lines are trimmed BEFORE the drop, so the
    /// three dropped lines are real content (the chrome), not blanks.
    @Test func trailingBlankLinesTrimmedBeforeDrop() {
        let composed = compose("line one\nchrome a\nchrome b\nstatus bar\n   \n\n")
        let rows = lines(of: composed)
        #expect(rows.count == 1 + blockRows)
        #expect(rows[0] == "line one")
        #expect(!composed.contains("chrome"))
        #expect(!composed.contains("status bar"))
        #expect(rows[2].contains(message))
    }

    /// \r\n snapshots: the trailing \r on each split line is whitespace, so
    /// blank-trimming and the chrome drop behave identically.
    @Test func crlfSnapshotHandled() {
        let composed = compose("line one\r\nchrome a\r\nchrome b\r\nstatus bar\r\n")
        #expect(composed.hasPrefix("line one"))
        #expect(!composed.contains("status bar"))
        #expect(textRow(of: composed).contains(message))
    }

    /// nil snapshot (a capture-less parked pane) → just the block, so the
    /// pane explains itself instead of rendering pitch black.
    @Test func nilSnapshotProducesBlockOnly() {
        let composed = compose(nil)
        #expect(lines(of: composed).count == blockRows)
        #expect(composed.contains(message))
    }

    /// Empty-string snapshot → block only, same as nil.
    @Test func emptySnapshotProducesBlockOnly() {
        let composed = compose("")
        #expect(lines(of: composed).count == blockRows)
        #expect(composed.contains(message))
    }

    /// Whitespace-only snapshot → every line trims away → block only.
    @Test func whitespaceOnlySnapshotProducesBlockOnly() {
        let composed = compose("   \n\n  \n")
        #expect(lines(of: composed).count == blockRows)
        #expect(composed.contains(message))
    }

    /// Single-line snapshot → fewer content lines than the block consumes →
    /// replaced entirely by the block.
    @Test func singleLineSnapshotReplacedEntirely() {
        let composed = compose("only status line")
        #expect(!composed.contains("only status line"))
        #expect(lines(of: composed).count == blockRows)
        #expect(composed.contains(message))
    }

    /// Two-line snapshot (fewer than `blockRows`) → both lines dropped, the
    /// block stands alone — no partial retention.
    @Test func twoLineSnapshotReplacedEntirely() {
        let composed = compose("line one\nstatus bar")
        #expect(!composed.contains("line one"))
        #expect(!composed.contains("status bar"))
        #expect(lines(of: composed).count == blockRows)
        #expect(composed.contains(message))
    }

    /// Exactly `blockRows` content lines → all consumed, block only; one
    /// more line and the first survives (the boundary of the drop rule).
    @Test func exactlyBlockRowsLinesReplacedEntirely() {
        let atBoundary = compose("a\nb\nc")
        #expect(lines(of: atBoundary).count == blockRows)
        #expect(!atBoundary.contains("a\n"))

        let overBoundary = compose("keep\na\nb\nc")
        let rows = lines(of: overBoundary)
        #expect(rows.count == 1 + blockRows)
        #expect(rows[0] == "keep")
    }

    // MARK: - Styling / SGR hygiene

    /// Every block row starts fresh and ends reset: the text row carries the
    /// truecolor bg + fg SGR and a trailing reset so the block's colors
    /// can't bleed into later output.
    @Test func textRowContainsTruecolorSGRAndReset() {
        let composed = compose("one\ntwo\nthree\nfour")
        let row = textRow(of: composed)
        #expect(row.contains(bgSGR))
        #expect(row.contains(fgSGR))
        #expect(row.hasSuffix(reset))
    }

    /// Dangling SGR state from the retained snapshot lines (e.g. an unclosed
    /// red foreground) must be reset BEFORE the block's own styling starts
    /// (the top padding row's indigo foreground is the block's first SGR).
    @Test func resetPrecedesBlockAfterDanglingSGR() {
        let composed = compose("\u{1B}[31mred text\na\nb\nc")
        guard let blockStart = composed.range(of: padFgSGR) else {
            Issue.record("block padding foreground SGR missing")
            return
        }
        let beforeBlock = String(composed[..<blockStart.lowerBound])
        #expect(beforeBlock.contains("red text"))
        // A reset must sit between the retained content and the block's SGR.
        guard let resetRange = beforeBlock.range(of: reset, options: .backwards),
              let redRange = beforeBlock.range(of: "red text") else {
            Issue.record("expected a reset between the retained content and the block")
            return
        }
        #expect(resetRange.lowerBound >= redRange.upperBound)
    }

    // MARK: - Column padding / truncation

    /// The text row's visible text is padded with spaces to exactly
    /// `columns`, so the background spans the full row.
    @Test func textRowPaddedToColumnWidth() {
        let composed = compose(nil, columns: 120)
        let visible = visibleText(of: textRow(of: composed))
        #expect(visible.count == 120)
        #expect(visible.hasSuffix(" "))
    }

    /// Message longer than the column count → truncated with an ellipsis to
    /// exactly `columns` visible cells.
    @Test func longMessageTruncatedWithEllipsis() {
        let composed = compose(nil, columns: 10)
        let visible = visibleText(of: textRow(of: composed))
        #expect(visible.count == 10)
        #expect(visible.hasSuffix("…"))
    }

    /// columns <= 0 (defensive: dimensions not yet known) → no padding and
    /// no truncation, just the inset + styled glyph + message.
    @Test func zeroColumnsEmitsUnpaddedText() {
        let composed = compose(nil, columns: 0)
        #expect(visibleText(of: textRow(of: composed)) == "  ☾ \(message)")
    }

    /// Negative columns behave like zero (defensive).
    @Test func negativeColumnsEmitsUnpaddedText() {
        let composed = compose(nil, columns: -5)
        #expect(visibleText(of: textRow(of: composed)) == "  ☾ \(message)")
    }
}
