import Foundation
import Testing
@testable import TBDApp

/// The parked pane's in-grid hibernate notice: `ParkedSnapshotComposer`
/// composes the frozen snapshot with a truecolor notice bar as its LAST ROW
/// (overwriting the frozen status bar). Every branch of the pure compose
/// function is exercised here without SwiftUI, in the same fixture style as
/// `HibernatedBannerModelTests`.
@Suite("Parked snapshot composer")
struct ParkedSnapshotComposerTests {
    private let message = "Hibernated — click anywhere in the pane to resume"
    private let bgSGR = ParkedSnapshotComposer.barBackgroundSGR
    private let fgSGR = ParkedSnapshotComposer.barForegroundSGR
    private let reset = ParkedSnapshotComposer.sgrReset

    private func compose(_ snapshot: String?, columns: Int = 80) -> String {
        ParkedSnapshotComposer.compose(snapshot: snapshot, message: message, columns: columns)
    }

    /// The bar's visible text: everything with SGR escape sequences stripped.
    private func visibleText(of composed: String) -> String {
        composed.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    /// The bar line alone (last line of the composed output).
    private func lastLine(of composed: String) -> String {
        composed.components(separatedBy: "\n").last ?? ""
    }

    // MARK: - Snapshot line handling

    /// Multi-line snapshot → the final content line (the frozen status bar)
    /// is dropped, earlier lines are intact, and the bar is the new last row.
    @Test func multiLineSnapshotReplacesLastContentLine() {
        let composed = compose("line one\nline two\nclaude status bar")
        let lines = composed.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[0] == "line one")
        #expect(lines[1] == "line two")
        #expect(!composed.contains("claude status bar"))
        #expect(lines[2].contains(message))
    }

    /// Trailing whitespace-only lines are trimmed BEFORE the drop, so the
    /// bar lands directly after the last real content line — the dropped
    /// line is the status bar, not a blank.
    @Test func trailingBlankLinesTrimmedBeforeDrop() {
        let composed = compose("line one\nclaude status bar\n   \n\n")
        let lines = composed.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "line one")
        #expect(!composed.contains("claude status bar"))
        #expect(lines[1].contains(message))
    }

    /// \r\n snapshots: the trailing \r on each split line is whitespace, so
    /// blank-trimming and the status-bar drop behave identically.
    @Test func crlfSnapshotHandled() {
        let composed = compose("line one\r\nclaude status bar\r\n")
        #expect(composed.hasPrefix("line one"))
        #expect(!composed.contains("claude status bar"))
        #expect(lastLine(of: composed).contains(message))
    }

    /// nil snapshot (a capture-less parked pane) → just the bar, so the pane
    /// explains itself instead of rendering pitch black.
    @Test func nilSnapshotProducesBarOnly() {
        let composed = compose(nil)
        #expect(!composed.contains("\n"))
        #expect(composed.contains(message))
    }

    /// Empty-string snapshot → bar only, same as nil.
    @Test func emptySnapshotProducesBarOnly() {
        let composed = compose("")
        #expect(!composed.contains("\n"))
        #expect(composed.contains(message))
    }

    /// Whitespace-only snapshot → every line trims away → bar only.
    @Test func whitespaceOnlySnapshotProducesBarOnly() {
        let composed = compose("   \n\n  \n")
        #expect(!composed.contains("\n"))
        #expect(composed.contains(message))
    }

    /// Single-line snapshot → the bar replaces it entirely (acceptable: the
    /// sole line of a parked capture is the status bar being overwritten).
    @Test func singleLineSnapshotReplacedEntirely() {
        let composed = compose("only status line")
        #expect(!composed.contains("only status line"))
        #expect(!composed.contains("\n"))
        #expect(composed.contains(message))
    }

    // MARK: - Bar styling

    /// The bar carries the truecolor background + foreground SGR and ends
    /// with a full reset so its colors can't bleed into later output.
    @Test func barContainsTruecolorSGRAndReset() {
        let composed = compose("line one\nstatus")
        let bar = lastLine(of: composed)
        #expect(bar.contains(bgSGR))
        #expect(bar.contains(fgSGR))
        #expect(bar.hasSuffix(reset))
    }

    /// Dangling SGR state from the retained snapshot lines (e.g. an unclosed
    /// red foreground) must be reset BEFORE the bar's own styling starts.
    @Test func resetPrecedesBarAfterDanglingSGR() {
        let composed = compose("\u{1B}[31mred text\nstatus")
        guard let barStart = composed.range(of: bgSGR) else {
            Issue.record("bar background SGR missing")
            return
        }
        let beforeBar = String(composed[..<barStart.lowerBound])
        #expect(beforeBar.contains("red text"))
        // A reset must sit between the retained content and the bar's SGR.
        guard let resetRange = beforeBar.range(of: reset, options: .backwards),
              let redRange = beforeBar.range(of: "red text") else {
            Issue.record("expected a reset between the retained content and the bar")
            return
        }
        #expect(resetRange.lowerBound >= redRange.upperBound)
    }

    // MARK: - Column padding / truncation

    /// The bar's visible text is padded with spaces to exactly `columns`, so
    /// the background spans the full row.
    @Test func barPaddedToColumnWidth() {
        let composed = compose(nil, columns: 120)
        #expect(visibleText(of: composed).count == 120)
        #expect(visibleText(of: composed).hasSuffix(" "))
    }

    /// Message longer than the column count → truncated with an ellipsis to
    /// exactly `columns` visible cells.
    @Test func longMessageTruncatedWithEllipsis() {
        let composed = compose(nil, columns: 10)
        let visible = visibleText(of: composed)
        #expect(visible.count == 10)
        #expect(visible.hasSuffix("…"))
    }

    /// columns <= 0 (defensive: dimensions not yet known) → no padding and
    /// no truncation, just the styled glyph + message.
    @Test func zeroColumnsEmitsUnpaddedText() {
        let composed = compose(nil, columns: 0)
        let visible = visibleText(of: composed)
        #expect(visible == "☾ \(message)")
    }

    /// Negative columns behave like zero (defensive).
    @Test func negativeColumnsEmitsUnpaddedText() {
        let composed = compose(nil, columns: -5)
        #expect(visibleText(of: composed) == "☾ \(message)")
    }

    /// The moon glyph leads the bar so the notice reads as a hibernate state
    /// at a glance.
    @Test func barLeadsWithMoonGlyph() {
        let composed = compose(nil)
        #expect(visibleText(of: composed).hasPrefix("☾ "))
    }
}
