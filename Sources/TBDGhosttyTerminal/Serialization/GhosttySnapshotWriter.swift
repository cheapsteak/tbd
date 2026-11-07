// The detach handback from a libghostty terminal: bytes that rebuild its screen in the daemon's
// SwiftTerm emulator, the way `TerminalSnapshotWriter` does for a SwiftTerm viewer.
//
// The bytes come from libghostty's own VT formatter, which already writes the modes, tab stops,
// screen contents, scrolling region and cursor state of the active screen. What this file adds is
// what the formatter cannot do alone: the primary screen behind an alternate one, a scrollback cap,
// a reset prelude for a receiver that was used before, reorderings inside the formatter's modes
// that a SwiftTerm receiver would otherwise read differently, and the bytes of a sequence the
// terminal was left inside, so the receiver finishes it from the live stream. The composition is
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
    /// A terminal left inside an escape sequence or a UTF-8 character hands back the bytes of it
    /// last, so the receiver's parser is left inside the same sequence and the rest of it, read
    /// live after the handback, finishes it there. libghostty keeps those bytes only up to
    /// `GhosttyTerminal.continuationMaxBytes`; past that nothing of the sequence is handed back and
    /// the receiver reads its rest as text. A terminal that cannot be cloned, which that case also
    /// leaves, hands back an alternate screen without the primary behind it: the receiver's
    /// primary is blank, with its cursor at home.
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
        // Read first: nil when the sequence outgrew the bytes libghostty keeps for it.
        let unfinished = state.pendingContinuationBytes()
        var out = resetPrelude
        if state.isAlternateScreen {
            out += try alternateHandback(live, state: state, cap: cap)
        } else {
            let formatted = try formatCapped(live, extras: handoverExtras, cap: cap)
            out += reorderModes(formatted, live: live, alternate: nil)
        }
        // Last of all, so the receiver's parser is left inside the same sequence and the live bytes
        // after the handback finish it. A decoded snapshot replays these bytes itself; a handback is
        // parsed as plain bytes, so they are written out here.
        out += unfinished ?? []
        return out
    }

    /// An alternate screen, with the primary screen behind it written first, from a clone that has
    /// left the alternate screen. The primary's cursor, pen, protection and charsets are put in
    /// place before the receiver switches, so the receiver holds them when the program leaves.
    private static func alternateHandback(_ live: VtTerminal, state: GhosttyTerminalState, cap: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var primaryOrigin = false
        if let clone = primaryClone(of: live, state: state) {
            // The state below holds the clone's raw handle, so the clone must outlive every read of it.
            try withExtendedLifetime(clone) {
                // Its ESC cancels any sequence the clone was left inside, which nothing reads after.
                clone.feed(leaveAlternate(state))
                // After `?1049l` this is the origin mode saved with the primary's cursor; after
                // `?47l` or `?1047l`, the one both screens share. It is set before the primary is
                // written, where the full-screen region makes it move nothing, so a receiver's
                // `?1049h` saves it too.
                primaryOrigin = GhosttyTerminalState(raw: clone.raw).mode(6)
                if primaryOrigin { out += Array("\(esc)[?6h".utf8) }
                out += try formatCapped(clone.raw, extras: savedCursorExtras, cap: cap)
            }
        }
        let formatted = try GhosttyVTFormat.format(live, extras: handoverExtras, unwrap: true, trim: false, selection: nil)
        out += reorderModes(formatted, live: live, alternate: AlternateEntry(primaryOrigin: primaryOrigin, liveOrigin: state.mode(6)))
        return out
    }

    /// A clone of `live` to reach the primary screen through, or nil when none can be made.
    /// libghostty keeps the bytes of an unfinished sequence, so a terminal left inside one clones
    /// too, unless the sequence grew past what it keeps. The formatter reads only the active
    /// screen, so without a clone the alternate screen is handed back alone, never an error.
    private static func primaryClone(of live: VtTerminal, state: GhosttyTerminalState) -> GhosttyTerminalClone? {
        do {
            return try GhosttyTerminalClone(of: live)
        } catch {
            let reason = String(describing: error)
            if state.isAtGround {
                terminalEngineLog.error(
                    "libghostty handback: cloning the terminal failed (\(reason, privacy: .public)), so its alternate screen is handed back without the primary screen behind it")
            } else {
                terminalEngineLog.notice(
                    "libghostty handback: the terminal stopped inside a sequence too long to keep (\(reason, privacy: .public)), so its alternate screen is handed back without the primary screen behind it")
            }
            return nil
        }
    }

    /// The reset that leaves the alternate screen the way the program entered it. `?1049l` puts
    /// back the cursor `?1049h` saved; `?47l` and `?1047l` carry the alternate screen's cursor to
    /// the primary, as they will when the program leaves.
    private static func leaveAlternate(_ state: GhosttyTerminalState) -> [UInt8] {
        let entered = [1049, 1047].first { state.mode(UInt16($0)) } ?? 47
        return Array("\(esc)[?\(entered)l".utf8)
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

    /// The modes run at the head of the formatter's output, reordered for a SwiftTerm receiver.
    ///
    /// The formatter writes every mode that differs from its default, in its own enum order, before
    /// the tab stops (`CSI 3 g`) and the contents. A SwiftTerm receiver reads four things in that
    /// run differently from libghostty:
    /// 1. One mouse tracking mode and one report encoding are in effect, the ones set last, but
    ///    libghostty's table keeps a mode set when a later one replaces it, and the run writes them
    ///    in number order. After `?1003h ?1000h` the receiver would track any motion, and after
    ///    `?1015h ?1006h` it would report in urxvt's encoding. Only the one of each in effect is
    ///    written.
    /// 2. Autowrap off and insert mode change how the contents print. The formatter writes a soft
    ///    wrapped line as one run, which lays out only with autowrap on, and its contents and its
    ///    pending-wrap cursor assume a printed character replaces the cell under it. So `?7l` and
    ///    `CSI 4 h` go after everything the formatter writes. That also lands `?45h` while
    ///    autowrap is on, which SwiftTerm needs: it refuses reverse wrap while autowrap is off.
    /// 3. On an alternate screen, SwiftTerm shows the cursor on every switch, so `?25l` moves after
    ///    the switch.
    /// 4. On an alternate screen, SwiftTerm saves origin mode, autowrap, reverse wrap and DECLRMM
    ///    with the cursor on `?1049h` and puts them back on `?1049l`. libghostty keeps one value of
    ///    each for both screens and saves only origin mode with its cursor, so it has no record of
    ///    the primary's other three. Written before the switch, the alternate screen's values would
    ///    be saved as the primary's, and stay after the program left. So all four take the
    ///    alternate screen's values after the switch: the receiver saves the primary's origin mode,
    ///    put back from libghostty's saved cursor, and the prelude's defaults for the other three.
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

        // 1. Only the mouse tracking mode and the report encoding in effect.
        keepOnlyInEffect(&tokens, of: [9, 1000, 1002, 1003], inEffect: effectiveMouseMode(live))
        keepOnlyInEffect(&tokens, of: [1005, 1006, 1015, 1016], inEffect: effectiveMouseEncoding(live))

        // 2. Autowrap off and insert mode after everything else.
        let printing: [ModeToken] = [.dec(7, false), ModeToken(value: 4, decPrivate: false, isSet: true)]
        let trailer = printing.filter { tokens.contains($0) }.flatMap(\.bytes)
        tokens.removeAll { printing.contains($0) }

        guard let alternate else { return tokens.flatMap(\.bytes) + formatted[end...] + trailer }
        let switches: Set<Int> = [47, 1047, 1049]
        guard let enter = tokens.lastIndex(where: { $0.decPrivate && $0.isSet && switches.contains($0.value) }) else {
            terminalEngineLog.error("libghostty handback: alternate screen with no switch mode in the formatter output")
            return tokens.flatMap(\.bytes) + formatted[end...] + trailer
        }
        var before = Array(tokens[..<enter])
        // 3. The cursor is hidden after the switch shows it. 4. Reverse wrap and DECLRMM are the
        // alternate screen's, after the receiver saved the defaults; autowrap is already last.
        var moved = [ModeToken.dec(25, false), .dec(45, true), .dec(69, true)].filter { before.contains($0) }
        before.removeAll { moved.contains($0) || $0 == .dec(6, true) }
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
        return head + defaults + tail + formatted[end...] + trailer
    }

    /// Replaces the tokens that set any of `modes` with one that sets `inEffect`, at the first
    /// one's place, or with none for 0. Left alone when the probe that read `inEffect` failed.
    private static func keepOnlyInEffect(_ tokens: inout [ModeToken], of modes: Set<Int>, inEffect: Int?) {
        guard let inEffect, let first = tokens.firstIndex(where: { $0.decPrivate && modes.contains($0.value) }) else { return }
        tokens.removeAll { $0.decPrivate && modes.contains($0.value) }
        if inEffect != 0 { tokens.insert(.dec(inEffect, true), at: first) }
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

    /// The mouse report encoding the terminal reports in: 1005, 1006, 1015 or 1016, or 0 for
    /// X10's. libghostty reports in the encoding set last, and has no getter for it. So one motion
    /// is encoded with the terminal's encoding under any-motion tracking, whatever the terminal
    /// tracks, in a cell and at a pixel whose numbers tell the five apart. nil when the probe fails.
    static func effectiveMouseEncoding(_ terminal: VtTerminal) -> Int? {
        do {
            let encoder = try GhosttyMouseEncoderHandle()
            var event: GhosttyMouseEvent?
            try ghosttyCheck(ghostty_mouse_event_new(nil, &event), "ghostty_mouse_event_new")
            guard let event else {
                throw GhosttyCallError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_mouse_event_new")
            }
            defer { ghostty_mouse_event_free(event) }
            try ghosttyCheck(
                ghostty_mouse_encoder_set_from_terminal(encoder.raw, terminal), "ghostty_mouse_encoder_set_from_terminal")
            var tracking = GHOSTTY_MOUSE_TRACKING_ANY
            try ghosttyCheck(
                ghostty_mouse_encoder_set(encoder.raw, GHOSTTY_MOUSE_ENCODER_OPT_EVENT, &tracking), "MOUSE_ENCODER_OPT_EVENT")
            // 300 columns of 10-pixel cells. The probe is in column 151, past the 95 in which X10's
            // single bytes and UTF-8's characters still agree, at pixel 1505.
            var size = TerminalPixelGeometry(screenWidth: 3_000, screenHeight: 100, cellWidth: 10, cellHeight: 10).ghostty
            try ghosttyCheck(
                ghostty_mouse_encoder_set(encoder.raw, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size), "MOUSE_ENCODER_OPT_SIZE")
            _ = ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_MOTION)
            _ = ghostty_mouse_event_clear_button(event)
            _ = ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: 1_505, y: 5))
            var report = [UInt8](repeating: 0, count: 64)
            var written = 0
            let result = report.withUnsafeMutableBufferPointer { buffer in
                ghostty_mouse_encoder_encode(encoder.raw, event, buffer.baseAddress, buffer.count, &written)
            }
            try ghosttyCheck(result, "ghostty_mouse_encoder_encode")
            guard let encoding = mouseEncoding(ofReport: report.prefix(written)) else {
                terminalEngineLog.error("libghostty handback: the mouse encoding probe wrote \(written, privacy: .public) unreadable bytes")
                return nil
            }
            return encoding
        } catch {
            terminalEngineLog.error("libghostty handback: mouse encoding probe failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Which encoding wrote the probe's report of column 151, row 1, pixel 1505: `ESC [ M` and
    /// three single bytes for X10, with the column as two UTF-8 bytes for 1005; `ESC [ <` and the
    /// column for 1006, or the pixel for 1016; `ESC [` and decimal fields for 1015.
    static func mouseEncoding(ofReport report: ArraySlice<UInt8>) -> Int? {
        let fields = Array(report)
        guard fields.count > 3, fields[0] == 0x1b, fields[1] == 0x5b else { return nil }
        switch fields[2] {
        case 0x4d:
            return fields.count > 6 ? 1005 : 0
        case 0x3c:
            let numbers = fields[3...].split(separator: 0x3b)
            guard numbers.count >= 2 else { return nil }
            return Array(numbers[1]) == Array("151".utf8) ? 1006 : 1016
        case 0x30...0x39:
            return 1015
        default:
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
