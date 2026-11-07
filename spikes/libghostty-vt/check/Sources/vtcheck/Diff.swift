// `diff`: same bytes through both engines, compared at checkpoints and at the end.
import Foundation

protocol Term: AnyObject {
    func feed(_ b: [UInt8])
    func snap(history: Bool) -> Snap
}
extension STerm: Term {}
extension GTerm: Term {}

/// Splits a stream into units that must not be cut: one escape sequence, one
/// UTF-8 scalar, or one control byte.
func tokenize(_ b: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
    var out: [ArraySlice<UInt8>] = []
    var i = b.startIndex
    let end = b.endIndex
    while i < end {
        let c = b[i]
        var j = i + 1
        if c == 0x1b, j < end {
            let k = b[j]
            if k == UInt8(ascii: "[") {
                j += 1
                while j < end, !(0x40...0x7e).contains(b[j]) { j += 1 }
                j = min(j + 1, end)
            } else if k == UInt8(ascii: "]") || k == UInt8(ascii: "P") || k == UInt8(ascii: "_") {
                j += 1
                while j < end {
                    if b[j] == 0x07 { j += 1; break }
                    if b[j] == 0x1b, j + 1 < end, b[j + 1] == UInt8(ascii: "\\") { j += 2; break }
                    j += 1
                }
            } else if (0x20...0x2f).contains(k) {
                j += 1
                while j < end, (0x20...0x2f).contains(b[j]) { j += 1 }
                j = min(j + 1, end)
            } else { j += 1 }
        } else if c >= 0xC0 {
            while j < end, b[j] & 0xC0 == 0x80 { j += 1 }
        }
        out.append(b[i..<j])
        i = j
    }
    return out
}

private func differs(_ bytes: [UInt8], cols: Int, rows: Int, cat: String) -> Bool {
    let s = STerm(cols: cols, rows: rows, scrollback: 2000)
    let g = GTerm(cols: cols, rows: rows, scrollback: 2000)
    s.feed(bytes); g.feed(bytes)
    let hist = cat.hasPrefix("h.")
    return compare(s.snap(history: hist), g.snap(history: hist), history: hist).counts[cat] != nil
}

/// Shrinks a stream to a short one that still shows `cat`. The result is always
/// verified, and the search stops at a wall-clock budget so a big stream cannot stall it.
func minimize(prefix: ArraySlice<UInt8>, cols: Int, rows: Int, cat: String, budget: Double = 25) -> [UInt8]? {
    let deadline = Date().addingTimeInterval(budget)
    let toks = tokenize(prefix)
    func join<C: Collection>(_ t: C) -> [UInt8] where C.Element == ArraySlice<UInt8> {
        var out = [UInt8]()
        for s in t { out.append(contentsOf: s) }
        return out
    }
    guard differs(join(toks), cols: cols, rows: rows, cat: cat) else { return nil }
    var lo = 0, hi = toks.count
    while hi - lo > 1, Date() < deadline {
        let mid = (lo + hi) / 2
        if differs(join(toks[0..<mid]), cols: cols, rows: rows, cat: cat) { hi = mid } else { lo = mid }
    }
    var cur = Array(toks[0..<hi])
    var k = 1
    while k < hi, Date() < deadline {
        let tail = Array(toks[(hi - k)..<hi])
        if differs(join(tail), cols: cols, rows: rows, cat: cat) { cur = tail; break }
        k *= 2
    }
    var chunk = max(1, cur.count / 2)
    while Date() < deadline {
        var removed = false, i = 0
        while i < cur.count, Date() < deadline {
            var cand = cur
            cand.removeSubrange(i..<min(i + chunk, cur.count))
            if !cand.isEmpty, differs(join(cand), cols: cols, rows: rows, cat: cat) { cur = cand; removed = true } else { i += chunk }
        }
        if chunk == 1 && !removed { break }
        chunk = max(1, chunk / 2)
    }
    return join(cur)
}

func runDiff(arguments: [String]) {
    let small = arguments.contains("--small")
    noGrapheme = arguments.contains("--no-grapheme")
    let names = arguments.filter { !$0.hasPrefix("--") }
    let filter: Set<String>? = names.isEmpty ? nil : Set(names)
    // Small streams first, so a category's reproducer comes from the smallest place it shows.
    var list = stateScenarios().filter { filter?.contains($0.name) ?? true }
    let loaded = loadWorkloads(filter)
    list += loaded.filter { $0.name.hasPrefix("rec-") }
    if !small { list += loaded.filter { !$0.name.hasPrefix("rec-") } }
    let scrollback = 10_000, checkpoints = 32
    var total = Tally()
    var perWorkload: [String: [String: Int]] = [:]
    var firstSeen: [String: (name: String, end: Int, cols: Int, rows: Int, bytes: [UInt8])] = [:]
    var checkpointsDone = 0
    print("scrollback \(scrollback) lines on both, byte limit lifted, mode 2027 \(noGrapheme ? "OFF" : "on") in libghostty-vt")
    print("up to \(checkpoints) checkpoints per stream, each at parser ground; history compared at the end only\n")
    for w in list {
        let s = STerm(cols: w.cols, rows: w.rows, scrollback: scrollback)
        let g = GTerm(cols: w.cols, rows: w.rows, scrollback: scrollback)
        var mine = Tally()
        let n = w.bytes.count < 4096 ? 1 : checkpoints
        let step = max(1, w.bytes.count / n)
        var off = 0
        for i in 1...n {
            let target = max(off, i == n ? w.bytes.count : i * step)
            g.feed(w.bytes[off..<target])
            let more = target < w.bytes.count ? g.feedToGround(w.bytes[target...]) : 0
            let end = target + more
            s.feed(w.bytes[off..<end])
            off = end
            let last = i == n
            let t = compare(s.snap(history: last), g.snap(history: last), history: last)
            checkpointsDone += 1
            for cat in t.counts.keys where firstSeen[cat] == nil {
                firstSeen[cat] = (w.name, end, w.cols, w.rows, w.bytes)
            }
            mine.merge(t, prefixExample: "\(w.name)@\(end): ")
        }
        total.merge(mine)
        perWorkload[w.name] = mine.counts
        let visible = mine.counts.keys.filter { !cosmeticCategories.contains($0) }.sorted()
        print("\(padR(w.name, 34)) \(padL(String(w.bytes.count), 9)) bytes  " + (visible.isEmpty ? "no visible difference" : visible.map { "\($0)=\(mine.counts[$0]!)" }.joined(separator: " ")))
    }
    print("\n\(checkpointsDone) checkpoints. Totals by category (cells or occurrences), with a minimized reproducer:\n")
    var report: [[String: Any]] = []
    for cat in total.counts.keys.sorted() {
        let seen = firstSeen[cat]!
        let repro = minimize(prefix: seen.bytes[0..<seen.end], cols: seen.cols, rows: seen.rows, cat: cat)
        print("\(cat): \(total.counts[cat]!)\(cosmeticCategories.contains(cat) ? "  (no visible effect)" : "")")
        print("  first in \(seen.name), grid \(seen.cols)x\(seen.rows)")
        print("  example  \((total.examples[cat] ?? "").prefix(300))")
        print("  repro    \(repro.map { String(escaped($0).prefix(400)) } ?? "did not reproduce from a fresh start")")
        var detail = ""
        if let repro {
            let hist = cat.hasPrefix("h.")
            let s = STerm(cols: seen.cols, rows: seen.rows, scrollback: 2000), g = GTerm(cols: seen.cols, rows: seen.rows, scrollback: 2000)
            s.feed(repro); g.feed(repro)
            detail = compare(s.snap(history: hist), g.snap(history: hist), history: hist).examples[cat] ?? ""
            print("  repro shows  \(detail.prefix(300))")
        }
        report.append(["category": cat, "count": total.counts[cat]!, "firstIn": seen.name, "example": total.examples[cat] ?? "",
                       "reproducer": repro.map(escaped) ?? "", "reproducerShows": detail,
                       "cosmetic": cosmeticCategories.contains(cat)])
    }
    writeJSON("diff.json", ["categories": report, "perWorkload": perWorkload, "checkpoints": checkpointsDone])
}

/// `show <scenario | workload@offset | escaped bytes>`: one state, both engines, every direction.
func runShow(arguments: [String]) {
    guard let key = arguments.first else { return }
    let expanded = key.replacingOccurrences(of: "\\e", with: "\u{1b}").replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\n", with: "\n")
    var w = Workload(name: "arg", bytes: Array(expanded.utf8), cols: 80, rows: 24)
    if let found = stateScenarios().first(where: { $0.name == key }) { w = found }
    let parts = key.split(separator: "@")
    if parts.count == 2, let off = Int(parts[1]), let found = loadWorkloads([String(parts[0])]).first {
        w = Workload(name: key, bytes: Array(found.bytes[0..<off]), cols: found.cols, rows: found.rows)
    }
    let sb = 5000
    let s = STerm(cols: w.cols, rows: w.rows, scrollback: sb), g = GTerm(cols: w.cols, rows: w.rows, scrollback: sb)
    s.feed(w.bytes); g.feed(w.bytes)
    let sA = s.snap(history: true), gA = g.snap(history: true)
    let wb = s.writerBytes(maxLines: sb), fb = g.vt(extras: GX_HANDOVER, unwrap: true, trim: false)
    print("cursor S \(sA.cx),\(sA.cy) pending \(sA.pending) G \(gA.cx),\(gA.cy) pending \(gA.pending); hist S \(sA.hist.count) G \(gA.hist.count); alt \(sA.alt) \(gA.alt)")
    print("writer    \(String(escaped(wb).suffix(900)))")
    print("formatter \(String(escaped(fb).suffix(900)))")
    func show(_ label: String, _ a: Snap, _ b: Snap) {
        let t = compare(a, b)
        print("\n\(label): " + (t.isEmpty ? "identical" : ""))
        for (k, v) in t.counts.sorted(by: { $0.key < $1.key }) { print("  \(padR(k, 18)) \(padL(String(v), 6))  \((t.examples[k] ?? "").prefix(190))") }
    }
    let rs = STerm(cols: w.cols, rows: w.rows, scrollback: sb); rs.feed(wb)
    let rg = GTerm(cols: w.cols, rows: w.rows, scrollback: sb); rg.feed(wb)
    let gs = STerm(cols: w.cols, rows: w.rows, scrollback: sb); gs.feed(fb)
    let gg = GTerm(cols: w.cols, rows: w.rows, scrollback: sb); gg.feed(fb)
    show("engine (S vs G)", sA, gA)
    show("S>S", sA, rs.snap(history: true))
    show("S>G vs S source", sA, rg.snap(history: true))
    show("G>S vs G source", gA, gs.snap(history: true))
    show("G>G", gA, gg.snap(history: true))
}
