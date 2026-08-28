// Deterministic repro attempt for the "stale glyph" render artifact seen in TBD
// terminal panes (leftover pixels from a previous frame surviving in cells that
// are now blank / default-background).
//
// WHY THIS SHAPE. The artifact is pixels-only: the SwiftTerm grid is clean (the
// stale text is not selectable) and nudging the window size — i.e. a full
// redraw over a fresh backing store — wipes it. So a test that renders the whole
// view once into a fresh context and diffs proves NOTHING. Two conditions have
// to hold simultaneously for the artifact to be observable at all:
//
//   1. A PERSISTENT backing store across frames. Frame N+1 draws on top of
//      frame N's pixels. A fresh CGContext per frame starts transparent/blank
//      and cannot show a failure-to-erase.
//   2. Drawing CONSTRAINED to the rects SwiftTerm actually invalidated. AppKit
//      clips draw() to the dirty region; `cacheDisplay(in:to:)` would force a
//      full-bounds redraw and mask the bug.
//
// Both are reproduced here: one NSBitmapImageRep + NSGraphicsContext lives for
// the whole scenario, and each frame is drawn only inside the rects SwiftTerm
// passed to `setNeedsDisplay(_:)`, with the CGContext clipped to that rect the
// way AppKit clips it. The rects are captured by overriding `setNeedsDisplay(_:)`
// on a TerminalView subclass (SwiftTerm's own override at
// Mac/MacTerminalView.swift:833 is `#if false`'d out, so NSView's open method is
// the one we override).
//
// The initial bitmap fill with `nativeBackgroundColor` mirrors SwiftTerm's
// `layer.backgroundColor` (Mac/MacTerminalView.swift:573) plus TBD's own repaint
// of it (TBDTerminalView.applyScheme). That is the *only* thing painting the
// backdrop; `drawTerminalContents` never fills the dirty rect wholesale, it
// relies entirely on each glyph run carrying a `.backgroundColor` attribute
// (Apple/AppleTerminalView.swift:1341-1401).
//
// A PASS here is a finding about the harness, not proof the artifact is absent.

import AppKit
import SwiftTerm
import Testing

@testable import TBDApp

// MARK: - Recording view

/// TerminalView that records every invalidation rect SwiftTerm asks for. The
/// recorded rects are evidence in their own right: they say which rows SwiftTerm
/// believed needed repainting after a given feed.
private final class RecordingTerminalView: TerminalView {
    private(set) var invalidations: [NSRect] = []

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        invalidations.append(invalidRect)
        super.setNeedsDisplay(invalidRect)
    }

    func resetInvalidations() {
        invalidations.removeAll()
    }
}

// MARK: - Persistent-bitmap harness

/// One TerminalView + one bitmap that survives every frame.
@MainActor
private final class StalePixelHarness {
    let view: RecordingTerminalView
    let rep: NSBitmapImageRep
    let context: NSGraphicsContext
    let cell: (width: CGFloat, height: CGFloat)
    let cols: Int
    let rows: Int
    let scale: Int
    let background: NSColor

    /// Log of what each frame invalidated, for the failure message.
    private(set) var frameLog: [String] = []

    init(cols: Int = 80, rows: Int = 24, scale: Int = 2) throws {
        self.cols = cols
        self.rows = rows
        self.scale = scale

        // Same font family TBD hands SwiftTerm by default.
        let font = TBDTerminalView.defaultMonospaceFont
        // TBDTerminalView.cellDimensions(for:) mirrors SwiftTerm's own internal
        // cellDimension computation (see its doc comment), so the grid geometry
        // here matches what drawTerminalContents will use.
        self.cell = TBDTerminalView.cellDimensions(for: font)

        let pointWidth = cell.width * CGFloat(cols)
        let pointHeight = cell.height * CGFloat(rows)
        let frame = CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight)

        self.view = RecordingTerminalView(frame: frame, font: font)

        // Mirror TBDTerminalView.applyScheme(): an opaque background, an
        // explicit foreground, a full ANSI palette, and the layer repaint.
        // Deliberately NOT NSColor.textBackgroundColor — we want a colour that
        // cannot be confused with anything else in the bitmap.
        self.background = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.10, alpha: 1.0)
        let foreground = NSColor(srgbRed: 0.90, green: 0.90, blue: 0.90, alpha: 1.0)
        view.installColors(Self.ansiPalette)
        view.nativeBackgroundColor = background
        view.nativeForegroundColor = foreground
        view.layer?.backgroundColor = background.cgColor
        view.withTerminal { $0.updateFullScreen() }

        view.resize(cols: cols, rows: rows)

        let pixelsWide = Int((pointWidth * CGFloat(scale)).rounded(.up))
        let pixelsHigh = Int((pointHeight * CGFloat(scale)).rounded(.up))
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .calibratedRGB,
                bitmapFormat: [],
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            throw HarnessError.bitmapAllocationFailed
        }
        // Point size != pixel size gives the context a `scale`x backing scale,
        // matching a Retina display, which is what TBD actually runs on.
        rep.size = NSSize(width: pointWidth, height: pointHeight)
        self.rep = rep

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            throw HarnessError.contextCreationFailed
        }
        self.context = ctx

        // Paint the backdrop once, the way the CALayer does. Nothing in
        // drawTerminalContents ever fills the dirty rect wholesale.
        withContext {
            background.setFill()
            NSRect(x: 0, y: 0, width: pointWidth, height: pointHeight).fill()
        }
    }

    enum HarnessError: Error {
        case bitmapAllocationFailed
        case contextCreationFailed
    }

    /// A plain 16-colour palette so `installColors` has real values to work with.
    static let ansiPalette: [SwiftTerm.Color] = {
        let raw: [(Int, Int, Int)] = [
            (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
            (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
            (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
            (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
        ]
        return raw.map {
            SwiftTerm.Color(
                red: UInt16($0.0) * 257, green: UInt16($0.1) * 257, blue: UInt16($0.2) * 257)
        }
    }()

    private func withContext(_ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        body()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Feed bytes and let SwiftTerm's throttled `queuePendingDisplay` (a
    /// `DispatchQueue.main.asyncAfter` at ~1/60s, AppleTerminalView.swift:1795)
    /// actually fire, which is what calls `setNeedsDisplay(region)`.
    func feedAndSettle(_ text: String) {
        view.feed(text: text)
        pump(0.25)
    }

    func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Draw the whole view (the "first paint" / "window nudge" case).
    func drawFullFrame(label: String) {
        let full = view.bounds
        frameLog.append("\(label): FULL \(rectDescription(full))")
        withContext {
            context.cgContext.saveGState()
            context.cgContext.clip(to: full)
            view.draw(full)
            context.cgContext.restoreGState()
        }
        view.resetInvalidations()
    }

    /// Draw ONLY the rects SwiftTerm invalidated, each with the CGContext clipped
    /// to that rect — the incremental/partial repaint AppKit performs.
    /// Returns the rects that were drawn.
    @discardableResult
    func drawInvalidatedFrame(label: String) -> [NSRect] {
        let rects = view.invalidations
        frameLog.append("\(label): \(rects.count) invalidation(s) -> \(rects.map(rectDescription).joined(separator: ", "))")
        withContext {
            for rect in rects {
                context.cgContext.saveGState()
                context.cgContext.clip(to: rect)
                view.draw(rect)
                context.cgContext.restoreGState()
            }
        }
        view.resetInvalidations()
        return rects
    }

    func rectDescription(_ r: NSRect) -> String {
        let topRow = Int(((view.bounds.height - r.maxY) / cell.height).rounded())
        let rowCount = Int((r.height / cell.height).rounded())
        return String(
            format: "(x %.1f, y %.1f, w %.1f, h %.1f) [rows %d..<%d]",
            r.origin.x, r.origin.y, r.width, r.height, topRow, topRow + rowCount)
    }

    // MARK: Pixel inspection

    /// Pixel rect (bitmap coordinates, origin TOP-left, as NSBitmapImageRep
    /// addresses samples) for a grid cell, inset by 1 device pixel on every side
    /// so cell-boundary antialiasing from a NEIGHBOURING cell's glyph cannot be
    /// mistaken for stale content inside this one.
    private func pixelRect(row: Int, col: Int, inset: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let s = CGFloat(scale)
        let x0 = Int((CGFloat(col) * cell.width * s).rounded(.up)) + inset
        let x1 = Int((CGFloat(col + 1) * cell.width * s).rounded(.down)) - inset
        let y0 = Int((CGFloat(row) * cell.height * s).rounded(.up)) + inset
        let y1 = Int((CGFloat(row + 1) * cell.height * s).rounded(.down)) - inset
        return (x0, y0, x1, y1)
    }

    struct CellReading {
        let row: Int
        let col: Int
        /// Pixels differing from the background beyond the tolerance.
        let offBackgroundPixels: Int
        let totalPixels: Int
        /// Largest per-channel deviation seen, 0...255.
        let maxDeviation: Int
    }

    /// How far a pixel may sit from the background colour and still count as
    /// "erased". Generous: we are hunting whole glyph strokes, not a rounding
    /// artefact on a single subpixel.
    static let tolerance = 24

    func readCell(row: Int, col: Int, inset: Int = 1) -> CellReading {
        let r = pixelRect(row: row, col: col, inset: inset)
        guard let data = rep.bitmapData else {
            return CellReading(row: row, col: col, offBackgroundPixels: 0, totalPixels: 0, maxDeviation: 0)
        }
        let bpr = rep.bytesPerRow
        let spp = rep.samplesPerPixel
        // Sample the background straight out of the bitmap's own colour space by
        // reading a pixel we painted with it — avoids any sRGB/calibratedRGB
        // conversion mismatch between NSColor components and stored samples.
        let bg = backgroundSample()

        var off = 0
        var total = 0
        var maxDev = 0
        var y = r.y0
        while y < r.y1 {
            var x = r.x0
            while x < r.x1 {
                let p = data + (y * bpr) + (x * spp)
                let dev = max(
                    abs(Int(p[0]) - Int(bg.0)),
                    abs(Int(p[1]) - Int(bg.1)),
                    abs(Int(p[2]) - Int(bg.2)))
                total += 1
                if dev > Self.tolerance { off += 1 }
                maxDev = max(maxDev, dev)
                x += 1
            }
            y += 1
        }
        return CellReading(row: row, col: col, offBackgroundPixels: off, totalPixels: total, maxDeviation: maxDev)
    }

    /// The background as it is actually stored in this bitmap: read from the
    /// very first pixel, which the initial fill painted and which no glyph in
    /// any scenario here ever touches (scenarios keep row 0 col 0 blank).
    private var cachedBackgroundSample: (UInt8, UInt8, UInt8)?
    private func backgroundSample() -> (UInt8, UInt8, UInt8) {
        if let c = cachedBackgroundSample { return c }
        guard let data = rep.bitmapData else { return (0, 0, 0) }
        // Bottom-right-most pixel of the bitmap: outside every scenario's text.
        let x = rep.pixelsWide - 1
        let y = rep.pixelsHigh - 1
        let p = data + (y * rep.bytesPerRow) + (x * rep.samplesPerPixel)
        let c = (p[0], p[1], p[2])
        cachedBackgroundSample = c
        return c
    }

    /// Sweep every grid cell that currently holds a blank character and report
    /// the ones still carrying ink. Restricted to cells the scenario knows are
    /// default-background.
    func scanBlankCells(rowRange: Range<Int>, colRange: Range<Int>) -> [CellReading] {
        // Copy the blank-cell coordinates out under the lock (SwiftTerm 2.0
        // locked access); the bitmap reads below run outside it.
        let blankCells: [(row: Int, col: Int)] = view.withTerminal { terminal in
            var cells: [(row: Int, col: Int)] = []
            for row in rowRange {
                for col in colRange {
                    let ch = terminal.getCharacter(col: col, row: row)
                    if ch == " " || ch == "\0" {
                        cells.append((row, col))
                    }
                }
            }
            return cells
        }
        var dirty: [CellReading] = []
        for cell in blankCells {
            let reading = readCell(row: cell.row, col: cell.col)
            if reading.offBackgroundPixels > 0 {
                dirty.append(reading)
            }
        }
        return dirty
    }

    /// Row as SwiftTerm's grid holds it — used to prove the BUFFER is clean, so
    /// any residue is pixels-only.
    func bufferRow(_ row: Int) -> String {
        view.withTerminal { terminal in
            (0..<cols).map { String(terminal.getCharacter(col: $0, row: row) ?? " ") }.joined()
        }
    }

    func dumpLog() -> String {
        frameLog.joined(separator: "\n")
    }

    /// Write the bitmap out for eyeballing when something fails.
    @discardableResult
    func savePNG(_ name: String) -> String? {
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-stale-pixels")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        try? png.write(to: url)
        return url.path
    }
}

// MARK: - Tests

@Suite(
    "Terminal incremental-repaint stale pixels",
    .serialized,
    // DISABLED, and honestly so: this harness does not yet drive SwiftTerm's
    // display path. Every test fails FIRST on `!rects.isEmpty` ("SwiftTerm
    // invalidated nothing") — identically at the old pin dae32cc AND at
    // 16c5286, which carries the `context.clear(dirtyRect)` fix. Since nothing
    // is invalidated, nothing is drawn, so the residue these tests then report
    // is trivially explained and proves nothing about the product.
    //
    // What the harness DID establish, and why it is kept: pixels genuinely
    // persist across a partial repaint into a retained backing store, which is
    // the mechanism behind the artifact.
    //
    // To finish it, resolve why `feed` -> `feedFinish` -> `queuePendingDisplay`
    // (Apple/AppleTerminalView.swift:2512, a `DispatchQueue.main.asyncAfter` at
    // ~1/60s) never reaches `updateDisplay` here despite a 0.25s
    // `RunLoop.current.run(until:)` pump on a @MainActor suite. Assert
    // `terminal.getUpdateRange()` is non-nil right after the feed to split the
    // two cases: non-nil means rows WERE dirtied and the async pump is the gap;
    // nil means the fed bytes changed nothing and the scenario is wrong.
    .disabled("harness does not yet drive SwiftTerm's invalidation; see comment")
)
@MainActor
struct TerminalStalePixelRepaintTests {

    /// Scenario A — the exact Claude Code shape from the field report: rows that
    /// held glyphs in columns 0-1 are replaced by rows whose first two columns
    /// are the 2-space continuation indent. Only the invalidated rows are
    /// repainted, onto a bitmap that still holds the previous frame.
    @Test("partial repaint erases glyphs replaced by a 2-space default-bg indent")
    func twoSpaceIndentErasesPriorGlyphs() throws {
        let h = try StalePixelHarness()

        // Frame 1: dense glyphs everywhere, including columns 0 and 1.
        h.feedAndSettle("\u{1b}[2J\u{1b}[H")
        for row in 1...20 {
            h.feedAndSettle("\u{1b}[\(row);1H" + String(repeating: "W", count: 70))
        }
        h.drawFullFrame(label: "frame1 (first paint)")

        // Sanity: the pixels we are about to demand be erased must exist first.
        let before = h.readCell(row: 5, col: 0)
        #expect(
            before.offBackgroundPixels > 0,
            "harness broken: frame 1 put no ink in row 5 col 0 (maxDev \(before.maxDeviation))")

        // Frame 2: overwrite rows 5..9 with the 2-space continuation indent.
        // This dirties ONLY those rows, so SwiftTerm invalidates a partial band.
        for row in 6...10 {
            h.view.feed(text: "\u{1b}[\(row);1H\u{1b}[K  continuation text for row \(row)")
        }
        h.pump(0.25)
        let rects = h.drawInvalidatedFrame(label: "frame2 (2-space indent)")

        #expect(!rects.isEmpty, "SwiftTerm invalidated nothing — nothing was repainted")

        // The buffer must be clean: cols 0-1 of rows 5..9 are spaces.
        for row in 5...9 {
            let line = h.bufferRow(row)
            #expect(line.hasPrefix("  "), "row \(row) buffer is not 2-space indented: \(line.prefix(20))")
        }

        var residue: [StalePixelHarness.CellReading] = []
        for row in 5...9 {
            for col in 0...1 {
                let reading = h.readCell(row: row, col: col)
                if reading.offBackgroundPixels > 0 { residue.append(reading) }
            }
        }

        let png = h.savePNG("scenarioA")
        #expect(
            residue.isEmpty,
            """
            STALE PIXELS: \(residue.count) of 10 indent cells still carry frame-1 ink.
            \(residue.map { "  row \($0.row) col \($0.col): \($0.offBackgroundPixels)/\($0.totalPixels) px off-bg, maxDev \($0.maxDeviation)" }.joined(separator: "\n"))
            Invalidation log:
            \(h.dumpLog())
            bitmap: \(png ?? "<unsaved>")
            """)
    }

    /// Scenario B — scrolling. The field report's trigger. A `\n` at the bottom
    /// row scrolls the whole region; SwiftTerm widens refreshStart/refreshEnd
    /// across it, so the invalidation should be the full screen — but the bitmap
    /// still holds the old frame, so any cell whose fill rect is short or
    /// misplaced keeps its old ink.
    @Test("scrolling repaint erases every cell that became blank")
    func scrollRepaintErasesVacatedCells() throws {
        let h = try StalePixelHarness()

        h.feedAndSettle("\u{1b}[2J\u{1b}[H")
        for row in 1...24 {
            h.feedAndSettle("\u{1b}[\(row);1H" + String(repeating: "M", count: 78))
        }
        h.drawFullFrame(label: "frame1 (full screen of M)")

        // Scroll five lines in, each one a Claude-Code-shaped continuation line.
        h.view.feed(text: "\u{1b}[24;1H")
        for i in 1...5 {
            h.view.feed(text: "\r\n  wrapped continuation \(i)")
        }
        h.pump(0.3)
        let rects = h.drawInvalidatedFrame(label: "frame2 (5-line scroll)")
        #expect(!rects.isEmpty, "SwiftTerm invalidated nothing after a scroll")

        // Every blank cell in the visible grid must now read as background.
        let residue = h.scanBlankCells(rowRange: 0..<24, colRange: 0..<80)
        let png = h.savePNG("scenarioB")
        #expect(
            residue.isEmpty,
            """
            STALE PIXELS after scroll: \(residue.count) blank cells still carry ink.
            \(residue.prefix(25).map { "  row \($0.row) col \($0.col): \($0.offBackgroundPixels)/\($0.totalPixels) px off-bg, maxDev \($0.maxDeviation)" }.joined(separator: "\n"))
            Invalidation log:
            \(h.dumpLog())
            bitmap: \(png ?? "<unsaved>")
            """)
    }

    /// Scenario C — mixed attributes and non-ASCII, i.e. what a Claude Code TUI
    /// frame actually looks like: coloured chips with an explicit background next
    /// to default-background runs, box-drawing characters, and wide glyphs. The
    /// field report says explicit-background cells render correctly and only
    /// default-background regions are corrupted, which points at the per-run fill
    /// loop's column accounting (AppleTerminalView.swift:1341-1401) rather than
    /// at the invalidation region.
    @Test("mixed-attribute rows erase their default-background cells")
    func mixedAttributeRowsEraseDefaultBackground() throws {
        let h = try StalePixelHarness()

        h.feedAndSettle("\u{1b}[2J\u{1b}[H")
        // Frame 1: rows crowded with the sort of glyph soup the TUI emits.
        for row in 1...20 {
            let body = "\u{1b}[44;97m ● tool \u{1b}[0m ╭──────╮ 日本語テキスト \u{1b}[31mERROR\u{1b}[0m ▁▂▃▄▅▆▇█ ok"
            h.feedAndSettle("\u{1b}[\(row);1H" + body)
        }
        h.drawFullFrame(label: "frame1 (glyph soup)")

        // Frame 2: replace rows 6..12 with the 2-space continuation indent and
        // nothing else, so the whole row becomes default background after col 1.
        for row in 7...13 {
            h.view.feed(text: "\u{1b}[\(row);1H\u{1b}[0m\u{1b}[K  short")
        }
        h.pump(0.3)
        let rects = h.drawInvalidatedFrame(label: "frame2 (indent over glyph soup)")
        #expect(!rects.isEmpty, "SwiftTerm invalidated nothing")

        let residue = h.scanBlankCells(rowRange: 6..<13, colRange: 0..<80)
        let png = h.savePNG("scenarioC")
        #expect(
            residue.isEmpty,
            """
            STALE PIXELS over mixed-attribute rows: \(residue.count) blank cells still carry ink.
            \(residue.prefix(25).map { "  row \($0.row) col \($0.col): \($0.offBackgroundPixels)/\($0.totalPixels) px off-bg, maxDev \($0.maxDeviation)" }.joined(separator: "\n"))
            Invalidation log:
            \(h.dumpLog())
            bitmap: \(png ?? "<unsaved>")
            """)
    }
}
