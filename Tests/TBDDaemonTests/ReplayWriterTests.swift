import Foundation
import Testing

@testable import TBDDaemonLib

/// Byte-level assertions for the replay assembler (M4.2). The companion
/// SwiftTerm round-trip suite lives in Tests/TBDAppTests (it needs the
/// SwiftTerm product, which only the app test target links).
@Suite("ReplayWriter byte assembly")
struct ReplayWriterTests {
    private let esc = "\u{1b}"
    private let cols = 80
    private let rows = 25

    private func makeState(
        cursorX: Int = 0, cursorY: Int = 0,
        alternateOn: Bool = false,
        alternateSavedX: Int? = nil, alternateSavedY: Int? = nil,
        scrollRegionUpper: Int = 0, scrollRegionLower: Int = 24,
        cursorVisible: Bool = true, insertMode: Bool = false,
        applicationCursorKeys: Bool = false, applicationKeypad: Bool = false,
        wraparound: Bool = true,
        mouseStandard: Bool = false, mouseButton: Bool = false,
        mouseAny: Bool = false, mouseSGR: Bool = false,
        originMode: Bool = false
    ) -> PaneState {
        PaneState(
            paneID: "%1", cursorX: cursorX, cursorY: cursorY,
            alternateOn: alternateOn,
            alternateSavedX: alternateSavedX, alternateSavedY: alternateSavedY,
            scrollRegionUpper: scrollRegionUpper, scrollRegionLower: scrollRegionLower,
            cursorVisible: cursorVisible, insertMode: insertMode,
            applicationCursorKeys: applicationCursorKeys, applicationKeypad: applicationKeypad,
            wraparound: wraparound,
            mouseStandard: mouseStandard, mouseButton: mouseButton,
            mouseAny: mouseAny, mouseSGR: mouseSGR,
            originMode: originMode, paneInMode: 0,
            width: cols, height: rows, historySize: 0)
    }

    private func assembleText(
        history: [String] = [], altScreen: [String]? = nil, pending: [String] = [],
        state: PaneState
    ) throws -> String {
        let data = try ReplayWriter.assemble(
            history: history, altScreen: altScreen, pending: pending,
            state: state, cols: cols, rows: rows)
        return String(decoding: data, as: UTF8.self)
    }

    /// Index of `needle`'s first occurrence — failing the test if absent.
    private func index(of needle: String, in text: String,
                       sourceLocation: SourceLocation = #_sourceLocation) throws -> String.Index {
        try #require(text.range(of: needle), "missing \(needle.debugDescription)",
                     sourceLocation: sourceLocation).lowerBound
    }

    // MARK: prelude

    @Test("replay starts with the reset prelude, which supersedes stale state")
    func preludeFirst() throws {
        let text = try assembleText(history: ["hello"], state: makeState())
        #expect(text.hasPrefix(ReplayWriter.resetPrelude))

        // Load-bearing prelude contents and internal ordering.
        let prelude = ReplayWriter.resetPrelude
        for piece in ["\(esc)[?1049l", "\(esc)[r", "\(esc)[?1l", "\(esc)>", "\(esc)[?7h",
                      "\(esc)[?6l", "\(esc)[4l", "\(esc)[?1000l", "\(esc)[?1002l",
                      "\(esc)[?1003l", "\(esc)[?1006l", "\(esc)[?2004l", "\(esc)[?25h",
                      "\(esc)[0m", "\(esc)[2J", "\(esc)[3J"] {
            #expect(prelude.contains(piece), "prelude missing \(piece.debugDescription)")
        }
        // Alt exit first; SGR reset before ED (erase paints current attrs);
        // clear-screen + clear-scrollback + home are the final prelude bytes.
        #expect(try index(of: "\(esc)[?1049l", in: prelude) == prelude.startIndex)
        #expect(try index(of: "\(esc)[0m", in: prelude) < index(of: "\(esc)[2J", in: prelude))
        #expect(prelude.hasSuffix("\(esc)[2J\(esc)[3J\(esc)[H"))
    }

    // MARK: ordering invariants

    @Test("primary-screen order: prelude → history → modes → region → pending → cursor (last)")
    func primaryOrdering() throws {
        let state = makeState(cursorX: 7, cursorY: 5, scrollRegionUpper: 2, scrollRegionLower: 20,
                              applicationCursorKeys: true)
        let text = try assembleText(history: ["AAA", "BBB"], pending: ["PEND"], state: state)

        let history = try index(of: "AAA\r\nBBB", in: text)
        let modes = try index(of: "\(esc)[?1h", in: text)
        let region = try index(of: "\(esc)[3;21r", in: text)
        let pending = try index(of: "PEND", in: text)
        let cursor = try index(of: "\(esc)[6;8H", in: text)

        #expect(history < modes)
        #expect(modes < region)
        #expect(region < pending)
        #expect(pending < cursor)
        #expect(text.hasSuffix("\(esc)[6;8H"), "cursor must be the LAST bytes of the replay")
    }

    @Test("history lines join with CRLF and no trailing newline")
    func historyJoining() throws {
        let text = try assembleText(history: ["one", "two", "three"], state: makeState())
        #expect(text.contains("one\r\ntwo\r\nthree\(esc)"), "no trailing CRLF after the last history line")
    }

    // MARK: alt screen

    @Test("no 1049h anywhere when the pane is not on the alt screen")
    func noAltEntryOnPrimary() throws {
        let text = try assembleText(history: ["x"], state: makeState())
        #expect(!text.contains("\(esc)[?1049h"))
    }

    @Test("alt order: saved primary cursor → 1049h → home → content → region → cursor")
    func altOrdering() throws {
        let state = makeState(cursorX: 2, cursorY: 1, alternateOn: true,
                              alternateSavedX: 3, alternateSavedY: 4,
                              scrollRegionUpper: 1, scrollRegionLower: 22)
        let text = try assembleText(history: ["hist"], altScreen: ["ALT1", "ALT2"], state: state)

        let saved = try index(of: "\(esc)[5;4H", in: text)  // 0-based (3,4) → 1-based 5;4
        let enter = try index(of: "\(esc)[?1049h", in: text)
        let home = try index(of: "\(esc)[?1049h\(esc)[H", in: text)
        let content = try index(of: "ALT1\r\nALT2", in: text)
        let region = try index(of: "\(esc)[2;23r", in: text)
        let cursor = try index(of: "\(esc)[2;3H", in: text)

        #expect(saved < enter, "primary cursor must be positioned BEFORE 1049h so 1049l restores it")
        #expect(home == enter, "1049h must be followed immediately by a home escape")
        #expect(enter < content)
        #expect(content < region, "region belongs to the alt screen and must not scroll the content feed")
        #expect(region < cursor)
        #expect(text.hasSuffix("\(esc)[2;3H"))
    }

    @Test("no saved-cursor CUP when tmux reported the no-saved-cursor sentinel")
    func altWithoutSavedCursor() throws {
        let state = makeState(alternateOn: true)
        let text = try assembleText(altScreen: ["A"], state: state)
        // Mode escapes end with the last flag escape; the next escape must be 1049h itself.
        #expect(text.contains("\(esc)[?6l\(esc)[?1049h"))
    }

    // MARK: scroll region

    @Test("full-screen region emits no DECSTBM beyond the prelude reset")
    func fullScreenRegionOmitted() throws {
        let text = try assembleText(history: ["x"], state: makeState())
        let stbm = try #require(try? NSRegularExpression(pattern: "\u{1b}\\[[0-9]+;[0-9]+r"))
        let matches = stbm.numberOfMatches(
            in: text, range: NSRange(text.startIndex..., in: text))
        #expect(matches == 0)
    }

    @Test("insane region bounds (raced resize) are skipped, not emitted")
    func insaneRegionSkipped() throws {
        let state = makeState(scrollRegionUpper: 5, scrollRegionLower: 40)  // lower ≥ rows
        let text = try assembleText(state: state)
        #expect(!text.contains("\(esc)[6;41r"))
    }

    // MARK: mode synthesis

    @Test("mode escapes mirror every captured flag; mouse set-only ascending; never 2004")
    func modeSynthesis() throws {
        let allOn = makeState(cursorVisible: false, insertMode: true,
                              applicationCursorKeys: true, applicationKeypad: true,
                              wraparound: false,
                              mouseStandard: true, mouseButton: true,
                              mouseAny: true, mouseSGR: true, originMode: true)
        let text = try assembleText(state: allOn)
        // The mode section (after the prelude, which ends in ...[H).
        let modeSection = String(text.dropFirst(ReplayWriter.resetPrelude.count))
        for piece in ["\(esc)[?25l", "\(esc)[4h", "\(esc)[?1h", "\(esc)=", "\(esc)[?7l",
                      "\(esc)[?6h", "\(esc)[?1000h", "\(esc)[?1002h", "\(esc)[?1003h",
                      "\(esc)[?1006h"] {
            #expect(modeSection.contains(piece), "missing \(piece.debugDescription)")
        }
        #expect(try index(of: "\(esc)[?1000h", in: modeSection)
                < index(of: "\(esc)[?1002h", in: modeSection))
        #expect(try index(of: "\(esc)[?1002h", in: modeSection)
                < index(of: "\(esc)[?1003h", in: modeSection))
        // Bracketed paste is never synthesized — tmux is the paste authority.
        #expect(!text.contains("\(esc)[?2004h"))

        let allOff = makeState()
        let offText = try assembleText(state: allOff)
        let offSection = String(offText.dropFirst(ReplayWriter.resetPrelude.count))
        for piece in ["\(esc)[?25h", "\(esc)[4l", "\(esc)[?1l", "\(esc)>", "\(esc)[?7h",
                      "\(esc)[?6l"] {
            #expect(offSection.contains(piece), "missing \(piece.debugDescription)")
        }
        for absent in ["\(esc)[?1000h", "\(esc)[?1002h", "\(esc)[?1003h", "\(esc)[?1006h"] {
            #expect(!offSection.contains(absent), "unexpected \(absent.debugDescription)")
        }
    }

    // MARK: cursor

    @Test("out-of-range cursor coordinates clamp to the pane size")
    func cursorClamping() throws {
        let state = makeState(cursorX: 200, cursorY: 99)
        let text = try assembleText(state: state)
        #expect(text.hasSuffix("\(esc)[\(rows);\(cols)H"))
    }

    @Test("origin mode translates the absolute tmux cursor into region-relative CUP")
    func originModeCompensation() throws {
        // Absolute row 5 inside region rows 2–20 → CUP row 5-2+1 = 4.
        let state = makeState(cursorX: 0, cursorY: 5,
                              scrollRegionUpper: 2, scrollRegionLower: 20, originMode: true)
        let text = try assembleText(state: state)
        #expect(text.hasSuffix("\(esc)[4;1H"))

        // Origin mode with a full-screen region needs no translation.
        let fullScreen = makeState(cursorX: 0, cursorY: 5, originMode: true)
        let fullText = try assembleText(state: fullScreen)
        #expect(fullText.hasSuffix("\(esc)[6;1H"))
    }

    // MARK: pending-output octal unescape

    @Test("octal unescape: C0 controls, backslash (\\134), and UTF-8 bytes round-trip raw")
    func octalUnescape() throws {
        #expect(try ReplayWriter.unescapePendingLine("abc") == Data("abc".utf8))
        #expect(try ReplayWriter.unescapePendingLine("\\033[31m") == Data([0x1b]) + Data("[31m".utf8))
        // tmux escapes backslash as \134 (never as a doubled backslash).
        #expect(try ReplayWriter.unescapePendingLine("a\\134b") == Data("a\\b".utf8))
        // Multi-byte UTF-8 arrives fully octal-escaped (char is signed on
        // Darwin, so 0x80–0xFF are escaped) and must reassemble to raw bytes.
        #expect(try ReplayWriter.unescapePendingLine("\\346\\227\\245") == Data([0xE6, 0x97, 0xA5]))
        #expect(try ReplayWriter.unescapePendingLine("\\346\\227\\245") == Data("日".utf8))
        // DEL (0x7F) is ≥ ' ' under signed char — tmux leaves it literal.
        #expect(try ReplayWriter.unescapePendingLine("\u{7f}") == Data([0x7F]))
        // NUL and highest byte.
        #expect(try ReplayWriter.unescapePendingLine("\\000\\377") == Data([0x00, 0xFF]))

        // Lines concatenate without separators (real newlines arrive as \012).
        #expect(try ReplayWriter.unescapePending(lines: ["a\\012", "b"]) == Data([0x61, 0x0A, 0x62]))
    }

    @Test("malformed octal escapes abort the replay")
    func malformedOctalThrows() throws {
        for bad in ["\\12", "\\", "\\9ab", "\\1x2", "trailing\\03"] {
            #expect(throws: ReplayWriterError.malformedPendingEscape(line: bad)) {
                try ReplayWriter.unescapePendingLine(bad)
            }
        }
        // \400+ (> 0xFF) cannot come from tmux's %03hho — reject.
        #expect(throws: ReplayWriterError.malformedPendingEscape(line: "\\777")) {
            try ReplayWriter.unescapePendingLine("\\777")
        }
    }

    @Test("unescaped pending bytes land between region and cursor")
    func pendingBytesInAssembly() throws {
        let state = makeState(cursorX: 3, cursorY: 3)
        let data = try ReplayWriter.assemble(
            history: [], altScreen: nil, pending: ["X\\346\\227\\245"],
            state: state, cols: cols, rows: rows)
        let expectedTail = Data("X".utf8) + Data([0xE6, 0x97, 0xA5]) + Data("\(esc)[4;4H".utf8)
        #expect(data.suffix(expectedTail.count) == expectedTail)
    }
}
