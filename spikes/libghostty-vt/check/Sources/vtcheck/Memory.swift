// `memory`: phys_footprint from task_info(TASK_VM_INFO), never RSS. Each measurement is
// a fresh child process, so one engine's allocator state cannot colour the other's.
import Foundation
import GhosttyVt

func physFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(kr == KERN_SUCCESS)
    return info.phys_footprint
}

private func screenBytes(rows: Int, cols: Int) -> [UInt8] {
    var s = ""
    for y in 0..<rows {
        s += "\u{1b}[\(y + 1);1H\u{1b}[3\(y % 8)m" + String(repeating: "x", count: cols / 2) + "\u{1b}[0m"
    }
    return Array(s.utf8)
}

private func historyBytes(lines: Int, cols: Int, styled: Bool) -> [UInt8] {
    var s = ""
    s.reserveCapacity(lines * (cols + 40))
    for i in 0..<lines {
        if styled {
            let n = cols / 4
            s += "\u{1b}[3\(i % 8)m" + String(repeating: "a", count: n) + "\u{1b}[1;4\(i % 8)m" + String(repeating: "b", count: n)
                + "\u{1b}[38;5;\(i % 256)m" + String(repeating: "c", count: 8) + "\u{1b}[0m\r\n"
        } else {
            let tag = String(i)
            s += tag + String(repeating: "x", count: cols - tag.count) + "\r\n"
        }
    }
    return Array(s.utf8)
}

/// Child entry: `memory-child s|g idle N` or `memory-child s|g history plain|styled`.
func runMemoryChild(arguments a: [String]) {
    let engine = a[0], mode = a[1]
    let cols = 200, rows = 60, scrollback = 10_000
    // Warm both allocators with one terminal that is then released.
    do { let w = STerm(cols: cols, rows: rows, scrollback: 100); w.feed(screenBytes(rows: rows, cols: cols)) }
    do { let w = GTerm(cols: cols, rows: rows, scrollback: 100); w.feed(screenBytes(rows: rows, cols: cols)) }
    var out: [String: Any] = ["engine": engine, "mode": mode]
    // The input is built ahead of the baseline, so it never counts as terminal memory.
    var data: [UInt8] = []
    if mode == "history" {
        data = historyBytes(lines: scrollback + rows + 300, cols: cols, styled: a[2] == "styled")
        // TBD's own source files: text that compresses like text, not like a row of x.
        if a[2] == "source", let w = loadWorkloads(["ascii"]).first { data = Array(w.bytes.prefix(3 << 20)) }
    }
    let before = physFootprint()
    var keepS: [STerm] = [], keepG: [GTerm] = []
    if mode == "idle" {
        let n = Int(a[2])!
        out["n"] = n
        let screen = screenBytes(rows: rows, cols: cols)
        for _ in 0..<n {
            if engine == "s" { let t = STerm(cols: cols, rows: rows, scrollback: scrollback); t.feed(screen); keepS.append(t) }
            else { let t = GTerm(cols: cols, rows: rows, scrollback: scrollback); t.feed(screen); keepG.append(t) }
        }
    } else {
        out["variant"] = a[2]
        var off = 0
        if engine == "s" {
            let t = STerm(cols: cols, rows: rows, scrollback: scrollback)
            while off < data.count { let n = min(16384, data.count - off); t.feed(data[off..<(off + n)]); off += n }
            keepS.append(t)
            out["retainedRows"] = t.t.buffer.yDisp
        } else {
            let t = GTerm(cols: cols, rows: rows, scrollback: scrollback)
            while off < data.count { let n = min(16384, data.count - off); t.feed(data[off..<(off + n)]); off += n }
            keepG.append(t)
            out["retainedRows"] = t.scrollbackRows
            var use = GhosttyTerminalMemoryUsage()
            use.size = MemoryLayout<GhosttyTerminalMemoryUsage>.size
            ghostty_terminal_get(t.t, GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, &use)
            out["ghosttyResidentBytes"] = use.primary_resident_bytes
            out["ghosttyVirtualBytes"] = use.primary_virtual_bytes
            out["ghosttyPages"] = use.primary_pages
            out["compressionSupported"] = use.compression_supported
            out["delta"] = Int64(physFootprint()) - Int64(before)
            var result = GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED
            ghostty_terminal_compress(t.t, GHOSTTY_TERMINAL_COMPRESSION_MODE_FULL, &result)
            out["compressResult"] = result.rawValue
            ghostty_terminal_get(t.t, GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, &use)
            out["ghosttyCompressedBytes"] = use.primary_compressed_bytes
            out["ghosttyCompressedPages"] = use.primary_compressed_pages
            out["deltaAfterCompress"] = Int64(physFootprint()) - Int64(before)
        }
    }
    if out["delta"] == nil { out["delta"] = Int64(physFootprint()) - Int64(before) }
    let d = try! JSONSerialization.data(withJSONObject: out, options: .sortedKeys)
    print(String(decoding: d, as: UTF8.self))
    _ = (keepS.count, keepG.count)
}

private func child(_ a: [String]) -> [String: Any] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    p.arguments = ["memory-child"] + a
    let pipe = Pipe()
    p.standardOutput = pipe
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "{}"
    return (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
}

func runMemory(arguments: [String]) {
    let reps = 5
    print("phys_footprint delta, grid 200x60, 10,000-line scrollback limit, median of \(reps) child processes, load \(loadAverage())\n")
    func med(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
    var rows: [[String: Any]] = []
    print(padR("case", 34) + padL("SwiftTerm MB", 14) + padL("libghostty MB", 15) + padL("ratio G/S", 11))
    func row(_ label: String, _ a: [String]) {
        let s = (0..<reps).map { _ in child(["s"] + a) }, g = (0..<reps).map { _ in child(["g"] + a) }
        let sm = med(s.map { ($0["delta"] as? NSNumber)?.doubleValue ?? 0 }) / 1_048_576
        let gm = med(g.map { ($0["delta"] as? NSNumber)?.doubleValue ?? 0 }) / 1_048_576
        print(padR(label, 34) + padL(String(format: "%.2f", sm), 14) + padL(String(format: "%.2f", gm), 15) + padL(String(format: "%.2f", gm / sm), 11))
        var r: [String: Any] = ["case": label, "swiftTermMB": sm, "ghosttyMB": gm]
        if let last = g.last { r["ghosttyDetail"] = last }
        if let last = s.last { r["swiftTermDetail"] = last }
        rows.append(r)
    }
    row("1 idle (one screen of text)", ["idle", "1"])
    row("20 idle", ["idle", "20"])
    row("100 idle", ["idle", "100"])
    row("1 full history, plain text", ["history", "plain"])
    row("1 full history, styled", ["history", "styled"])
    row("1 full history, TBD source text", ["history", "source"])
    for r in rows {
        if let d = r["ghosttyDetail"] as? [String: Any], d["retainedRows"] != nil {
            let s = r["swiftTermDetail"] as? [String: Any]
            print("\(r["case"]!): retained rows S \(s?["retainedRows"] ?? "?"), G \(d["retainedRows"]!); G pages \(d["ghosttyPages"] ?? "?"), resident \(d["ghosttyResidentBytes"] ?? "?"), compressed \(d["ghosttyCompressedBytes"] ?? "?") in \(d["ghosttyCompressedPages"] ?? "?") pages (result \(d["compressResult"] ?? "?"), supported \(d["compressionSupported"] ?? "?")); footprint after a FULL ghostty_terminal_compress \(String(format: "%.2f", ((d["deltaAfterCompress"] as? NSNumber)?.doubleValue ?? 0) / 1_048_576)) MB")
        }
    }
    writeJSON("memory.json", ["rows": rows, "load": loadAverage()])
}
