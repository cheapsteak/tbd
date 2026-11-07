// Engine-neutral screen model and the comparison every subcommand shares.
import Foundation

enum Col: Equatable, Hashable, CustomStringConvertible {
    case def, pal(UInt8), rgb(UInt8, UInt8, UInt8)
    var description: String {
        switch self {
        case .def: return "default"
        case .pal(let n): return "p\(n)"
        case .rgb(let r, let g, let b): return "#\(r),\(g),\(b)"
        }
    }
}

struct Flag {
    static let bold: UInt8 = 1, dim: UInt8 = 2, italic: UInt8 = 4, blink: UInt8 = 8
    static let inverse: UInt8 = 16, invisible: UInt8 = 32, strike: UInt8 = 64, overline: UInt8 = 128
    /// Flags that change nothing on a cell with no glyph.
    static let glyphOnly: UInt8 = bold | dim | italic | blink | invisible
    static func name(_ f: UInt8) -> String {
        var s: [String] = []
        if f & bold != 0 { s.append("bold") }
        if f & dim != 0 { s.append("dim") }
        if f & italic != 0 { s.append("italic") }
        if f & blink != 0 { s.append("blink") }
        if f & inverse != 0 { s.append("inverse") }
        if f & invisible != 0 { s.append("invisible") }
        if f & strike != 0 { s.append("strike") }
        if f & overline != 0 { s.append("overline") }
        return s.isEmpty ? "none" : s.joined(separator: "+")
    }
}

struct Cell: Equatable {
    var cp: UInt32 = 0            // first scalar, 0 = no text written
    var more: [UInt32]? = nil     // remaining scalars of a cluster
    var width: UInt8 = 1          // 1, 2, or 0 for the trailing half of a wide cell
    var fg: Col = .def
    var bg: Col = .def
    var ul: Col = .def
    var flags: UInt8 = 0
    var underline: UInt8 = 0      // 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed
    var link: String? = nil

    var isBlank: Bool { (cp == 0 || cp == 32) && more == nil }
    var text: String {
        var u = String.UnicodeScalarView()
        for v in [cp] + (more ?? []) { if v != 0, let s = Unicode.Scalar(v) { u.append(s) } }
        return String(u)
    }
    var hexText: String { ([cp] + (more ?? [])).map { String($0, radix: 16) }.joined(separator: "+") }
    var dump: String {
        "'\(text)' [\(hexText)] w\(width) fg=\(fg) bg=\(bg) ul=\(ul) f=\(Flag.name(flags)) u=\(underline)" + (link.map { " link=\($0)" } ?? "")
    }
}

struct Snap {
    var cols = 0, rows = 0
    var grid: [[Cell]] = []
    var wrap: [Bool] = []            // row continues the row above
    var hist: [[Cell]] = []
    var histWrap: [Bool] = []
    var cx = 0, cy = 0
    var pending = false
    var cursorVisible = true
    var alt = false
    var modes: [String: Bool] = [:]
    var top = 0, bottom = 0, left = 0, right = 0
    var pen = Cell()
    var kitty = 0
}

/// DEC private and ANSI modes compared on both engines. `dec` false is ANSI.
let comparedModes: [(name: String, n: Int, dec: Bool)] = [
    ("DECCKM", 1, true), ("DECOM", 6, true), ("DECAWM", 7, true),
    ("DECTCEM", 25, true), ("reverseWrap", 45, true), ("DECNKM", 66, true), ("DECLRMM", 69, true),
    ("mouseX10", 9, true), ("mouse1000", 1000, true), ("mouse1002", 1002, true), ("mouse1003", 1003, true),
    ("focus1004", 1004, true), ("mouseUTF8", 1005, true), ("mouseSGR", 1006, true),
    ("altScroll1007", 1007, true), ("mouseURXVT", 1015, true), ("mouseSGRPixels", 1016, true),
    ("bracketedPaste", 2004, true), ("syncOutput", 2026, true),
    ("reverseVideo", 5, true), ("IRM", 4, false), ("LNM", 20, false),
]

/// Counts of differing things, by category, with one example each.
struct Tally {
    var counts: [String: Int] = [:]
    var examples: [String: String] = [:]
    mutating func add(_ cat: String, _ n: Int = 1, _ example: @autoclosure () -> String) {
        if counts[cat] == nil { examples[cat] = example() }
        counts[cat, default: 0] += n
    }
    mutating func merge(_ o: Tally, prefixExample: String = "") {
        for (k, v) in o.counts {
            if counts[k] == nil { examples[k] = prefixExample + (o.examples[k] ?? "") }
            counts[k, default: 0] += v
        }
    }
    var isEmpty: Bool { counts.isEmpty }
    func filtered(_ keep: (String) -> Bool) -> Tally {
        var t = Tally()
        for (k, v) in counts where keep(k) { t.counts[k] = v; t.examples[k] = examples[k] }
        return t
    }
}

/// Categories with no visible effect. They are counted, and reported apart.
let cosmeticCategories: Set<String> = [
    "blankKind", "fgOnBlank", "attrsOnBlank", "ulColorOnBlank", "inertMargins",
    "h.blankKind", "h.fgOnBlank", "h.attrsOnBlank", "h.ulColorOnBlank",
]

private func compareCells(_ a: Cell, _ b: Cell, _ where_: @autoclosure () -> String, _ p: String, _ t: inout Tally) {
    if a.width != b.width {
        t.add(p + "wide", 1, "\(where_()): \(a.dump) vs \(b.dump)")
    }
    if a.width == 0 && b.width == 0 { return }   // trailing half: nothing else to read
    let blank = a.isBlank && b.isBlank
    if blank {
        if a.cp != b.cp { t.add(p + "blankKind", 1, "\(where_()): \(a.dump) vs \(b.dump)") }
    } else if a.cp != b.cp || a.more != b.more {
        t.add(p + "text", 1, "\(where_()): \(a.dump) vs \(b.dump)")
    }
    let inverse = (a.flags | b.flags) & Flag.inverse != 0
    if a.fg != b.fg {
        t.add(p + (blank && !inverse ? "fgOnBlank" : "fg"), 1, "\(where_()): \(a.dump) vs \(b.dump)")
    }
    if a.bg != b.bg { t.add(p + "bg", 1, "\(where_()): \(a.dump) vs \(b.dump)") }
    if a.flags != b.flags || a.underline != b.underline {
        let visible = !blank || (a.flags ^ b.flags) & ~Flag.glyphOnly != 0 || a.underline != b.underline
        t.add(p + (visible ? "attrs" : "attrsOnBlank"), 1, "\(where_()): \(a.dump) vs \(b.dump)")
    }
    if a.ul != b.ul {
        let shown = a.underline != 0 || b.underline != 0
        t.add(p + (shown ? "ulColor" : "ulColorOnBlank"), 1, "\(where_()): \(a.dump) vs \(b.dump)")
    }
    if a.link != b.link { t.add(p + "link", 1, "\(where_()): \(a.dump) vs \(b.dump)") }
}

/// Compares two states. `a` is the reference. History rows are aligned at the
/// newest row, because the engines trim at different granularity.
func compare(_ a: Snap, _ b: Snap, history: Bool = true) -> Tally {
    var t = Tally()
    if a.alt != b.alt { t.add("activeScreen", 1, "alt \(a.alt) vs \(b.alt)") }
    for y in 0..<min(a.rows, b.rows) {
        for x in 0..<min(a.cols, b.cols) {
            compareCells(a.grid[y][x], b.grid[y][x], "row \(y) col \(x)", "", &t)
        }
        if a.wrap[y] != b.wrap[y] { t.add("softWrap", 1, "row \(y): \(a.wrap[y]) vs \(b.wrap[y])") }
    }
    if a.cx != b.cx || a.cy != b.cy { t.add("cursorPos", 1, "\(a.cx),\(a.cy) vs \(b.cx),\(b.cy) (x,y)") }
    if a.pending != b.pending { t.add("pendingWrap", 1, "\(a.pending) vs \(b.pending) at \(a.cx),\(a.cy)") }
    if a.cursorVisible != b.cursorVisible { t.add("cursorVisible", 1, "\(a.cursorVisible) vs \(b.cursorVisible)") }
    // Left and right margins do nothing while DECLRMM is off, so a difference there is inert.
    let leftRightLive = a.modes["DECLRMM"] == true || b.modes["DECLRMM"] == true
    let lrDiffer = a.left != b.left || a.right != b.right
    let regionText = "top \(a.top) bottom \(a.bottom) left \(a.left) right \(a.right) vs top \(b.top) bottom \(b.bottom) left \(b.left) right \(b.right)"
    if a.top != b.top || a.bottom != b.bottom || (leftRightLive && lrDiffer) {
        t.add("region", 1, regionText)
    } else if lrDiffer {
        t.add("inertMargins", 1, regionText)
    }
    for (k, v) in a.modes.sorted(by: { $0.key < $1.key }) where b.modes[k] != nil && b.modes[k] != v {
        t.add("mode." + k, 1, "\(v) vs \(b.modes[k]!)")
    }
    if a.pen.fg != b.pen.fg || a.pen.bg != b.pen.bg || a.pen.flags != b.pen.flags
        || a.pen.underline != b.pen.underline || a.pen.ul != b.pen.ul {
        t.add("pen", 1, "\(a.pen.dump) vs \(b.pen.dump)")
    }
    if a.kitty != b.kitty { t.add("kittyFlags", 1, "\(a.kitty) vs \(b.kitty)") }
    if history {
        if a.hist.count != b.hist.count { t.add("h.rowCount", 1, "\(a.hist.count) vs \(b.hist.count) rows") }
        let n = min(a.hist.count, b.hist.count)
        for i in 0..<n {
            let ra = a.hist[a.hist.count - 1 - i], rb = b.hist[b.hist.count - 1 - i]
            for x in 0..<min(ra.count, rb.count) {
                compareCells(ra[x], rb[x], "history -\(i + 1) col \(x)", "h.", &t)
            }
            if a.histWrap[a.hist.count - 1 - i] != b.histWrap[b.hist.count - 1 - i] {
                t.add("h.softWrap", 1, "history -\(i + 1)")
            }
        }
    }
    return t
}

func loadAverage() -> String {
    var l = [Double](repeating: 0, count: 3)
    getloadavg(&l, 3)
    return String(format: "%.2f %.2f %.2f", l[0], l[1], l[2])
}

let baseDir: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let workloadDir = baseDir.appendingPathComponent("workloads")
let outDir = baseDir.appendingPathComponent("out")

func writeJSON(_ name: String, _ value: Any) {
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: outDir.appendingPathComponent(name))
    print("wrote \(outDir.appendingPathComponent(name).path)")
}

func padR(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
func padL(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: " ", count: n - s.count) + s }

/// Escapes bytes as a printable reproducer.
func escaped(_ b: [UInt8]) -> String {
    var s = ""
    var i = 0
    while i < b.count {
        let c = b[i]
        if c == 0x1b { s += "\\e" }
        else if c == 0x0d { s += "\\r" }
        else if c == 0x0a { s += "\\n" }
        else if c == 0x08 { s += "\\b" }
        else if c == 0x09 { s += "\\t" }
        else if c == 0x07 { s += "\\a" }
        else if c < 0x20 || c == 0x7f { s += String(format: "\\x%02x", c) }
        else if c < 0x80 { s.unicodeScalars.append(Unicode.Scalar(c)) }
        else {
            var j = i + 1
            while j < b.count && b[j] & 0xC0 == 0x80 { j += 1 }
            if let t = String(bytes: b[i..<j], encoding: .utf8), let u = t.unicodeScalars.first {
                s += String(format: "\\u{%x}", u.value)
                i = j - 1
            } else { s += String(format: "\\x%02x", c) }
        }
        i += 1
    }
    return s
}
