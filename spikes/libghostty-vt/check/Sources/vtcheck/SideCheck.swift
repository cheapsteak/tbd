// `sidecheck`: repeats the screen check in side-terminal-bench against TBD's fork, then
// repeats it with one change, to find out why it reports 0/60 on the unicode workload.
//
// The row-building loop is adapted from VTBench/Sources/VTBench/main.swift in
// gazishahi/side-terminal-bench (Apache-2.0), commit f94797090bac3d9e7585dbf1756d6684a18376da.
// See third_party/side-terminal-bench/LICENSE and NOTICE.
import Foundation
import GhosttyVt
import SwiftTerm

extension GTerm {
    /// The whole terminal as plain text, as the source benchmark reads it.
    func plain() -> String {
        var f: GhosttyFormatter?
        precondition(ghostty_formatter_terminal_new(nil, &f, t) == GHOSTTY_SUCCESS)
        defer { ghostty_formatter_free(f) }
        var emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_EMIT, &emit)
        var trim = true
        ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_TRIM, &trim)
        var ptr: UnsafeMutablePointer<UInt8>?, len = 0
        precondition(ghostty_formatter_format_alloc(f, nil, &ptr, &len) == GHOSTTY_SUCCESS)
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }
}

private func swiftTermRows(_ s: STerm, skipWideTail: Bool) -> [String] {
    s.t.terminalLock.withLock {
        var lines: [String] = []
        for y in 0..<s.t.rows {
            var line = ""
            for x in 0..<s.t.cols {
                if skipWideTail, let d = s.t.getCharData(col: x, row: y), d.width == 0 { continue }
                let c = s.t.getCharacter(col: x, row: y) ?? " "
                line += c == "\0" ? " " : String(c)
            }
            while line.last == " " { line.removeLast() }
            lines.append(line)
        }
        while lines.last == "" { lines.removeLast() }
        return lines
    }
}

private func matchingRows(_ a: [String], _ g: String) -> (same: Int, of: Int) {
    let bl = g.split(separator: "\n", omittingEmptySubsequences: false).suffix(a.count).map(String.init)
    return (zip(a, bl).filter { $0 == $1 }.count, max(a.count, bl.count))
}

func runSideCheck(arguments: [String]) {
    let cols = 200, rows = 60, scrollback = 10_000
    print("first 1 MiB of each workload, fed at once, grid \(cols)x\(rows), as the source benchmark does\n")
    print(padR("workload", 12) + padL("as written", 12) + padL("no wide tail", 14) + padL("2027 off", 12))
    var out: [[String: Any]] = []
    for w in loadWorkloads(["ascii", "colors", "unicode", "cursor", "tui", "scroll"]) {
        let data = Array(w.bytes.prefix(1 << 20))
        let s = STerm(cols: cols, rows: rows, scrollback: scrollback)
        let g = GTerm(cols: cols, rows: rows, scrollback: scrollback, grapheme: true)
        let off = GTerm(cols: cols, rows: rows, scrollback: scrollback, grapheme: false)
        s.feed(data); g.feed(data); off.feed(data)
        let a = swiftTermRows(s, skipWideTail: false), b = swiftTermRows(s, skipWideTail: true)
        let r1 = matchingRows(a, g.plain()), r2 = matchingRows(b, g.plain()), r3 = matchingRows(b, off.plain())
        print(padR(w.name, 12) + padL("\(r1.same)/\(r1.of)", 12) + padL("\(r2.same)/\(r2.of)", 14) + padL("\(r3.same)/\(r3.of)", 12))
        out.append(["workload": w.name, "asWritten": r1.same, "noWideTail": r2.same, "grapheme2027Off": r3.same, "rows": r1.of])
        if w.name == "unicode" {
            let bl = g.plain().split(separator: "\n", omittingEmptySubsequences: false).suffix(b.count).map(String.init)
            if let (x, y) = zip(b, bl).first(where: { $0 != $1 }) {
                let i = zip(x, y).prefix(while: { $0 == $1 }).count
                print("  first remaining mismatch at character \(i):")
                print("    S \(escaped(Array(String(x.dropFirst(max(0, i - 3)).prefix(10)).utf8)))")
                print("    G \(escaped(Array(String(y.dropFirst(max(0, i - 3)).prefix(10)).utf8)))")
            }
        }
    }
    writeJSON("sidecheck.json", ["rows": out])
}
