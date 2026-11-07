// The handover corpus: the libghostty proof of concept's generated terminal states, as named byte
// sequences. Ported from spikes/libghostty-vt/check/Sources/vtcheck/Workloads.swift on branch
// spike/libghostty-vt-poc. The LCG and the colors, unicode, cursor, tui and scroll workloads there
// are adapted from gazishahi/side-terminal-bench VTBench/Sources/VTBench/main.swift (Apache-2.0,
// commit f94797090bac3d9e7585dbf1756d6684a18376da); its notice and licence are in
// SideTerminalBenchLicense.swift beside this file. The state scenarios were written for the check.
//
// Two parts of the proof of concept's 213 states are not here. Its 96 recorded states came from
// real sessions that were captured to disk, not generated, so they cannot be rebuilt from code. Its
// `ascii` workload read the repository's own Swift sources, which change with every commit, so it is
// not deterministic. What is left is 81 scenarios and 5 workloads cut at 6 points each: 111 states.
import Foundation

/// One state: the bytes that reach it, fed to a fresh terminal of this size.
struct HandoverState: Sendable {
    let name: String
    let bytes: [UInt8]
    let cols: Int
    let rows: Int
}

enum HandoverCorpus {
    static let scenarioCols = 80
    static let scenarioRows = 24
    static let workloadCols = 200
    static let workloadRows = 60

    /// Where each workload is cut. The proof of concept cut a 1,000,000-byte prefix at each sixth
    /// and moved every cut forward to the next byte at which libghostty's parser was at ground, so
    /// no state ends inside an escape sequence or a UTF-8 character. These are its cut points.
    static let checkpoints: [(workload: String, offsets: [Int])] = [
        ("colors", [166_666, 333_339, 500_006, 666_682, 833_335, 1_000_006]),
        ("cursor", [166_666, 333_333, 500_002, 666_666, 833_335, 1_000_003]),
        ("scroll", [166_666, 333_333, 500_000, 666_666, 833_335, 1_000_000]),
        ("tui", [166_666, 333_335, 500_000, 666_672, 833_333, 1_000_003]),
        ("unicode", [166_667, 333_333, 500_000, 666_668, 833_333, 1_000_003]),
    ]

    /// Every state's name: the scenarios, then `<workload>@<byte offset>`.
    static let names: [String] = scenarios.map(\.name)
        + checkpoints.flatMap { entry in entry.offsets.map { "\(entry.workload)@\($0)" } }

    static func state(named name: String) -> HandoverState {
        if let scenario = scenarioByName[name] { return scenario }
        let parts = name.split(separator: "@")
        guard parts.count == 2, let end = Int(parts[1]) else { preconditionFailure("no corpus state named \(name)") }
        return HandoverState(
            name: name, bytes: Array(workloadBytes(String(parts[0])).prefix(end)),
            cols: workloadCols, rows: workloadRows)
    }

    /// A whole workload, a little past its last cut point.
    static func workloadBytes(_ workload: String) -> [UInt8] {
        switch workload {
        case "colors": return colors
        case "cursor": return cursor
        case "scroll": return scroll
        case "tui": return tui
        case "unicode": return unicode
        default: preconditionFailure("no workload named \(workload)")
        }
    }

    /// Each workload is generated once, the first time a state asks for it.
    private static let generatedSize = 1_000_100
    private static let colors = colorsWorkload(generatedSize)
    private static let cursor = cursorWorkload(generatedSize, cols: workloadCols, rows: workloadRows)
    private static let scroll = scrollWorkload(generatedSize, rows: workloadRows)
    private static let tui = tuiWorkload(generatedSize, cols: workloadCols, rows: workloadRows)
    private static let unicode = unicodeWorkload(generatedSize)

    private static let scenarioByName: [String: HandoverState] = Dictionary(
        uniqueKeysWithValues: scenarios.map { ($0.name, $0) })

    /// What a receiver may hold before a preamble arrives: a viewer reused by a session like vim,
    /// and one left in everything the reset prelude never names.
    static let priorLives: [(name: String, bytes: [UInt8])] = {
        let vim = fill(40) + "\(e)[?1049h\(e)[?1h\(e)=\(e)[?1000h\(e)[?1006h\(e)[?2004h\(e)[?25l\(e)[3;20r\(e)[1;33;44m\(e)[2Jjunk text\(e)[?1004h"
        let everything = fill(40) + [
            "\(e)[>1u", "\(e)[3g", "\(e)(0", "\(e))0", "\u{0e}", "\(e)[?45h", "\(e)[?69h\(e)[5;40s", "\(e)[?1005h", "\(e)[?1015h",
            "\(e)[?1016h", "\(e)[?5h", "\(e)[20h", "\(e)[?2026h", "\(e)]2;old title\u{07}", "\(e)]8;;https://example.com/old\(e)\\",
            "\(e)[5 q", "\(e)[1\"q", "\(e)[?6h", "\(e)7", "\(e)[?1007l", "\(e)[>4;2m", "\(e)]7;file:///tmp/old\(e)\\", "\(e)[53m",
            "junk",
        ].joined()
        return [("vim-like", Array(vim.utf8)), ("everything", Array(everything.utf8))]
    }()

    // MARK: - Scenarios

    private static let e = "\u{1b}"

    /// Numbered, coloured lines, enough to push text into scrollback.
    private static func fill(_ count: Int) -> String {
        (0..<count).map { "\(e)[3\($0 % 8)mline \($0)\(e)[0m tail\r\n" }.joined()
    }

    /// Each state reached by real escape sequences. Grid 80x24.
    static let scenarios: [HandoverState] = {
        let cases: [(String, String)] = [
            ("primary-fresh", "hello"),
            ("primary-scrollback", fill(60) + "prompt$ "),
            ("primary-short-screen", "one\r\ntwo\r\nthree\r\n"),
            ("primary-cleared-after-scrollback", fill(60) + "\(e)[H\(e)[2Jhi"),
            ("primary-cursor-high-text-higher", fill(60) + "\(e)[5;10H"),
            ("primary-blank-rows-at-bottom", fill(60) + "\(e)[20;1H\(e)[Jend\(e)[10;1H"),
            ("pending-wrap", String(repeating: "x", count: 80)),
            ("pending-wrap-styled", "\(e)[41m" + String(repeating: "x", count: 80)),
            ("wrapped-line", String(repeating: "abcdefghij", count: 20) + "\r\nnext"),
            ("wrapped-exact-width", String(repeating: "y", count: 160) + "\r\nnext"),
            ("wrapped-styled", "\(e)[31m" + String(repeating: "r", count: 75) + "\(e)[32m" + String(repeating: "g", count: 75) + "\(e)[0m"),
            ("wrapped-in-scrollback", (0..<30).map { "\($0) " + String(repeating: "w", count: 190) + "\r\n" }.joined()),
            ("wrapped-trailing-spaces", "ab" + String(repeating: " ", count: 100) + "cd"),
            ("wide-at-edge", String(repeating: "a", count: 79) + "漢after"),
            ("wide-at-edge-nowrap", "\(e)[?7l" + String(repeating: "a", count: 79) + "漢"),
            ("wide-overwrite-tail", "漢字\(e)[1;2Hx"),
            ("wide-overwrite-head", "漢字\(e)[1;3Hx"),
            ("wide-row-full", String(repeating: "漢", count: 41)),
            ("wide-in-scrollback", (0..<40).map { _ in String(repeating: "a", count: 79) + "字z\r\n" }.joined()),
            ("emoji-clusters", "🇯🇵 👩‍💻 👍🏽 ❤\u{fe0f} 1\u{fe0f}\u{20e3} ☺\u{fe0e} 🏳️‍🌈 end"),
            ("combining-marks", "e\u{301} a\u{308}\u{304} 각 \u{1100}\u{1161}\u{11a8} क्ष ไทย ก\u{e33}"),
            ("vs16-at-edge", String(repeating: "a", count: 79) + "❤\u{fe0f}z"),
            ("alt-simple", fill(30) + "\(e)[?1049h\(e)[2;3Hin alt"),
            ("alt-no-scrollback", "before\(e)[?1049h\(e)[5;5Hx"),
            ("alt-region", fill(30) + "\(e)[?1049h\(e)[2;20r\(e)[5;1Htext"),
            ("alt-saved-cursor", fill(10) + "\(e)[10;10H\(e)[?1049h\(e)[3;3H\(e)7\(e)[10;10Hhi"),
            ("alt-legacy-47", fill(5) + "\(e)[?47h\(e)[2Jx"),
            ("alt-1047", fill(5) + "\(e)[?1047h\(e)[2Jx"),
            ("alt-tui-full", fill(30) + "\(e)[?1049h\(e)[?25l\(e)[2J\(e)[1;1H\(e)[7m status \(e)[0m\(e)[24;1H-- INSERT --\(e)[?1000h\(e)[?1006h\(e)[?2004h\(e)[3;22r\(e)[5;5H"),
            ("region-primary", fill(30) + "\(e)[5;15r\(e)[10;1H"),
            ("region-origin", "\(e)[5;15r\(e)[?6h\(e)[3;3Hx"),
            ("region-origin-alt", "\(e)[?1049h\(e)[5;15r\(e)[?6h\(e)[3;3Hx"),
            ("hidden-then-alt", "\(e)[?25l\(e)[?1049hx"),
            ("mouse-downgrade", "\(e)[?1003h\(e)[?1000h"),
            ("mouse-1000", "\(e)[?1000h"),
            ("mouse-1002-sgr", "\(e)[?1002h\(e)[?1006h"),
            ("mouse-1003-sgr", "\(e)[?1003h\(e)[?1006h"),
            ("mouse-urxvt", "\(e)[?1000h\(e)[?1015h"),
            ("mouse-utf8", "\(e)[?1000h\(e)[?1005h"),
            ("mouse-sgr-pixels", "\(e)[?1000h\(e)[?1016h"),
            ("mouse-x10", "\(e)[?9h"),
            ("bracketed-paste", "\(e)[?2004h"),
            ("focus-reporting", "\(e)[?1004h"),
            ("app-cursor-keypad", "\(e)[?1h\(e)="),
            ("insert-mode", "abcdef\(e)[1;2H\(e)[4hXY"),
            ("no-autowrap", "\(e)[?7l" + String(repeating: "x", count: 100)),
            ("reverse-wrap", "\(e)[?45habc"),
            ("reverse-wrap-no-autowrap", "\(e)[?45h\(e)[?7labc"),
            ("lr-margins", "\(e)[?69h\(e)[5;40s\(e)[3;3Htext"),
            ("sgr-all", "\(e)[1mbold\(e)[0m \(e)[2mdim\(e)[0m \(e)[3mital\(e)[0m \(e)[4munder\(e)[0m \(e)[5mblink\(e)[0m \(e)[7minv\(e)[0m \(e)[8mhide\(e)[0m \(e)[9mstrike\(e)[0m \(e)[1;3;4;9mmix\(e)[0m"),
            ("sgr-colors", (0..<16).map { "\(e)[38;5;\($0)mf\(e)[48;5;\($0)mb\(e)[0m" }.joined() + "\(e)[31mR\(e)[91mB\(e)[41mG\(e)[101mH\(e)[0m\(e)[38;5;200mX\(e)[48;5;17mY\(e)[38;2;1;2;3mZ\(e)[48;2;4;5;6mW\(e)[0m"),
            ("underline-styles", "\(e)[4:1ma\(e)[4:2mb\(e)[4:3mc\(e)[4:4md\(e)[4:5me\(e)[21mf\(e)[0m\(e)[58;5;9m\(e)[4mg\(e)[58;2;1;2;3mh\(e)[58:2::9:8:7mi\(e)[59mj\(e)[0m"),
            ("overline", "\(e)[53mover\(e)[55mno\(e)[0m"),
            ("bce-erase", "\(e)[41m\(e)[K\(e)[2;1H\(e)[42m\(e)[2K\(e)[3;5H\(e)[43m\(e)[J\(e)[0m"),
            ("bce-styled-erase", "\(e)[4;7;44m\(e)[K\(e)[0m"),
            ("ech-dch-bce", "abcdefgh\(e)[1;3H\(e)[45m\(e)[2X\(e)[2P\(e)[0m"),
            ("open-pen", "\(e)[1;31;44mopen"),
            ("hidden-cursor", "\(e)[?25lhidden"),
            ("tabstops-custom", "\(e)[3g\(e)[1;5H\(e)H\(e)[1;17H\(e)H\r\tA\tB"),
            ("charset-linedraw-open", "\(e)(0lqk\(e)(B\r\n\(e)(0"),
            ("charset-so", "\(e))0\u{0e}lqk"),
            ("hyperlink", "\(e)]8;;https://example.com/a\(e)\\link\(e)]8;;\(e)\\ plain"),
            ("hyperlink-open", "\(e)]8;id=x;https://example.com/b\(e)\\open"),
            ("title-set", "\(e)]2;my title\u{07}"),
            ("saved-cursor-primary", "\(e)[5;5H\(e)[31m\(e)7\(e)[0m\(e)[10;10Hx"),
            ("kitty-keyboard-flags", "\(e)[>1u\(e)[=5;1u"),
            ("modify-other-keys", "\(e)[>4;2m"),
            ("sync-output-open", "\(e)[?2026habc"),
            ("cursor-style", "\(e)[5 q"),
            ("protected-cells", "\(e)[1\"qPROT\(e)[0\"q plain\(e)[1;1H\(e)[K"),
            ("reverse-video", "\(e)[?5htext"),
            ("linefeed-mode", "\(e)[20hab\ncd"),
            ("rep", "x\(e)[5b"),
            ("insert-delete-lines", fill(10) + "\(e)[3;1H\(e)[2L\(e)[6;1H\(e)[1M"),
            ("scroll-up-down", fill(10) + "\(e)[3S\(e)[1T"),
            ("soft-reset", "\(e)[?7l\(e)[?6h\(e)[5;10r\(e)[1;31m\(e)[!p"),
            ("full-reset", fill(5) + "\(e)c"),
            ("backspace-tab-cr", "abc\u{08}\u{08}X\tY\rZ"),
            ("erase-scrollback", fill(40) + "\(e)[3Jnow"),
            ("decaln", "\(e)#8"),
            ("nul-gap", "\(e)[10Chello"),
        ]
        return cases.map {
            HandoverState(name: $0.0, bytes: Array($0.1.utf8), cols: scenarioCols, rows: scenarioRows)
        }
    }()

    // MARK: - Workloads

    private struct LCG {
        var s: UInt64
        mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private static func colorsWorkload(_ size: Int) -> [UInt8] {
        var r = LCG(s: 1), out = ""
        out.reserveCapacity(size)
        let words = ["let", "value", "return", "func", "self", "error:", "warning", "0x7f3a", "→", "done"]
        while out.utf8.count < size {
            for _ in 0..<30 {
                out += "\u{1b}[38;2;\(r.int(256));\(r.int(256));\(r.int(256))m\u{1b}[48;5;\(r.int(256))m\(words[r.int(words.count)]) "
            }
            out += "\u{1b}[0m\r\n"
        }
        return Array(out.utf8)
    }

    private static func unicodeWorkload(_ size: Int) -> [UInt8] {
        var r = LCG(s: 2), out = ""
        let pieces = ["漢字テスト", "한국어", "👩‍💻", "🇯🇵", "e\u{301}", "ñ", "✓", "│", "─", "Ω≈ç√", "🙂", "a", "مرحبا", "ascii text "]
        while out.utf8.count < size {
            for _ in 0..<25 { out += pieces[r.int(pieces.count)] }
            out += "\r\n"
        }
        return Array(out.utf8)
    }

    private static func cursorWorkload(_ size: Int, cols: Int, rows: Int) -> [UInt8] {
        var r = LCG(s: 3), out = ""
        while out.utf8.count < size {
            out += "\u{1b}[\(r.int(rows) + 1);\(r.int(cols) + 1)H\u{1b}[3\(r.int(8))mxyz\u{1b}[K"
            if r.int(50) == 0 { out += "\u{1b}[2J" }
        }
        return Array(out.utf8)
    }

    private static func tuiWorkload(_ size: Int, cols: Int, rows: Int) -> [UInt8] {
        var r = LCG(s: 4), out = "", frame = 0
        let spinner = ["·", "✢", "✳", "✶", "✻", "✽"]
        let inner = cols - 4
        while out.utf8.count < size {
            frame += 1
            out += "\u{1b}[?25l\u{1b}[\(rows - 18);1H"
            out += "\u{1b}[38;5;245m╭" + String(repeating: "─", count: inner) + "╮\u{1b}[0m\r\n"
            for line in 0..<12 {
                var body = "\u{1b}[1m⏺\u{1b}[0m Update(\u{1b}[36mSIDE/File\(line).swift\u{1b}[0m) \u{1b}[32m+\(r.int(40))\u{1b}[0m \u{1b}[31m-\(r.int(20))\u{1b}[0m"
                body += String(repeating: " ", count: max(0, inner - 40))
                out += "\u{1b}[38;5;245m│\u{1b}[0m " + body + "\u{1b}[K\r\n"
            }
            out += "\u{1b}[38;5;245m╰" + String(repeating: "─", count: inner) + "╯\u{1b}[0m\r\n"
            out += "\u{1b}[38;5;174m\(spinner[frame % spinner.count]) Thinking… (\(frame / 10)s · ↑ \(r.int(9000)) tokens · esc to interrupt)\u{1b}[0m\u{1b}[K\r\n"
            out += "\u{1b}[K\r\n> \u{1b}[K\u{1b}[?25h"
        }
        return Array(out.utf8)
    }

    private static func scrollWorkload(_ size: Int, rows: Int) -> [UInt8] {
        var r = LCG(s: 5), out = "\u{1b}[5;\(rows - 5)r"
        while out.utf8.count < size {
            out += "\u{1b}[\(rows - 5);1H\r\n\u{1b}[3\(r.int(8))mline \(r.next()) in a scroll region, like less or vim\u{1b}[0m"
        }
        return Array((out + "\u{1b}[r").utf8)
    }
}
