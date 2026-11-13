import Foundation
import SwiftTerm

/// Renders a live terminal as a byte stream that reconstructs it in a fresh one.
///
/// The byte order is reset prelude → history → modes → (alt screen) → region →
/// cursor, and every step of it was learned by `ReplayWriter` on the tmux path.
/// On an alt screen, cursor visibility moves from the modes step to just after
/// the switch, because the receiver shows the cursor on every `?1049h`. The
/// modes that switch saves with the cursor (DECOM and the wrap modes) split in
/// two: the modes step carries the primary's saved values, and the alt
/// program's own values follow the alt content.
/// Two orderings inside are counter-intuitive and are called out where they
/// happen: SGR reset precedes the erase, and the scroll region follows the alt
/// content.
///
/// **The caller must hold `terminal.terminalLock` across `snapshot`**, which
/// both reads the terminal and feeds it — the alt-screen toggle, and whatever
/// the supplied `ModeReplyReader` does to obtain a `DECRQM` answer. The lock is
/// not re-entrant, so it is taken by the caller and never here; see
/// `TerminalCellWalk` for why the rule exists at all.
///
/// **Call it between sequences** (`Terminal.isAtSequenceBoundary`). The first
/// `ESC` those feeds carry ends whatever sequence the source terminal is
/// part-way through — an OSC, a DCS, an APC, a CSI's parameters — and the rest
/// of that sequence, when it arrives, prints as text. The bytes this returns
/// cannot carry the open sequence either, so a receiver fed them, and then fed
/// the rest, prints it as text too.
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
        // paints those back from the state captured a moment ago. Its doc
        // comment records what cannot be put back, and why the residue is
        // survivable.
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

        // `capture` reads the saved cursor — `savedX`/`savedY` and the four
        // saved modes — off whichever buffer is active, so on an alt screen it
        // returns the ALT buffer's DECSC. `assemble` needs the other one: it
        // emits these as the cursor and modes `?1049h` will store for a later
        // `?1049l` to restore, which is the PRIMARY buffer's saved state.
        // Emitting the alt buffer's sends a returning viewer to the wrong place
        // on exit — and usually to 0,0, because an alt-screen app that never
        // issues DECSC leaves it unset, which is what made the bug invisible.
        // The toggle has just made the primary current, so read them here,
        // where they mean what `assemble` needs.
        var primaryState = state
        primaryState.savedX = terminal.buffer.savedX
        primaryState.savedY = terminal.buffer.savedY
        primaryState.savedOriginMode = terminal.buffer.savedOriginMode
        primaryState.savedWraparound = terminal.buffer.savedWraparound
        primaryState.savedReverseWraparound = terminal.buffer.savedReverseWraparound
        primaryState.savedMarginMode = terminal.buffer.savedMarginMode

        let history = TerminalCellWalk.styledHistory(
            of: terminal, maxScrollbackLines: maxScrollbackLines)
        return assemble(history: history, altScreen: altScreen, state: primaryState)
    }

    public static func assemble(
        history: String, altScreen: String?, state: CapturedTerminalState
    ) -> Data {
        var out = Data()
        func emit(_ text: String) { out.append(contentsOf: text.utf8) }

        emit(resetPrelude)
        emit(history)   // already joined, wrap-aware — see Task 2
        // `?1049h` saves DECOM, DECAWM, reverse wraparound and DECLRMM along
        // with the cursor (`cmdSaveCursor`), and `?1049l` restores them, so
        // what is current at the switch is what the receiver's primary gets
        // back when the program exits. On an alt screen the live modes in
        // `state` are the program's, and sending them here leaves the primary
        // with autowrap off after a program that turned it off quits — long
        // output then overwrites the last column — or with every CUP read
        // relative to a scroll region. So the primary's saved values go here,
        // and the program's follow the alt content below.
        var beforeSwitch = state
        if state.alternateOn {
            beforeSwitch.originMode = state.savedOriginMode
            beforeSwitch.wraparound = state.savedWraparound
            beforeSwitch.reverseWraparound = state.savedReverseWraparound
            beforeSwitch.marginMode = state.savedMarginMode
        }
        // Cursor visibility is withheld on an alt screen: this fork shows the
        // cursor on every `?1049h`, so it is emitted after the switch below.
        emit(modeEscapes(for: beforeSwitch, includeCursorVisibility: !state.alternateOn))

        let region = regionEscape(for: state)
        let cursor = cursorEscape(for: state, regionEmitted: region != nil)

        if state.alternateOn {
            // 1049h saves the cursor for a later 1049l restore, so the primary
            // position must be in place BEFORE the switch.
            if let savedX = state.savedX, let savedY = state.savedY {
                emit(cup(col: min(savedX, state.cols - 1), row: min(savedY, state.rows - 1)))
            }
            emit("\(esc)[?1049h")
            // Autowrap on for the alt content, which re-wraps continuation rows
            // through it, and so that `?45h` below lands. The primary's own
            // `?7` may be off; the switch has already saved it.
            emit("\(esc)[?7h")
            emit("\(esc)[H")   // 1049h clears but inherits the primary's cursor
            // AFTER the switch: the fork's `?1049h` calls `showCursor()`, so a
            // `?25l` sent earlier is undone and a hidden cursor comes back.
            // Visibility is the only mode the switch changes.
            emit(cursorVisibilityEscape(for: state))
            emit(altScreen ?? "")
            // The program's saved-cursor modes AFTER the content, so the
            // content paints under autowrap, and before the region and the
            // cursor, the order `restoreAlternateScreen` keeps: DECSTBM homes
            // the cursor, and under DECOM the final CUP is read relative to
            // the region, which `cursorEscape` allows for.
            emit(savedCursorModeEscapes(for: state))
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
    /// **Three residual losses are accepted, not oversights.** What the toggle
    /// mutates is the daemon's headless *model* of the screen — no ioctl and
    /// no byte reaches the pty, so the child process never sees it — and the
    /// preamble's content is captured before the destructive half, so what the
    /// viewer receives is unaffected either way. At detach the daemon resets
    /// this emulator and replays the viewer's handback, overwriting the model
    /// wholesale. The real cost is therefore a briefly degraded model, which
    /// matters for a `terminal.output` read taken inside that window, and
    /// which persists only if an attach fails before the detach that would
    /// have overwritten it. (The overwrite is the handback preamble's own
    /// reset prelude, which erases the display and the scrollback before it
    /// replays either.)
    ///
    /// - The selected character set (SCS). `cmdSaveCursor` carries `charset`,
    ///   it is absent from `CapturedTerminalState`, and no public SwiftTerm
    ///   API exposes it.
    /// - Kitty graphics attached to the alt buffer: both buffer activations
    ///   call `clearKittyImages`, and there is no sequence that re-attaches
    ///   them.
    /// - Two spurious `bufferActivated` / alternate-screen-switch delegate
    ///   rounds. Inert in the daemon, whose delegate is
    ///   `ReplyForwardingDelegate` (`SwiftTermHolderEmulator.swift`) and
    ///   implements only `send`, `showCursor` and `hideCursor`, none of which
    ///   reacts to a buffer switch. **Not inert in the app**, where
    ///   `MacTerminalView` posts each one onto its event queue and reacts —
    ///   so running this same path against an app-side emulator, as the
    ///   detach handback would, needs that considered first.
    ///
    /// Known gap: the alt buffer's own saved cursor (`ESC 7` / DECSC, in
    /// `altBuffer.savedX/savedY` and the saved autowrap flag) is not carried
    /// to the viewer, whose alt buffer keeps its defaults (origin, autowrap
    /// off). A program that sent `ESC 7` before the attach and `ESC 8` after
    /// it lands at the default position with autowrap off on the viewer only.
    private static func restoreAlternateScreen(
        of terminal: Terminal,
        content: String,
        state: CapturedTerminalState,
        attribute: Attribute
    ) {
        // `?7h` after the switch for `assemble`'s reason: the toggle restored
        // the primary's autowrap, which may be off, and the content re-wraps
        // continuation rows through it.
        var out = "\(esc)[?1049h\(esc)[?7h\(esc)[H"
        out += content
        // Same order as `assemble`'s tail, for the same reasons: modes after
        // the content and before the region, region before the cursor
        // (DECSTBM homes it, and under DECOM the CUP is region-relative),
        // cursor last.
        out += modeEscapes(for: state)
        let region = regionEscape(for: state)
        if let region { out += region }
        out += cursorEscape(for: state, regionEmitted: region != nil)
        out += SGREncoder.sequence(for: attribute)
        terminal.feed(text: out)
    }

    private static func cursorVisibilityEscape(for state: CapturedTerminalState) -> String {
        "\(esc)[?25\(state.cursorVisible ? "h" : "l")"
    }

    private static func modeEscapes(
        for state: CapturedTerminalState, includeCursorVisibility: Bool = true
    ) -> String {
        var out = ""
        func mode(_ code: Int, _ on: Bool, decPrivate: Bool = true) {
            out += "\(esc)[\(decPrivate ? "?" : "")\(code)\(on ? "h" : "l")"
        }
        mode(1, state.applicationCursor)
        out += state.applicationKeypad ? "\(esc)=" : "\(esc)>"
        out += savedCursorModeEscapes(for: state)
        mode(4, state.insertMode, decPrivate: false)
        if includeCursorVisibility { out += cursorVisibilityEscape(for: state) }
        mode(2004, state.bracketedPaste)
        mode(1004, state.focusReporting)
        // The prelude turned all tracking off, so only a set needs emitting;
        // the encoding must follow the mode it applies to.
        if let tracking = state.mouseTracking { mode(tracking, true) }
        if state.sgrMouseEncoding { mode(1006, true) }
        return out
    }

    /// DECOM, reverse wraparound, DECAWM and DECLRMM: the modes `?1049h` saves
    /// with the cursor and `?1049l` restores.
    private static func savedCursorModeEscapes(for state: CapturedTerminalState) -> String {
        // 45 BEFORE 7, and the order is load-bearing. This fork only lets
        // reverse wraparound turn on while autowrap is currently on, so
        // emitting `?7l` first makes a following `?45h` silently no-op — and
        // the state (autowrap off, reverse wraparound on) is reachable, since
        // turning 7 off afterwards does not clear 45. Every caller sends this
        // with 7 on — after the prelude's `?7h`, or after the `?7h` that
        // follows an alt-screen switch — so 45 lands here and 7 is then set to
        // its real value.
        "\(esc)[?6\(state.originMode ? "h" : "l")"
            + "\(esc)[?45\(state.reverseWraparound ? "h" : "l")"
            + "\(esc)[?7\(state.wraparound ? "h" : "l")"
            + "\(esc)[?69\(state.marginMode ? "h" : "l")"
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
