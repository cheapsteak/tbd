// The engine-neutral screen model the handover suites compare, and the comparison itself. Ported
// from the libghostty proof of concept's Model.swift, with its readers from GTerm.swift and
// STerm.swift (spikes/libghostty-vt/check/Sources/vtcheck/ on branch spike/libghostty-vt-poc).
// The comparison and its category names are the proof of concept's, so a miss here names the
// same category its handover.json does, except `mouseTracking` and `mouseEncoding`, which across
// the engines take the place of its per-bit mouse modes. Two libghostty terminals still compare
// those bits too.
import Foundation
import SwiftTerm
@testable import TBDGhosttyTerminal

enum HandoverColor: Equatable, CustomStringConvertible {
    case standard, palette(UInt8), rgb(UInt8, UInt8, UInt8)

    var description: String {
        switch self {
        case .standard: return "default"
        case .palette(let index): return "p\(index)"
        case .rgb(let red, let green, let blue): return "#\(red),\(green),\(blue)"
        }
    }
}

enum HandoverFlag {
    static let bold: UInt8 = 1, dim: UInt8 = 2, italic: UInt8 = 4, blink: UInt8 = 8
    static let inverse: UInt8 = 16, invisible: UInt8 = 32, strike: UInt8 = 64, overline: UInt8 = 128
    /// Flags that change nothing on a cell with no glyph.
    static let glyphOnly: UInt8 = bold | dim | italic | blink | invisible

    static func name(_ flags: UInt8) -> String {
        let names: [(UInt8, String)] = [
            (bold, "bold"), (dim, "dim"), (italic, "italic"), (blink, "blink"), (inverse, "inverse"),
            (invisible, "invisible"), (strike, "strike"), (overline, "overline"),
        ]
        let set = names.filter { flags & $0.0 != 0 }.map(\.1)
        return set.isEmpty ? "none" : set.joined(separator: "+")
    }
}

struct HandoverCell: Equatable {
    /// The first scalar, 0 when no text was written.
    var code: UInt32 = 0
    /// The rest of a cluster's scalars.
    var more: [UInt32]?
    /// 1, 2, or 0 for the second half of a wide character.
    var width: UInt8 = 1
    var foreground: HandoverColor = .standard
    var background: HandoverColor = .standard
    var underlineColor: HandoverColor = .standard
    var flags: UInt8 = 0
    /// 0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed.
    var underline: UInt8 = 0
    var link: String?

    var isBlank: Bool { (code == 0 || code == 32) && more == nil }

    var text: String {
        var view = String.UnicodeScalarView()
        for value in [code] + (more ?? []) where value != 0 {
            if let scalar = Unicode.Scalar(value) { view.append(scalar) }
        }
        return String(view)
    }

    var dump: String {
        let scalars = ([code] + (more ?? [])).map { String($0, radix: 16) }.joined(separator: "+")
        return "'\(text)' [\(scalars)] w\(width) fg=\(foreground) bg=\(background) ul=\(underlineColor) "
            + "f=\(HandoverFlag.name(flags)) u=\(underline)" + (link.map { " link=\($0)" } ?? "")
    }
}

struct HandoverSnap {
    var cols = 0, rows = 0
    var grid: [[HandoverCell]] = []
    /// Each row continues the row above it.
    var wrap: [Bool] = []
    var history: [[HandoverCell]] = []
    var historyWrap: [Bool] = []
    var cursorX = 0, cursorY = 0
    var pending = false
    var cursorVisible = true
    var alt = false
    /// The modes in `handoverComparedModes` other than the mouse modes, by name. A mode the
    /// terminal gave no answer for is missing.
    var modes: [String: Bool] = [:]
    /// libghostty's bit for each mouse mode, set ones included that a later mode replaced. nil for
    /// SwiftTerm, which keeps only the ones in effect.
    var mouseModeBits: [String: Bool]?
    /// The mouse tracking mode in effect: 9, 1000, 1002 or 1003, or 0 for none. nil when unread.
    var mouseTracking: Int?
    /// The mouse report encoding in effect: 1005, 1006, 1015 or 1016, or 0 for X10's. nil when unread.
    var mouseEncoding: Int?
    var top = 0, bottom = 0, left = 0, right = 0
    var pen = HandoverCell()
    var kitty = 0

    /// This snap with only its newest `count` rows of scrollback, which is what a writer capped at
    /// `count` rows carries.
    func keepingNewestHistory(_ count: Int) -> HandoverSnap {
        guard history.count > count else { return self }
        var snap = self
        snap.history = Array(history.suffix(count))
        snap.historyWrap = Array(historyWrap.suffix(count))
        return snap
    }
}

/// The mouse modes, tracking then encoding. libghostty keeps a bit for each in its mode table and
/// SwiftTerm keeps one tracking mode and one encoding, so across the two engines they are
/// compared as `mouseTracking` and `mouseEncoding`, the ones in effect.
let handoverMouseTrackingModes: Set<Int> = [9, 1000, 1002, 1003]
let handoverMouseEncodingModes: Set<Int> = [1005, 1006, 1015, 1016]

private func isMouseMode(_ mode: (name: String, value: Int, decPrivate: Bool)) -> Bool {
    mode.decPrivate && (handoverMouseTrackingModes.contains(mode.value) || handoverMouseEncodingModes.contains(mode.value))
}

/// The DEC private and ANSI modes compared. `decPrivate` false is ANSI.
let handoverComparedModes: [(name: String, value: Int, decPrivate: Bool)] = [
    ("DECCKM", 1, true), ("DECOM", 6, true), ("DECAWM", 7, true),
    ("DECTCEM", 25, true), ("reverseWrap", 45, true), ("DECNKM", 66, true), ("DECLRMM", 69, true),
    ("mouseX10", 9, true), ("mouse1000", 1000, true), ("mouse1002", 1002, true), ("mouse1003", 1003, true),
    ("focus1004", 1004, true), ("mouseUTF8", 1005, true), ("mouseSGR", 1006, true),
    ("altScroll1007", 1007, true), ("mouseURXVT", 1015, true), ("mouseSGRPixels", 1016, true),
    ("bracketedPaste", 2004, true), ("syncOutput", 2026, true),
    ("reverseVideo", 5, true), ("IRM", 4, false), ("LNM", 20, false),
]

/// What a reader sees on the screen: text, width, colours, attributes, links, the cursor's cell
/// and which screen is active.
let handoverScreenCategories: Set<String> = [
    "text", "wide", "fg", "bg", "attrs", "ulColor", "link", "cursorPos", "activeScreen",
]

/// Left and right margins while DECLRMM is off. They do nothing, and SwiftTerm keeps its right
/// margin at column 80 on a wider grid, so a crossing between the engines does not compare them.
let handoverInertCategories: Set<String> = ["inertMargins"]

/// A state listed as differing in one crossing: why, and the only categories it may differ in.
/// A difference in any other category fails, as a difference in an unlisted state does.
struct HandoverMiss: Sendable {
    let reason: String
    let categories: Set<String>
}

/// Counts of differing things, by category, with the first example of each.
struct HandoverTally {
    var counts: [String: Int] = [:]
    var examples: [String: String] = [:]

    mutating func add(_ category: String, _ example: @autoclosure () -> String) {
        if counts[category] == nil { examples[category] = example() }
        counts[category, default: 0] += 1
    }

    var isEmpty: Bool { counts.isEmpty }

    var categories: Set<String> { Set(counts.keys) }

    func filtered(to keep: Set<String>) -> HandoverTally { filtered { keep.contains($0) } }

    func excluding(_ drop: Set<String>) -> HandoverTally { filtered { !drop.contains($0) } }

    private func filtered(_ keep: (String) -> Bool) -> HandoverTally {
        var tally = HandoverTally()
        for (category, count) in counts where keep(category) {
            tally.counts[category] = count
            tally.examples[category] = examples[category]
        }
        return tally
    }

    /// One line per category, for a failure message.
    var summary: String {
        counts.keys.sorted().map { "\($0) x\(counts[$0] ?? 0): \(examples[$0] ?? "")" }.joined(separator: " | ")
    }
}

private func compareCells(
    _ lhs: HandoverCell, _ rhs: HandoverCell, _ place: @autoclosure () -> String, _ prefix: String,
    _ tally: inout HandoverTally
) {
    if lhs.width != rhs.width { tally.add(prefix + "wide", "\(place()): \(lhs.dump) vs \(rhs.dump)") }
    // The second half of a wide character: nothing else to read.
    if lhs.width == 0 && rhs.width == 0 { return }
    let blank = lhs.isBlank && rhs.isBlank
    if blank {
        if lhs.code != rhs.code { tally.add(prefix + "blankKind", "\(place()): \(lhs.dump) vs \(rhs.dump)") }
    } else if lhs.code != rhs.code || lhs.more != rhs.more {
        tally.add(prefix + "text", "\(place()): \(lhs.dump) vs \(rhs.dump)")
    }
    let inverse = (lhs.flags | rhs.flags) & HandoverFlag.inverse != 0
    if lhs.foreground != rhs.foreground {
        tally.add(prefix + (blank && !inverse ? "fgOnBlank" : "fg"), "\(place()): \(lhs.dump) vs \(rhs.dump)")
    }
    if lhs.background != rhs.background { tally.add(prefix + "bg", "\(place()): \(lhs.dump) vs \(rhs.dump)") }
    if lhs.flags != rhs.flags || lhs.underline != rhs.underline {
        let visible = !blank || (lhs.flags ^ rhs.flags) & ~HandoverFlag.glyphOnly != 0 || lhs.underline != rhs.underline
        tally.add(prefix + (visible ? "attrs" : "attrsOnBlank"), "\(place()): \(lhs.dump) vs \(rhs.dump)")
    }
    if lhs.underlineColor != rhs.underlineColor {
        let shown = lhs.underline != 0 || rhs.underline != 0
        tally.add(prefix + (shown ? "ulColor" : "ulColorOnBlank"), "\(place()): \(lhs.dump) vs \(rhs.dump)")
    }
    if lhs.link != rhs.link { tally.add(prefix + "link", "\(place()): \(lhs.dump) vs \(rhs.dump)") }
}

/// Compares two snaps, `expected` the reference. History rows are aligned at the newest row,
/// because the two engines trim scrollback at different granularity.
///
/// What is compared: every cell of the screen and the scrollback, soft wraps, the cursor's cell,
/// pending wrap and visibility, the active screen, the modes in `handoverComparedModes`, the
/// mouse tracking mode and encoding in effect, the scrolling region and margins, the pen and the
/// kitty keyboard flags. A mode one side gave no answer for differs. libghostty's bits for each
/// mouse mode are compared when both sides have them. What SwiftTerm cannot expose, and so is not
/// compared:
///
/// - **Character sets and tab stops** – SwiftTerm keeps its G0 to G3 designations, the shift
///   state and the tab stops private.
/// - **The pen's hyperlink** – SwiftTerm's pen has none. An open link shows on the cells printed
///   after it, which are compared.
/// - **Protection (DECSCA) and modifyOtherKeys** – SwiftTerm implements neither.
/// - **The title** – SwiftTerm hands it to its delegate and keeps no copy.
///
/// And what libghostty cannot expose, or nothing sets:
///
/// - **Cursor shape and blink** – libghostty gives the shape only to a render state, and neither
///   handover writer writes DECSCUSR.
/// - **The saved cursor** – libghostty has no getter for it. The origin-mode test checks the
///   cursor that `?1049h` saved, by leaving the alternate screen.
/// - **The working directory** – no corpus state sets one.
func handoverCompare(_ expected: HandoverSnap, _ actual: HandoverSnap, history: Bool = true) -> HandoverTally {
    var tally = HandoverTally()
    if expected.alt != actual.alt { tally.add("activeScreen", "alt \(expected.alt) vs \(actual.alt)") }
    for row in 0..<min(expected.rows, actual.rows) {
        for column in 0..<min(expected.cols, actual.cols) {
            compareCells(expected.grid[row][column], actual.grid[row][column], "row \(row) col \(column)", "", &tally)
        }
        if expected.wrap[row] != actual.wrap[row] {
            tally.add("softWrap", "row \(row): \(expected.wrap[row]) vs \(actual.wrap[row])")
        }
    }
    if expected.cursorX != actual.cursorX || expected.cursorY != actual.cursorY {
        tally.add("cursorPos", "\(expected.cursorX),\(expected.cursorY) vs \(actual.cursorX),\(actual.cursorY) (x,y)")
    }
    if expected.pending != actual.pending { tally.add("pendingWrap", "\(expected.pending) vs \(actual.pending)") }
    if expected.cursorVisible != actual.cursorVisible {
        tally.add("cursorVisible", "\(expected.cursorVisible) vs \(actual.cursorVisible)")
    }
    // Left and right margins do nothing while DECLRMM is off, so a difference there is inert.
    let marginsLive = expected.modes["DECLRMM"] == true || actual.modes["DECLRMM"] == true
    let marginsDiffer = expected.left != actual.left || expected.right != actual.right
    let regionText = "top \(expected.top) bottom \(expected.bottom) left \(expected.left) right \(expected.right) vs "
        + "top \(actual.top) bottom \(actual.bottom) left \(actual.left) right \(actual.right)"
    if expected.top != actual.top || expected.bottom != actual.bottom || (marginsLive && marginsDiffer) {
        tally.add("region", regionText)
    } else if marginsDiffer {
        tally.add("inertMargins", regionText)
    }
    let unanswered = "no answer"
    for name in Set(expected.modes.keys).union(actual.modes.keys).sorted() {
        let lhs = expected.modes[name], rhs = actual.modes[name]
        if lhs != rhs {
            tally.add("mode." + name, "\(lhs.map { "\($0)" } ?? unanswered) vs \(rhs.map { "\($0)" } ?? unanswered)")
        }
    }
    if let lhsBits = expected.mouseModeBits, let rhsBits = actual.mouseModeBits {
        for (name, value) in lhsBits.sorted(by: { $0.key < $1.key }) where rhsBits[name] != value {
            tally.add("mode." + name, "\(value) vs \(rhsBits[name].map { "\($0)" } ?? unanswered)")
        }
    }
    let unread = "unread"
    if expected.mouseTracking != actual.mouseTracking {
        tally.add("mouseTracking", "\(expected.mouseTracking.map(String.init) ?? unread) vs \(actual.mouseTracking.map(String.init) ?? unread)")
    }
    if expected.mouseEncoding != actual.mouseEncoding {
        tally.add("mouseEncoding", "\(expected.mouseEncoding.map(String.init) ?? unread) vs \(actual.mouseEncoding.map(String.init) ?? unread)")
    }
    let lhsPen = expected.pen, rhsPen = actual.pen
    if lhsPen.foreground != rhsPen.foreground || lhsPen.background != rhsPen.background || lhsPen.flags != rhsPen.flags
        || lhsPen.underline != rhsPen.underline || lhsPen.underlineColor != rhsPen.underlineColor {
        tally.add("pen", "\(lhsPen.dump) vs \(rhsPen.dump)")
    }
    if expected.kitty != actual.kitty { tally.add("kittyFlags", "\(expected.kitty) vs \(actual.kitty)") }
    guard history else { return tally }
    if expected.history.count != actual.history.count {
        tally.add("h.rowCount", "\(expected.history.count) vs \(actual.history.count) rows")
    }
    for back in 0..<min(expected.history.count, actual.history.count) {
        let lhsIndex = expected.history.count - 1 - back, rhsIndex = actual.history.count - 1 - back
        let lhsRow = expected.history[lhsIndex], rhsRow = actual.history[rhsIndex]
        for column in 0..<min(lhsRow.count, rhsRow.count) {
            compareCells(lhsRow[column], rhsRow[column], "history -\(back + 1) col \(column)", "h.", &tally)
        }
        if expected.historyWrap[lhsIndex] != actual.historyWrap[rhsIndex] { tally.add("h.softWrap", "history -\(back + 1)") }
    }
    return tally
}

// MARK: - libghostty reader

extension HandoverColor {
    init(_ color: GhosttyCellColor) {
        switch color {
        case .none: self = .standard
        case .palette(let index): self = .palette(index)
        case .rgb(let red, let green, let blue): self = .rgb(red, green, blue)
        }
    }
}

extension HandoverCell {
    /// A libghostty cell. Its flags are in libghostty's bit order, which puts italic before faint.
    init(_ cell: GhosttyGridCell) {
        self.init(style: cell.style)
        code = cell.scalars.first ?? 0
        more = cell.scalars.count > 1 ? Array(cell.scalars.dropFirst()) : nil
        switch cell.width {
        case .wide: width = 2
        case .spacerTail: width = 0
        // A spacer head is a blank narrow cell to a reader.
        case .narrow, .spacerHead: width = 1
        }
        link = cell.hyperlink
    }

    /// A pen, or the style half of a cell.
    init(style: GhosttyCellStyle) {
        foreground = HandoverColor(style.foreground)
        background = HandoverColor(style.background)
        underlineColor = HandoverColor(style.underlineColor)
        let pairs: [(UInt16, UInt8)] = [
            (GhosttyCellStyle.bold, HandoverFlag.bold), (GhosttyCellStyle.faint, HandoverFlag.dim),
            (GhosttyCellStyle.italic, HandoverFlag.italic), (GhosttyCellStyle.blink, HandoverFlag.blink),
            (GhosttyCellStyle.inverse, HandoverFlag.inverse), (GhosttyCellStyle.invisible, HandoverFlag.invisible),
            (GhosttyCellStyle.strikethrough, HandoverFlag.strike), (GhosttyCellStyle.overline, HandoverFlag.overline),
        ]
        flags = pairs.reduce(0) { style.flags & $1.0 != 0 ? $0 | $1.1 : $0 }
        underline = style.underline
    }
}

extension GhosttyTerminal {
    /// Everything the comparison reads, in one locked reading.
    func handoverSnap(history: Bool = true) -> HandoverSnap {
        withLocked { state in
            var snap = HandoverSnap()
            snap.cols = state.cols
            snap.rows = state.rows
            snap.alt = state.isAlternateScreen
            let blankRow = [HandoverCell](repeating: HandoverCell(), count: state.cols)
            for row in 0..<state.rows {
                let line = state.gridRow(.active, row, hyperlinks: true)
                snap.grid.append(line.map { $0.cells.map(HandoverCell.init) } ?? blankRow)
                snap.wrap.append(line?.isWrapContinuation ?? false)
            }
            if history {
                for row in 0..<state.historyRowCount {
                    let line = state.gridRow(.history, row, hyperlinks: true)
                    snap.history.append(line.map { $0.cells.map(HandoverCell.init) } ?? blankRow)
                    snap.historyWrap.append(line?.isWrapContinuation ?? false)
                }
            }
            let cursor = state.cursor
            snap.cursorX = cursor.col
            snap.cursorY = cursor.row
            snap.pending = state.cursorPendingWrap
            snap.cursorVisible = state.isCursorVisible
            var bits: [String: Bool] = [:]
            for mode in handoverComparedModes {
                let value = state.mode(UInt16(mode.value), ansi: !mode.decPrivate)
                if isMouseMode(mode) {
                    bits[mode.name] = value
                } else {
                    snap.modes[mode.name] = value
                }
            }
            snap.mouseModeBits = bits
            snap.mouseTracking = state.mouseTrackingInEffect
            snap.mouseEncoding = state.mouseEncodingInEffect
            (snap.top, snap.bottom, snap.left, snap.right) = Self.region(state)
            snap.pen = HandoverCell(style: state.cursorStyle)
            snap.kitty = Int(state.kittyKeyboardFlags)
            return snap
        }
    }

    /// The scrolling region has no getter, so it is read back from a formatter run that asks for
    /// that one extra. Its output ends with `CSI t;b r` when the region is not full height, then
    /// `CSI l;r s` when left and right margins are set, and it is parsed strictly from the end,
    /// because printed text can end in "r" or "s" too.
    private static func region(_ state: GhosttyTerminalState) -> (Int, Int, Int, Int) {
        var out = ((try? state.formattedVT(extras: GhosttyVTFormat.scrollingRegion, unwrap: false, trim: true)) ?? [])[...]
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
        if let region = takeTail(0x72) { (top, bottom) = region }
        return (top, bottom, left, right)
    }
}

// MARK: - SwiftTerm reader

extension HandoverColor {
    init(_ color: Attribute.Color?) {
        switch color {
        case .none, .some(.defaultColor), .some(.defaultInvertedColor): self = .standard
        case .some(.ansi256(let code)): self = .palette(code)
        case .some(.trueColor(let red, let green, let blue)): self = .rgb(red, green, blue)
        }
    }
}

extension HandoverCell {
    init(_ data: CharData) {
        self.init(attribute: data.attribute)
        let scalars = data.getCharacter().unicodeScalars
        code = scalars.first?.value ?? 0
        if scalars.count > 1 { more = scalars.dropFirst().map(\.value) }
        width = UInt8(max(0, data.width))
        // SwiftTerm keeps an OSC 8 link's whole body, "params;uri".
        if let payload = data.getPayload() as? String {
            link = payload.firstIndex(of: ";").map { String(payload[payload.index(after: $0)...]) } ?? payload
        }
    }

    /// A pen, or the style half of a cell.
    init(attribute: Attribute) {
        foreground = HandoverColor(attribute.fg)
        background = HandoverColor(attribute.bg)
        underlineColor = HandoverColor(attribute.underlineColor)
        let style = attribute.style
        let pairs: [(CharacterStyle, UInt8)] = [
            (.bold, HandoverFlag.bold), (.dim, HandoverFlag.dim), (.italic, HandoverFlag.italic),
            (.blink, HandoverFlag.blink), (.inverse, HandoverFlag.inverse), (.invisible, HandoverFlag.invisible),
            (.crossedOut, HandoverFlag.strike),
        ]
        flags = pairs.reduce(0) { style.contains($1.0) ? $0 | $1.1 : $0 }
        switch attribute.underlineStyle {
        case .none: underline = style.contains(.underline) ? 1 : 0
        case .single: underline = 1
        case .double: underline = 2
        case .curly: underline = 3
        case .dotted: underline = 4
        case .dashed: underline = 5
        }
    }
}

extension HandoverSwiftTerm {
    /// Everything the comparison reads, in one locked reading. The modes are read with DECRQM,
    /// which this fork answers for every compared mode. A mode it answers as unknown, or does not
    /// answer, is left out of `modes`, and the comparison counts it. For the mouse modes it
    /// answers with the one tracking mode and the one encoding in effect, so those fill
    /// `mouseTracking` and `mouseEncoding`, nil when one of their modes went unanswered.
    func handoverSnap(history: Bool = true) -> HandoverSnap {
        locked { terminal in
            var snap = HandoverSnap()
            snap.cols = terminal.cols
            snap.rows = terminal.rows
            for row in 0..<terminal.rows {
                guard let line = terminal.getLine(row: row) else {
                    snap.grid.append([HandoverCell](repeating: HandoverCell(), count: terminal.cols))
                    snap.wrap.append(false)
                    continue
                }
                snap.grid.append((0..<terminal.cols).map { HandoverCell(line[$0]) })
                snap.wrap.append(line.isWrapped)
            }
            if history {
                // Scroll-invariant rows count the trimmed ones, so the oldest kept row is the
                // first one not trimmed and the screen starts `yDisp` rows after it.
                let oldest = terminal.buffer.totalLinesTrimmed
                var row = oldest
                while row < oldest + terminal.buffer.yDisp, let line = terminal.getScrollInvariantLine(row: row) {
                    snap.history.append((0..<min(terminal.cols, line.count)).map { HandoverCell(line[$0]) })
                    snap.historyWrap.append(line.isWrapped)
                    row += 1
                }
            }
            // SwiftTerm marks a pending wrap by putting the cursor one past the last column.
            snap.cursorX = min(terminal.buffer.x, terminal.cols - 1)
            snap.cursorY = terminal.buffer.y
            snap.pending = terminal.buffer.x >= terminal.cols
            snap.alt = terminal.isCurrentBufferAlternate
            // The mouse mode in effect after one more answer: nil once any of them went unanswered.
            func inEffect(_ current: Int?, _ value: Int, _ isSet: Bool?) -> Int? {
                guard let current, let isSet else { return nil }
                return isSet ? value : current
            }
            var tracking: Int? = 0, encoding: Int? = 0
            for mode in handoverComparedModes {
                let answer = collector.requestMode(mode.value, decPrivate: mode.decPrivate)
                let isSet: Bool? = answer == 1 ? true : answer == 2 ? false : nil
                if mode.decPrivate, handoverMouseTrackingModes.contains(mode.value) {
                    tracking = inEffect(tracking, mode.value, isSet)
                } else if mode.decPrivate, handoverMouseEncodingModes.contains(mode.value) {
                    encoding = inEffect(encoding, mode.value, isSet)
                } else if let isSet {
                    snap.modes[mode.name] = isSet
                }
            }
            snap.mouseTracking = tracking
            snap.mouseEncoding = encoding
            snap.cursorVisible = snap.modes["DECTCEM"] ?? true
            snap.top = terminal.buffer.scrollTop
            snap.bottom = terminal.buffer.scrollBottom
            snap.left = terminal.buffer.marginLeft
            snap.right = terminal.buffer.marginRight
            snap.pen = HandoverCell(attribute: terminal.currentAttribute)
            snap.kitty = terminal.keyboardEnhancementFlags.rawValue
            return snap
        }
    }
}
