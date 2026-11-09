// Adapted from tkzmux c961533 Sources/TkzTerminalRender/FrameBuilder.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// FrameBuilder — libghostty render state → instance buffers.
//
// The renderer's cost lives in this file. Per tick:
//
//   1. `ghostty_render_state_begin_update` **under the terminal lock** — and nothing else. The
//      lock closure is one line.
//   2. `ghostty_render_state_end_update` and *all* row/cell iteration **unlocked**. render.h
//      documents the split (lines 42–51) and spike result 2 verified it empirically: row data is
//      stale-but-valid until the next update, so the IO thread runs free while we decode.
//   3. `get(DIRTY)`; on `FULL` re-read cols/rows and resize the caches. Colours and cursor are
//      re-read on *every* non-clean tick, because a cursor move is only `DIRTY_PARTIAL` (spike 5)
//      and OSC 4/10/11 need not force `FULL` either.
//   4. `row_iterator_next_dirty` → `row_get(SELECTION)` → per cell
//      `row_cells_get_multi(RAW, STYLE, GRAPHEMES_LEN, HAS_STYLING)` + individual `FG_COLOR` /
//      `BG_COLOR` + `ghostty_cell_get(WIDE, HAS_HYPERLINK)`.
//   5. `ghostty_render_state_clean`.
//
// Why the colours are fetched one at a time rather than folded into the multi call: `FG_COLOR` and
// `BG_COLOR` return `GHOSTTY_INVALID_VALUE` as their *result code* when the cell has no explicit
// colour (spike 7), and `row_cells_get_multi` stops at the first non-success key. Putting them in
// the batch would abort it for almost every cell on screen.
//
// Three more spike findings are implemented here rather than assumed:
//   * inverse (`SGR 7`) is **not** resolved by the library — both colours read INVALID and
//     `style.inverse` is true, so the swap (of the *defaults*, when unset) is ours (spike 4);
//   * bold-brightening is **not** applied — `ESC[1;31m` yields palette[1], not palette[9] (spike 4);
//   * `SPACER_TAIL` cells report `GRAPHEMES_LEN == 0` and empty UTF-8 — skip them, never draw a
//     space, and pass libghostty's `WIDE` down to the glyph cache instead of re-guessing from
//     Unicode (spike 6).

import Foundation
import GhosttyVt
import TBDGhosttyShaderTypes

// MARK: - Result

/// What one `FrameBuilder.update` did.
struct FrameUpdate: Sendable, Hashable {
    var dirty: SurfaceDirty
    /// Row rebuilds the update did. A row rebuilt twice, as when the update's own glyphs cleared
    /// the atlas, counts twice, so this is the update's row work, not a count of distinct rows.
    var rowsRebuilt: Int
    var glyphCount: Int
    var rectCount: Int

    /// True when the surface has nothing new to draw and the renderer must return early.
    var isClean: Bool { dirty == .none }
}

// MARK: - FrameBuilder

/// Decodes a `TerminalSurface`'s render state into instance buffers.
///
/// One per renderer (it owns the shared `GlyphCache`); not `Sendable`, lives on the main thread.
final class FrameBuilder {
    let glyphCache: GlyphCache
    /// The selection tint, packed RGBA with straight alpha, composited over each selected cell's
    /// background. The one colour the terminal itself cannot express: every other colour comes
    /// from the render state, which already carries the appearance the terminal was given plus
    /// anything OSC changed at runtime.
    var selectionColor: UInt32 = FrameBuilder.defaultSelectionColor

    /// White at 20%.
    static let defaultSelectionColor: UInt32 = 0x33FF_FFFF

    /// When true, glyphs coloured by the *program* opt into the shader's min-contrast fix.
    /// Glyphs in the appearance's own colours never do (they are contrast-checked already).
    var appliesMinContrast: Bool = true

    // Reusable scratch, so a tick allocates nothing per cell.
    private var graphemeBuffer = [UInt32](repeating: 0, count: 16)
    private var glyphScratch: [TkzGlyphInstance] = []
    private var rectScratch: [TkzRectInstance] = []

    /// Every row this builder has built, across all the surfaces it serves. Its change across one
    /// update is that update's row work, counted where the work happens, so a test can tell one
    /// pass over the grid from two whatever `FrameUpdate.rowsRebuilt` reports.
    private(set) var rowBuildCount = 0

    init(glyphCache: GlyphCache) {
        self.glyphCache = glyphCache
    }

    var metrics: CellMetrics { glyphCache.metrics }

    // MARK: - The tick

    /// Updates `surface` from its terminal. Returns what changed; `FrameUpdate.isClean` is the
    /// renderer's cue to skip the frame entirely.
    @discardableResult
    func update(_ surface: TerminalSurface) throws -> FrameUpdate {
        guard let terminal = surface.terminal, let state = surface.renderState else {
            return FrameUpdate(dirty: .none, rowsRebuilt: 0, glyphCount: 0, rectCount: 0)
        }
        let rs = state.raw

        // (1) The lock closure is `begin_update` plus the scroll poll — two amortized-O(1) calls.
        // The poll rides along here because reading it separately would take the same lock a
        // second time, once per frame, for 24 bytes.
        var scroll = TerminalScrollMetrics.empty
        let began = terminal.withRaw { raw -> GhosttyResult in
            let result = ghostty_render_state_begin_update(rs, raw)
            scroll = TerminalScrollMetrics.read(raw)
            return result
        }
        guard let beginResult = began else {
            // Closed: nothing new can arrive. The render state still holds the last frame, which
            // is what stays on screen.
            surface.finishUpdate(dirty: .none, rowsRebuilt: 0)
            return FrameUpdate(dirty: .none, rowsRebuilt: 0,
                               glyphCount: surface.glyphCount, rectCount: surface.rectCount)
        }
        try renderCheck(beginResult, "ghostty_render_state_begin_update")

        // Stored before the dirty check below, not after. Scrolled into history, new child output
        // grows `total` and moves the thumb while every *visible* cell stays clean — a read behind
        // the `dirty == .none` guard would freeze the thumb exactly when it is carrying the most
        // information. Same argument as the cursor read further down, different state.
        surface.setScrollMetrics(scroll)

        // (2) Deferred work; touches render-state memory only.
        try renderCheck(ghostty_render_state_end_update(rs), "ghostty_render_state_end_update")

        // (3) Dirty state is only meaningful after end_update.
        var rawDirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        try renderCheck(
            ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_DIRTY, &rawDirty),
            "ghostty_render_state_get(DIRTY)")
        let dirty: SurfaceDirty
        switch rawDirty {
        case GHOSTTY_RENDER_STATE_DIRTY_PARTIAL: dirty = .partial
        case GHOSTTY_RENDER_STATE_DIRTY_FULL: dirty = .full
        default: dirty = .none
        }
        // Clean cells are not a clean surface when the atlas was rebuilt since its rows were built.
        // Views with the same font and scale share this builder's glyph cache, so another surface's
        // frame can clear the atlas while this one is idle. Its row caches then point at whatever has
        // been packed there since, and its next frame — a blink, a cursor move — would draw that. So
        // a stale stamp falls through to the full rebuild below instead of returning here.
        let atlasIsStale = surface.atlasRebuildStamp != atlasRebuildStamp
        guard dirty != .none || atlasIsStale else {
            // libghostty's dirty flag tracks *cells*. A cursor that only moved — a space echoed
            // onto a blank cell, a bare cursor-motion sequence — leaves every row clean, and the
            // cursor would stay drawn where it was until the next real change (GUI pass
            // 2026-09-08: "typing a space does not move the cursor; the next letter jumps two
            // cells"). The cursor read is one `get`, so do it on clean ticks too and treat a change
            // as a partial frame with no rows to rebuild.
            let cursor = try readCursor(rs)
            guard cursor != surface.cursor else {
                surface.finishUpdate(dirty: .none, rowsRebuilt: 0)
                return FrameUpdate(dirty: .none, rowsRebuilt: 0,
                                   glyphCount: surface.glyphCount, rectCount: surface.rectCount)
            }
            surface.setCursor(cursor)
            surface.finishUpdate(dirty: .partial, rowsRebuilt: 0)
            return FrameUpdate(dirty: .partial, rowsRebuilt: 0,
                               glyphCount: surface.glyphCount, rectCount: surface.rectCount)
        }

        if dirty == .full {
            var cols: UInt16 = 0
            var rows: UInt16 = 0
            try renderCheck(
                ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_COLS, &cols),
                "ghostty_render_state_get(COLS)")
            try renderCheck(
                ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows),
                "ghostty_render_state_get(ROWS)")
            surface.resize(columns: Int(cols), rows: Int(rows))
        }
        surface.setMetrics(metrics)

        let colors = try readColors(rs)
        surface.setColors(colors)
        surface.setCursor(try readCursor(rs))

        // (4) Rows. The iterator is reused but must be repopulated every tick: positions reset.
        //
        // An atlas *rebuild* (the atlas ran out of room at max size and was cleared) invalidates
        // every `atlasPos` ever handed out, including the ones sitting in rows this tick is not
        // going to visit. `GlyphCache` drops its own entries, but only a full re-iteration can fix
        // the row caches — so the stamp is checked before the loop (a rebuild during another
        // surface's frame) and again after it (a rebuild caused by this very tick). The second
        // check compares with the stamp the loop started from, not the surface's: the surface's is
        // still the stale one when the first check forced the loop, and would force a second pass.
        var effectiveDirty = dirty
        if atlasIsStale {
            effectiveDirty = .full
        }
        let stampBeforeRows = atlasRebuildStamp
        var rowsRebuilt = try iterateRows(rs, surface: surface, colors: colors,
                                          forceFull: effectiveDirty == .full && dirty != .full)
        if atlasRebuildStamp != stampBeforeRows {
            // The atlas was cleared while this frame was being built: redo every row against the
            // repacked atlas before anything is drawn.
            effectiveDirty = .full
            rowsRebuilt += try iterateRows(rs, surface: surface, colors: colors, forceFull: true)
        }
        surface.setAtlasRebuildStamp(atlasRebuildStamp)

        // (5) Both dirty layers, consumed in one call.
        try renderCheck(ghostty_render_state_clean(rs), "ghostty_render_state_clean")

        surface.finishUpdate(dirty: effectiveDirty, rowsRebuilt: rowsRebuilt)
        return FrameUpdate(dirty: effectiveDirty, rowsRebuilt: rowsRebuilt,
                           glyphCount: surface.glyphCount, rectCount: surface.rectCount)
    }

    /// The pair of atlas rebuild generations. Any change means "every cached `atlasPos` is stale".
    var atlasRebuildStamp: SIMD2<UInt64> {
        SIMD2<UInt64>(glyphCache.grayscale.rebuildGeneration, glyphCache.color.rebuildGeneration)
    }

    /// Walks the dirty rows (or every row when `forceFull`) and rebuilds their caches.
    private func iterateRows(
        _ rs: GhosttyRenderState, surface: TerminalSurface, colors: SurfaceColors, forceFull: Bool
    ) throws -> Int {
        guard surface.columns > 0, surface.rowCount > 0,
              var iterator = surface.rowIterator, let cells = surface.rowCells else { return 0 }

        if forceFull {
            var full = GHOSTTY_RENDER_STATE_DIRTY_FULL
            try renderCheck(
                ghostty_render_state_set(rs, GHOSTTY_RENDER_STATE_OPT_DIRTY, &full),
                "ghostty_render_state_set(DIRTY = FULL)")
        }
        try renderCheck(
            ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator),
            "ghostty_render_state_get(ROW_ITERATOR)")

        var rowsRebuilt = 0
        var y: UInt16 = 0
        while ghostty_render_state_row_iterator_next_dirty(iterator, &y) {
            let row = Int(y)
            guard row < surface.rowCount else { continue }
            try buildRow(row: row, iterator: iterator, cells: cells, colors: colors, surface: surface)
            rowsRebuilt += 1
        }
        return rowsRebuilt
    }

    // MARK: - Global state

    private func readColors(_ rs: GhosttyRenderState) throws -> SurfaceColors {
        var raw = GhosttyRenderStateColors()
        raw.size = MemoryLayout<GhosttyRenderStateColors>.stride
        try renderCheck(
            ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_COLORS, &raw),
            "ghostty_render_state_get(COLORS)")

        var colors = SurfaceColors()
        colors.background = pack(raw.background)
        colors.foreground = pack(raw.foreground)
        colors.cursor = raw.cursor_has_value ? pack(raw.cursor) : nil
        // `palette` imports as a 256-element tuple; read it as a buffer rather than by index.
        colors.palette = withUnsafeBytes(of: raw.palette) { bytes in
            let entries = bytes.bindMemory(to: GhosttyColorRgb.self)
            return (0..<256).map { pack(entries[$0]) }
        }
        return colors
    }

    private func readCursor(_ rs: GhosttyRenderState) throws -> SurfaceCursorState {
        var raw = GhosttyRenderStateCursor()
        raw.size = MemoryLayout<GhosttyRenderStateCursor>.stride
        try renderCheck(
            ghostty_render_state_get(rs, GHOSTTY_RENDER_STATE_DATA_CURSOR, &raw),
            "ghostty_render_state_get(CURSOR)")

        var cursor = SurfaceCursorState()
        cursor.isVisible = raw.visible && raw.viewport_has_value
        cursor.isBlinking = raw.blinking
        if raw.viewport_has_value {
            cursor.column = Int(raw.viewport_x)
            cursor.row = Int(raw.viewport_y)
            cursor.isWideTail = raw.wide_tail
        }
        switch raw.visual_style {
        case GHOSTTY_CURSOR_STYLE_BAR: cursor.style = .bar
        case GHOSTTY_CURSOR_STYLE_UNDERLINE: cursor.style = .underline
        case GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW: cursor.style = .blockHollow
        default: cursor.style = .block
        }
        return cursor
    }

    // MARK: - One row

    private func buildRow(
        row: Int,
        iterator: GhosttyRenderStateRowIterator,
        cells: GhosttyRenderStateRowCells,
        colors: SurfaceColors,
        surface: TerminalSurface
    ) throws {
        rowBuildCount += 1
        // One selection query per row beats one `SELECTED` query per cell (render.h says so).
        var selection: ClosedRange<Int>?
        var rowSelection = GhosttyRenderStateRowSelection()
        rowSelection.size = MemoryLayout<GhosttyRenderStateRowSelection>.stride
        let selectionResult = ghostty_render_state_row_get(
            iterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &rowSelection)
        if selectionResult == GHOSTTY_SUCCESS {
            let lo = Int(rowSelection.start_x), hi = Int(rowSelection.end_x)
            selection = lo <= hi ? lo...hi : hi...lo
        } else if selectionResult != GHOSTTY_NO_VALUE {
            try renderCheck(selectionResult, "ghostty_render_state_row_get(SELECTION)")
        }

        var cellsHandle: GhosttyRenderStateRowCells? = cells
        try renderCheck(
            ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cellsHandle),
            "ghostty_render_state_row_get(CELLS)")

        glyphScratch.removeAll(keepingCapacity: true)
        rectScratch.removeAll(keepingCapacity: true)
        var decorations = DecorationRuns(row: row, metrics: metrics)

        var column = 0
        while ghostty_render_state_row_cells_next(cells) {
            defer { column += 1 }
            guard column < surface.columns else { continue }
            try buildCell(column: column, row: row, cells: cells, colors: colors,
                          selected: selection?.contains(column) ?? false,
                          surface: surface, decorations: &decorations)
        }
        decorations.flush(into: &rectScratch)

        // Any column the row iterator did not reach (a short row) keeps the default background.
        if column < surface.columns {
            for x in column..<surface.columns {
                surface.setBackground(column: x, row: row, color: 0)
                surface.setWideLead(column: x, row: row, false)
            }
        }

        surface.store(row: row, glyphs: glyphScratch, rects: rectScratch)
    }

    // MARK: - One cell

    private func buildCell(
        column: Int,
        row: Int,
        cells: GhosttyRenderStateRowCells,
        colors: SurfaceColors,
        selected: Bool,
        surface: TerminalSurface,
        decorations: inout DecorationRuns
    ) throws {
        var rawCell: GhosttyCell = 0
        var style = GhosttyStyle()
        var graphemesLen: UInt32 = 0
        var hasStyling = false
        try cellGetMulti(cells, &rawCell, &style, &graphemesLen, &hasStyling)

        var wide = GHOSTTY_CELL_WIDE_NARROW
        _ = ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_WIDE, &wide)
        // Before any early return: a wide cell with no glyph still sizes the cursor.
        surface.setWideLead(column: column, row: row, wide == GHOSTTY_CELL_WIDE_WIDE)
        var hasHyperlink = false
        _ = ghostty_cell_get(rawCell, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &hasHyperlink)

        // --- Colours -------------------------------------------------------------------------
        var explicitForeground: UInt32?
        var explicitBackground: UInt32?
        var color = GhosttyColorRgb()
        if ghostty_render_state_row_cells_get(
            cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &color) == GHOSTTY_SUCCESS {
            explicitForeground = pack(color)
        }
        if ghostty_render_state_row_cells_get(
            cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &color) == GHOSTTY_SUCCESS {
            explicitBackground = pack(color)
        }

        var foreground = explicitForeground ?? colors.foreground
        var background = explicitBackground
        var programColored = explicitForeground != nil
        // The style's own colour for the text, which bold may brighten below.
        var textColor = style.fg_color

        // Inverse is app-side, and when a colour is unset it is the *default* that gets swapped.
        if hasStyling, style.has(.inverse) {
            let newForeground = background ?? colors.background
            let newBackground = foreground
            foreground = newForeground
            background = newBackground
            textColor = style.bg_color
            programColored = true
        }

        // Bold brightening is ours too (spike 4), and comes after the swap, as in SwiftTerm: it is
        // the colour the text ends up in that brightens, never the background.
        let isBold = hasStyling && style.has(.bold)
        if isBold, let bright = boldBright(textColor, colors: colors) {
            foreground = bright
        }

        if hasStyling, style.has(.faint) {
            foreground = (foreground & 0x00FF_FFFF) | (UInt32(0x99) << 24)
        }

        if selected {
            background = composite(selectionColor, over: background ?? colors.background)
        }

        surface.setBackground(column: column, row: row, color: background ?? 0)

        // --- Decorations ---------------------------------------------------------------------
        if hasStyling {
            // SwiftTerm brightens a bold cell's underline colour as it does its text colour.
            var underlineColor = resolve(style.underline_color, colors: colors) ?? foreground
            if isBold, let bright = boldBright(style.underline_color, colors: colors) {
                underlineColor = bright
            }
            if style.underlineStyle != Int32(GHOSTTY_SGR_UNDERLINE_NONE.rawValue) {
                decorations.add(.underline(rectStyle(forUnderline: style.underlineStyle)),
                                column: column, color: underlineColor)
            } else if hasHyperlink {
                // OSC 8 links are underlined so they are visibly clickable (⌘-click opens them).
                decorations.add(.underline(UInt32(TKZ_RECT_STYLE_UNDERLINE_SINGLE)),
                                column: column, color: underlineColor)
            }
            if style.has(.strikethrough) {
                decorations.add(.strikethrough, column: column, color: foreground)
            }
        } else if hasHyperlink {
            decorations.add(.underline(UInt32(TKZ_RECT_STYLE_UNDERLINE_SINGLE)),
                            column: column, color: foreground)
        }

        // --- Glyph ---------------------------------------------------------------------------
        // SPACER_TAIL / SPACER_HEAD report no text at all: skip, do not draw a space (spike 6).
        guard graphemesLen > 0 else { return }
        if hasStyling, style.has(.invisible) { return }

        if graphemeBuffer.count < Int(graphemesLen) {
            graphemeBuffer = [UInt32](repeating: 0, count: Int(graphemesLen))
        }
        let fontStyle = hasStyling ? FontStyle(bold: style.has(.bold), italic: style.has(.italic)) : .regular
        // libghostty's WIDE is authoritative; the shaper's Unicode heuristic is only the fallback.
        let cellSpan = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1

        // Single-scalar clusters — all ASCII, and the large majority of everything else — go
        // through the scalar entry point, which needs no `[Unicode.Scalar]` and no array-backed
        // cache key. Building that array per cell was one of three allocations every cell paid.
        let cached: CachedGlyph?
        if graphemesLen == 1 {
            var raw: UInt32 = 0
            try graphemeBuffer.withUnsafeMutableBufferPointer { buffer in
                // PORT: silent ABI change. GRAPHEMES_BUF takes a GhosttyCodepointBuffer* in 1.0.0,
                // not a uint32_t*. The value is a void*, so the old call still compiles.
                var out = GhosttyCodepointBuffer(ptr: buffer.baseAddress, cap: buffer.count, len: 0)
                try renderCheck(
                    ghostty_render_state_row_cells_get(
                        cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &out),
                    "ghostty_render_state_row_cells_get(GRAPHEMES_BUF)")
                raw = buffer[0]
            }
            guard let scalar = Unicode.Scalar(raw) else { return }
            cached = glyphCache.glyph(forScalar: scalar, style: fontStyle, cellSpan: cellSpan)
        } else {
            let codepoints: [Unicode.Scalar] = try graphemeBuffer.withUnsafeMutableBufferPointer { buffer in
                var out = GhosttyCodepointBuffer(ptr: buffer.baseAddress, cap: buffer.count, len: 0)
                try renderCheck(
                    ghostty_render_state_row_cells_get(
                        cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &out),
                    "ghostty_render_state_row_cells_get(GRAPHEMES_BUF)")
                return (0..<Int(graphemesLen)).compactMap { Unicode.Scalar(buffer[$0]) }
            }
            guard !codepoints.isEmpty else { return }
            cached = glyphCache.glyph(for: codepoints, style: fontStyle, cellSpan: cellSpan)
        }
        guard let cached else { return }

        var instance = TkzGlyphInstance()
        instance.gridPos = SIMD2<UInt16>(UInt16(column), UInt16(row))
        instance.offsetPx = SIMD2<Int16>(
            Int16(clamping: cached.bearingX),
            Int16(clamping: metrics.baseline - cached.bearingTop))
        instance.sizePx = SIMD2<UInt16>(UInt16(cached.slot.width), UInt16(cached.slot.height))
        instance.atlasPos = SIMD2<UInt16>(UInt16(cached.slot.x), UInt16(cached.slot.y))
        instance.color = foreground
        instance.bgColor = background ?? colors.background
        var flags: UInt32 = 0
        if cached.isColor { flags |= UInt32(TKZ_GLYPH_FLAG_COLOR) }
        if cached.cellSpan > 1 { flags |= UInt32(TKZ_GLYPH_FLAG_WIDE) }
        if appliesMinContrast && programColored { flags |= UInt32(TKZ_GLYPH_FLAG_MIN_CONTRAST) }
        instance.flags = flags
        instance.reserved0 = 0
        glyphScratch.append(instance)
    }

    /// The batch getter's key list. `static` because it is a constant and `cellGetMulti` runs once
    /// per cell — as a local array literal it was an allocation per cell.
    private static let multiGetKeys: [GhosttyRenderStateRowCellsData] = [
        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING,
    ]

    /// The four keys that never fail, in one call. `FG_COLOR` / `BG_COLOR` are deliberately absent
    /// (they return `GHOSTTY_INVALID_VALUE` when unset and would abort the batch).
    private func cellGetMulti(
        _ cells: GhosttyRenderStateRowCells,
        _ rawCell: inout GhosttyCell,
        _ style: inout GhosttyStyle,
        _ graphemesLen: inout UInt32,
        _ hasStyling: inout Bool
    ) throws {
        let keys = Self.multiGetKeys
        let result: GhosttyResult = withUnsafeMutablePointer(to: &rawCell) { pRaw in
            withUnsafeMutablePointer(to: &style) { pStyle in
                withUnsafeMutablePointer(to: &graphemesLen) { pLen in
                    withUnsafeMutablePointer(to: &hasStyling) { pStyling in
                        var values: [UnsafeMutableRawPointer?] = [
                            UnsafeMutableRawPointer(pRaw),
                            UnsafeMutableRawPointer(pStyle),
                            UnsafeMutableRawPointer(pLen),
                            UnsafeMutableRawPointer(pStyling),
                        ]
                        return keys.withUnsafeBufferPointer { keyBuffer in
                            values.withUnsafeMutableBufferPointer { valueBuffer in
                                ghostty_render_state_row_cells_get_multi(
                                    cells, keys.count, keyBuffer.baseAddress,
                                    valueBuffer.baseAddress, nil)
                            }
                        }
                    }
                }
            }
        }
        try renderCheck(result, "ghostty_render_state_row_cells_get_multi")
    }

    // MARK: - Helpers

    private func resolve(_ color: GhosttyStyleColor, colors: SurfaceColors) -> UInt32? {
        // PORT: GhosttyStyleColor.tag is uint8_t now, so the enum no longer compares directly.
        switch UInt32(color.tag) {
        case GHOSTTY_STYLE_COLOR_RGB.rawValue: return pack(color.value.rgb)
        case GHOSTTY_STYLE_COLOR_PALETTE.rawValue: return colors.palette[Int(color.value.palette)]
        default: return nil
        }
    }

    /// The colour bold text drawn in `color` takes instead, or `nil` when bold leaves it alone.
    ///
    /// SwiftTerm's rule, with `useBrightColors` at the default TBD leaves it on (adapted from
    /// SwiftTerm, MIT, Copyright (c) 2019-2026 Miguel de Icaza, `mapColor` in
    /// Sources/SwiftTerm/Apple/SnapshotTextBuilder.swift at cheapsteak/SwiftTerm b4db5b0): palette
    /// entries 0 to 6 move to their bright twins 8 to 14. Its test is `ansi < 7`, so palette 7,
    /// white, keeps its colour, as do the bright entries, the rest of the 256 and RGB colours.
    private func boldBright(_ color: GhosttyStyleColor, colors: SurfaceColors) -> UInt32? {
        guard UInt32(color.tag) == GHOSTTY_STYLE_COLOR_PALETTE.rawValue else { return nil }
        let index = Int(color.value.palette)
        return index < 7 ? colors.palette[index + 8] : nil
    }

    private func rectStyle(forUnderline underline: Int32) -> UInt32 {
        switch underline {
        case Int32(GHOSTTY_SGR_UNDERLINE_DOUBLE.rawValue): return UInt32(TKZ_RECT_STYLE_UNDERLINE_DOUBLE)
        case Int32(GHOSTTY_SGR_UNDERLINE_CURLY.rawValue): return UInt32(TKZ_RECT_STYLE_UNDERLINE_CURLY)
        case Int32(GHOSTTY_SGR_UNDERLINE_DOTTED.rawValue): return UInt32(TKZ_RECT_STYLE_UNDERLINE_DOTTED)
        case Int32(GHOSTTY_SGR_UNDERLINE_DASHED.rawValue): return UInt32(TKZ_RECT_STYLE_UNDERLINE_DASHED)
        default: return UInt32(TKZ_RECT_STYLE_UNDERLINE_SINGLE)
        }
    }
}

// MARK: - Decoration runs

/// Coalesces per-cell underline / strikethrough into per-run rects.
///
/// One rect per cell would restart the dotted and dashed patterns at every cell boundary and put a
/// visible seam in them; a run-length rect draws the pattern continuously. The curly wavelength is
/// half a cell, so its phase is continuous at any cell boundary either way.
struct DecorationRuns {
    enum Kind: Hashable {
        case underline(UInt32)
        case strikethrough
    }

    private struct Run {
        var kind: Kind
        var color: UInt32
        var startColumn: Int
        var endColumn: Int
    }

    private let row: Int
    private let metrics: CellMetrics
    private var open: [Kind: Run] = [:]

    init(row: Int, metrics: CellMetrics) {
        self.row = row
        self.metrics = metrics
    }

    mutating func add(_ kind: Kind, column: Int, color: UInt32) {
        if var run = open[kind] {
            if run.color == color, run.endColumn == column - 1 {
                run.endColumn = column
                open[kind] = run
                return
            }
            finished.append(run)
        }
        open[kind] = Run(kind: kind, color: color, startColumn: column, endColumn: column)
    }

    private var finished: [Run] = []

    mutating func flush(into rects: inout [TkzRectInstance]) {
        var runs = finished
        finished.removeAll(keepingCapacity: true)
        for (_, run) in open { runs.append(run) }
        open.removeAll(keepingCapacity: true)
        // Deterministic order: rect instances are compared byte-for-byte by the tests.
        runs.sort { ($0.startColumn, styleValue($0.kind)) < ($1.startColumn, styleValue($1.kind)) }
        for run in runs { rects.append(rect(for: run)) }
    }

    private func styleValue(_ kind: Kind) -> UInt32 {
        switch kind {
        case .underline(let style): return style
        case .strikethrough: return UInt32(TKZ_RECT_STYLE_STRIKETHROUGH)
        }
    }

    /// The rect is the *box the decoration lives in*, not the ink: the shader lays every style out
    /// relative to it (`TBDGhosttyShaderTypes.h`). A three-thickness-tall box centred on the line puts a
    /// single underline exactly on the font's underline position and gives `DOUBLE` its gap.
    private func rect(for run: Run) -> TkzRectInstance {
        let cellWidth = Float(metrics.width)
        let cellHeight = Float(metrics.height)
        let isStrike = run.kind == .strikethrough
        let thickness = Float(isStrike ? metrics.strikethroughThickness : metrics.underlineThickness)
        let offset = Float(isStrike ? metrics.strikethroughOffset : metrics.underlineOffset)
        let style = styleValue(run.kind)
        let boxHeight = style == UInt32(TKZ_RECT_STYLE_UNDERLINE_CURLY)
            ? max(thickness * 4, 4) : max(thickness * 3, 3)
        let center = Float(metrics.baseline) + offset
        var top = center - boxHeight / 2
        top = min(max(top, 0), max(cellHeight - boxHeight, 0))

        var rect = TkzRectInstance()
        rect.originPx = SIMD2<Float>(Float(run.startColumn) * cellWidth,
                                     Float(row) * cellHeight + top)
        rect.sizePx = SIMD2<Float>(Float(run.endColumn - run.startColumn + 1) * cellWidth, boxHeight)
        rect.color = run.color
        rect.style = style
        rect.thicknessPx = thickness
        rect.reserved0 = 0
        return rect
    }
}

// MARK: - GhosttyStyle flags

// PORT: GhosttyStyle replaced its bools and `int underline` with one uint16 of flags. The accessor
// macros are C casts and do not import into Swift, so the bits are restated here.
extension GhosttyStyle {
    struct Flag { let bit: UInt16
        static let bold = Flag(bit: 1 << 0), italic = Flag(bit: 1 << 1), faint = Flag(bit: 1 << 2)
        static let inverse = Flag(bit: 1 << 4), invisible = Flag(bit: 1 << 5)
        static let strikethrough = Flag(bit: 1 << 6)
    }
    @inline(__always) func has(_ flag: Flag) -> Bool { flags & flag.bit != 0 }
    @inline(__always) var underlineStyle: Int32 { Int32((flags >> 8) & 0x7) }
}

// MARK: - Colour packing

/// `GhosttyColorRgb` → the packed, opaque `uint32_t` the shaders expect.
@inline(__always)
func pack(_ color: GhosttyColorRgb) -> UInt32 {
    UInt32(color.r) | UInt32(color.g) << 8 | UInt32(color.b) << 16 | 0xFF00_0000
}

/// Source-over of a packed straight-alpha colour onto a packed colour treated as opaque. The
/// result is opaque.
@inline(__always)
func composite(_ top: UInt32, over base: UInt32) -> UInt32 {
    let alpha = Double((top >> 24) & 0xFF) / 255
    func channel(_ shift: UInt32) -> UInt32 {
        let over = Double((top >> shift) & 0xFF)
        let under = Double((base >> shift) & 0xFF)
        return min(UInt32((over * alpha + under * (1 - alpha)).rounded()), 0xFF) << shift
    }
    return 0xFF00_0000 | channel(0) | channel(8) | channel(16)
}
