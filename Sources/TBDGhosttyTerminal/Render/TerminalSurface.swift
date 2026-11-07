// Adapted from tkzmux c961533 Sources/TkzTerminalRender/TerminalSurface.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// TerminalSurface — the render state of one terminal on screen.
//
// Each `GhosttyTerminalView` owns one surface, attached while the view can draw. The surface owns
// everything that is expensive and per-terminal:
//
//   * a `GhosttyRenderState` (the incremental dirty-row view of the terminal),
//   * a `GhosttyRenderStateRowIterator` and a `GhosttyRenderStateRowCells`, both reused every tick,
//   * per-row caches of `TkzGlyphInstance` / `TkzRectInstance` and the flat `TkzBgCell` grid.
//
// `attach(_:)` builds all three; `detach()` frees them. Detaching must leave nothing behind: a
// detached surface renders as "skipped", not as a crash.
//
// Not `Sendable`: it holds raw libghostty handles and is touched only from the main thread.
// The only place it reaches into the terminal is `FrameBuilder`'s one-line `withRaw` closure
// around `ghostty_render_state_begin_update`. A closed terminal makes that closure return nil, and
// the surface keeps its last frame.

import Foundation
import GhosttyVt
import TBDGhosttyShaderTypes

// MARK: - Errors

/// A libghostty-vt call made by the renderer returned something other than `GHOSTTY_SUCCESS`.
/// Throws `GhosttyCallError`, the same as the terminal half.
@inline(__always)
func renderCheck(_ result: GhosttyResult, _ operation: String) throws {
    try ghosttyCheck(result, operation)
}

// MARK: - Value types mirrored out of the render state

/// `GhosttyRenderStateDirty`, in Swift.
enum SurfaceDirty: UInt8, Sendable, Hashable {
    /// Nothing changed; the frame can be skipped entirely.
    case none
    /// Some rows changed; only those rows are rebuilt.
    case partial
    /// Global state changed (size, colours, selection); every row is rebuilt.
    case full
}

/// `GhosttyRenderStateCursorVisualStyle`, in Swift.
enum SurfaceCursorStyle: UInt8, Sendable, Hashable {
    case bar, block, underline, blockHollow
}

/// Everything the renderer needs to draw the cursor. Read fresh on every non-clean tick — a cursor
/// move only produces `DIRTY_PARTIAL` (spike result 5), so it never rides on `DIRTY_FULL`.
struct SurfaceCursorState: Sendable, Hashable {
    /// True when the cursor is inside the viewport *and* enabled by terminal modes.
    var isVisible: Bool = false
    var column: Int = 0
    var row: Int = 0
    /// The cursor sits on the tail cell of a wide grapheme.
    var isWideTail: Bool = false
    /// Terminal modes ask for a blinking cursor (the *phase* is the view's business).
    var isBlinking: Bool = false
    var style: SurfaceCursorStyle = .block

    init() {}
}

/// The render state's own colours: the appearance's colours as the terminal applied them, plus
/// anything the program changed at runtime with OSC 4 / 10 / 11. These win for everything the
/// terminal can repaint; the renderer only adds the selection tint.
struct SurfaceColors: Sendable, Hashable {
    /// Packed RGBA (`r | g << 8 | b << 16 | a << 24`), always opaque.
    var background: UInt32 = 0xFF00_0000
    var foreground: UInt32 = 0xFFFF_FFFF
    /// The explicit cursor colour, when the terminal set one.
    var cursor: UInt32?
    /// The active 256-colour palette, packed.
    var palette: [UInt32] = Array(repeating: 0xFF00_0000, count: 256)

    init() {}

    /// The colour to paint the cursor with: explicit if set, else the default foreground.
    var effectiveCursor: UInt32 { cursor ?? foreground }
}

// MARK: - TerminalSurface

final class TerminalSurface {
    // MARK: Attachment

    /// The attached terminal, or `nil` when detached.
    private(set) var terminal: GhosttyTerminal?
    /// The render state; `nil` exactly when `terminal` is nil.
    private(set) var renderState: GhosttyRenderStateHandle?
    /// Reused across ticks. Repopulated from `DATA_ROW_ITERATOR` on every update (positions reset).
    private(set) var rowIterator: GhosttyRenderStateRowIterator?
    /// Reused across rows *and* ticks — that is the whole point of `row_cells_new`.
    private(set) var rowCells: GhosttyRenderStateRowCells?

    var isAttached: Bool { terminal != nil }

    /// This surface's instance buffers, created by the renderer on first encode and dropped by
    /// `detach()`. Per surface rather than per renderer so N panes in one tick do not contend for
    /// one ring's slots — and so a pane's buffers are sized to that pane, not to the widest one on
    /// screen (see `FrameRing`).
    var frameRing: FrameRing?

    // MARK: Grid state

    private(set) var columns: Int = 0
    private(set) var rowCount: Int = 0

    /// Row-major `columns * rowCount` background grid, bound directly as the bg pass's instance
    /// buffer. Alpha 0 means "no explicit background" (see `TBDGhosttyShaderTypes.h`).
    private(set) var backgroundCells: [TkzBgCell] = []
    /// Per-row glyph instances. Rebuilt only for rows libghostty reported dirty.
    private(set) var rowGlyphs: [[TkzGlyphInstance]] = []
    /// Per-row decoration rects drawn *after* the glyphs (underline, strikethrough).
    private(set) var rowRects: [[TkzRectInstance]] = []

    /// Running totals across `rowGlyphs` / `rowRects`, maintained by `store(row:)`.
    ///
    /// These used to be `reduce` over every row, and the renderer asks for them several times per
    /// frame — including on the *skipped*-frame path, which is the common idle case. Keeping the
    /// sums here turns each of those into an integer read.
    private var glyphTotal = 0
    private var rectTotal = 0

    /// Reused flatten buffers. `glyphInstances()` used to return a freshly allocated array on every
    /// encoded frame — a whole-screen copy regardless of how few rows were dirty.
    private var glyphFlatten: [TkzGlyphInstance] = []
    private var rectFlatten: [TkzRectInstance] = []

    private(set) var colors = SurfaceColors()
    private(set) var cursor = SurfaceCursorState()

    /// Where the viewport sits in the scrollable area, as of the last `FrameBuilder.update`.
    ///
    /// Polled every tick because libghostty offers no change notification for scroll state
    /// (`vt/terminal.h` → `DATA_SCROLLBAR`). Consumed by the view's scroll indicator, which diffs
    /// it — see `setScrollMetrics` for why nothing here marks the surface dirty.
    private(set) var scrollMetrics: TerminalScrollMetrics = .empty

    /// Cell geometry the caches were built at. The builder stamps it; the renderer reads it.
    private(set) var metrics: CellMetrics?

    /// The `(grayscale, colour)` atlas rebuild generations the row caches were built against.
    /// A change means every cached `atlasPos` is stale and every row must be rebuilt — see
    /// `FrameBuilder.update`. `.max` until the first update, so the first tick always rebuilds.
    private(set) var atlasRebuildStamp = SIMD2<UInt64>(repeating: .max)

    // MARK: Overlay state (owned by the view, not by libghostty)

    /// Cursor blink phase. `false` hides the cursor without touching a single row cache.
    var cursorBlinkOn: Bool = true {
        didSet { if cursorBlinkOn != oldValue { markNeedsDisplay() } }
    }
    /// Window focus. An unfocused terminal draws a hollow cursor.
    var isFocused: Bool = true {
        didSet { if isFocused != oldValue { markNeedsDisplay() } }
    }

    // MARK: Frame bookkeeping

    /// True when something changed since the last successfully encoded frame. The renderer's
    /// idle guarantee is exactly `needsDisplay == false → return before touching the GPU`.
    private(set) var needsDisplay: Bool = false
    /// Increments on every rebuild that changed instance data. Diagnostics and tests.
    private(set) var revision: UInt64 = 0
    /// Dirty state reported by the last `FrameBuilder.update`.
    private(set) var lastDirty: SurfaceDirty = .none
    /// Rows rebuilt by the last `FrameBuilder.update`.
    private(set) var lastRowsRebuilt: Int = 0

    init() {}

    deinit { releaseHandles() }

    // MARK: - Attach / detach

    /// Attaches to `terminal` and allocates the render state, row iterator and cell iterator.
    ///
    /// A freshly created render state reports `DIRTY_FULL` on its first update, so the first frame
    /// after an attach is a complete rebuild — no explicit invalidation is needed. Attaching while
    /// already attached detaches first, so `attach` is idempotent from the caller's point of view.
    func attach(_ terminal: GhosttyTerminal) throws {
        detach()

        let state = try makeRenderState()
        var iterator: GhosttyRenderStateRowIterator?
        try renderCheck(
            ghostty_render_state_row_iterator_new(nil, &iterator),
            "ghostty_render_state_row_iterator_new")
        var cells: GhosttyRenderStateRowCells?
        do {
            try renderCheck(
                ghostty_render_state_row_cells_new(nil, &cells),
                "ghostty_render_state_row_cells_new")
        } catch {
            ghostty_render_state_row_iterator_free(iterator)
            throw error
        }

        self.renderState = state
        self.rowIterator = iterator
        self.rowCells = cells
        self.terminal = terminal
        self.needsDisplay = true
    }

    /// Frees the render state and both iterators and forgets the terminal.
    ///
    /// Safe to call when already detached. After this the surface holds no libghostty memory at
    /// all, so a hidden view costs only the terminal itself.
    func detach() {
        releaseHandles()
        terminal = nil
        // Load-bearing for "an unattached terminal costs only IO": a hidden view must give its
        // instance buffers back, not merely stop drawing.
        frameRing = nil
        columns = 0
        rowCount = 0
        backgroundCells.removeAll(keepingCapacity: false)
        rowGlyphs.removeAll(keepingCapacity: false)
        rowRects.removeAll(keepingCapacity: false)
        glyphFlatten.removeAll(keepingCapacity: false)
        rectFlatten.removeAll(keepingCapacity: false)
        glyphTotal = 0
        rectTotal = 0
        colors = SurfaceColors()
        cursor = SurfaceCursorState()
        scrollMetrics = .empty
        metrics = nil
        atlasRebuildStamp = SIMD2<UInt64>(repeating: .max)
        needsDisplay = false
        lastDirty = .none
        lastRowsRebuilt = 0
    }

    private func releaseHandles() {
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        rowCells = nil
        rowIterator = nil
        renderState = nil  // the handle class frees the render state in its own deinit
    }

    private func makeRenderState() throws -> GhosttyRenderStateHandle {
        try GhosttyRenderStateHandle()
    }

    // MARK: - Mutation (FrameBuilder only)

    /// Marks the surface as needing a frame. Called by the overlay setters and by the builder.
    func markNeedsDisplay() { needsDisplay = true }

    /// Called by the renderer after a frame has been successfully encoded.
    func clearNeedsDisplay() { needsDisplay = false }

    /// Stores the scroll position read by the builder.
    ///
    /// Deliberately **not** `markNeedsDisplay()`. The scroll indicator is a `CALayer` over the
    /// surface, not GPU content, so a moved thumb needs no frame — and marking dirty here would
    /// leave `renderNow`'s `needsUpdate = surface.needsDisplay` handoff permanently true and hold
    /// the display link at 120 Hz forever. That is the same trap `DisplayLinkDriver` documents for
    /// the cursor blink, arrived at from the other side.
    func setScrollMetrics(_ value: TerminalScrollMetrics) { scrollMetrics = value }

    func resize(columns newColumns: Int, rows newRows: Int) {
        guard newColumns != columns || newRows != rowCount else { return }
        columns = max(0, newColumns)
        rowCount = max(0, newRows)
        backgroundCells = Array(repeating: TkzBgCell(color: 0), count: columns * rowCount)
        rowGlyphs = Array(repeating: [], count: rowCount)
        rowRects = Array(repeating: [], count: rowCount)
        glyphTotal = 0
        rectTotal = 0
    }

    func setColors(_ value: SurfaceColors) { colors = value }
    func setCursor(_ value: SurfaceCursorState) { cursor = value }
    func setMetrics(_ value: CellMetrics) { metrics = value }
    func setAtlasRebuildStamp(_ value: SIMD2<UInt64>) { atlasRebuildStamp = value }

    /// Takes a rebuilt row's instances.
    ///
    /// Copies into the row's own storage rather than adopting the caller's buffer. `FrameBuilder`
    /// clears its scratch arrays with `removeAll(keepingCapacity: true)` between rows, but the
    /// previous `rowGlyphs[row] = glyphs` left the row and the scratch sharing one buffer — so that
    /// `removeAll` was a copy-on-write reallocation and the scratch allocated a fresh array for
    /// every row of every rebuild, which is exactly what it exists to avoid.
    func store(row: Int, glyphs: [TkzGlyphInstance], rects: [TkzRectInstance]) {
        guard row >= 0, row < rowCount else { return }
        glyphTotal -= rowGlyphs[row].count
        rowGlyphs[row].removeAll(keepingCapacity: true)
        rowGlyphs[row].append(contentsOf: glyphs)
        glyphTotal += glyphs.count

        rectTotal -= rowRects[row].count
        rowRects[row].removeAll(keepingCapacity: true)
        rowRects[row].append(contentsOf: rects)
        rectTotal += rects.count
    }

    func setBackground(column: Int, row: Int, color: UInt32) {
        guard column >= 0, column < columns, row >= 0, row < rowCount else { return }
        backgroundCells[row * columns + column] = TkzBgCell(color: color)
    }

    func finishUpdate(dirty: SurfaceDirty, rowsRebuilt: Int) {
        lastDirty = dirty
        lastRowsRebuilt = rowsRebuilt
        if dirty != .none {
            revision &+= 1
            needsDisplay = true
        }
    }

    // MARK: - Flattened instance views

    /// Total glyph instances across every row.
    var glyphCount: Int { glyphTotal }
    /// Total decoration rects across every row (cursor excluded — it is an overlay).
    var rectCount: Int { rectTotal }

    /// Every glyph in viewport order, with `TKZ_GLYPH_FLAG_UNDER_CURSOR` stamped on the glyph the
    /// cursor currently covers.
    ///
    /// The flag is applied *here* and not baked into the row cache, so a blink or focus change
    /// costs one flatten instead of a full row rebuild.
    func glyphInstances() -> [TkzGlyphInstance] {
        flattenGlyphs()
        return glyphFlatten
    }

    /// Flattens every row into the reused `glyphFlatten` buffer and hands it to `body` without
    /// copying it out. This is what the renderer uses.
    ///
    /// `glyphInstances()` remains for tests and tools. Handing the array out shares its storage, so
    /// the *next* flatten's `removeAll(keepingCapacity:)` has to reallocate — which is precisely the
    /// copy-on-write trap `store(row:)` documents, kept off the hot path rather than fixed, because
    /// returning an array is the whole point of that entry point.
    func withGlyphInstances<T>(_ body: (UnsafeBufferPointer<TkzGlyphInstance>) throws -> T) rethrows -> T {
        flattenGlyphs()
        return try glyphFlatten.withUnsafeBufferPointer(body)
    }

    private func flattenGlyphs() {
        glyphFlatten.removeAll(keepingCapacity: true)
        glyphFlatten.reserveCapacity(glyphTotal)
        let highlight = filledCursorCell
        for (y, glyphs) in rowGlyphs.enumerated() {
            if let highlight, highlight.row == y {
                for var glyph in glyphs {
                    if Int(glyph.gridPos.x) == highlight.column {
                        glyph.flags |= UInt32(TKZ_GLYPH_FLAG_UNDER_CURSOR)
                        glyph.flags &= ~UInt32(TKZ_GLYPH_FLAG_MIN_CONTRAST)
                    }
                    glyphFlatten.append(glyph)
                }
            } else {
                glyphFlatten.append(contentsOf: glyphs)
            }
        }
    }

    /// Decoration rects drawn after the glyphs (underline, strikethrough) plus the hollow cursor.
    func rectInstancesAbove(geometry: GridGeometry) -> [TkzRectInstance] {
        flattenRectsAbove(geometry: geometry)
        return rectFlatten
    }

    /// `rectInstancesAbove` without the copy out — see `withGlyphInstances`.
    func withRectInstancesAbove<T>(
        geometry: GridGeometry, _ body: (UnsafeBufferPointer<TkzRectInstance>) throws -> T
    ) rethrows -> T {
        flattenRectsAbove(geometry: geometry)
        return try rectFlatten.withUnsafeBufferPointer(body)
    }

    private func flattenRectsAbove(geometry: GridGeometry) {
        rectFlatten.removeAll(keepingCapacity: true)
        rectFlatten.reserveCapacity(rectTotal + 1)
        for rects in rowRects { rectFlatten.append(contentsOf: rects) }
        if let rect = cursorRect(geometry: geometry), rect.style != UInt32(TKZ_RECT_STYLE_SOLID) {
            rectFlatten.append(rect)
        }
    }

    /// Rects drawn *before* the glyphs: the filled cursor shapes. The selection is not here — it is
    /// composited into `backgroundCells`, because a selection change forces a full row rebuild
    /// anyway (spike result 5) and the bg grid gives it for free.
    func rectInstancesBelow(geometry: GridGeometry) -> [TkzRectInstance] {
        guard let rect = cursorRect(geometry: geometry),
              rect.style == UInt32(TKZ_RECT_STYLE_SOLID) else { return [] }
        return [rect]
    }

    /// The cell whose glyph must be drawn in `cursorTextColor`: only a *filled block* cursor covers
    /// its glyph completely. On either half of a wide grapheme that is the lead cell: the block
    /// covers both (see `cursorCells`), and the grapheme's glyph is anchored on the lead.
    var filledCursorCell: (column: Int, row: Int)? {
        guard isCursorDrawn, isFocused, cursor.style == .block else { return nil }
        return (cursorCells.column, cursor.row)
    }

    /// The cells a block or underline cursor covers: the first column and how many columns, one or
    /// two. On either half of a wide grapheme it covers both halves, as most terminals draw it.
    /// Covering one half would leave the grapheme's whole glyph drawn in `cursorTextColor`, the
    /// background, with only that half behind the block, so the other half would vanish.
    ///
    /// libghostty reports a cursor on the tail. A lead is known by the glyph anchored on it, which
    /// carries `TKZ_GLYPH_FLAG_WIDE`; a lead with no glyph has nothing to hide, so one cell does.
    private var cursorCells: (column: Int, width: Int) {
        if cursor.isWideTail { return (max(0, cursor.column - 1), 2) }
        guard cursor.row >= 0, cursor.row < rowGlyphs.count else { return (cursor.column, 1) }
        let column = cursor.column
        let isWideLead = rowGlyphs[cursor.row].contains { glyph in
            Int(glyph.gridPos.x) == column && glyph.flags & UInt32(TKZ_GLYPH_FLAG_WIDE) != 0
        }
        return (column, isWideLead ? 2 : 1)
    }

    /// Suppresses the cursor entirely, whatever the terminal's own modes say.
    ///
    /// For a terminal whose program has exited: the grid is kept, but a blinking insertion point
    /// on a dead terminal invites typing that goes nowhere. The terminal's own cursor state is left
    /// untouched, so clearing this restores its cursor.
    var isCursorSuppressed: Bool = false {
        didSet { if isCursorSuppressed != oldValue { markNeedsDisplay() } }
    }

    /// True when the cursor should appear this frame: visible, inside the grid, and either steady
    /// or in the on phase of its blink. A steady cursor ignores the phase, so one set while the
    /// blink was off shows on the next frame.
    var isCursorDrawn: Bool {
        !isCursorSuppressed && cursor.isVisible && (cursorBlinkOn || !cursor.isBlinking)
            && cursor.column >= 0 && cursor.column < columns
            && cursor.row >= 0 && cursor.row < rowCount
    }

    /// The cursor as a single rect, or `nil` when it is not drawn this frame.
    ///
    /// An unfocused window always draws the hollow outline, whatever the terminal asked for — that
    /// is the macOS convention and the one thing about the cursor libghostty does not decide.
    func cursorRect(geometry: GridGeometry) -> TkzRectInstance? {
        guard isCursorDrawn, let metrics else { return nil }
        let origin = geometry.origin(ofColumn: cursor.column, row: cursor.row)
        let cellWidth = geometry.cellSizePx.x
        let cellHeight = geometry.cellSizePx.y
        let thickness = Float(max(1, metrics.underlineThickness))
        let color = colors.effectiveCursor

        var rect = TkzRectInstance()
        rect.color = color
        rect.thicknessPx = thickness
        rect.reserved0 = 0

        // On either half of a wide grapheme the box covers both cells, starting on the lead.
        let cells = cursorCells
        let boxOrigin = geometry.origin(ofColumn: cells.column, row: cursor.row)
        let boxWidth = cellWidth * Float(cells.width)

        let effectiveStyle: SurfaceCursorStyle = isFocused ? cursor.style : .blockHollow
        switch effectiveStyle {
        case .block:
            rect.originPx = boxOrigin
            rect.sizePx = SIMD2<Float>(boxWidth, cellHeight)
            rect.style = UInt32(TKZ_RECT_STYLE_SOLID)
        case .blockHollow:
            rect.originPx = boxOrigin
            rect.sizePx = SIMD2<Float>(boxWidth, cellHeight)
            rect.style = UInt32(TKZ_RECT_STYLE_HOLLOW)
        case .bar:
            rect.originPx = origin
            rect.sizePx = SIMD2<Float>(max(thickness, 1), cellHeight)
            rect.style = UInt32(TKZ_RECT_STYLE_SOLID)
        case .underline:
            let height = max(thickness, 1)
            rect.originPx = SIMD2<Float>(boxOrigin.x, origin.y + cellHeight - height)
            rect.sizePx = SIMD2<Float>(boxWidth, height)
            rect.style = UInt32(TKZ_RECT_STYLE_SOLID)
        }
        return rect
    }
}

// MARK: - GridGeometry

/// Where the grid sits inside the drawable, in device pixels (origin top-left, +y down).
struct GridGeometry: Sendable, Hashable {
    var cellSizePx: SIMD2<Float>
    var originPx: SIMD2<Float>
    var viewportSizePx: SIMD2<Float>

    init(cellSizePx: SIMD2<Float>, originPx: SIMD2<Float> = .zero, viewportSizePx: SIMD2<Float>) {
        self.cellSizePx = cellSizePx
        self.originPx = originPx
        self.viewportSizePx = viewportSizePx
    }

    /// Convenience: a grid pinned to the top-left of a `width × height` drawable.
    init(metrics: CellMetrics, viewportWidth: Int, viewportHeight: Int) {
        self.init(
            cellSizePx: SIMD2<Float>(Float(metrics.width), Float(metrics.height)),
            originPx: .zero,
            viewportSizePx: SIMD2<Float>(Float(viewportWidth), Float(viewportHeight)))
    }

    func origin(ofColumn column: Int, row: Int) -> SIMD2<Float> {
        originPx + SIMD2<Float>(Float(column) * cellSizePx.x, Float(row) * cellSizePx.y)
    }
}
