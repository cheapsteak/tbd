import Foundation
import SwiftTerm

/// Renders a live terminal as a byte stream that reconstructs it in a fresh one.
///
/// The byte order is reset prelude → history → modes → (alt screen) → region →
/// cursor, and every step of it was learned by `ReplayWriter` on the tmux path.
/// Two orderings inside are counter-intuitive and are called out where they
/// happen: SGR reset precedes the erase, and the scroll region follows the alt
/// content.
public enum TerminalSnapshotWriter {
    private static let esc = "\u{1b}"

    /// Supersedes whatever state the receiving terminal was already in. A
    /// viewer may be reused, so nothing here may assume a virgin terminal.
    static let resetPrelude: String = [
        "\(esc)[?1049l",   // leave alt screen first: everything after is primary
        "\(esc)[r",        // reset scroll region (also homes the cursor)
        "\(esc)[?1l",      // normal cursor keys
        "\(esc)>",         // normal keypad
        "\(esc)[?7h",      // autowrap on — the history feed depends on it
        "\(esc)[?6l",      // origin mode off
        "\(esc)[4l",       // replace mode
        "\(esc)[?1000l", "\(esc)[?1002l", "\(esc)[?1003l", "\(esc)[?1006l",
        "\(esc)[?1004l",   // focus reporting off
        "\(esc)[?2004l",   // bracketed paste off
        "\(esc)[?25h",     // cursor visible
        "\(esc)[0m",       // SGR reset BEFORE the erase — ED uses current attrs
        "\(esc)[2J\(esc)[3J\(esc)[H",
    ].joined()

    public static func snapshot(
        of terminal: Terminal, reply: ModeReplyReader, maxScrollbackLines: Int
    ) -> Data {
        let state = TerminalModeCapture.capture(from: terminal, reply: reply)
        guard state.alternateOn else {
            let history = TerminalCellWalk.styledHistory(
                of: terminal, maxScrollbackLines: maxScrollbackLines)
            return assemble(history: history, altScreen: nil, state: state)
        }

        // The inactive buffer is unreachable: `Terminal.buffers` does not
        // exist and normalBuffer/altBuffer are internal, and SwiftTerm is an
        // external release-built package no `@testable` import can open. So
        // capture the alt screen, toggle the live terminal back to the primary
        // to walk its history, and toggle forward again.
        //
        // The toggle is destructive, so toggling forward is not enough on its
        // own: `?1049l` calls `altBuffer.clear()` and `?1049h` refills the
        // viewport blank, and both ends run the buffer's saved-cursor
        // save/restore, which carries the current SGR run, DECOM, DECAWM,
        // DECLRMM and reverse wraparound with it. `restoreAlternateScreen`
        // paints those back from the state captured a moment ago, so a live
        // session — this is the daemon's real emulator, not a copy — is left
        // as it was found. Its doc comment records what cannot be put back.
        let attribute = terminal.currentAttribute
        let altScreen = TerminalCellWalk.styledViewport(of: terminal)
        terminal.feed(text: "\(esc)[?1049l")
        // Registered on the statement after the switch, so nothing between the
        // two feeds — now or after a later edit — can return, throw or trap
        // and strand the session on the primary buffer.
        defer {
            restoreAlternateScreen(
                of: terminal, content: altScreen, state: state, attribute: attribute)
        }
        let history = TerminalCellWalk.styledHistory(
            of: terminal, maxScrollbackLines: maxScrollbackLines)
        return assemble(history: history, altScreen: altScreen, state: state)
    }

    public static func assemble(
        history: String, altScreen: String?, state: CapturedTerminalState
    ) -> Data {
        var out = Data()
        func emit(_ text: String) { out.append(contentsOf: text.utf8) }

        emit(resetPrelude)
        emit(history)   // already joined, wrap-aware — see Task 2
        emit(modeEscapes(for: state))

        let region = regionEscape(for: state)
        let cursor = cursorEscape(for: state, regionEmitted: region != nil)

        if state.alternateOn {
            // 1049h saves the cursor for a later 1049l restore, so the primary
            // position must be in place BEFORE the switch.
            if let savedX = state.savedX, let savedY = state.savedY {
                emit(cup(col: min(savedX, state.cols - 1), row: min(savedY, state.rows - 1)))
            }
            emit("\(esc)[?1049h")
            emit("\(esc)[H")   // 1049h clears but inherits the primary's cursor
            emit(altScreen ?? "")
            // Region AFTER the content: SwiftTerm's region is per-buffer, and
            // painting rows through an active one scrolls inside it.
            if let region { emit(region) }
        } else if let region {
            emit(region)
        }
        emit(cursor)   // always last
        return out
    }

    /// Re-enters the alt screen the history walk had to leave, and repaints
    /// what leaving it destroyed: the viewport, the alt buffer's own scroll
    /// region, the cursor, the modes the saved-cursor restore overwrote, and
    /// the open SGR run.
    ///
    /// Three things it cannot put back, all outside `CapturedTerminalState`:
    /// the selected character set (SCS — saved and restored alongside the
    /// cursor, and not readable through any public API), kitty graphics
    /// attached to the alt buffer, and the two `bufferActivated` /
    /// alternate-screen-switch delegate callbacks the toggle fires on the way
    /// through.
    private static func restoreAlternateScreen(
        of terminal: Terminal,
        content: String,
        state: CapturedTerminalState,
        attribute: Attribute
    ) {
        var out = "\(esc)[?1049h\(esc)[H"
        out += content
        // Same order as `assemble`'s tail, for the same reasons: modes before
        // the region (DECOM homes the cursor), region before the cursor
        // (DECSTBM homes it too), cursor last.
        out += modeEscapes(for: state)
        let region = regionEscape(for: state)
        if let region { out += region }
        out += cursorEscape(for: state, regionEmitted: region != nil)
        out += SGREncoder.sequence(for: attribute)
        terminal.feed(text: out)
    }

    private static func modeEscapes(for state: CapturedTerminalState) -> String {
        var out = ""
        func mode(_ code: Int, _ on: Bool, decPrivate: Bool = true) {
            out += "\(esc)[\(decPrivate ? "?" : "")\(code)\(on ? "h" : "l")"
        }
        mode(1, state.applicationCursor)
        out += state.applicationKeypad ? "\(esc)=" : "\(esc)>"
        mode(6, state.originMode)
        // 45 BEFORE 7, and the order is load-bearing. This fork only lets
        // reverse wraparound turn on while autowrap is currently on, so
        // emitting `?7l` first makes a following `?45h` silently no-op — and
        // the state (autowrap off, reverse wraparound on) is reachable, since
        // turning 7 off afterwards does not clear 45. The prelude leaves 7 on,
        // so 45 lands here and 7 is then set to its real value.
        mode(45, state.reverseWraparound)
        mode(7, state.wraparound)
        mode(69, state.marginMode)
        mode(4, state.insertMode, decPrivate: false)
        mode(25, state.cursorVisible)
        mode(2004, state.bracketedPaste)
        mode(1004, state.focusReporting)
        // The prelude turned all tracking off, so only a set needs emitting;
        // the encoding must follow the mode it applies to.
        if let tracking = state.mouseTracking { mode(tracking, true) }
        if state.sgrMouseEncoding { mode(1006, true) }
        return out
    }

    private static func regionEscape(for state: CapturedTerminalState) -> String? {
        // Full-screen or nonsensical bounds: emit nothing and let the prelude's
        // reset stand.
        guard state.scrollTop > 0 || state.scrollBottom < state.rows - 1 else { return nil }
        guard state.scrollTop < state.scrollBottom, state.scrollBottom < state.rows else {
            return nil
        }
        return "\(esc)[\(state.scrollTop + 1);\(state.scrollBottom + 1)r"
    }

    private static func cursorEscape(
        for state: CapturedTerminalState, regionEmitted: Bool
    ) -> String {
        // Under DECOM, CUP is region-relative: buffer.y = scrollTop + row.
        let row = state.originMode && regionEmitted
            ? state.cursorY - state.scrollTop
            : state.cursorY
        return cup(
            col: max(0, min(state.cursorX, state.cols - 1)),
            row: max(0, min(row, state.rows - 1)))
    }

    private static func cup(col: Int, row: Int) -> String {
        "\(esc)[\(row + 1);\(col + 1)H"
    }
}
