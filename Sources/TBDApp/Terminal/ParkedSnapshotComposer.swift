import Foundation

// MARK: - ParkedSnapshotComposer

/// Render-time composition of a PARKED pane's frozen snapshot with an
/// in-grid hibernate notice: the notice renders as the snapshot's LAST ROWS,
/// in the terminal's own grid and font — a truecolor indigo block — instead
/// of a SwiftUI overlay strip floating above the content.
///
/// The block is `blockRows` (3) rows tall: one blank full-width padding row,
/// the text row (two-space left inset + moon glyph + message), one more
/// padding row — all on the same background. To preserve the zero-shift
/// property the composer consumes exactly as many trailing content rows as
/// the block emits: the bottom rows of a parked Claude capture are its own
/// status bar + input-box chrome, so overwriting them loses nothing
/// meaningful and the pane never shifts. The stored snapshot stays clean —
/// this composition happens only at feed time (see
/// `TerminalPanelRepresentable.makeNSView`'s `onReady`), never daemon-side.
///
/// Pure and stateless so every branch is unit-testable without SwiftUI
/// (same pattern as `HibernatedBannerModel` / `ParkedPaneWakeModel`).
enum ParkedSnapshotComposer {
    /// Height of the notice block in terminal rows (padding + text +
    /// padding), and therefore also how many trailing content rows the
    /// composer drops from the snapshot — the two must match or the pane
    /// shifts. One-line tunable.
    static let blockRows = 3
    /// Truecolor block background — Apple systemIndigo (88/86/214), the
    /// same family the deleted SwiftUI banner strip used.
    static let barBackgroundSGR = "\u{1B}[48;2;88;86;214m"
    /// Pure white foreground for contrast on the indigo background.
    static let barForegroundSGR = "\u{1B}[38;2;255;255;255m"
    /// Full SGR reset. Emitted BEFORE each block row (the retained snapshot
    /// lines may leave dangling SGR state — color, bold — that would bleed
    /// into the block's own styling) and AFTER it (so the block's colors
    /// don't bleed into whatever tmux feeds next on wake).
    static let sgrReset = "\u{1B}[0m"
    /// Two spaces of breathing room inside the colored bar, before the glyph.
    private static let leftInset = "  "
    /// Single-cell moon glyph — deliberately NOT the emoji (double-width
    /// cell, would break the character-count padding math below).
    private static let moonGlyph = "☾"

    /// Compose the feed text for a parked pane.
    ///
    /// - `snapshot` with more than `blockRows` content lines → trailing
    ///   whitespace-only lines trimmed, the last `blockRows` content lines
    ///   (the frozen status bar + input-box chrome) dropped, then the styled
    ///   notice block appended as the new last rows.
    /// - `snapshot` nil / empty / `blockRows`-or-fewer content lines → just
    ///   the block (a capture-less parked pane previously rendered pitch
    ///   black; now it explains itself).
    /// - Text longer than `columns` → truncated with an ellipsis; otherwise
    ///   every block row is space-padded to `columns` so the background
    ///   spans the full row. `columns <= 0` → no truncation or padding
    ///   (defensive: emit the styled text as-is).
    ///
    /// Lines are joined with plain `\n`; the caller feeds the result through
    /// the same `\n → \r\n` normalization as a raw snapshot, so the block
    /// cannot stair-step.
    static func compose(snapshot: String?, message: String, columns: Int) -> String {
        let block = noticeBlock(message: message, columns: columns)
        guard let snapshot, !snapshot.isEmpty else { return block }

        // Split on \n only: a \r\n snapshot leaves a trailing \r on each
        // line, which the whitespace trim below treats as blank content and
        // the caller's normalization collapses on rejoin.
        var lines = snapshot.components(separatedBy: "\n")

        // Trim trailing whitespace-only lines so the block lands directly
        // after the last REAL content row, not below a run of blanks.
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }

        // Drop as many trailing content lines as the block emits — the
        // frozen status bar + input-box chrome it replaces. A snapshot with
        // `blockRows` or fewer content lines is replaced entirely.
        guard lines.count > blockRows else { return block }
        lines.removeLast(blockRows)

        return lines.joined(separator: "\n") + "\n" + block
    }

    /// The full notice block: padding row, text row, padding row — each on
    /// its own line, each reset-prefixed and reset-terminated.
    private static func noticeBlock(message: String, columns: Int) -> String {
        let padding = paddingRow(columns: columns)
        return padding + "\n" + textRow(message: message, columns: columns) + "\n" + padding
    }

    /// A blank full-width row carrying only the block background.
    private static func paddingRow(columns: Int) -> String {
        let fill = columns > 0 ? String(repeating: " ", count: columns) : ""
        return sgrReset + barBackgroundSGR + fill + sgrReset
    }

    /// The styled text row: `SGR-reset` + truecolor bg/fg + left inset +
    /// moon glyph + message, space-padded (or ellipsis-truncated) to
    /// `columns`, + reset.
    private static func textRow(message: String, columns: Int) -> String {
        var text = "\(leftInset)\(moonGlyph) \(message)"
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
