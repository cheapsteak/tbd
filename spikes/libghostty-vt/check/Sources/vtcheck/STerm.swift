// SwiftTerm side: TBD's fork, driven the way HolderEmulator drives it. Every
// read and every feed sits inside terminalLock, and replies go to a collector.
import Foundation
import SwiftTerm
import TBDTerminalSerialization

final class SDelegate: TerminalDelegate, ModeReplyReader {
    var replies: [UInt8] = []
    var events: [String] = []
    weak var terminal: Terminal?

    func send(source: Terminal, data: ArraySlice<UInt8>) { replies.append(contentsOf: data) }

    /// Same shape as the ReplyCollector in TBD's round-trip tests, and as
    /// DelegateModeReader in HolderReader.swift.
    func requestMode(_ mode: Int, decPrivate: Bool) -> Int? {
        guard let terminal else { return nil }
        let saved = replies
        defer { replies = saved }
        replies.removeAll()
        let prefix = decPrivate ? "?" : ""
        terminal.feed(text: "\u{1b}[\(prefix)\(mode)$p")
        let reply = String(bytes: replies, encoding: .utf8) ?? ""
        guard let head = reply.range(of: "\(prefix)\(mode);"),
              let tail = reply[head.upperBound...].range(of: "$y") else { return nil }
        return Int(reply[head.upperBound..<tail.lowerBound])
    }

    func setTerminalTitle(source: Terminal, title: String) { events.append("title(\(title))") }
    func setTerminalIconTitle(source: Terminal, title: String) { events.append("iconTitle(\(title))") }
    func bell(source: Terminal) { events.append("bell") }
    func notify(source: Terminal, title: String, body: String) { events.append("notify(\(title)|\(body))") }
    func clipboardCopy(source: Terminal, content: Data) { events.append("clipboardCopy(\(String(decoding: content, as: UTF8.self)))") }
    func clipboardRead(source: Terminal) -> Data? { events.append("clipboardRead"); return Data("clip".utf8) }
    func hostCurrentDirectoryUpdated(source: Terminal) { events.append("pwd(\(source.hostCurrentDirectory ?? "nil"))") }
    func hostCurrentDocumentUpdated(source: Terminal) { events.append("doc(\(source.hostCurrentDocument ?? "nil"))") }
    func progressReport(source: Terminal, report: Terminal.ProgressReport) { events.append("progress(\(report))") }
    func mouseModeChanged(source: Terminal) { events.append("mouseMode(\(source.mouseMode))") }
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) { events.append("cursorStyle(\(newStyle.tagName))") }
    func synchronizedOutputChanged(source: Terminal, active: Bool) { events.append("sync(\(active))") }
    func colorChanged(source: Terminal, idx: Int?) { events.append("colorChanged(\(idx.map(String.init) ?? "nil"))") }
    func showCursor(source: Terminal) { events.append("showCursor") }
    func hideCursor(source: Terminal) { events.append("hideCursor") }
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        events.append("windowCommand(\(command))"); return nil
    }
    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { (8, 16) }
}

private func col(_ c: Attribute.Color?) -> Col {
    switch c {
    case .none, .some(.defaultColor), .some(.defaultInvertedColor): return .def
    case .some(.ansi256(let n)): return .pal(n)
    case .some(.trueColor(let r, let g, let b)): return .rgb(r, g, b)
    }
}

private func style(_ a: Attribute, into c: inout Cell) {
    c.fg = col(a.fg); c.bg = col(a.bg); c.ul = col(a.underlineColor)
    var f: UInt8 = 0
    let s = a.style
    if s.contains(.bold) { f |= Flag.bold }
    if s.contains(.dim) { f |= Flag.dim }
    if s.contains(.italic) { f |= Flag.italic }
    if s.contains(.blink) { f |= Flag.blink }
    if s.contains(.inverse) { f |= Flag.inverse }
    if s.contains(.invisible) { f |= Flag.invisible }
    if s.contains(.crossedOut) { f |= Flag.strike }
    c.flags = f
    switch a.underlineStyle {
    case .none: c.underline = s.contains(.underline) ? 1 : 0
    case .single: c.underline = 1
    case .double: c.underline = 2
    case .curly: c.underline = 3
    case .dotted: c.underline = 4
    case .dashed: c.underline = 5
    }
}

private func cell(_ d: CharData) -> Cell {
    var c = Cell()
    let scalars = d.getCharacter().unicodeScalars
    c.cp = scalars.first?.value ?? 0
    if scalars.count > 1 { c.more = scalars.dropFirst().map(\.value) }
    c.width = UInt8(max(0, d.width))
    style(d.attribute, into: &c)
    if d.hasPayload, let p = d.getPayload() as? String {
        // SwiftTerm stores the raw OSC 8 body, "params;uri".
        c.link = p.firstIndex(of: ";").map { String(p[p.index(after: $0)...]) } ?? p
    }
    return c
}

final class STerm {
    let del = SDelegate()
    let t: Terminal
    init(cols: Int, rows: Int, scrollback: Int) {
        t = Terminal(delegate: del, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback))
        del.terminal = t
    }
    func feed(_ b: ArraySlice<UInt8>) { t.terminalLock.withLock { t.feed(buffer: b) } }
    func feed(_ b: [UInt8]) { feed(b[...]) }

    /// TBD's handover writer, called the way HolderEmulator.snapshotPreamble calls it.
    func writerBytes(maxLines: Int) -> [UInt8] {
        t.terminalLock.withLock {
            [UInt8](TerminalSnapshotWriter.snapshot(of: t, reply: del, maxScrollbackLines: maxLines))
        }
    }

    func snap(history: Bool = true) -> Snap {
        t.terminalLock.withLock {
            var s = Snap()
            s.cols = t.cols; s.rows = t.rows
            s.grid.reserveCapacity(t.rows)
            for y in 0..<t.rows {
                let line = t.getLine(row: y)!
                var row = [Cell](); row.reserveCapacity(t.cols)
                for x in 0..<t.cols { row.append(cell(line[x])) }
                s.grid.append(row)
                s.wrap.append(line.isWrapped)
            }
            if history {
                let first = t.buffer.totalLinesTrimmed, end = first + t.buffer.yDisp
                s.hist.reserveCapacity(end - first)
                var r = first
                while r < end, let line = t.getScrollInvariantLine(row: r) {
                    var row = [Cell](); row.reserveCapacity(t.cols)
                    for x in 0..<min(t.cols, line.count) { row.append(cell(line[x])) }
                    s.hist.append(row)
                    s.histWrap.append(line.isWrapped)
                    r += 1
                }
            }
            s.cx = min(t.buffer.x, t.cols - 1); s.cy = t.buffer.y
            s.pending = t.buffer.x >= t.cols
            s.alt = t.isCurrentBufferAlternate
            for m in comparedModes {
                if let r = del.requestMode(m.n, decPrivate: m.dec), r == 1 || r == 2 { s.modes[m.name] = r == 1 }
            }
            s.modes["DECCKM"] = t.applicationCursor
            s.cursorVisible = s.modes["DECTCEM"] ?? true
            s.top = t.buffer.scrollTop; s.bottom = t.buffer.scrollBottom
            s.left = t.buffer.marginLeft; s.right = t.buffer.marginRight
            style(t.currentAttribute, into: &s.pen)
            s.kitty = t.keyboardEnhancementFlags.rawValue
            return s
        }
    }
}
