import Foundation

/// Per-pane terminal state captured during attach replay (addendum §3, capture
/// step 3: `list-panes -F` through the FIFO correlator). The replay writer
/// (M4.2) re-synthesizes these as mode escapes after feeding history, so the
/// attached SwiftTerm ends up in the same modes as the live pane.
///
/// All flags carry tmux's `0`/`1` semantics surfaced as `Bool`; coordinates are
/// 0-based cells relative to the pane.
struct PaneState: Equatable, Sendable {
    /// tmux pane id (`%N`) — lets a multi-pane response be filtered.
    let paneID: String

    /// Cursor position in the *current* screen (primary or alt).
    let cursorX: Int
    let cursorY: Int

    /// True when the pane is showing the alternate screen (DECSET 1049).
    let alternateOn: Bool

    /// Cursor position saved by CSI ? 1049 h — the primary-screen cursor,
    /// meaningful only while `alternateOn`. `nil` when the pane has no saved
    /// cursor (tmux reports its UINT_MAX sentinel, verified live).
    let alternateSavedX: Int?
    let alternateSavedY: Int?

    /// Scroll region (DECSTBM), 0-based inclusive rows.
    let scrollRegionUpper: Int
    let scrollRegionLower: Int

    /// Cursor visible (DECTCEM, `cursor_flag`).
    let cursorVisible: Bool
    /// Insert mode (IRM, `insert_flag`).
    let insertMode: Bool
    /// Application cursor keys (DECCKM, `keypad_cursor_flag`).
    let applicationCursorKeys: Bool
    /// Application keypad (DECKPAM, `keypad_flag`).
    let applicationKeypad: Bool
    /// Autowrap (DECAWM, `wrap_flag`).
    let wraparound: Bool
    /// Mouse click tracking (mode 1000, `mouse_standard_flag`).
    let mouseStandard: Bool
    /// Mouse button-drag tracking (mode 1002, `mouse_button_flag`).
    let mouseButton: Bool
    /// Mouse any-motion tracking (mode 1003, `mouse_any_flag`).
    let mouseAny: Bool
    /// SGR mouse encoding (mode 1006, `mouse_sgr_flag`).
    let mouseSGR: Bool
    /// Origin mode (DECOM, `origin_flag`).
    let originMode: Bool
    /// Number of tmux modes the pane is in (copy mode etc.); `0` = none.
    /// (Older tmux documents this as a 0/1 flag — an `Int` covers both.)
    let paneInMode: Int
    /// Pane size in cells (`pane_width`/`pane_height`, both present at the
    /// 3.2 floor). The replay assembler (M4.2) needs the pane's cols/rows for
    /// cursor/region clamping — capturing them here keeps the whole replay
    /// input inside the one atomic capture batch (M4.3).
    let width: Int
    let height: Int
    /// Lines currently in the pane's PRIMARY-screen scrollback
    /// (`history_size`, present at the 3.2 floor). The replay orchestrator
    /// needs it to know whether the pure-scrollback capture leg
    /// (`-S -<depth> -E -1`) is trustworthy: live-probed on tmux 3.6a, that
    /// leg CLAMPS on a history-less pane and returns the first visible screen
    /// row instead of nothing — so it must be discarded when `historySize`
    /// is 0 or the replay would paint that row twice.
    let historySize: Int
}

/// A capture that can't be trusted must abort the replay, not degrade it —
/// so the parser throws instead of skipping (a half-parsed state would replay
/// wrong modes into the pane). Blank lines are tolerated; anything else
/// malformed throws.
enum PaneStateCaptureError: Error, Equatable {
    /// A non-blank line didn't have exactly `PaneStateCapture.fieldCount`
    /// space-separated fields.
    case wrongFieldCount(line: String, expected: Int, actual: Int)
    /// A field failed to parse (empty, non-numeric, or a `pane_id` without
    /// its `%` prefix). An *empty* field is how an unknown format variable
    /// manifests — tmux expands unknown `#{...}` to nothing.
    case invalidField(name: String, value: String)
}

/// The canonical `list-panes -F` format for pane-state capture, plus its
/// parser. Mirrors iTerm2's `TmuxStateParser` field set minus fields that are
/// unavailable at our tmux floor (3.2) or that the replay writer doesn't use:
///
///   - `mouse_utf8_flag`    — removed in tmux 2.2
///   - `bracket_paste_flag` — an iTerm2 patch, never in any tmux release
///   - `pane_key_mode`      — tmux 3.5+, above the 3.2 floor
///   - `pane_tabs`          — tab stops; not in the replay writer's field set
///
/// Every remaining variable is verified present in tmux 3.2's `format.c`.
///
/// Encoding: one line per pane, fields space-separated in fixed order.
/// Unambiguous because every value is numeric except `pane_id` (`%N`), and
/// none can contain a space — unlike iTerm2's `key=value` tab-separated
/// format, there is no tab-vs-`\t` escaping ambiguity to work around.
enum PaneStateCapture {
    /// Number of space-separated fields in `format` (and in every valid line).
    static let fieldCount = 22

    /// Field order is load-bearing: `parse` consumes positionally.
    static let format = [
        "#{pane_id}",
        "#{cursor_x}",
        "#{cursor_y}",
        "#{alternate_on}",
        "#{alternate_saved_x}",
        "#{alternate_saved_y}",
        "#{scroll_region_upper}",
        "#{scroll_region_lower}",
        "#{cursor_flag}",
        "#{insert_flag}",
        "#{keypad_cursor_flag}",
        "#{keypad_flag}",
        "#{wrap_flag}",
        "#{mouse_standard_flag}",
        "#{mouse_button_flag}",
        "#{mouse_any_flag}",
        "#{mouse_sgr_flag}",
        "#{origin_flag}",
        "#{pane_in_mode}",
        "#{pane_width}",
        "#{pane_height}",
        "#{history_size}",
    ].joined(separator: " ")

    /// tmux reports `alternate_saved_x`/`_y` as UINT_MAX when the pane has no
    /// saved cursor (never entered the alt screen). Verified against live tmux.
    private static let noSavedCursorSentinel = 4294967295

    /// The full capture command for the correlator. `target` may be a pane id
    /// (`%N`, tmux resolves its window) or a window target; the response lists
    /// every pane in that window — filter with `state(forPane:in:)`. The format
    /// is single-quoted (it contains spaces and `#{}` but never a quote).
    static func listPanesCommand(target: String) -> String {
        "list-panes -t \(target) -F '\(format)'"
    }

    /// Parse a `list-panes` reply (the correlator's response lines) into one
    /// `PaneState` per pane. Empty/whitespace-only lines are skipped; any other
    /// malformed line throws `PaneStateCaptureError` (see the error's doc).
    static func parse(_ lines: [String]) throws -> [PaneState] {
        try lines.compactMap { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return try parseLine(line)
        }
    }

    /// Convenience: parse and select one pane. `nil` when the pane isn't in
    /// the response (still throws if any line is malformed — a bad capture is
    /// a bad capture regardless of which pane it describes).
    static func state(forPane paneID: String, in lines: [String]) throws -> PaneState? {
        try parse(lines).first { $0.paneID == paneID }
    }

    // MARK: - Internals

    private static func parseLine(_ line: String) throws -> PaneState {
        let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == fieldCount else {
            throw PaneStateCaptureError.wrongFieldCount(
                line: line, expected: fieldCount, actual: fields.count)
        }

        let paneID = fields[0]
        guard paneID.hasPrefix("%"), Int(paneID.dropFirst()) != nil else {
            throw PaneStateCaptureError.invalidField(name: "pane_id", value: paneID)
        }

        func int(_ index: Int, _ name: String) throws -> Int {
            guard let value = Int(fields[index]) else {
                throw PaneStateCaptureError.invalidField(name: name, value: fields[index])
            }
            return value
        }
        func flag(_ index: Int, _ name: String) throws -> Bool {
            try int(index, name) != 0
        }
        func savedCoord(_ index: Int, _ name: String) throws -> Int? {
            let value = try int(index, name)
            return value == noSavedCursorSentinel ? nil : value
        }

        return PaneState(
            paneID: paneID,
            cursorX: try int(1, "cursor_x"),
            cursorY: try int(2, "cursor_y"),
            alternateOn: try flag(3, "alternate_on"),
            alternateSavedX: try savedCoord(4, "alternate_saved_x"),
            alternateSavedY: try savedCoord(5, "alternate_saved_y"),
            scrollRegionUpper: try int(6, "scroll_region_upper"),
            scrollRegionLower: try int(7, "scroll_region_lower"),
            cursorVisible: try flag(8, "cursor_flag"),
            insertMode: try flag(9, "insert_flag"),
            applicationCursorKeys: try flag(10, "keypad_cursor_flag"),
            applicationKeypad: try flag(11, "keypad_flag"),
            wraparound: try flag(12, "wrap_flag"),
            mouseStandard: try flag(13, "mouse_standard_flag"),
            mouseButton: try flag(14, "mouse_button_flag"),
            mouseAny: try flag(15, "mouse_any_flag"),
            mouseSGR: try flag(16, "mouse_sgr_flag"),
            originMode: try flag(17, "origin_flag"),
            paneInMode: try int(18, "pane_in_mode"),
            width: try int(19, "pane_width"),
            height: try int(20, "pane_height"),
            historySize: try int(21, "history_size"))
    }
}
