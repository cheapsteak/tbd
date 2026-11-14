// The emulator parity suite's machinery: both daemon emulators fed one stream, what each answers
// read into named fields, the recordings it feeds, and the thread its bodies run on. The suite and
// its expected misses are in HolderEmulatorParityTests.swift.
import Foundation
import Synchronization
@testable import TBDDaemonLib
@testable import TBDGhosttyCore
// Scoped: the screen model is all this needs from TBDShared, and a bare `Terminal` stays unbound.
import struct TBDShared.TerminalScreen
import TestSupport
import Testing

enum EmulatorParity {
    /// Lines asked of `screen(maxLines:source:)` and scrollback asked of `styledCapture`: more
    /// than any scenario's history, and the window `ProjectionParityTests` reads in the engine's
    /// own suites. The snapshot carries the daemon's whole cap, `HolderReader.scrollbackLines`.
    static let screenLines = 1_000
    static let captureScrollback = 1_000

    /// A failure whose text must reach the primary failure line: `Issue.record(_: some Error)`
    /// is the form that puts it there (`Tests/CLAUDE.md`, "Timeout errors must report observed
    /// state").
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - What the emulators send

    /// What one emulator sent: the bytes it wrote to the child and the program-status payloads it
    /// delivered, each in order. The emulators call in on the feeding thread, inside a parse or
    /// just after it, so the lists sit behind a lock.
    final class Sink: Sendable {
        private struct Sent {
            var replies: [UInt8] = []
            var reports: [[UInt8]] = []
        }

        private let sent = Mutex(Sent())

        func reply(_ bytes: ArraySlice<UInt8>) { sent.withLock { $0.replies.append(contentsOf: bytes) } }
        func report(_ payload: [UInt8]) { sent.withLock { $0.reports.append(payload) } }
        var replies: [UInt8] { sent.withLock { $0.replies } }
        var reports: [[UInt8]] { sent.withLock { $0.reports } }
    }

    // MARK: - The two emulators

    /// How a recording is fed: whole, or cut into chunks of a fixed size, so sequences and
    /// characters split across reads as a pty splits them.
    struct FeedPlan: Sendable, CustomTestStringConvertible {
        let chunkSize: Int?

        static let chunkSizes: [Int] = [64, 4_096]
        static let all: [FeedPlan] = [FeedPlan(chunkSize: nil)] + chunkSizes.map { FeedPlan(chunkSize: $0) }

        var testDescription: String { chunkSize.map { "\($0)-byte chunks" } ?? "whole" }

        /// What a miss key adds after the recording's name for this plan alone: `whole`, or the
        /// chunk size.
        var keySuffix: String { chunkSize.map { "\($0)" } ?? "whole" }

        /// The key of a miss that holds for this plan only: `<recording>/<plan>`. A miss keyed by
        /// the recording's bare name holds for every plan.
        func missKey(for name: String) -> String { "\(name)/\(keySuffix)" }
    }

    /// A clock the suite moves by hand, so the age an emulator reports says when it last stamped
    /// a byte: an emulator that stopped stamping in `feed` reports the age of its construction.
    final class HandClock: Sendable {
        private let instant = Mutex(ContinuousClock.now)

        var now: ContinuousClock.Instant { instant.withLock { $0 } }

        func advance(by duration: Duration) {
            instant.withLock { $0 = $0.advanced(by: duration) }
        }
    }

    /// Both daemon emulators for one stream, each built as `HolderEmulatorKind.makeEmulator`
    /// builds a reader's, with the daemon's scrollback, a program-status tap and a reply sink of
    /// its own, and one hand-moved clock: built at t0, each feed `feedDelay` after the last
    /// event, each comparison `readDelay` after the last feed. Both emulators then report an age
    /// of `readDelay`, and one that stopped stamping its feeds reports a longer one.
    struct Pair {
        static let feedDelay: Duration = .seconds(7)
        static let readDelay: Duration = .seconds(3)

        let cols: Int
        let rows: Int
        let clock: HandClock
        let swiftTerm: any HolderEmulator
        let ghostty: any HolderEmulator
        let swiftTermSink: Sink
        let ghosttySink: Sink

        /// Throws when libghostty could not make its terminal: the kind falls back to SwiftTerm
        /// then, and two SwiftTerm emulators would agree on everything.
        init(cols: Int, rows: Int) throws {
            let clock = HandClock()
            let swiftTermSink = Sink()
            let ghosttySink = Sink()
            let swiftTerm = Self.emulator(.swiftTerm, cols: cols, rows: rows, clock: clock, sink: swiftTermSink)
            let ghostty = Self.emulator(.ghostty, cols: cols, rows: rows, clock: clock, sink: ghosttySink)
            guard swiftTerm.kind == .swiftTerm, ghostty.kind == .ghostty else {
                throw Failure(
                    description: "the libghostty emulator fell back to \(ghostty.kind), so there is nothing to compare")
            }
            self.cols = cols
            self.rows = rows
            self.clock = clock
            self.swiftTerm = swiftTerm
            self.ghostty = ghostty
            self.swiftTermSink = swiftTermSink
            self.ghosttySink = ghosttySink
        }

        private static func emulator(
            _ kind: HolderEmulatorKind, cols: Int, rows: Int, clock: HandClock, sink: Sink
        ) -> any HolderEmulator {
            kind.makeEmulator(
                sessionID: UUID(),
                columns: cols,
                rows: rows,
                scrollback: HolderReader.scrollbackLines,
                observedChildFromStart: true,
                monotonicNow: { clock.now },
                programStatus: HolderProgramStatusTap(deliver: { sink.report($0) }),
                reply: { sink.reply($0) })
        }

        /// Feeds both emulators the same bytes, whole or in chunks of `chunkSize`, `feedDelay`
        /// after the last event.
        func feed(_ bytes: ArraySlice<UInt8>, chunkSize: Int? = nil) {
            clock.advance(by: Self.feedDelay)
            for emulator in [swiftTerm, ghostty] {
                guard let chunkSize else {
                    emulator.feed(bytes)
                    continue
                }
                var start = bytes.startIndex
                while start < bytes.endIndex {
                    let end = min(start + chunkSize, bytes.endIndex)
                    emulator.feed(bytes[start..<end])
                    start = end
                }
            }
        }

        /// Every field in which the libghostty emulator's answer differs from SwiftTerm's, with
        /// its first difference, read `readDelay` after the last feed. `stream` is every byte fed
        /// so far, which says how a viewer on an alternate screen leaves it.
        func differences(stream: ArraySlice<UInt8>) throws -> [String: String] {
            clock.advance(by: Self.readDelay)
            var expected = try observe(swiftTerm, sink: swiftTermSink, stream: stream)
            var actual = try observe(ghostty, sink: ghosttySink, stream: stream)
            EmulatorParity.narrowReplyOrder(&expected, &actual)
            return EmulatorParity.differences(expected, actual)
        }

        func observe(_ emulator: any HolderEmulator, sink: Sink, stream: ArraySlice<UInt8>) throws -> [String: Observed] {
            try EmulatorParity.observe(emulator, sink: sink, cols: cols, rows: rows, stream: stream)
        }
    }

    // MARK: - Reading an emulator

    /// One thing an emulator or a viewer answers, as text a failure can print. Compared byte for
    /// byte, so two spellings of one character are a difference.
    enum Observed: Equatable {
        /// A short value, printed whole.
        case value(String)
        /// Many lines, or a run of bytes. A failure prints where they first differ.
        case text(String)

        var string: String {
            switch self {
            case .value(let string), .text(let string): return string
            }
        }

        static func == (lhs: Observed, rhs: Observed) -> Bool {
            switch (lhs, rhs) {
            case (.value(let left), .value(let right)), (.text(let left), .text(let right)):
                return left.utf8.elementsEqual(right.utf8)
            default:
                return false
            }
        }
    }

    /// Comparison 1: what the daemon reads of a session's screen.
    static let daemonFields: [String] = [
        "screen.lines", "screen.viewportStart", "screen.cursor", "screen.cursorVisible", "screen.size", "screen.modes",
        "screen.provenance", "render", "capture",
    ]
    /// Comparison 2: what the emulator sent. The replies to the child, one field per kind of
    /// reply (`replyKind`), each reply on a line of its own, and `replies.order`, the order of
    /// the kinds both emulators sent; then the program-status reports.
    static let sentFields: [String] = replyKinds.map { "replies." + $0 } + ["replies.order", "reports"]

    /// Comparison 3: what a viewer restores from the snapshot, read under `prefix`.
    static func viewerFields(prefix: String) -> [String] {
        let screen: [String] = ["text", "styled", "cursor", "pendingWrap", "cursorVisible", "cursorStyle", "alternateScreen"]
        let modes: [String] = viewerModes.map { "mode." + $0.name }
        let rest: [String] = ["mouseTracking", "mouseEncoding", "region", "kittyFlags"]
        let extras: [String] = viewerExtras.map { $0.name }
        let read: [String] = screen + modes + rest + extras + ["savedCursor"]
        return read.map { prefix + $0 }
    }

    /// Every field a reading of a stream left on an alternate screen holds. One left on the
    /// primary screen holds all but the `viewer.leave.` ones.
    static var allFields: Set<String> {
        Set(daemonFields + sentFields + viewerFields(prefix: "viewer.") + viewerFields(prefix: "viewer.leave."))
    }

    /// What the daemon reads of one emulator, then its attach snapshot as a fresh libghostty
    /// viewer restores it.
    ///
    /// Every daemon read comes before the snapshot. The SwiftTerm emulator's snapshot feeds its
    /// own terminal: a `DECRQM` query per mode it reads, and on an alternate screen a switch away
    /// and back, which shows the cursor. The reads after it would see that.
    static func observe(
        _ emulator: any HolderEmulator, sink: Sink, cols: Int, rows: Int, stream: ArraySlice<UInt8>
    ) throws -> [String: Observed] {
        var fields: [String: Observed] = [:]
        let screen = try emulator.screen(maxLines: screenLines, source: .daemon)
        fields["screen.lines"] = .text(screen.lines.joined(separator: "\n"))
        fields["screen.viewportStart"] = .value("\(screen.viewportStart)")
        fields["screen.cursor"] = .value("column \(screen.cursor.column), row \(screen.cursor.row)")
        fields["screen.cursorVisible"] = .value("\(screen.cursor.visible)")
        fields["screen.size"] = .value("\(screen.size.columns)x\(screen.size.rows)")
        fields["screen.modes"] = .value(
            "bracketedPaste \(screen.modes.bracketedPaste), applicationCursor \(screen.modes.applicationCursor), "
                + "alternateScreen \(screen.modes.alternateScreen)")
        fields["screen.provenance"] = .value(
            "modesObserved \(screen.modesObserved), contentObserved \(screen.contentObserved), "
                + "source \(screen.source.rawValue), age \(screen.ageMilliseconds) ms")
        fields["render"] = .text(trimmedRender(emulator.renderScreen()))
        fields["capture"] = .text(emulator.styledCapture(maxScrollbackLines: captureScrollback))
        let replies = splitReplies(sink.replies)
        let kinds = replies.map { replyKind($0) }
        for kind in replyKinds {
            let sent = zip(replies, kinds).filter { $0.1 == kind }.map { escaped($0.0) }
            fields["replies." + kind] = .text(sent.joined(separator: "\n"))
        }
        // Every reply's kind in turn: `narrowReplyOrder` keeps the kinds both emulators sent.
        fields["replies.order"] = .text(kinds.joined(separator: "\n"))
        fields["reports"] = .text(sink.reports.map { escaped($0) }.joined(separator: "\n"))

        // The attach path waits for this before it asks such an emulator for a snapshot.
        if emulator.snapshotNeedsSequenceBoundary, !emulator.isAtSequenceBoundary {
            throw Failure(description: "the \(emulator.kind) emulator stopped inside a sequence, where no snapshot is taken")
        }
        let preamble = [UInt8](emulator.snapshotPreamble(maxScrollbackLines: HolderReader.scrollbackLines))
        fields.merge(try viewerReading(preamble, cols: cols, rows: rows, prefix: "viewer.")) { _, viewer in viewer }
        if fields["viewer.alternateScreen"] == .value("true") {
            let left = try viewerReading(preamble + leaveSequence(stream), cols: cols, rows: rows, prefix: "viewer.leave.")
            fields.merge(left) { _, viewer in viewer }
        }
        return fields
    }

    /// `renderScreen` with the spaces at the end of each row, and then the empty rows at the end,
    /// removed. libghostty's render trims the spaces a program wrote at the end of a row, where
    /// SwiftTerm's keeps them (`GhosttyTerminalState.viewportLines` says so); trimmed on both
    /// sides, everything else must still agree.
    static func trimmedRender(_ render: String) -> String {
        var lines = render.components(separatedBy: "\n").map { line in
            var line = line
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// How the program would leave the alternate screen: the way it last entered one, `?47`,
    /// `?1047` or `?1049`, as the handover suites leave it. Both snapshots enter with `?1049h`,
    /// so a `?47l` or `?1047l` leaves without restoring the cursor `?1049h` saved, as the
    /// program's own would.
    static func leaveSequence(_ stream: ArraySlice<UInt8>) -> [UInt8] {
        let modes: [Int] = [47, 1047, 1049]
        let entries: [(mode: Int, at: Int)] = modes.compactMap { mode in
            lastIndex(of: Array("\u{1b}[?\(mode)h".utf8), in: stream).map { (mode: mode, at: $0) }
        }
        let entered = entries.max { $0.at < $1.at }?.mode ?? 1049
        return Array("\u{1b}[?\(entered)l".utf8)
    }

    private static func lastIndex(of needle: [UInt8], in haystack: ArraySlice<UInt8>) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        // A workload runs to a megabyte, so the first byte is checked before any slice is made.
        return (haystack.startIndex...(haystack.endIndex - needle.count)).last {
            haystack[$0] == needle[0] && haystack[$0..<($0 + needle.count)].elementsEqual(needle)
        }
    }

    // MARK: - Replies

    /// The kinds of reply `replyKind` tells apart, each compared as a field of its own.
    static let replyKinds: [String] = [
        "DA1", "DA2", "XTVERSION", "DSR", "CPR", "DECRQM", "7501probe", "OSC10", "OSC11", "windowOps",
        "kittyGraphics", "focus", "other",
    ]

    /// An emulator's reply bytes as one sequence per reply, however its writes cut them: each CSI,
    /// OSC, DCS, APC, PM or SOS sequence whole, any other escape sequence as its two bytes, and a
    /// run of bytes outside any sequence as one entry.
    static func splitReplies(_ bytes: [UInt8]) -> [[UInt8]] {
        var replies: [[UInt8]] = []
        var start = 0
        while start < bytes.count {
            let end = sequenceEnd(bytes, from: start)
            replies.append(Array(bytes[start..<end]))
            start = end
        }
        return replies
    }

    /// Where the reply that starts at `start` ends: a CSI at its final byte, a string sequence at
    /// its ST (or, for an OSC, its BEL), and a run of plain bytes at the next ESC. A sequence the
    /// bytes leave unfinished runs to their end.
    private static func sequenceEnd(_ bytes: [UInt8], from start: Int) -> Int {
        guard bytes[start] == 0x1b, start + 1 < bytes.count else {
            var end = start + 1
            while end < bytes.count, bytes[end] != 0x1b { end += 1 }
            return end
        }
        let introducer = bytes[start + 1]
        var end = start + 2
        switch introducer {
        case UInt8(ascii: "["):
            while end < bytes.count, !(0x40...0x7e).contains(bytes[end]) { end += 1 }
            return min(end + 1, bytes.count)
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"):
            while end < bytes.count {
                if introducer == UInt8(ascii: "]"), bytes[end] == 0x07 { return end + 1 }
                if bytes[end] == 0x1b, end + 1 < bytes.count, bytes[end + 1] == UInt8(ascii: "\\") { return end + 2 }
                end += 1
            }
            return end
        default:
            return end
        }
    }

    /// What a reply answers, by its form: DA1 `CSI ? … c`, DA2 `CSI > … c`, XTVERSION
    /// `DCS > | … ST`, DSR `CSI … n`, CPR `CSI … R`, DECRQM `CSI … $ y`, the OSC 7501 probe, the
    /// OSC 10 and 11 colours, window ops `CSI … t`, a kitty graphics `APC G … ST`, a focus report
    /// `CSI I` or `CSI O`, and anything else.
    static func replyKind(_ reply: [UInt8]) -> String {
        guard reply.count >= 3, reply[0] == 0x1b else { return "other" }
        let body = reply.dropFirst(2)
        func starts(_ prefix: String) -> Bool { body.starts(with: prefix.utf8) }
        switch reply[1] {
        case UInt8(ascii: "["):
            let parameters = body.dropLast()
            switch reply[reply.count - 1] {
            case UInt8(ascii: "c") where parameters.first == UInt8(ascii: "?"): return "DA1"
            case UInt8(ascii: "c") where parameters.first == UInt8(ascii: ">"): return "DA2"
            case UInt8(ascii: "n") where parameters.first != UInt8(ascii: "?"): return "DSR"
            case UInt8(ascii: "R"): return "CPR"
            case UInt8(ascii: "y") where parameters.last == UInt8(ascii: "$"): return "DECRQM"
            case UInt8(ascii: "t"): return "windowOps"
            case UInt8(ascii: "I"), UInt8(ascii: "O"): return parameters.isEmpty ? "focus" : "other"
            default: return "other"
            }
        case UInt8(ascii: "]"):
            if starts("7501;") { return "7501probe" }
            if starts("10;") { return "OSC10" }
            if starts("11;") { return "OSC11" }
            return "other"
        case UInt8(ascii: "P"):
            return starts(">|") ? "XTVERSION" : "other"
        case UInt8(ascii: "_"):
            return starts("G") ? "kittyGraphics" : "other"
        default:
            return "other"
        }
    }

    /// Keeps, in each reading's `replies.order`, only the kinds both emulators sent, with a run of
    /// one kind as one entry: a kind only one of them sent already differs under its own field,
    /// and the order then compares the rest.
    static func narrowReplyOrder(_ expected: inout [String: Observed], _ actual: inout [String: Observed]) {
        func kinds(_ observed: Observed?) -> [String] {
            guard let text = observed?.string, !text.isEmpty else { return [] }
            return text.components(separatedBy: "\n")
        }
        let left = kinds(expected["replies.order"])
        let right = kinds(actual["replies.order"])
        let shared = Set(left).intersection(right)
        func narrowed(_ order: [String]) -> Observed {
            var runs: [String] = []
            for kind in order where shared.contains(kind) && runs.last != kind {
                runs.append(kind)
            }
            return .text(runs.joined(separator: "\n"))
        }
        expected["replies.order"] = narrowed(left)
        actual["replies.order"] = narrowed(right)
    }

    /// `bytes` as text, each byte that is not part of a well-formed UTF-8 character written as
    /// `\xNN`, so two different malformed runs never read the same.
    static func escaped(_ bytes: [UInt8]) -> String {
        var text = ""
        var index = 0
        while index < bytes.count {
            let length = utf8Length(lead: bytes[index])
            if length > 0, index + length <= bytes.count {
                let character = Array(bytes[index..<(index + length)])
                let decoded = String(decoding: character, as: UTF8.self)
                if decoded.utf8.elementsEqual(character) {
                    text += decoded
                    index += length
                    continue
                }
            }
            text += String(format: "\\x%02X", UInt32(bytes[index]))
            index += 1
        }
        return text
    }

    /// How many bytes a UTF-8 character with this first byte has, or 0 for a byte no character
    /// starts with.
    private static func utf8Length(lead: UInt8) -> Int {
        switch lead {
        case 0x00...0x7f: return 1
        case 0xc2...0xdf: return 2
        case 0xe0...0xef: return 3
        case 0xf0...0xf4: return 4
        default: return 0
        }
    }

    // MARK: - Reading a viewer

    /// The modes a viewer's reading names, each read with `mode(_:ansi:)`: the handover suites'
    /// list (`handoverComparedModes`) without the mouse modes, which `mouseTracking` and
    /// `mouseEncoding` read as the one in effect, and without DECTCEM, which is `cursorVisible`;
    /// and the modes the recordings set that the list leaves out, and the keyboard, autorepeat,
    /// extended reverse wrap and in-band size report modes libghostty's formatter writes.
    static let viewerModes: [(name: String, value: UInt16, ansi: Bool)] = [
        ("DECCKM", 1, false), ("DECOM", 6, false), ("DECAWM", 7, false), ("cursorBlink", 12, false),
        ("reverseWrap", 45, false), ("DECNKM", 66, false), ("DECLRMM", 69, false), ("focus1004", 1004, false),
        ("altScroll1007", 1007, false), ("bracketedPaste", 2004, false), ("syncOutput", 2026, false),
        ("graphemeClusters", 2027, false), ("colorSchemeReports", 2031, false), ("reverseVideo", 5, false),
        ("DECARM", 8, false), ("ignoreKeypadWithNumLock1035", 1035, false), ("altEscPrefix1036", 1036, false),
        ("altSendsEscape1039", 1039, false), ("reverseWrapExtended1045", 1045, false),
        ("inBandSizeReports2048", 2048, false),
        ("IRM", 4, true), ("LNM", 20, true),
    ]

    /// The state with no getter, read as the sequences libghostty's formatter adds to restore it:
    /// the pen, the hyperlink the cursor writes with, the tab stops, the character sets,
    /// modifyOtherKeys and DECSCA protection.
    static let viewerExtras: [(name: String, bits: UInt32)] = [
        ("pen", GhosttyVTFormat.style), ("link", GhosttyVTFormat.hyperlink), ("tabstops", GhosttyVTFormat.tabstops),
        ("charsets", GhosttyVTFormat.charsets), ("keyboard", GhosttyVTFormat.keyboard),
        ("protection", GhosttyVTFormat.protection),
    ]

    /// Saves the cursor with its pen and character sets, erases the screen in the default style
    /// and then the scrollback, and puts the cursor back: the screen and history are gone, so the
    /// formatter runs for the extras are short, and the state they restore is untouched. It
    /// overwrites the saved cursor, which `savedCursor` therefore reads from a viewer of its own.
    private static let blankOut: [UInt8] = Array("\u{1b}7\u{1b}[0m\u{1b}[2J\u{1b}[3J\u{1b}8".utf8)

    /// DECRC: makes the saved cursor the cursor, so a viewer's readings of the cursor read it.
    private static let restoreCursor: [UInt8] = Array("\u{1b}8".utf8)

    /// What a fresh headless libghostty viewer of the stream's size holds once fed `bytes` muted,
    /// as the app's viewer ingests a snapshot. `savedCursor` comes from a second viewer fed the
    /// same bytes and then DECRC, because the first viewer's blank-out overwrites the saved cursor.
    static func viewerReading(_ bytes: [UInt8], cols: Int, rows: Int, prefix: String) throws -> [String: Observed] {
        var fields = try withViewer(bytes, cols: cols, rows: rows) { (viewer) throws -> [String: Observed] in
            var read = try viewer.withLocked { try viewerState($0, prefix: prefix) }
            viewer.feed(blankOut[...])
            let extras = try viewer.withLocked { try extraState($0, prefix: prefix) }
            read.merge(extras) { _, extra in extra }
            return read
        }
        let saved = try withViewer(bytes + restoreCursor + blankOut, cols: cols, rows: rows) { viewer in
            try viewer.withLocked { try savedCursorState($0) }
        }
        fields[prefix + "savedCursor"] = .value(saved)
        return fields
    }

    private static func withViewer<Value>(
        _ bytes: [UInt8], cols: Int, rows: Int, _ body: (TBDGhosttyCore.GhosttyTerminal) throws -> Value
    ) throws -> Value {
        let viewer = try TBDGhosttyCore.GhosttyTerminal(
            cols: cols, rows: rows, scrollbackLines: HolderReader.scrollbackLines,
            callbacks: TBDGhosttyCore.GhosttyTerminalCallbacks())
        defer { viewer.close() }
        viewer.isMuted = true
        viewer.feed(bytes[...])
        return try body(viewer)
    }

    /// One viewer's screen and modes, read in one hold. The screen goes through libghostty's
    /// formatter, so the whole scrollback is read without a cell walk: `text` is its plain text
    /// row by row, and `styled` is its VT form, which carries the colours, the attributes and the
    /// soft wraps, joined back into the lines they wrapped from.
    private static func viewerState(
        _ state: TBDGhosttyCore.GhosttyTerminalState, prefix: String
    ) throws -> [String: Observed] {
        var fields: [String: Observed] = [:]
        guard let text = state.formatted(.plain, trim: true, unwrap: false) else {
            throw Failure(description: "libghostty's plain-text formatter failed on a viewer")
        }
        fields[prefix + "text"] = .text(text)
        let styled = try state.formattedVT(extras: 0, unwrap: true, trim: true)
        fields[prefix + "styled"] = .text(String(decoding: spacingOutCursorForward(styled), as: UTF8.self))
        let cursor = state.cursor
        fields[prefix + "cursor"] = .value("column \(cursor.col), row \(cursor.row)")
        fields[prefix + "pendingWrap"] = .value("\(state.cursorPendingWrap)")
        fields[prefix + "cursorVisible"] = .value("\(state.isCursorVisible)")
        fields[prefix + "cursorStyle"] = .value(try cursorShape(state))
        fields[prefix + "alternateScreen"] = .value("\(state.isAlternateScreen)")
        for mode in viewerModes {
            fields[prefix + "mode." + mode.name] = .value("\(state.mode(mode.value, ansi: mode.ansi))")
        }
        guard let tracking = state.mouseTrackingInEffect, let encoding = state.mouseEncodingInEffect else {
            throw Failure(description: "libghostty could not say which mouse tracking mode and encoding a viewer is in")
        }
        fields[prefix + "mouseTracking"] = .value("\(tracking)")
        fields[prefix + "mouseEncoding"] = .value("\(encoding)")
        fields[prefix + "region"] = .value(try region(state))
        fields[prefix + "kittyFlags"] = .value("\(state.kittyKeyboardFlags)")
        return fields
    }

    /// Each extra as the bytes it adds to the formatter's output of the blanked-out viewer.
    private static func extraState(
        _ state: TBDGhosttyCore.GhosttyTerminalState, prefix: String
    ) throws -> [String: Observed] {
        let base = try state.formattedVT(extras: 0, unwrap: false, trim: true)
        var fields: [String: Observed] = [:]
        for extra in viewerExtras {
            let output = try state.formattedVT(extras: extra.bits, unwrap: false, trim: true)
            let restores = added(output, to: base)
            fields[prefix + extra.name] = .value(escaped(extra.name == "charsets" ? withoutASCIIDesignations(restores) : restores))
        }
        return fields
    }

    /// What DECRC restores, read from a viewer that restored it and then blanked out: where the
    /// cursor goes, whether a wrap is pending, origin mode, and the pen, character sets and
    /// protection, each as the formatter writes it. On the primary screen this is the primary
    /// screen's saved cursor; a reading on an alternate screen has its `viewer.leave.` twin for that.
    private static func savedCursorState(_ state: TBDGhosttyCore.GhosttyTerminalState) throws -> String {
        let base = try state.formattedVT(extras: 0, unwrap: false, trim: true)
        func extra(_ bits: UInt32) throws -> [UInt8] {
            let output = try state.formattedVT(extras: bits, unwrap: false, trim: true)
            return added(output, to: base)
        }
        let pen = try escaped(extra(GhosttyVTFormat.style))
        let charsets = try escaped(withoutASCIIDesignations(extra(GhosttyVTFormat.charsets)))
        let protection = try escaped(extra(GhosttyVTFormat.protection))
        let cursor = state.cursor
        return "column \(cursor.col), row \(cursor.row), pendingWrap \(state.cursorPendingWrap), "
            + "origin \(state.mode(6)), pen \(pen), charsets \(charsets), protection \(protection)"
    }

    /// `charsets` with every designation of ASCII removed: `ESC ( B`, `ESC ) B`, `ESC * B` and
    /// `ESC + B`. libghostty's default for G0 to G3 is its UTF-8 set, and its formatter writes
    /// every slot that holds anything else, ASCII included. libghostty's snapshot opens with
    /// `ESC ( B` (`GhosttySnapshotWriter.resetPrelude`, "G0 is ASCII and in use"), so a viewer of
    /// it holds ASCII in G0 where a viewer of SwiftTerm's, whose prelude designates nothing, holds
    /// UTF-8. The two print alike: libghostty prints a character as it is under either set (its
    /// `printCell` maps only British and DEC special graphics), so an ASCII designation reads as
    /// no designation, on both sides.
    static func withoutASCIIDesignations(_ charsets: [UInt8]) -> [UInt8] {
        let slotDesignators: [UInt8] = [UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+")]
        var out: [UInt8] = []
        var index = 0
        while index < charsets.count {
            if index + 2 < charsets.count, charsets[index] == 0x1b,
                slotDesignators.contains(charsets[index + 1]),
                charsets[index + 2] == UInt8(ascii: "B")
            {
                index += 3
                continue
            }
            out.append(charsets[index])
            index += 1
        }
        return out
    }

    /// `styled` with each cursor-forward `ESC [ n C` written while the output's pen is the
    /// default replaced by n spaces. libghostty's VT formatter steps over a run of cells that hold
    /// no character and no style with CUF, and writes a space a program printed as a space, so a
    /// viewer of libghostty's snapshot, which leaves such cells unwritten, prints `ESC[2C` where a
    /// viewer of SwiftTerm's, which writes spaces there, prints two spaces. Both read as the same
    /// blank cells in the default style, and `viewer.text` compares the characters anyway. Only a
    /// CUF under the default pen is expanded, so one written while a colour or attribute is in
    /// effect still differs from spaces painted with it.
    static func spacingOutCursorForward(_ styled: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(styled.count)
        var penIsDefault = true
        var index = 0
        while index < styled.count {
            guard styled[index] == 0x1b, index + 1 < styled.count, styled[index + 1] == UInt8(ascii: "[") else {
                out.append(styled[index])
                index += 1
                continue
            }
            var end = index + 2
            while end < styled.count, !(0x40...0x7e).contains(styled[end]) { end += 1 }
            guard end < styled.count else {
                out.append(contentsOf: styled[index...])
                break
            }
            let parameters = styled[(index + 2)..<end]
            let digitsOnly = parameters.allSatisfy { (0x30...0x39).contains($0) }
            switch styled[end] {
            case UInt8(ascii: "m"):
                // `ESC[m` and `ESC[0m` reset the pen; any other SGR sets something.
                penIsDefault = parameters.allSatisfy { $0 == UInt8(ascii: "0") }
                out.append(contentsOf: styled[index...end])
            case UInt8(ascii: "C") where penIsDefault && digitsOnly:
                let count = parameters.isEmpty ? 1 : Int(String(decoding: parameters, as: UTF8.self)) ?? 1
                out.append(contentsOf: repeatElement(UInt8(ascii: " "), count: max(count, 1)))
            default:
                out.append(contentsOf: styled[index...end])
            }
            index = end + 1
        }
        return out
    }

    /// The bytes `output` has that `base` does not: what lies between their common prefix and
    /// their common suffix.
    static func added(_ output: [UInt8], to base: [UInt8]) -> [UInt8] {
        var start = 0
        while start < output.count, start < base.count, output[start] == base[start] { start += 1 }
        var end = output.count, baseEnd = base.count
        while end > start, baseEnd > start, output[end - 1] == base[baseEnd - 1] {
            end -= 1
            baseEnd -= 1
        }
        return Array(output[start..<end])
    }

    /// The scrolling region, and the left and right margins while DECLRMM is on. The region has
    /// no getter, so it is read back from the end of a formatter run that asks for that one
    /// extra: `CSI t;b r` when it is not full height, then `CSI l;r s` when margins are set. The
    /// handover suites' reader (`HandoverModel.swift`), parsing strictly from the end because
    /// printed text can end in "r" or "s" too.
    private static func region(_ state: TBDGhosttyCore.GhosttyTerminalState) throws -> String {
        var out = try state.formattedVT(extras: GhosttyVTFormat.scrollingRegion, unwrap: false, trim: true)[...]
        var top = 0, bottom = state.rows - 1, left = 0, right = state.cols - 1
        func takeTail(_ final: UInt8) -> (Int, Int)? {
            guard out.last == final else { return nil }
            var index = out.endIndex - 2
            var fields: [Int] = [], value = 0, place = 1, digits = 0
            while index >= out.startIndex {
                let byte = out[index]
                if byte >= 0x30, byte <= 0x39 {
                    value += Int(byte - 0x30) * place
                    place *= 10
                    digits += 1
                } else if byte == 0x3b, digits > 0 {
                    fields.insert(value, at: 0)
                    value = 0
                    place = 1
                    digits = 0
                } else {
                    break
                }
                index -= 1
            }
            guard digits > 0, index >= out.startIndex + 1, out[index] == 0x5b, out[index - 1] == 0x1b else { return nil }
            fields.insert(value, at: 0)
            guard fields.count == 2 else { return nil }
            out = out[out.startIndex..<(index - 1)]
            return (fields[0] - 1, fields[1] - 1)
        }
        if let margins = takeTail(0x73) { (left, right) = margins }
        if let rows = takeTail(0x72) { (top, bottom) = rows }
        let margins = state.mode(69) ? ", columns \(left + 1) to \(right + 1)" : ""
        return "rows \(top + 1) to \(bottom + 1)\(margins)"
    }

    // MARK: - Comparing

    /// Every field the two readings disagree on, a field one of them lacks included, with the
    /// first difference in it.
    static func differences(_ expected: [String: Observed], _ actual: [String: Observed]) -> [String: String] {
        var differences: [String: String] = [:]
        for field in Set(expected.keys).union(actual.keys) where expected[field] != actual[field] {
            switch (expected[field], actual[field]) {
            case (.text(let left)?, .text(let right)?):
                differences[field] = firstDifference(left, right)
            case (let left, let right):
                differences[field] = "SwiftTerm \(describe(left)), libghostty \(describe(right))"
            }
        }
        return differences
    }

    private static func describe(_ observed: Observed?) -> String {
        switch observed {
        case .value(let value)?, .text(let value)?: return window(Array(value.unicodeScalars), from: 0)
        case nil: return "<not read>"
        }
    }

    /// The first line two texts disagree on, from a little before the first scalar that differs.
    static func firstDifference(_ expected: String, _ actual: String) -> String {
        let left = lines(expected), right = lines(actual)
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : nil
            let rhs = index < right.count ? right[index] : nil
            if let lhs, let rhs, lhs.utf8.elementsEqual(rhs.utf8) { continue }
            let place = "line \(index + 1) of \(left.count) vs \(right.count)"
            guard let lhs, let rhs else {
                let shown = { (line: String?) in line.map { window(Array($0.unicodeScalars), from: 0) } ?? "<no line>" }
                return "\(place): SwiftTerm \(shown(lhs)), libghostty \(shown(rhs))"
            }
            let lhsScalars = Array(lhs.unicodeScalars), rhsScalars = Array(rhs.unicodeScalars)
            var common = 0
            while common < min(lhsScalars.count, rhsScalars.count), lhsScalars[common] == rhsScalars[common] {
                common += 1
            }
            let start = max(0, common - 24)
            return "\(place), from scalar \(common): SwiftTerm \(window(lhsScalars, from: start)), "
                + "libghostty \(window(rhsScalars, from: start))"
        }
        return "texts that differ only in how their lines end"
    }

    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// Up to 120 scalars from `start`, quoted with escapes, so a control character shows.
    private static func window(_ scalars: [Unicode.Scalar], from start: Int) -> String {
        let end = min(scalars.count, start + 120)
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[min(start, end)..<end])
        return (start > 0 ? "…" : "") + String(view).debugDescription + (end < scalars.count ? "…" : "")
    }

    // MARK: - The recordings

    /// The recorded streams in `Fixtures/EmulatorParity`, with `manifest.json` describing each:
    /// the size it was recorded at, and its length and SHA-256, which
    /// `EmulatorParityRecordingPinTests` holds the files to. Written by
    /// `scripts/record-emulator-parity-corpus.py`.
    enum Recordings {
        static let names: [String] = ["claude-stub", "vim", "less", "colour-log"]

        struct Entry: Decodable, Sendable {
            let name: String
            let file: String
            let cols: Int
            let rows: Int
            let bytes: Int
            let sha256: String
        }

        private struct Manifest: Decodable {
            let recordings: [Entry]
        }

        static let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EmulatorParity")

        static func entries() throws -> [Entry] {
            let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            return try JSONDecoder().decode(Manifest.self, from: data).recordings
        }

        static func entry(named name: String) throws -> Entry {
            guard let entry = try entries().first(where: { $0.name == name }) else {
                throw Failure(description: "manifest.json lists no recording named \(name)")
            }
            return entry
        }

        static func bytes(of entry: Entry) throws -> [UInt8] {
            [UInt8](try Data(contentsOf: directory.appendingPathComponent(entry.file)))
        }
    }

    // MARK: - The thread

    /// Runs `body` on a thread the tests own, not on the cooperative pool, as the engine's
    /// handover suites do (`onHandoverThread`): a body feeds a megabyte and walks thousands of
    /// rows without suspending, and on CI's three-thread pool that would hold up every suite
    /// waiting on it (`Tests/CLAUDE.md`, "A stall is a spell of 1–20 s"). The thread is checked by
    /// name first, so a preference that stopped reaching the body fails instead of quietly putting
    /// the work back on the pool. Suites that use it are `.serialized`, because `GateExecutor`
    /// starts a thread for every job.
    static func onOwnThread(_ body: () throws -> Void) async throws {
        try await withTaskExecutorPreference(GateExecutor.shared) {
            #expect(threadName() == GateExecutor.threadName)
            try body()
        }
    }

    /// Synchronous on purpose: `Thread.current` is unavailable from an async context.
    private static func threadName() -> String? {
        Thread.current.name
    }
}
