// `bench`: bytes per second through each engine, no window. Same grid, same scrollback,
// fed in pty-sized chunks. A/B/A/B order, with a discarded warm-up for each.
import Foundation

private let chunk = 16 * 1024

private func seconds(_ f: () -> Void) -> Double {
    let t0 = DispatchTime.now().uptimeNanoseconds
    f()
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
}

private func runS(_ data: [UInt8], cols: Int, rows: Int, scrollback: Int) -> Double {
    let s = STerm(cols: cols, rows: rows, scrollback: scrollback)
    return seconds {
        var off = 0
        while off < data.count {
            let n = min(chunk, data.count - off)
            s.feed(data[off..<(off + n)])
            off += n
        }
    }
}

private func runG(_ data: [UInt8], cols: Int, rows: Int, scrollback: Int) -> Double {
    let g = GTerm(cols: cols, rows: rows, scrollback: scrollback)
    return seconds {
        var off = 0
        while off < data.count {
            let n = min(chunk, data.count - off)
            g.feed(data[off..<(off + n)])
            off += n
        }
    }
}

private func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }

func runBench(arguments: [String]) {
    var runs = 7
    var names: Set<String>? = nil
    var it = arguments.makeIterator()
    while let a = it.next() {
        if a == "--runs", let n = it.next() { runs = max(5, Int(n) ?? 7) } else { names = (names ?? []).union([a]) }
    }
    let scrollback = 10_000, mb = 1 << 20
    print("scrollback \(scrollback) lines on both, byte limit lifted, mode 2027 on, \(chunk / 1024) KB chunks, median of \(runs), A/B/A/B")
    print("start load average \(loadAverage()), \(ProcessInfo.processInfo.activeProcessorCount) cores\n")
    print(padR("workload", 20) + padL("ratio G/S", 10) + padL("S MB/s", 10) + padL("G MB/s", 10) + padL("MB", 6) + "  grid     load avg")
    var rows: [[String: Any]] = []
    for w in loadWorkloads(names) {
        var data = w.bytes
        // A recording is a few KB, too short to time. Repeat it, as a long session would.
        if data.count < 8 * mb {
            let one = data
            data.reserveCapacity(8 * mb + one.count)
            while data.count < 8 * mb { data += one }
        }
        _ = runS(data, cols: w.cols, rows: w.rows, scrollback: scrollback)
        _ = runG(data, cols: w.cols, rows: w.rows, scrollback: scrollback)
        var ts: [Double] = [], tg: [Double] = []
        for _ in 0..<runs {
            ts.append(runS(data, cols: w.cols, rows: w.rows, scrollback: scrollback))
            tg.append(runG(data, cols: w.cols, rows: w.rows, scrollback: scrollback))
        }
        let size = Double(data.count) / Double(mb)
        let s = size / median(ts), g = size / median(tg)
        let load = loadAverage()
        print(padR(w.name, 20) + padL(String(format: "%.1fx", g / s), 10) + padL(String(format: "%.1f", s), 10) + padL(String(format: "%.1f", g), 10)
              + padL(String(format: "%.0f", size), 6) + "  " + padR("\(w.cols)x\(w.rows)", 9) + load)
        rows.append(["workload": w.name, "ratio": g / s, "swiftTermMBps": s, "ghosttyMBps": g, "sizeMB": size, "cols": w.cols, "rows": w.rows,
                     "load": load, "secondsS": ts, "secondsG": tg])
    }
    writeJSON("bench.json", ["runs": runs, "chunk": chunk, "scrollback": scrollback, "results": rows])
}
