import Foundation
import SwiftTerm
import Testing

/// The screen a headless emulator paints must not depend on where the reader's
/// `read()` boundaries happened to fall.
///
/// `HolderReader` drains a pty in chunks of up to 64 KB and feeds each chunk to
/// one long-lived `Terminal`. Nothing about a pty guarantees where those chunks
/// split: the same output can arrive as one 8 KB read or as two hundred small
/// ones, and the split points move from redraw to redraw. So the emulator owes
/// the caller a property — **the painted screen is a function of the byte
/// stream, not of its chunking** — and every escape sequence, every multi-byte
/// UTF-8 character, and every column-boundary wrap has to survive being cut in
/// half.
///
/// This suite exists because a holder-backed session was observed rendering
/// single characters missing from otherwise intact words ("brown" as "brow "),
/// stable across repeated reads of one static screen but moving to different
/// lines after a redraw — the signature of a chunk-boundary artefact rather
/// than of anything the program actually drew.
///
/// Rendering walks the buffer one row at a time, the way
/// `HolderReader.renderScreen` does, so a difference here is a difference a
/// user would have seen. What the subject is, though, is the *cells* — whether
/// a byte landed in the grid at all — which is why the walk here stays the
/// plain one and does not need to track the projection production applies on
/// top of it.
@Suite struct EmulatorFeedChunkingTests {

    private static let columns = 100
    private static let rows = 24

    // MARK: - The property

    /// One chunk versus two, at the cuts that can plausibly matter.
    ///
    /// Not every offset: cutting between two ordinary printable bytes exercises
    /// the same code as cutting between the two before them, and paying for
    /// tens of thousands of full renders to learn that costs half a minute per
    /// run. What is *not* sampled is anything with internal structure — every
    /// offset inside an escape sequence and inside a multi-byte UTF-8
    /// character is tried, because those are the cuts that leave the parser
    /// holding half a token. The plain runs between them get a coarse stride
    /// so a regression in the boring path still has somewhere to show up.
    @Test func aSingleSplitAnywhereInTheStreamPaintsTheSameScreen() {
        let stream = Self.claudeShapedStream()
        let reference = Self.render(chunks: [stream[...]])

        let offsets = Self.interestingSplitOffsets(in: stream)
        // Guards the sampler itself: a bug that returned only the stride would
        // silently drop the cases this test exists for.
        #expect(offsets.count > stream.count / 7 + 100)

        var firstFailure: (index: Int, screen: String)?
        for k in offsets {
            let painted = Self.render(chunks: [stream[..<k], stream[k...]])
            if painted != reference {
                firstFailure = (k, painted)
                break
            }
        }

        if let failure = firstFailure {
            Issue.record(
                """
                Splitting the stream at byte \(failure.index) changed the screen.
                Context: \(Self.describe(stream, around: failure.index))
                \(Self.diff(reference: reference, actual: failure.screen))
                """)
        }
        #expect(firstFailure == nil)
    }

    /// The same stream cut into uniform runs, which is what a slow writer or a
    /// contended pty actually produces. Every stride, including 1, must land on
    /// the same screen as one whole feed.
    @Test(arguments: [1, 2, 3, 7, 13, 64, 511, 1024])
    func aStreamFedInFixedSizeRunsPaintsTheSameScreen(stride: Int) {
        let stream = Self.claudeShapedStream()
        let reference = Self.render(chunks: [stream[...]])

        var chunks: [ArraySlice<UInt8>] = []
        var start = 0
        while start < stream.count {
            let end = min(start + stride, stream.count)
            chunks.append(stream[start..<end])
            start = end
        }

        let painted = Self.render(chunks: chunks)
        #expect(
            painted == reference,
            """
            Feeding in runs of \(stride) changed the screen.
            \(Self.diff(reference: reference, actual: painted))
            """)
    }

    /// Redrawing the identical stream over an emulator that already painted it
    /// must be a no-op. A TUI repaints constantly; if the second pass differs
    /// the holes would appear to move on their own.
    @Test func feedingTheSameStreamTwicePaintsTheSameScreen() {
        let stream = Self.claudeShapedStream()
        let once = Self.render(chunks: [stream[...]])
        let twice = Self.render(chunks: [stream[...], stream[...]])
        #expect(
            once == twice,
            "A redraw of the identical stream changed the screen.\n\(Self.diff(reference: once, actual: twice))")
    }

    /// Wide glyphs straddling the right margin, and combining marks that extend
    /// the glyph before them. Both are the cases where a cut between two bytes
    /// of one *character* — not one sequence — decides how many cells get used.
    ///
    /// Sampled the same way, and nothing is given up by it: every offset inside
    /// every multi-byte character here is one of the offsets the sampler keeps.
    @Test func wideAndCombiningCharactersSurviveEverySplit() {
        let stream = Self.wideCharacterStream()
        let reference = Self.render(chunks: [stream[...]])

        var firstFailure: (index: Int, screen: String)?
        for k in Self.interestingSplitOffsets(in: stream) {
            let painted = Self.render(chunks: [stream[..<k], stream[k...]])
            if painted != reference {
                firstFailure = (k, painted)
                break
            }
        }

        if let failure = firstFailure {
            Issue.record(
                """
                Splitting the wide/combining stream at byte \(failure.index) changed the screen.
                Context: \(Self.describe(stream, around: failure.index))
                \(Self.diff(reference: reference, actual: failure.screen))
                """)
        }
        #expect(firstFailure == nil)
    }

    /// A chunk larger than the drain thread's 64 KB read buffer, to rule out a
    /// cap or a truncation inside a single feed. Fed whole, it must match the
    /// same bytes fed in 64 KB pieces — which is what the reader would deliver.
    @Test func aChunkLargerThanTheDrainBufferIsNotTruncated() {
        var stream: [UInt8] = []
        var copies = 0
        while stream.count < 200_000 {
            stream.append(contentsOf: Self.claudeShapedStream())
            copies += 1
        }
        #expect(copies > 1)

        let whole = Self.render(chunks: [stream[...]])

        var chunks: [ArraySlice<UInt8>] = []
        var start = 0
        while start < stream.count {
            let end = min(start + 65_536, stream.count)
            chunks.append(stream[start..<end])
            start = end
        }
        let inReads = Self.render(chunks: chunks)

        #expect(
            whole == inReads,
            "A >64 KB stream painted differently whole than in 64 KB reads.\n\(Self.diff(reference: whole, actual: inReads))")
    }

    /// The screen is not merely chunk-independent, it is *right*.
    ///
    /// A determinism check compares two runs of the same code and passes when
    /// both are wrong in the same way. This one compares the painted cells
    /// against what the bytes say they should be: an SGR change between every
    /// pair of letters, started at every column offset so that the style switch
    /// lands on the right margin, on the cell before it, and on the cell after
    /// it. Nothing here may swallow a letter.
    ///
    /// Padding is `.` rather than a space so that `trimRight: true` cannot hide
    /// a hole at the end of a row.
    @Test(arguments: [false, true])
    func styleChangesBetweenLettersNeverSwallowOne(byteAtATime: Bool) {
        let letters = "abcdefghij"
        for offset in 0..<(Self.columns + 4) {
            var out = "\(Self.esc)[2J\(Self.esc)[H"
            out += String(repeating: ".", count: offset)
            for (index, letter) in letters.enumerated() {
                out += "\(Self.esc)[3\(index % 8)m\(letter)"
            }
            out += "\(Self.esc)[0m"
            let bytes = Array(out.utf8)

            let chunks: [ArraySlice<UInt8>]
            if byteAtATime {
                chunks = (0..<bytes.count).map { bytes[$0..<($0 + 1)] }
            } else {
                chunks = [bytes[...]]
            }
            let painted = Self.render(chunks: chunks).components(separatedBy: "\n").joined()
            let expected = String(repeating: ".", count: offset) + letters
            #expect(
                painted == expected,
                "offset \(offset), byteAtATime=\(byteAtATime): painted \(painted.debugDescription)")
        }
    }

    /// The same, with a non-ASCII glyph in the middle of the run. It takes the
    /// print path off its ASCII fast path for everything that follows, which is
    /// the other side of the branch the previous test covers.
    @Test(arguments: [false, true])
    func aNonASCIIGlyphMidRunNeverSwallowsANeighbour(byteAtATime: Bool) {
        for offset in 0..<(Self.columns + 4) {
            var out = "\(Self.esc)[2J\(Self.esc)[H"
            out += String(repeating: ".", count: offset)
            out += "abcd\(Self.esc)[1m✻\(Self.esc)[0mefgh"
            let bytes = Array(out.utf8)

            let chunks: [ArraySlice<UInt8>]
            if byteAtATime {
                chunks = (0..<bytes.count).map { bytes[$0..<($0 + 1)] }
            } else {
                chunks = [bytes[...]]
            }
            let painted = Self.render(chunks: chunks).components(separatedBy: "\n").joined()
            let expected = String(repeating: ".", count: offset) + "abcd✻efgh"
            #expect(
                painted == expected,
                "offset \(offset), byteAtATime=\(byteAtATime): painted \(painted.debugDescription)")
        }
    }

    // MARK: - Rendering, the way the daemon does it

    private static func render(chunks: [ArraySlice<UInt8>]) -> String {
        let delegate = SilentDelegate()
        let terminal = SwiftTerm.Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: columns, rows: rows, scrollback: 500))
        for chunk in chunks {
            terminal.terminalLock.withLock { terminal.feed(buffer: chunk) }
        }
        return terminal.terminalLock.withLock {
            var lines: [String] = []
            lines.reserveCapacity(terminal.rows)
            for row in 0..<terminal.rows {
                lines.append(terminal.getLine(row: row)?.translateToString(trimRight: true) ?? "")
            }
            while let last = lines.last, last.isEmpty { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - The stream

    private static let esc = "\u{1b}"

    /// Output shaped like a Claude Code frame: truecolour SGR runs inside
    /// words, lines longer than the terminal is wide so they autowrap, box
    /// drawing and wide glyphs, synchronized-output and bracketed-paste mode
    /// toggles, absolute cursor positioning, erase-to-end-of-line, and an
    /// Ink-style "walk back up N rows and rewrite" pass.
    private static func claudeShapedStream() -> [UInt8] {
        var out = ""
        out += "\(esc)[?2004h"
        out += "\(esc)[?2026h"
        out += "\(esc)[2J\(esc)[H"

        for i in 0..<12 {
            let number = String(format: "%03d", i)
            out += "\(esc)[38;2;\(20 + i * 5);\(200 - i * 3);\(120 + i)m"
            out += "line \(number): the quick "
            out += "\(esc)[1mbrown\(esc)[0m"
            out += " fox jumps over the lazy dog and keeps going to pad this out"
            out += "\(esc)[38;2;90;120;200m │ ─── ⏵ ✻ tail\(esc)[39m"
            out += "\r\n"
        }
        out += "\(esc)[?2026l"

        // An absolute repositioning pass that rewrites in place with ESC[K,
        // the way a status region repaints.
        for row in 5...12 {
            out += "\(esc)[\(row);1H\(esc)[K"
            out += "\(esc)[2m╭─ status \(row) ─────────────────────────────╮\(esc)[22m"
        }

        // Ink's diff renderer: walk up N rows, carriage return, erase the whole
        // line, rewrite it.
        out += "\(esc)[10A"
        for step in 0..<10 {
            out += "\r\(esc)[2K"
            out += "\(esc)[1m✻\(esc)[0m redrawn row \(step) — this text is deliberately long enough that it wraps past the hundredth column of the grid"
            out += "\(esc)[1B"
        }
        out += "\r\n"

        out += "\(esc)[?2004l"
        out += "\(esc)[38;2;255;170;0m⏵⏵ done\(esc)[39m\r\n"
        return Array(out.utf8)
    }

    /// A grid whose right margin is crossed by a two-cell glyph at every
    /// starting column, plus base letters carrying combining marks.
    private static func wideCharacterStream() -> [UInt8] {
        var out = "\(esc)[2J\(esc)[H"
        for offset in 0..<12 {
            out += String(repeating: "a", count: columns - 1 - offset)
            out += "漢字テスト"
            out += "e\u{301}o\u{308}n\u{303}"
            out += "\r\n"
        }
        return Array(out.utf8)
    }

    // MARK: - Choosing where to cut

    /// The cuts worth paying for: every offset with structure on either side of
    /// it, plus a coarse stride over everything else.
    ///
    /// "Structure" is an escape sequence or a multi-byte UTF-8 character —
    /// anything the parser holds partial state across. Every offset inside one,
    /// and the offset immediately after it, is included; a cut between two
    /// plain printable bytes exercises the same branch as its neighbours, so
    /// those are sampled rather than enumerated.
    private static func interestingSplitOffsets(in stream: [UInt8]) -> [Int] {
        guard stream.count > 1 else { return [] }
        var interesting = [Bool](repeating: false, count: stream.count)

        // The coarse pass, so the boring runs still have somewhere to fail.
        for offset in Swift.stride(from: 1, to: stream.count, by: 7) {
            interesting[offset] = true
        }

        // Every cut inside an escape sequence, and the one just after it.
        var index = 0
        while index < stream.count {
            guard stream[index] == 0x1b else {
                index += 1
                continue
            }
            var end = index + 1
            if end < stream.count, stream[end] == UInt8(ascii: "[") || stream[end] == UInt8(ascii: "]") {
                let isOperatingSystemCommand = stream[end] == UInt8(ascii: "]")
                end += 1
                while end < stream.count {
                    let byte = stream[end]
                    if isOperatingSystemCommand {
                        if byte == 0x07 || byte == 0x1b { break }
                    } else if (0x40...0x7e).contains(byte) {
                        break
                    }
                    end += 1
                }
            }
            let last = min(end + 1, stream.count - 1)
            if index + 1 <= last {
                for offset in (index + 1)...last { interesting[offset] = true }
            }
            index = end + 1
        }

        // Every cut inside a multi-byte character, and the one just after it.
        for offset in 1..<stream.count
        where stream[offset] & 0xc0 == 0x80 || stream[offset - 1] & 0x80 != 0 {
            interesting[offset] = true
        }

        return (1..<stream.count).filter { interesting[$0] }
    }

    // MARK: - Reporting

    /// What the bytes on either side of a cut are, so a failure names the
    /// sequence it landed inside rather than only an offset.
    private static func describe(_ stream: [UInt8], around index: Int) -> String {
        let lower = max(0, index - 12)
        let upper = min(stream.count, index + 12)
        func show(_ slice: ArraySlice<UInt8>) -> String {
            slice.map { byte in
                switch byte {
                case 0x1b: return "<ESC>"
                case 0x0d: return "<CR>"
                case 0x0a: return "<LF>"
                case 0x20...0x7e: return String(UnicodeScalar(byte))
                default: return String(format: "<%02x>", byte)
                }
            }.joined()
        }
        return "…\(show(stream[lower..<index]))‖\(show(stream[index..<upper]))…"
    }

    private static func diff(reference: String, actual: String) -> String {
        let left = reference.components(separatedBy: "\n")
        let right = actual.components(separatedBy: "\n")
        var report: [String] = []
        for row in 0..<max(left.count, right.count) {
            let a = row < left.count ? left[row] : "<absent>"
            let b = row < right.count ? right[row] : "<absent>"
            if a != b {
                report.append("row \(row) expected: \(a.debugDescription)")
                report.append("row \(row)   actual: \(b.debugDescription)")
            }
        }
        if report.isEmpty { return "(rows identical; the strings differ elsewhere)" }
        return report.prefix(8).joined(separator: "\n")
    }
}

private final class SilentDelegate: TerminalDelegate {
    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {}
}
