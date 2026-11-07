// `tabs`: where a tab lands past column 80. Terminal.init grows its buffers through
// setup(), which adds no tab stops; only resize(cols:rows:) does. So a fork terminal built
// wider than 80 and one built at 80 and then resized should disagree, and this measures it.
import Foundation

func runTabs(arguments: [String]) {
    let rows = 24
    let e = "\u{1b}"
    print("cursor column after one tab from column 88, default stops every 8 columns, so 96 expected\n")
    print(padR("grid", 8) + padR("screen", 10) + padL("S built at width", 18) + padL("S built 80, resized", 21) + padL("libghostty-vt", 15))
    var out: [[String: Any]] = []
    for cols in [120, 200] {
        for (label, text) in [("primary", "\(e)[1;89H\t"), ("alt", "\(e)[?1049h\(e)[1;89H\t")] {
            let bytes = Array(text.utf8)
            let built = STerm(cols: cols, rows: rows, scrollback: 100)
            let resized = STerm(cols: 80, rows: rows, scrollback: 100)
            resized.t.terminalLock.withLock { resized.t.resize(cols: cols, rows: rows) }
            let g = GTerm(cols: cols, rows: rows, scrollback: 100)
            built.feed(bytes)
            resized.feed(bytes)
            g.feed(bytes)
            let b = built.snap(history: false).cx, r = resized.snap(history: false).cx, x = g.snap(history: false).cx
            print(padR("\(cols)x\(rows)", 8) + padR(label, 10) + padL(String(b), 18) + padL(String(r), 21) + padL(String(x), 15))
            out.append(["cols": cols, "screen": label, "builtAtWidth": b, "builtThenResized": r, "ghostty": x])
        }
    }
    writeJSON("tabs.json", ["rows": out])
}
