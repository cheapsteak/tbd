// The detach handback from a libghostty terminal: bytes that rebuild its screen in the daemon's
// SwiftTerm emulator, the way `TerminalSnapshotWriter` does for a SwiftTerm viewer.
//
// The bytes come from libghostty's own VT formatter, which already writes the modes, tab stops,
// screen contents, scrolling region and cursor state of the active screen. What this file adds is
// what the formatter cannot do alone: the primary screen behind an alternate one, a scrollback cap,
// a reset prelude for a receiver that was used before, and four reorderings inside the formatter's
// modes, each of which a SwiftTerm receiver would otherwise read differently. The composition is
// adapted from the libghostty proof of concept's `formatterComposed`
// (spikes/libghostty-vt/check/Sources/vtcheck/Handover.swift on branch spike/libghostty-vt-poc).
import Foundation
import GhosttyVt
import os

/// Why a handback could not be written.
public enum GhosttyHandbackError: LocalizedError, Equatable, Sendable {
    /// The terminal was closed, so there is no screen to hand back.
    case terminalClosed
    /// A libghostty call failed. `result` is its `GhosttyResult` value.
    case libraryCall(operation: String, result: Int32)

    public var errorDescription: String? {
        switch self {
        case .terminalClosed: return "the libghostty terminal is closed"
        case .libraryCall(let operation, let result): return "\(operation) failed (result \(result))"
        }
    }
}

public enum GhosttySnapshotWriter {
    /// The terminal's screen as bytes that rebuild it in a receiving terminal of the same size,
    /// with at most `maxScrollbackLines` rows of scrollback. Taken inside the terminal's lock, and
    /// the live terminal is only read: the primary screen behind an alternate one is reached
    /// through an in-process clone.
    ///
    /// A terminal that stopped inside an escape sequence or a UTF-8 character cannot be cloned,
    /// so on the alternate screen it is handed back without the primary behind it: the receiver's
    /// primary is blank, with its cursor at home. Either way the unfinished sequence is not part
    /// of the handback, so the rest of it reaches the receiver as a sequence that never started.
    public static func snapshot(of terminal: GhosttyTerminal, maxScrollbackLines: Int) throws -> Data {
        let cap = max(0, maxScrollbackLines)
        let bytes: [UInt8]? = try terminal.withLocked { state in
            guard let raw = state.raw else { return nil }
            do {
                return try handback(raw, state: state, cap: cap)
            } catch let error as GhosttyCallError {
                terminalEngineLog.error("libghostty handback failed: \(error.description, privacy: .public)")
                throw GhosttyHandbackError.libraryCall(operation: error.operation, result: error.result)
            }
        }
        guard let bytes else { throw GhosttyHandbackError.terminalClosed }
        return Data(bytes)
    }

    // MARK: - Composition

    private static let esc = "\u{1b}"

    /// Supersedes whatever state the receiver was in, so a receiver that was used before reads the
    /// handback as a fresh one would. `TerminalSnapshotWriter.resetPrelude`, plus the modes,
    /// charsets and protection the formatter can set but the SwiftTerm writer never does.
    static let resetPrelude: [UInt8] = Array([
        "\(esc)[?1049l",   // leave the alternate screen: everything after starts on the primary
        "\(esc)[?69l",     // no left and right margins, so the region reset below is full width
        "\(esc)[r",        // full-screen scrolling region; also homes the cursor
        "\(esc)[?1l", "\(esc)>",
        "\(esc)[?7h",      // autowrap on: the formatter writes a wrapped line as one run
        "\(esc)[?45l",
        "\(esc)[?6l",
        "\(esc)[4l", "\(esc)[20l", "\(esc)[?5l",
        "\(esc)[?9l", "\(esc)[?1000l", "\(esc)[?1002l", "\(esc)[?1003l",
        "\(esc)[?1005l", "\(esc)[?1006l", "\(esc)[?1015l", "\(esc)[?1016l",
        "\(esc)[?1004l", "\(esc)[?2004l", "\(esc)[?2026l",
        "\(esc)[?25h",
        "\(esc)(B", "\u{0f}",   // G0 is ASCII and in use
        "\(esc)[0\"q",          // unprotected
        "\(esc)[0m",            // SGR reset before the erase, which paints with the current pen
        "\(esc)[2J\(esc)[3J\(esc)[H",
    ].joined().utf8)

    /// Everything but the palette: a palette replay would overwrite the receiver's theme.
    private static let handoverExtras = GhosttyVTFormat.all & ~GhosttyVTFormat.palette

    /// What `?1049h` saves for the matching `?1049l`: the cursor, the pen, protection and charsets.
    private static let savedCursorExtras = GhosttyVTFormat.cursor | GhosttyVTFormat.style
        | GhosttyVTFormat.protection | GhosttyVTFormat.charsets

    private static func handback(_ live: VtTerminal, state: GhosttyTerminalState, cap: Int) throws -> [UInt8] {
        var out = resetPrelude
        guard state.isAlternateScreen else {
            let formatted = try formatCapped(live, extras: handoverExtras, cap: cap)
            out += reorderModes(formatted, live: live, alternate: nil)
            return out
        }

        // The primary screen is behind the alternate one, so it is written first, from a clone
        // that has left the alternate screen. Its cursor, pen, protection and charsets are put in
        // place for the receiver's `?1049h` to save, so a later `?1049l` restores them.
        var primaryOrigin = false
        if let clone = try primaryClone(of: live, state: state) {
            // The state below holds the clone's raw handle, so the clone must outlive every read of it.
            try withExtendedLifetime(clone) {
                clone.feed(Array("\(esc)[?1049l".utf8))
                // libghostty's saved cursor carries origin mode, so the primary's comes back with it.
                // It is set before the primary is written, where the full-screen region makes it move
                // nothing, so the receiver's `?1049h` saves it too.
                primaryOrigin = GhosttyTerminalState(raw: clone.raw).mode(6)
                if primaryOrigin { out += Array("\(esc)[?6h".utf8) }
                out += try formatCapped(clone.raw, extras: savedCursorExtras, cap: cap)
            }
        }

        let formatted = try GhosttyVTFormat.format(live, extras: handoverExtras, unwrap: true, trim: false, selection: nil)
        out += reorderModes(formatted, live: live, alternate: AlternateEntry(primaryOrigin: primaryOrigin, liveOrigin: state.mode(6)))
        return out
    }

    /// A clone of `live` to reach the primary screen through, or nil when the terminal stopped
    /// inside an escape sequence or a UTF-8 character. The snapshot encoder copies an unfinished
    /// sequence only from the continuation bytes a terminal keeps once
    /// `GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES` is set, and refuses a terminal that keeps
    /// none. The formatter reads only the active screen, so without a clone the alternate screen
    /// is handed back alone. A clone that fails at ground is a library failure and is thrown.
    private static func primaryClone(of live: VtTerminal, state: GhosttyTerminalState) throws -> GhosttyTerminalClone? {
        do {
            return try GhosttyTerminalClone(of: live)
        } catch let error as GhosttyCallError where !state.isAtGround {
            terminalEngineLog.notice(
                "libghostty handback: the terminal stopped inside a sequence, so its alternate screen is handed back without the primary screen behind it (\(error.description, privacy: .public))")
            return nil
        }
    }

    /// The formatter's output for the whole screen, unwrapped and untrimmed, as a fresh receiver
    /// reads it back. With more than `cap` rows of scrollback, a selection keeps only the newest
    /// `cap` rows of it; the formatter writes its extras either way.
    private static func formatCapped(_ terminal: VtTerminal, extras: UInt32, cap: Int) throws -> [UInt8] {
        let state = GhosttyTerminalState(raw: terminal)
        let history = state.historyRowCount
        guard history > cap else {
            return try GhosttyVTFormat.format(terminal, extras: extras, unwrap: true, trim: false, selection: nil)
        }
        var selection = GhosttySelection()
        if cap > 0 {
            // History row 0 is the oldest, so the newest `cap` rows start at `history - cap`.
            selection.start = try gridRef(terminal, GHOSTTY_POINT_TAG_HISTORY, x: 0, y: history - cap)
        } else {
            selection.start = try gridRef(terminal, GHOSTTY_POINT_TAG_ACTIVE, x: 0, y: 0)
        }
        selection.end = try gridRef(terminal, GHOSTTY_POINT_TAG_ACTIVE, x: state.cols - 1, y: state.rows - 1)
        selection.rectangle = false
        return try GhosttyVTFormat.format(terminal, extras: extras, unwrap: true, trim: false, selection: selection)
    }

    private static func gridRef(_ terminal: VtTerminal, _ tag: GhosttyPointTag, x: Int, y: Int) throws -> GhosttyGridRef {
        var point = GhosttyPoint()
        point.tag = tag
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: max(x, 0)), y: UInt32(clamping: max(y, 0)))
        var ref = GhosttyGridRef()
        try ghosttyCheck(ghostty_terminal_grid_ref(terminal, point, &ref), "ghostty_terminal_grid_ref")
        return ref
    }

    // MARK: - Reordering the modes

    /// One `CSI [?] Pm h|l` the formatter writes for a mode that differs from its default.
    struct ModeToken: Equatable {
        var value: Int
        var decPrivate: Bool
        var isSet: Bool

        var bytes: [UInt8] { Array("\u{1b}[\(decPrivate ? "?" : "")\(value)\(isSet ? "h" : "l")".utf8) }

        static func dec(_ value: Int, _ isSet: Bool) -> ModeToken { ModeToken(value: value, decPrivate: true, isSet: isSet) }
    }

    /// The origin-mode facts the alternate-screen reordering needs.
    struct AlternateEntry {
        /// DECOM as the primary's saved cursor holds it.
        var primaryOrigin: Bool
        /// DECOM on the live alternate screen.
        var liveOrigin: Bool
    }

    /// The four reorderings, applied to the modes run at the head of the formatter's output.
    ///
    /// The formatter writes every mode that differs from its default, in its own enum order, before
    /// the tab stops (`CSI 3 g`) and the contents. A SwiftTerm receiver reads four things in that
    /// run differently from libghostty:
    /// 1. Only one mouse tracking mode is in effect, but a mode stays set in libghostty's table when
    ///    a later one replaces it, so after `?1003h ?1000h` the run holds both, lowest first, and
    ///    the receiver would track any motion. Only the mode in effect is written.
    /// 2. SwiftTerm refuses `?45h` while autowrap is off, and the run writes `?7l` first. `?45h`
    ///    moves ahead of `?7l`.
    /// 3. On an alternate screen, SwiftTerm shows the cursor on every switch, so `?25l` moves after
    ///    the switch.
    /// 4. On an alternate screen, origin mode written before the switch would be saved with the
    ///    primary's cursor, so it moves after the switch, and the primary's own is put back.
    /// A run that does not parse as mode tokens is written as the formatter wrote it.
    static func reorderModes(_ formatted: [UInt8], live: VtTerminal, alternate: AlternateEntry?) -> [UInt8] {
        let tabClear: [UInt8] = Array("\u{1b}[3g".utf8)
        guard let end = firstIndex(of: tabClear, in: formatted) else {
            terminalEngineLog.error("libghostty handback: no tab-stop reset in the formatter output; modes left as written")
            return formatted
        }
        guard var tokens = parseModes(formatted[..<end]) else {
            terminalEngineLog.error("libghostty handback: the formatter's modes did not parse; left as written")
            return formatted
        }

        // 1. Only the mouse tracking mode in effect.
        let mouseModes: Set<Int> = [9, 1000, 1002, 1003]
        if let first = tokens.firstIndex(where: { $0.decPrivate && mouseModes.contains($0.value) }),
           let effective = effectiveMouseMode(live) {
            tokens.removeAll { $0.decPrivate && mouseModes.contains($0.value) }
            if effective != 0 { tokens.insert(.dec(effective, true), at: first) }
        }

        // 2. Reverse wrap before autowrap goes off.
        if let wrapOff = tokens.firstIndex(of: .dec(7, false)),
           let reverseOn = tokens.firstIndex(of: .dec(45, true)), reverseOn > wrapOff {
            let reverse = tokens.remove(at: reverseOn)
            tokens.insert(reverse, at: wrapOff)
        }

        guard let alternate else { return tokens.flatMap(\.bytes) + formatted[end...] }
        let switches: Set<Int> = [47, 1047, 1049]
        guard let enter = tokens.lastIndex(where: { $0.decPrivate && $0.isSet && switches.contains($0.value) }) else {
            terminalEngineLog.error("libghostty handback: alternate screen with no switch mode in the formatter output")
            return tokens.flatMap(\.bytes) + formatted[end...]
        }
        var before = Array(tokens[..<enter])
        var moved: [ModeToken] = []
        // 3. The cursor is hidden after the switch shows it.
        if before.contains(.dec(25, false)) { moved.append(.dec(25, false)) }
        before.removeAll { $0 == .dec(25, false) || $0 == .dec(6, true) }
        // 4. Origin mode for the alternate screen, after the primary's is saved.
        if alternate.liveOrigin {
            moved.append(.dec(6, true))
        } else if alternate.primaryOrigin {
            moved.append(.dec(6, false))
        }
        // The primary's pen, protection and charset are saved by now. The formatter writes the
        // alternate screen's contents for a terminal at its defaults and puts that screen's own
        // pen back after them, so the defaults are restored before the rest of the run.
        let defaults = Array("\u{1b}[0m\u{1b}[0\"q\u{1b}(B\u{0f}".utf8)
        let head = (before + [tokens[enter]] + moved).flatMap(\.bytes)
        let tail = tokens[(enter + 1)...].flatMap(\.bytes)
        return head + defaults + tail + formatted[end...]
    }

    /// Parses a run of `ESC [ [?] digits h|l`. nil when anything else is in it.
    static func parseModes(_ run: ArraySlice<UInt8>) -> [ModeToken]? {
        var tokens: [ModeToken] = []
        var index = run.startIndex
        while index < run.endIndex {
            guard run[index] == 0x1b, index + 1 < run.endIndex, run[index + 1] == 0x5b else { return nil }
            index += 2
            var decPrivate = false
            if index < run.endIndex, run[index] == 0x3f {
                decPrivate = true
                index += 1
            }
            var value = 0
            var digits = 0
            while index < run.endIndex, run[index] >= 0x30, run[index] <= 0x39, digits < 6 {
                value = 10 * value + Int(run[index] - 0x30)
                digits += 1
                index += 1
            }
            guard digits > 0, index < run.endIndex, run[index] == 0x68 || run[index] == 0x6c else { return nil }
            tokens.append(ModeToken(value: value, decPrivate: decPrivate, isSet: run[index] == 0x68))
            index += 1
        }
        return tokens
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return start }
        }
        return nil
    }

    /// The mouse tracking mode the terminal reports with: 9, 1000, 1002 or 1003, or 0 for none.
    /// libghostty has no getter for it, so each probe event is encoded with the terminal's
    /// settings, from the one only any-motion tracking reports to the one even X10 reports. nil
    /// when a probe fails.
    static func effectiveMouseMode(_ terminal: VtTerminal) -> Int? {
        // A 10 by 10 grid of 10-pixel cells, with every probe inside its first cell.
        let geometry = TerminalPixelGeometry(screenWidth: 100, screenHeight: 100, cellWidth: 10, cellHeight: 10)
        let inside = SurfacePoint(x: 5, y: 5)
        let probes: [(mode: Int, press: MousePress)] = [
            (1003, MousePress(action: .motion, button: nil, position: inside)),
            (1002, MousePress(action: .motion, button: .left, position: inside)),
            (1000, MousePress(action: .release, button: .left, position: inside)),
            (9, MousePress(action: .press, button: .left, position: inside)),
        ]
        do {
            for probe in probes {
                // A fresh encoder each time, so no probe is dropped as a repeat of the last cell.
                let encoder = try MouseEncoder(geometry: geometry)
                if try encoder.encode(probe.press, terminal: terminal) != nil { return probe.mode }
            }
            return 0
        } catch {
            terminalEngineLog.error("libghostty handback: mouse mode probe failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// A deep copy of a terminal, made through libghostty's snapshot encoder and decoder, so the
/// handback can leave the alternate screen without touching the live terminal. Freed on deinit.
private final class GhosttyTerminalClone {
    let raw: VtTerminal

    init(of terminal: VtTerminal) throws {
        var encoded: UnsafeMutablePointer<UInt8>?
        var length = 0
        try ghosttyCheck(ghostty_snapshot_encode_alloc(terminal, nil, &encoded, &length), "ghostty_snapshot_encode_alloc")
        defer { if let encoded { ghostty_free(nil, encoded, length) } }
        var decoder: GhosttySnapshotDecoder?
        try ghosttyCheck(
            ghostty_snapshot_decoder_new_buf(nil, &decoder, UnsafePointer(encoded), length),
            "ghostty_snapshot_decoder_new_buf")
        defer { ghostty_snapshot_decoder_free(decoder) }
        var decoded: VtTerminal?
        try ghosttyCheck(ghostty_snapshot_decoder_decode(decoder, &decoded), "ghostty_snapshot_decoder_decode")
        guard let decoded else {
            throw GhosttyCallError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_snapshot_decoder_decode")
        }
        raw = decoded
    }

    deinit { ghostty_terminal_free(raw) }

    func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            ghostty_terminal_vt_write(raw, buffer.baseAddress, buffer.count)
        }
    }
}
