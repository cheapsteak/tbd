// `handover`: round trips between emulators, using TBD's real TerminalSnapshotWriter.
import Foundation
import GhosttyVt

private let screenCats: Set<String> = ["text", "wide", "fg", "bg", "attrs", "ulColor", "link", "cursorPos", "activeScreen"]

/// The formatter on its own. On an alternate screen it covers only that screen.
private func formatterBare(_ g: GTerm) -> [UInt8] { g.vt(extras: GX_HANDOVER, unwrap: true, trim: false) }

/// What a writer would have to do on an alternate screen: the primary is reached
/// through a snapshot clone, so the live terminal is never toggled.
private func formatterComposed(_ g: GTerm, alt: Bool) -> [UInt8] {
    guard alt else { return formatterBare(g) }
    let c = g.clone()
    c.feed(Array("\u{1b}[?1049l".utf8))
    // Cursor, pen, protection and charsets are what ?1049h saves for the matching ?1049l.
    let saved: UInt32 = (1 << 6) | (1 << 7) | (1 << 9) | (1 << 11)
    return c.vt(extras: saved, unwrap: true, trim: false) + formatterBare(g)
}

struct HCase {
    let name: String, workload: String
    let bytes: ArraySlice<UInt8>
    let cols: Int, rows: Int
    let streamProbe: [UInt8]?
}

struct HResult {
    var name = ""
    var tags: Set<String> = []
    var tallies: [String: Tally] = [:]     // key: comparison name
    var sizes: [String: Int] = [:]
    var times: [String: Double] = [:]
}

private func tags(of a: Snap) -> Set<String> {
    var t: Set<String> = [a.alt ? "alt" : "primary"]
    if a.top != 0 || a.bottom != a.rows - 1 { t.insert("region") }
    if a.left != 0 || a.right != a.cols - 1 { t.insert("lrMargins") }
    if ["mouse1000", "mouse1002", "mouse1003"].contains(where: { a.modes[$0] == true }) { t.insert("mouse") }
    if a.modes["bracketedPaste"] == true { t.insert("bracketedPaste") }
    if a.wrap.contains(true) || a.histWrap.contains(true) { t.insert("softWrap") }
    if a.pending { t.insert("pendingWrap") }
    if !a.hist.isEmpty { t.insert("scrollback") }
    for y in 1..<a.rows where a.wrap[y] && a.grid[y][0].width == 2 && a.grid[y - 1][a.cols - 1].isBlank { t.insert("wideAtEdge") }
    if a.grid.contains(where: { $0.contains { $0.width == 2 } }) { t.insert("wide") }
    return t
}

private func timed<T>(_ r: inout Double, _ f: () -> T) -> T {
    let t0 = DispatchTime.now().uptimeNanoseconds
    let v = f()
    r = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    return v
}

private func runCase(_ c: HCase, scrollback: Int) -> HResult {
    var res = HResult()
    res.name = c.name
    let prefix = Array(c.bytes)
    func directS() -> STerm { let t = STerm(cols: c.cols, rows: c.rows, scrollback: scrollback); t.feed(prefix); return t }
    func directG() -> GTerm { let t = GTerm(cols: c.cols, rows: c.rows, scrollback: scrollback); t.feed(prefix); return t }
    func freshS(_ b: [UInt8]) -> STerm { let t = STerm(cols: c.cols, rows: c.rows, scrollback: scrollback); t.feed(b); return t }
    func freshG(_ b: [UInt8]) -> GTerm { let t = GTerm(cols: c.cols, rows: c.rows, scrollback: scrollback); t.feed(b); return t }

    let sSource = directS()
    let sA = sSource.snap(history: true)
    res.tags = tags(of: sA)
    var ms = 0.0
    let sBytes = timed(&ms) { sSource.writerBytes(maxLines: scrollback) }
    res.sizes["writer"] = sBytes.count; res.times["writer"] = ms
    res.tallies["writerDamage"] = compare(sA, sSource.snap(history: true))

    let gSource = directG()
    let gA = gSource.snap(history: true)
    let gBytes = timed(&ms) { formatterBare(gSource) }
    res.sizes["formatter"] = gBytes.count; res.times["formatter"] = ms
    let gComposed = formatterComposed(gSource, alt: gA.alt)
    let gBin = timed(&ms) { gSource.encodeSnapshot() }
    res.sizes["snapshot"] = gBin.count; res.times["snapshotEncode"] = ms

    res.tallies["engine"] = compare(sA, gA)

    // "vsSource" compares with the source engine's state. "vsDirect" compares with
    // what the receiving engine holds had it read the raw stream itself.
    let rSS = freshS(sBytes)
    let rSG = timed(&ms) { freshG(sBytes) }
    res.times["writerReplayIntoG"] = ms
    let rGS = freshS(gBytes), rGG = freshG(gBytes)
    let rGScomp = freshS(gComposed), rGGcomp = freshG(gComposed)
    let rBin = timed(&ms) { GTerm.decodeSnapshot(gBin, cols: c.cols, rows: c.rows) }
    res.times["snapshotDecode"] = ms

    let snapSG = rSG.snap(history: true), snapSS = rSS.snap(history: true), snapGS = rGS.snap(history: true)
    res.tallies["S>S"] = compare(sA, snapSS)
    res.tallies["S>G vsSource"] = compare(sA, snapSG)
    res.tallies["S>G vsDirect"] = compare(gA, snapSG)
    res.tallies["S>G vs S>S result"] = compare(snapSS, snapSG)
    res.tallies["G>S vsSource"] = compare(gA, snapGS)
    res.tallies["G>S vsDirect"] = compare(sA, snapGS)
    res.tallies["G>S.composed vsSource"] = compare(gA, rGScomp.snap(history: true))
    res.tallies["G>G.vt"] = compare(gA, rGG.snap(history: true))
    res.tallies["G>G.composed"] = compare(gA, rGGcomp.snap(history: true))
    res.tallies["G>G.bin"] = compare(gA, rBin.snap(history: true))

    // Reused receivers: the same preamble, into a viewer that was already in use.
    for u in usedReceivers {
        let g = GTerm(cols: c.cols, rows: c.rows, scrollback: scrollback)
        g.feed(u.bytes); g.feed(sBytes)
        res.tallies["S>G used:\(u.name)"] = compare(snapSG, g.snap(history: true))
        let s = STerm(cols: c.cols, rows: c.rows, scrollback: scrollback)
        s.feed(u.bytes); s.feed(sBytes)
        res.tallies["S>S used:\(u.name)"] = compare(snapSS, s.snap(history: true))
        // The same, with a full reset ahead of the preamble.
        let ris = Array("\u{1b}c".utf8)
        let g2 = GTerm(cols: c.cols, rows: c.rows, scrollback: scrollback)
        g2.feed(u.bytes); g2.feed(ris); g2.feed(sBytes)
        res.tallies["S>G used+RIS:\(u.name)"] = compare(snapSG, g2.snap(history: true))
        let s2 = STerm(cols: c.cols, rows: c.rows, scrollback: scrollback)
        s2.feed(u.bytes); s2.feed(ris); s2.feed(sBytes)
        res.tallies["S>S used+RIS:\(u.name)"] = compare(snapSS, s2.snap(history: true))
    }

    // Probes: the receiver and a terminal of the same engine that read the raw
    // stream get the same further bytes. Only handover loss can separate them.
    var allProbes = probes(rows: c.rows)
    if !sA.alt { allProbes.removeAll { $0.name == "leaveAlt" } }   // leaving an alt screen that was never entered
    if let p = c.streamProbe { allProbes.append(("stream", p)) }
    let dirs: [(String, () -> Term, () -> Term)] = [
        ("S>S", { freshS(sBytes) }, { directS() }),
        ("S>G", { freshG(sBytes) }, { directG() }),
        ("G>S", { freshS(gComposed) }, { directS() }),
        ("G>G.vt", { freshG(gComposed) }, { directG() }),
        ("G>S.bare", { freshS(gBytes) }, { directS() }),
        ("G>G.bare", { freshG(gBytes) }, { directG() }),
        ("G>G.bin", { GTerm.decodeSnapshot(gBin, cols: c.cols, rows: c.rows) }, { directG() }),
    ]
    for (dir, make, reference) in dirs {
        for p in allProbes {
            let r = make(), d = reference()
            r.feed(p.bytes); d.feed(p.bytes)
            // Leaving an alt screen is the one probe that shows the primary's scrollback.
            let hist = p.name == "leaveAlt"
            res.tallies["probe.\(p.name) \(dir)"] = compare(d.snap(history: hist), r.snap(history: hist), history: hist)
        }
    }
    return res
}

private func buildCases() -> [HCase] {
    var cases: [HCase] = []
    for s in stateScenarios() {
        cases.append(HCase(name: s.name, workload: "scenario", bytes: s.bytes[...], cols: s.cols, rows: s.rows, streamProbe: nil))
    }
    for w in loadWorkloads() {
        let real = w.name.hasPrefix("rec-")
        let limit = real ? w.bytes.count : min(w.bytes.count, 1_000_000)
        let n = real ? 24 : 6
        let finder = GTerm(cols: w.cols, rows: w.rows, scrollback: 100)
        var off = 0
        for i in 1...n {
            let target = max(off, limit * i / n)
            finder.feed(w.bytes[off..<target])
            let more = target < w.bytes.count ? finder.feedToGround(w.bytes[target...]) : 0
            off = target + more
            let end = off
            var probeEnd = end
            if end < w.bytes.count {
                let wanted = min(end + 64 * 1024, w.bytes.count)
                // The continuation must end at ground too, so it is cut by a parser
                // that has read the whole prefix.
                let g = GTerm(cols: w.cols, rows: w.rows, scrollback: 100)
                g.feed(w.bytes[0..<wanted])
                probeEnd = wanted + (wanted < w.bytes.count ? g.feedToGround(w.bytes[wanted...]) : 0)
            }
            cases.append(HCase(name: "\(w.name)@\(end)", workload: w.name, bytes: w.bytes[0..<end], cols: w.cols, rows: w.rows,
                               streamProbe: probeEnd > end ? Array(w.bytes[end..<probeEnd]) : nil))
        }
    }
    return cases
}

func runHandover(arguments: [String]) {
    let scrollback = 5_000   // HolderReader.scrollbackLines and HolderHandback.handbackScrollbackLines
    var cases = buildCases()
    if let f = arguments.first { cases = cases.filter { $0.name.contains(f) } }
    print("\(cases.count) states, scrollback \(scrollback) (TBD's value), maxScrollbackLines \(scrollback)")
    let lock = NSLock()
    var results: [HResult] = []
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 4
    for c in cases {
        q.addOperation {
            let r = runCase(c, scrollback: scrollback)
            lock.lock(); results.append(r); lock.unlock()
        }
    }
    q.waitUntilAllOperationsAreFinished()
    results.sort { $0.name < $1.name }

    var keys = Set<String>()
    for r in results { keys.formUnion(r.tallies.keys) }
    var json: [String: Any] = [:]
    func summarize(_ key: String) {
        var perCat: [String: (states: Int, cells: Int, first: String, example: String)] = [:]
        var clean = 0, visibleClean = 0
        for r in results {
            guard let t = r.tallies[key] else { continue }
            if t.isEmpty { clean += 1 }
            if t.counts.keys.allSatisfy({ cosmeticCategories.contains($0) }) { visibleClean += 1 }
            for (cat, n) in t.counts {
                var e = perCat[cat] ?? (0, 0, r.name, t.examples[cat] ?? "")
                e.states += 1; e.cells += n
                perCat[cat] = e
            }
        }
        let total = results.filter { $0.tallies[key] != nil }.count
        print("\n\(key): \(clean)/\(total) states identical, \(visibleClean)/\(total) with no visible-category difference")
        for (cat, e) in perCat.sorted(by: { $0.value.states > $1.value.states }) {
            print("  \(padR(cat, 24)) \(padL(String(e.states), 4)) states \(padL(String(e.cells), 9)) items   e.g. \(e.first): \(e.example.prefix(170))")
        }
        var cats: [String: Any] = [:]
        for (k, e) in perCat { cats[k] = ["states": e.states, "items": e.cells, "firstState": e.first, "example": e.example] }
        json[key] = ["total": total, "identical": clean, "visibleIdentical": visibleClean, "categories": cats]
    }
    for key in ["engine", "S>S", "S>G vsSource", "S>G vsDirect", "G>S vsSource", "G>S vsDirect", "G>S.composed vsSource",
                "G>G.vt", "G>G.composed", "G>G.bin", "writerDamage",
                "S>G vs S>S result", "S>S used:vim-like", "S>G used:vim-like", "S>S used:everything", "S>G used:everything",
                "S>S used+RIS:vim-like", "S>G used+RIS:vim-like", "S>S used+RIS:everything", "S>G used+RIS:everything"] { summarize(key) }
    for key in keys.filter({ $0.hasPrefix("probe.") }).sorted() { summarize(key) }

    // Categories S>G adds that neither the S>S control nor the raw engines already show.
    print("\nS>G differences new to the crossing (not in the S>S control and not in the engine baseline for that state):")
    var novel: [String: [String]] = [:]
    for r in results {
        guard let sg = r.tallies["S>G vsSource"], let ss = r.tallies["S>S"], let en = r.tallies["engine"] else { continue }
        for cat in sg.counts.keys where ss.counts[cat] == nil && en.counts[cat] == nil { novel[cat, default: []].append(r.name) }
    }
    for (cat, names) in novel.sorted(by: { $0.key < $1.key }) { print("  \(cat): \(names.count) states: \(names.prefix(8).joined(separator: ", "))") }
    if novel.isEmpty { print("  none") }
    json["novelSG"] = novel

    // Per-tag pass rates, for the states the brief names.
    print("\nStates by tag: how many have a matching screen and cursor (cosmetic, history, modes and pen excluded):")
    func passes(_ r: HResult, _ k: String) -> Bool {
        guard let t = r.tallies[k] else { return true }
        return t.counts.keys.allSatisfy { !screenCats.contains($0) }
    }
    let allTags = Set(results.flatMap { $0.tags })
    let dirKeys = ["S>S", "S>G vsSource", "S>G vsDirect", "G>S vsSource", "G>G.vt", "G>G.composed", "G>G.bin"]
    print(padR("tag", 16) + padL("states", 8) + dirKeys.map { padL($0, 14) }.joined())
    var tagJSON: [String: Any] = [:]
    for tag in allTags.sorted() {
        let rs = results.filter { $0.tags.contains(tag) }
        var row: [String: Int] = [:]
        for k in dirKeys { row[k] = rs.filter { passes($0, k) }.count }
        print(padR(tag, 16) + padL(String(rs.count), 8) + dirKeys.map { padL(String(row[$0]!), 14) }.joined())
        tagJSON[tag] = ["states": rs.count, "pass": row]
    }
    json["tags"] = tagJSON

    // Sizes and times on the biggest state.
    if let big = results.max(by: { ($0.sizes["writer"] ?? 0) < ($1.sizes["writer"] ?? 0) }) {
        print("\nLargest state \(big.name): writer \(big.sizes["writer"]!) bytes, \(String(format: "%.1f", big.times["writer"]!)) ms; replay into G \(String(format: "%.1f", big.times["writerReplayIntoG"]!)) ms")
        print("  formatter \(big.sizes["formatter"]!) bytes, \(String(format: "%.1f", big.times["formatter"]!)) ms; snapshot \(big.sizes["snapshot"]!) bytes, encode \(String(format: "%.1f", big.times["snapshotEncode"]!)) ms, decode \(String(format: "%.1f", big.times["snapshotDecode"]!)) ms")
        json["largest"] = ["state": big.name, "sizes": big.sizes, "timesMs": big.times]
    }
    json["states"] = results.map { r -> [String: Any] in
        var d: [String: Any] = ["name": r.name, "tags": Array(r.tags).sorted(), "sizes": r.sizes, "timesMs": r.times]
        var t: [String: Any] = [:]
        for (k, v) in r.tallies where !v.isEmpty { t[k] = v.counts }
        d["diffs"] = t
        return d
    }
    writeJSON("handover.json", json)
}
