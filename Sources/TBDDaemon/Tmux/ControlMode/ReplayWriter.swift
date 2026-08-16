import Foundation

/// Errors from `ReplayWriter`. A capture that can't be decoded must abort the
/// replay, not degrade it (same philosophy as `PaneStateCaptureError` — a
/// half-decoded replay corrupts the attached terminal worse than no replay).
enum ReplayWriterError: LocalizedError, Equatable {
    /// A pending-output line (from `capture-pane -p -P -C`) contained a `\`
    /// not followed by exactly three octal digits ≤ `\377`. tmux 3.2's `-C`
    /// (cmd-capture-pane.c, `cmd_capture_pane_pending`) escapes every byte
    /// outside the literal range — and always as `\` + exactly three octal
    /// digits (`xsnprintf "\\%03hho"`) — so anything else means the response
    /// isn't the capture we think it is.
    case malformedPendingEscape(line: String)

    var errorDescription: String? {
        switch self {
        case .malformedPendingEscape(let line):
            return "Pending-output capture contained a backslash that wasn't followed by three octal digits: \(line)"
        }
    }
}

/// Pure byte assembler for the attach replay (addendum §3, base spec
/// §Scrollback). Consumes the 5-command capture's decoded responses and a
/// `PaneState` (M4.1) and produces the exact byte sequence the orchestrator
/// (M4.3) writes into the pane's pipe via `PaneFanout.writeReplay`.
///
/// Byte order (addendum §3): reset prelude → history → mode escapes →
/// scroll region → alt screen → pending output → cursor. Two deliberate
/// deviations, both verified against SwiftTerm (the only consumer):
///
/// 1. **Alt-screen scroll region.** tmux's `scroll_region_upper/lower`
///    describe the pane's *current* screen. SwiftTerm keeps an independent
///    scroll region per buffer and does NOT carry it across a 1049 switch
///    (`activateAltBuffer` copies only the cursor), so when `alternateOn`
///    the DECSTBM must be emitted *after* `\e[?1049h` — and after the alt
///    content, because painting rows through an active region would scroll
///    inside it. The spec's "region before cursor" invariant (DECSTBM homes
///    the cursor — M4.0 finding) is preserved in both layouts.
/// 2. **Alt-screen home.** `\e[?1049h` clears the alt screen but leaves the
///    cursor wherever the primary screen left it; a `\e[H` is emitted before
///    the alt content so it paints from the top-left.
enum ReplayWriter {
    private static let esc = "\u{1b}"

    /// Clean-slate prelude. The app feeds a STALE ANSI snapshot into SwiftTerm
    /// before attach (suspend/resume snapshot in TerminalPanelView.onReady),
    /// and fullscreen apps repaint differentially — so the prelude must fully
    /// supersede whatever state that snapshot left behind: exit the alt
    /// screen, reset every mode the replay may re-set (plus bracketed paste
    /// and SGR attributes), and clear screen AND scrollback.
    ///
    /// `\e[3J` (ED3, xterm scrollback clear) is honored by SwiftTerm via
    /// `feed` — `cmdEraseInDisplay` case 3 trims the scrollback lines —
    /// verified by the M4.2 round-trip test (ED3 was not covered by M4.0).
    ///
    /// Ordering inside the prelude is load-bearing:
    /// - `\e[?1049l` first, so everything after applies to the primary screen.
    /// - `\e[0m` before `\e[2J`, because ED erases using the current
    ///   attributes — a stale background color would repaint the cleared
    ///   screen.
    /// - `\e[2J\e[3J\e[H` last, so the replayed history starts on a blank,
    ///   homed, scrollback-free screen.
    static let resetPrelude: String = [
        "\(esc)[?1049l",  // exit alt screen (stale snapshot may have left it on)
        "\(esc)[r",       // reset scroll region (DECSTBM; also homes the cursor)
        "\(esc)[?1l",     // DECCKM off (normal cursor keys)
        "\(esc)>",        // DECKPNM (normal keypad)
        "\(esc)[?7h",     // DECAWM on (autowrap default; history feed relies on it)
        "\(esc)[?6l",     // DECOM off
        "\(esc)[4l",      // IRM off (replace mode)
        "\(esc)[?1000l",  // mouse click tracking off
        "\(esc)[?1002l",  // mouse button-drag tracking off
        "\(esc)[?1003l",  // mouse any-motion tracking off
        "\(esc)[?1006l",  // SGR mouse encoding off
        "\(esc)[?2004l",  // bracketed paste off (see modeEscapes: never re-synthesized)
        "\(esc)[?25h",    // cursor visible
        "\(esc)[0m",      // SGR reset — before ED, which erases with current attrs
        "\(esc)[2J\(esc)[3J\(esc)[H",  // clear screen + scrollback (ED3), home
    ].joined()

    /// Assemble the full replay byte stream.
    ///
    /// - Parameters:
    ///   - history: lines painted onto the PRIMARY screen (SGR escapes + text
    ///     only, `-J` joined wraps): the pure-scrollback leg (`-S -<N> -E -1`,
    ///     discarded by the orchestrator when `history_size` is 0) followed
    ///     by the current-screen leg for a primary-screen pane, or by the
    ///     `-a` saved-primary viewport when the pane is in alt mode (see the
    ///     orchestrator's leg recombination, review H1).
    ///   - altScreen: lines painted onto the ALT screen after `1049h` — the
    ///     pane's current-screen capture when `state.alternateOn`, else nil.
    ///     `state.alternateOn` alone decides whether the alt screen is
    ///     entered; `nil` content just paints it empty.
    ///   - pending: response lines of `capture-pane -p -P -C` — octal-escaped
    ///     in-flight bytes, unescaped here back to raw bytes.
    ///   - state: the pane's captured mode/cursor state (M4.1).
    ///   - cols/rows: the pane's size, for cursor/region clamping sanity.
    static func assemble(
        history: [String],
        altScreen: [String]?,
        pending: [String],
        state: PaneState,
        cols: Int,
        rows: Int
    ) throws -> Data {
        var out = Data()
        func emit(_ text: String) { out.append(contentsOf: text.utf8) }

        emit(resetPrelude)
        // History lines carry their own SGR state; \r\n between lines (not
        // after the last — the final CUP owns the cursor, and a trailing
        // newline would scroll one extra row into scrollback).
        emit(history.joined(separator: "\r\n"))
        emit(modeEscapes(for: state))

        let region = regionEscape(for: state, rows: rows)
        let cursor = cursorEscape(for: state, cols: cols, rows: rows, regionEmitted: region != nil)
        let pendingBytes = try unescapePending(lines: pending)

        if state.alternateOn {
            // Primary-screen cursor BEFORE 1049h: SwiftTerm's 1049h saves the
            // current cursor, so a later 1049l from the app restores it. tmux
            // reports UINT_MAX (mapped to nil) when nothing was saved — skip.
            // Best-effort: if the alt screen's modes include DECOM (already
            // emitted above), this CUP is region-relative — but no region is
            // active yet (the prelude reset it), so it lands absolutely.
            if let savedX = state.alternateSavedX, let savedY = state.alternateSavedY {
                emit(cup(col: clamp(savedX, max: cols - 1), row: clamp(savedY, max: rows - 1)))
            }
            emit("\(esc)[?1049h")
            // 1049h clears the alt screen but inherits the primary's cursor
            // position — home before painting (deviation 2, see type doc).
            emit("\(esc)[H")
            emit((altScreen ?? []).joined(separator: "\r\n"))
            // Region AFTER the alt switch and content (deviation 1) — still
            // before the cursor, because DECSTBM homes it (M4.0 finding).
            if let region { emit(region) }
            out.append(pendingBytes)
            emit(cursor)
        } else {
            if let region { emit(region) }
            out.append(pendingBytes)
            emit(cursor)
        }
        return out
    }

    // MARK: - Pending-output octal unescape

    /// Decode the `-C` escaping of `capture-pane -p -P -C` back to raw bytes.
    ///
    /// tmux 3.2 (`cmd_capture_pane_pending`) emits, per byte:
    /// - literal, when `byte >= ' ' && byte != '\\'` under *signed* char —
    ///   i.e. 0x20–0x5B and 0x5D–0x7F (DEL included) stay literal;
    /// - `\ooo` (backslash + exactly three octal digits of the unsigned
    ///   value) for everything else: C0 controls 0x00–0x1F, backslash
    ///   (`\134`, NOT `\\`), and — because char is signed on Darwin —
    ///   every byte 0x80–0xFF. Multi-byte UTF-8 therefore arrives fully
    ///   octal-escaped and must be reassembled as raw bytes, never decoded
    ///   as text scalars.
    ///
    /// Lines are concatenated without separators: a real newline in the
    /// pending buffer is escaped (`\012`), so line splits can only be
    /// response-framing artifacts.
    static func unescapePending(lines: [String]) throws -> Data {
        var out = Data()
        for line in lines {
            out.append(try unescapePendingLine(line))
        }
        return out
    }

    static func unescapePendingLine(_ line: String) throws -> Data {
        let bytes = Array(line.utf8)
        var out = Data()
        out.reserveCapacity(bytes.count)
        var index = 0
        let backslash = UInt8(ascii: "\\")
        while index < bytes.count {
            let byte = bytes[index]
            if byte != backslash {
                out.append(byte)
                index += 1
                continue
            }
            // `\` + exactly three octal digits, value ≤ 0xFF (`%03hho` can
            // emit at most \377; anything else is a corrupt response).
            guard index + 3 < bytes.count else {
                throw ReplayWriterError.malformedPendingEscape(line: line)
            }
            var value = 0
            for offset in 1...3 {
                let digit = bytes[index + offset]
                guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "7") else {
                    throw ReplayWriterError.malformedPendingEscape(line: line)
                }
                value = value << 3 | Int(digit - UInt8(ascii: "0"))
            }
            guard value <= 0xFF else {
                throw ReplayWriterError.malformedPendingEscape(line: line)
            }
            out.append(UInt8(value))
            index += 4
        }
        return out
    }

    // MARK: - Escape synthesis

    /// Mode escapes from the captured flags. Every independent mode is
    /// emitted explicitly (set OR reset) so the section is self-describing;
    /// mouse modes emit set-only (the prelude turned them all off) in
    /// ascending order so the most permissive wins in single-mode emulators
    /// like SwiftTerm.
    ///
    /// Deliberately NO bracketed-paste (2004) synthesis: stock tmux exposes
    /// no format variable for the pane's bracketed-paste state at our 3.2
    /// floor, and tmux stays the paste-wrapping authority regardless
    /// (`paste-buffer -p`, addendum §2) — the daemon never needs the app's
    /// emulator to know. The prelude reset 2004; it stays off until the
    /// pane's application re-enables it through live output.
    private static func modeEscapes(for state: PaneState) -> String {
        var out = ""
        out += state.cursorVisible ? "\(esc)[?25h" : "\(esc)[?25l"
        out += state.insertMode ? "\(esc)[4h" : "\(esc)[4l"
        out += state.applicationCursorKeys ? "\(esc)[?1h" : "\(esc)[?1l"
        out += state.applicationKeypad ? "\(esc)=" : "\(esc)>"
        out += state.wraparound ? "\(esc)[?7h" : "\(esc)[?7l"
        out += state.originMode ? "\(esc)[?6h" : "\(esc)[?6l"
        if state.mouseStandard { out += "\(esc)[?1000h" }
        if state.mouseButton { out += "\(esc)[?1002h" }
        if state.mouseAny { out += "\(esc)[?1003h" }
        if state.mouseSGR { out += "\(esc)[?1006h" }
        return out
    }

    /// DECSTBM for a non-default region; nil when the region spans the full
    /// screen (the prelude's `\e[r` already holds) or when the captured
    /// bounds are insane for this pane size (raced a resize — emitting a
    /// wrong region is worse than none).
    private static func regionEscape(for state: PaneState, rows: Int) -> String? {
        let upper = state.scrollRegionUpper
        let lower = state.scrollRegionLower
        guard upper != 0 || lower != rows - 1 else { return nil }
        guard upper >= 0, lower < rows, upper < lower else { return nil }
        return "\(esc)[\(upper + 1);\(lower + 1)r"
    }

    /// Final cursor position — the LAST bytes of the replay. tmux reports
    /// absolute 0-based coordinates, but CUP under DECOM is scroll-region-
    /// relative (SwiftTerm: `buffer.y = scrollTop + row`), so when origin
    /// mode is restored alongside a region the row is translated.
    private static func cursorEscape(
        for state: PaneState, cols: Int, rows: Int, regionEmitted: Bool
    ) -> String {
        let col = clamp(state.cursorX, max: cols - 1)
        var row = clamp(state.cursorY, max: rows - 1)
        if state.originMode && regionEmitted {
            row = clamp(row - state.scrollRegionUpper,
                        max: state.scrollRegionLower - state.scrollRegionUpper)
        }
        return cup(col: col, row: row)
    }

    /// CUP from 0-based coordinates (escape is 1-based).
    private static func cup(col: Int, row: Int) -> String {
        "\(esc)[\(row + 1);\(col + 1)H"
    }

    private static func clamp(_ value: Int, max limit: Int) -> Int {
        min(max(value, 0), max(limit, 0))
    }
}
