import Foundation

// MARK: - ParkedSnapshotComposer

/// Render-time composition of a PARKED pane's frozen snapshot with an
/// in-grid hibernate notice: the notice renders as the snapshot's LAST ROW,
/// in the terminal's own grid and font — a truecolor status bar — instead of
/// a SwiftUI overlay strip floating above the content.
///
/// The bottom row of a parked Claude capture is usually Claude's own status
/// bar, so the composer OVERWRITES it (drop the final content line, append
/// the bar): nothing meaningful is lost and the pane never shifts. The
/// stored snapshot stays clean — this composition happens only at feed time
/// (see `TerminalPanelRepresentable.makeNSView`'s `onReady`), never
/// daemon-side.
///
/// Pure and stateless so every branch is unit-testable without SwiftUI
/// (same pattern as `HibernatedBannerModel` / `ParkedPaneWakeModel`).
enum ParkedSnapshotComposer {
    /// Truecolor bar background — slightly darker than pastel blue
    /// (pastel blue ≈ 174/198/232) so it reads as a distinct status line
    /// over arbitrary snapshot content.
    static let barBackgroundSGR = "\u{1B}[48;2;135;165;210m"
    /// Near-black foreground, readable on the muted blue background.
    static let barForegroundSGR = "\u{1B}[38;2;20;30;50m"
    /// Full SGR reset. Emitted BEFORE the bar (the retained snapshot lines
    /// may leave dangling SGR state — color, bold — that would bleed into
    /// the bar's own styling) and AFTER it (so the bar's colors don't bleed
    /// into whatever tmux feeds next on wake).
    static let sgrReset = "\u{1B}[0m"
    /// Single-cell moon glyph — deliberately NOT the emoji (double-width
    /// cell, would break the character-count padding math below).
    private static let moonGlyph = "☾"

    /// Compose the feed text for a parked pane.
    ///
    /// - `snapshot` non-nil with 2+ content lines → trailing whitespace-only
    ///   lines trimmed, the final content line (the frozen status bar)
    ///   dropped, then the styled notice bar appended as the new last row.
    /// - `snapshot` nil / empty / single-line → just the bar (a capture-less
    ///   parked pane previously rendered pitch black; now it explains itself).
    /// - `message` longer than `columns` → truncated with an ellipsis;
    ///   otherwise padded with spaces to `columns` so the bar's background
    ///   spans the full row. `columns <= 0` → no truncation or padding
    ///   (defensive: emit the styled text as-is).
    ///
    /// Lines are joined with plain `\n`; the caller feeds the result through
    /// the same `\n → \r\n` normalization as a raw snapshot, so the bar
    /// cannot stair-step.
    static func compose(snapshot: String?, message: String, columns: Int) -> String {
        let bar = barLine(message: message, columns: columns)
        guard let snapshot, !snapshot.isEmpty else { return bar }

        // Split on \n only: a \r\n snapshot leaves a trailing \r on each
        // line, which the whitespace trim below treats as blank content and
        // the caller's normalization collapses on rejoin.
        var lines = snapshot.components(separatedBy: "\n")

        // Trim trailing whitespace-only lines so the bar lands directly
        // after the last REAL content row, not below a run of blanks.
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }

        // Drop the final content line — the frozen status bar the notice
        // replaces. A single-line snapshot is replaced entirely.
        guard lines.count > 1 else { return bar }
        lines.removeLast()

        return lines.joined(separator: "\n") + "\n" + bar
    }

    /// The styled notice row: `SGR-reset` + truecolor bg/fg + moon glyph +
    /// message, space-padded (or ellipsis-truncated) to `columns`, + reset.
    private static func barLine(message: String, columns: Int) -> String {
        var text = "\(moonGlyph) \(message)"
        if columns > 0 {
            if text.count > columns {
                text = String(text.prefix(max(columns - 1, 0))) + "…"
            }
            if text.count < columns {
                text += String(repeating: " ", count: columns - text.count)
            }
        }
        return sgrReset + barBackgroundSGR + barForegroundSGR + text + sgrReset
    }
}
