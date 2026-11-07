import Foundation

func runCorpus(arguments: [String]) {
    let scratch = arguments.first ?? NSTemporaryDirectory() + "vtcheck-corpus"
    try? FileManager.default.createDirectory(at: workloadDir, withIntermediateDirectories: true)
    let repo = baseDir.deletingLastPathComponent().deletingLastPathComponent()
    let mb = 1 << 20, cols = 200, rows = 60
    func put(_ name: String, _ bytes: [UInt8], cols: Int = 200, rows: Int = 60) {
        FileManager.default.createFile(atPath: workloadDir.appendingPathComponent(name + ".bin").path, contents: Data(bytes))
        let meta = try! JSONSerialization.data(withJSONObject: ["cols": cols, "rows": rows])
        FileManager.default.createFile(atPath: workloadDir.appendingPathComponent(name + ".json").path, contents: meta)
        print("\(name): \(bytes.count) bytes, \(cols)x\(rows)")
    }
    put("ascii", asciiWorkload(sourceDir: repo.appendingPathComponent("Sources").path, size: 32 * mb))
    put("colors", colorsWorkload(32 * mb))
    put("unicode", unicodeWorkload(16 * mb))
    put("cursor", cursorWorkload(16 * mb, cols: cols, rows: rows))
    put("tui", tuiWorkload(16 * mb, cols: cols, rows: rows))
    put("scroll", scrollWorkload(16 * mb, rows: rows))

    let script = repo.appendingPathComponent("spikes/libghostty-vt/check/scripts/record.py").path
    for (kind, c, r) in [("claude", 120, 40), ("claude-classic", 120, 40), ("vim", 100, 30), ("less", 100, 30)] {
        let out = workloadDir.appendingPathComponent("rec-\(kind).bin").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", script, kind, "--out", out, "--cols", "\(c)", "--rows", "\(r)",
                       "--scratch", scratch, "--repo", repo.path]
        do {
            try p.run(); p.waitUntilExit()
            let meta = try! JSONSerialization.data(withJSONObject: ["cols": c, "rows": r])
            FileManager.default.createFile(atPath: workloadDir.appendingPathComponent("rec-\(kind).json").path, contents: meta)
            print("rec-\(kind): exit \(p.terminationStatus)")
        } catch { print("rec-\(kind): could not run: \(error)") }
    }
}
