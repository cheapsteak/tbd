import AppKit
import CoreText
import Foundation
import Metal
import TBDGhosttyShaderTypes
@testable import TBDGhosttyTerminal
import TestSupport
import Testing

/// What a Metal test reports when the runner has no GPU. A test that needs a device is skipped
/// with this reason; it never passes without having drawn.
let noMetalDevice: Comment = "no Metal device on this runner"

@Suite(.fastPassBounded)
struct RendererTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func shaderSourceCompiles() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try TerminalRenderer.makeLibrary(device: device)
        let names = Set(library.functionNames)
        let wanted = [
            TKZ_FN_BG_VERTEX, TKZ_FN_BG_FRAGMENT,
            TKZ_FN_RECT_VERTEX, TKZ_FN_RECT_FRAGMENT,
            TKZ_FN_GLYPH_VERTEX, TKZ_FN_GLYPH_FRAGMENT,
        ]
        for name in wanted {
            #expect(names.contains(name), "the compiled library has no \(name); it has \(names.sorted())")
        }
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func offscreenFrameDrawsText() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let glyphCache = GlyphCache(fontSet: FontSet(font: font, scale: 2), device: device)
        let renderer = try TerminalRenderer(device: device, glyphCache: glyphCache)

        let terminal = try GhosttyTerminal(cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        // White on black, set explicitly so the check does not depend on the default colours: an
        // "A", then a space in the same colours as the control cell.
        terminal.feed(text: "\u{1b}[38;2;255;255;255;48;2;0;0;0mA \u{1b}[0m")

        let surface = TerminalSurface()
        try surface.attach(terminal)
        let size = renderer.drawableSize(columns: 10, rows: 3)
        let texture = try #require(renderer.makeOffscreenTexture(width: size.width, height: size.height))
        let outcome = try renderer.render(surface: surface, to: texture)
        #expect(outcome.didEncode, "the first frame after attach was skipped")
        outcome.commandBuffer?.waitUntilCompleted()

        let pixels = TerminalRenderer.bgraBytes(of: texture)
        let metrics = glyphCache.metrics
        func inkedPixels(column: Int) -> Int {
            var count = 0
            for y in 0..<metrics.height {
                for x in (column * metrics.width)..<((column + 1) * metrics.width) {
                    let offset = (y * texture.width + x) * 4
                    if max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) > 64 { count += 1 }
                }
            }
            return count
        }
        let inA = inkedPixels(column: 0)
        let inSpace = inkedPixels(column: 1)
        #expect(inA > 0, "cell (0,0) holds no light pixels: the A was not drawn")
        #expect(inA > inSpace, "the A cell (\(inA) light pixels) is no brighter than the blank cell (\(inSpace))")
        #expect(renderer.stats.framesEncoded == 1)
    }

    @Test func shaderHeaderMatchesTheCTarget() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let headerURL = packageRoot
            .appendingPathComponent("Sources/TBDGhosttyShaderTypes/include/TBDGhosttyShaderTypes.h")
        let onDisk = try String(contentsOf: headerURL, encoding: .utf8)
        let matches = onDisk == TerminalShaderSource.header
        #expect(matches, "TerminalShaderSource.header has drifted from TBDGhosttyShaderTypes.h; copy the header in again")
    }

    @Test func shaderSourceGuardsItsInclude() {
        let source = TerminalShaderSource.source
        // The directives themselves, matched as whole lines. The header's own comments quote the
        // guard condition in prose, so a bare search for `#if !defined(...)` finds that first.
        let guardedInclude = "\n#if !defined(TKZ_SHADER_TYPES_H)\n#include \"TBDGhosttyShaderTypes.h\"\n#endif\n"
        #expect(source.hasPrefix(TerminalShaderSource.header), "the source does not start with the header")
        let guardRange = source.range(of: guardedInclude)
        #expect(guardRange != nil, "the shader's include of TBDGhosttyShaderTypes.h is not guarded")
        if let guardRange {
            let headerBytes = TerminalShaderSource.header.utf8.count
            let guardOffset = source.utf8.distance(from: source.startIndex, to: guardRange.lowerBound)
            #expect(headerBytes <= guardOffset, "the header must come before the shader's guarded include")
        }
        // The guarded include must be the only one: an unguarded include asks the runtime
        // compiler for a file it has no search path to find.
        let includes = source.components(separatedBy: "\n#include \"TBDGhosttyShaderTypes.h\"").count - 1
        #expect(includes == 1, "the source includes TBDGhosttyShaderTypes.h \(includes) times; only the guarded include may")
    }

    /// The same sizes the header's `_Static_assert`s pin. Swift sees the structs through the C
    /// target, so a field added on one side only shows up here.
    @Test func sharedStructSizesMatchTheShaderContract() {
        #expect(MemoryLayout<TkzUniforms>.size == 80)
        #expect(MemoryLayout<TkzBgCell>.size == 4)
        #expect(MemoryLayout<TkzGlyphInstance>.size == 32)
        #expect(MemoryLayout<TkzRectInstance>.size == 32)
        #expect(MemoryLayout<TkzGlyphInstance>.stride == 32)
        #expect(MemoryLayout<TkzRectInstance>.stride == 32)
    }

    /// Clearing a full atlas makes a new texture, as growing does. A frame already encoded may
    /// still be sampling the old one on the GPU, and clearing that in place would tear its glyphs.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func rebuildingAFullAtlasMakesANewTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = GlyphAtlas(kind: .grayscale, device: device, initialSize: AtlasKind.grayscale.maxSize)
        let edge = atlas.size
        // A column as tall as the atlas takes its only possible shelf...
        let column = atlas.insert(pixels: [UInt8](repeating: 255, count: edge), width: 1, height: edge, bytesPerRow: 1)
        try #require(column != nil, "a one-pixel column did not fit an empty atlas")
        let before = try #require(atlas.texture)

        // ...so a row as wide as the atlas fits nowhere, and the atlas is cleared to take it.
        let row = atlas.insert(pixels: [UInt8](repeating: 255, count: edge), width: edge, height: 1, bytesPerRow: edge)
        #expect(row != nil, "the row did not fit even an atlas cleared for it")
        #expect(atlas.rebuildCount == 1, "the atlas was rebuilt \(atlas.rebuildCount) times, not once")
        let after = try #require(atlas.texture)
        #expect(after !== before, "the rebuild cleared, in place, the texture an encoded frame may be sampling")
    }

    /// Views with the same font and scale share one renderer, and so one glyph cache. When another
    /// surface's frame clears the atlas, an idle surface's rows still hold positions in the old
    /// one. Its next frame, here a cursor blink, must rebuild every row against the new atlas, not
    /// draw the old positions over whatever was packed there since.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, noMetalDevice))
    func anIdleSurfaceRebuildsItsRowsWhenAnotherSurfaceClearsTheSharedAtlas() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let glyphCache = GlyphCache(fontSet: FontSet(font: font, scale: 2), device: device)
        let renderer = try TerminalRenderer(device: device, glyphCache: glyphCache)
        let size = renderer.drawableSize(columns: 10, rows: 3)
        let atlas = glyphCache.grayscale
        try #require(atlas.size == AtlasKind.grayscale.maxSize,
                     "the atlas starts at \(atlas.size) px, so filling it would grow it, not clear it")

        // Surface A draws an "A", the only glyph in the atlas, and goes idle.
        let terminalA = try GhosttyTerminal(
            cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminalA.close() }
        terminalA.feed(text: "A")
        let surfaceA = TerminalSurface()
        try surfaceA.attach(terminalA)
        let textureA = try #require(renderer.makeOffscreenTexture(width: size.width, height: size.height))
        try renderer.render(surface: surfaceA, to: textureA).commandBuffer?.waitUntilCompleted()
        let idle = try renderer.render(surface: surfaceA, to: textureA)
        try #require(!idle.didEncode, "surface A drew again with nothing changed, so it never went idle")

        // Fill the atlas around the "A": the rest of its shelf, then everything under that shelf.
        // The next glyph packed anywhere then clears the atlas.
        let slotA = try #require(glyphCache.glyph(forScalar: "A", cellSpan: 1)?.slot, "surface A's A was not cached")
        try #require(slotA.x == 0 && slotA.y == 0,
                     "the A sits at (\(slotA.x), \(slotA.y)), so it was not the first glyph in the atlas")
        let edge = atlas.size
        let rebuildsBefore = atlas.rebuildCount
        let restOfShelf = edge - slotA.width
        let underShelf = edge - slotA.height
        try #require(atlas.insert(pixels: [UInt8](repeating: 0, count: restOfShelf * slotA.height),
                                  width: restOfShelf, height: slotA.height, bytesPerRow: restOfShelf) != nil)
        try #require(atlas.insert(pixels: [UInt8](repeating: 0, count: edge * underShelf),
                                  width: edge, height: underShelf, bytesPerRow: edge) != nil)
        try #require(atlas.rebuildCount == rebuildsBefore, "filling the atlas cleared it already")

        // Surface B's frame packs a "B", which fits nowhere, so the atlas is cleared and the "B" goes
        // where the "A" was.
        let terminalB = try GhosttyTerminal(
            cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminalB.close() }
        terminalB.feed(text: "B")
        let surfaceB = TerminalSurface()
        try surfaceB.attach(terminalB)
        let textureB = try #require(renderer.makeOffscreenTexture(width: size.width, height: size.height))
        try renderer.render(surface: surfaceB, to: textureB).commandBuffer?.waitUntilCompleted()
        try #require(atlas.rebuildCount == rebuildsBefore + 1,
                     "surface B's frame cleared the atlas \(atlas.rebuildCount - rebuildsBefore) times, not once")

        // Surface A's cells are still clean. Only its cursor blinks.
        surfaceA.cursorBlinkOn.toggle()
        let blink = try renderer.render(surface: surfaceA, to: textureA)
        blink.commandBuffer?.waitUntilCompleted()
        #expect(blink.didEncode, "the blink drew no frame")
        #expect(blink.update.dirty == .full,
                "the blink after the atlas was cleared was a \(blink.update.dirty) frame, not a full rebuild")
        #expect(blink.update.rowsRebuilt == 3, "the blink rebuilt \(blink.update.rowsRebuilt) of 3 rows")
        let freshA = try #require(glyphCache.glyph(forScalar: "A", cellSpan: 1)?.slot)
        let drawnAt = surfaceA.withGlyphInstances { instances in instances.map { $0.atlasPos } }
        #expect(drawnAt == [SIMD2<UInt16>(UInt16(freshA.x), UInt16(freshA.y))],
                "surface A draws its A from atlas position \(drawnAt), but the A is now at (\(freshA.x), \(freshA.y))")
    }

    /// A block cursor on either half of a wide character covers both of its cells, and the
    /// character's glyph, anchored on the lead, is the one drawn in the cursor's text colour. The
    /// rect and the marked glyph must agree: a block over one cell under a glyph drawn in the
    /// background colour leaves the glyph's other half invisible. Built without a GPU: the frame
    /// builder and the atlas's staging need none.
    ///
    /// - Parameter cursorColumn: the 1-based column CHA moves the cursor to: 1 is the lead, 2 the tail.
    @Test(arguments: [1, 2])
    func aBlockCursorOnEitherHalfOfAWideCharacterCoversBothCells(cursorColumn: Int) throws {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let builder = FrameBuilder(glyphCache: GlyphCache(fontSet: FontSet(font: font, scale: 2), device: nil))
        let terminal = try GhosttyTerminal(cols: 10, rows: 3, scrollbackLines: 100, callbacks: GhosttyTerminalCallbacks())
        defer { terminal.close() }
        // A wide character in columns 0 and 1, then the cursor back onto one of them.
        terminal.feed(text: "中\u{1b}[\(cursorColumn)G")
        let surface = TerminalSurface()
        try surface.attach(terminal)
        try builder.update(surface)

        let cursor = surface.cursor
        try #require(cursor.column == cursorColumn - 1 && cursor.isWideTail == (cursorColumn == 2),
                     "the cursor is at column \(cursor.column), wide tail \(cursor.isWideTail)")
        try #require(cursor.style == .block, "the cursor is a \(cursor.style), not a block")
        let anchored = surface.glyphInstances().first { $0.gridPos.x == 0 && $0.gridPos.y == 0 }
        let glyph = try #require(anchored, "no glyph was built for the wide character")
        #expect(glyph.flags & UInt32(TKZ_GLYPH_FLAG_UNDER_CURSOR) != 0,
                "the wide glyph under the block cursor is not marked: flags \(glyph.flags)")

        let metrics = try #require(surface.metrics, "the frame builder gave the surface no cell metrics")
        let geometry = GridGeometry(metrics: metrics, viewportWidth: 10 * metrics.width, viewportHeight: 3 * metrics.height)
        let rect = try #require(surface.cursorRect(geometry: geometry), "the block cursor has no rect")
        #expect(rect.originPx == geometry.origin(ofColumn: 0, row: 0),
                "the block starts at \(rect.originPx), not on the wide character's lead cell")
        #expect(rect.sizePx.x == geometry.cellSizePx.x * 2,
                "the block is \(rect.sizePx.x) px wide, not the wide character's two cells")
    }

    /// A frame that acquires a slot and bails before committing must not move the ring on: the
    /// next frame takes the same slot. Only committed frames advance it.
    @Test func frameRingAdvancesOnlyOnCommit() {
        let ring = FrameRing()
        let bailed = ring.acquire()
        ring.release()
        let retried = ring.acquire()
        #expect(retried === bailed, "a frame that bailed moved the ring on to another slot")

        // Committed frames cycle through every slot before reusing one. Each committed frame's
        // permit stays with the "GPU" until its releaser runs, as a completion handler would.
        ring.commit()
        var committed = [retried]
        for _ in 1..<FrameRing.depth {
            let slot = ring.acquire()
            ring.commit()
            committed.append(slot)
        }
        for (index, slot) in committed.enumerated() {
            for other in committed[(index + 1)...] {
                #expect(slot !== other, "two committed frames in a row shared a slot")
            }
        }
        for _ in committed { ring.releaser.release() }
        #expect(ring.acquire() === committed[0], "the ring did not wrap back to the oldest slot")
        ring.release()
    }

    /// Monaco has no italic, so its italic is the regular face slanted, and an italic "l" leans:
    /// the ink at its top sits right of the ink at its foot. Menlo has a real italic, which is
    /// used as it is.
    @Test(.enabled(if: NSFont(name: "Monaco", size: 13) != nil && NSFont(name: "Menlo", size: 13) != nil,
                   "Monaco or Menlo is not installed"))
    func familyWithoutItalicGetsASlantedFace() throws {
        let monaco = FontSet(font: try #require(NSFont(name: "Monaco", size: 13)), scale: 2)
        #expect(monaco.needsSyntheticItalic, "Monaco was taken to have an italic face")
        let shear = CTFontGetMatrix(monaco.font(for: .italic)).c
        #expect(abs(shear - tan(FontSet.syntheticItalicSkew)) < 0.001, "the italic face's shear is \(shear)")

        let metrics = CellMetrics(fontSet: monaco)
        let shaper = GraphemeShaper(fontSet: monaco)
        let rasterizer = GlyphRasterizer(fontSet: monaco, metrics: metrics)
        let upright = try #require(rasterizer.rasterize(shaper.shape("l", style: .regular), style: .regular))
        let slanted = try #require(rasterizer.rasterize(shaper.shape("l", style: .italic), style: .italic))
        let lean = inkLean(of: slanted) - inkLean(of: upright)
        #expect(lean > 1.5, "the italic l leans \(lean) px further right at the top than the upright one")

        let menlo = FontSet(font: try #require(NSFont(name: "Menlo", size: 13)), scale: 2)
        #expect(!menlo.needsSyntheticItalic, "Menlo's italic was synthesized")
        #expect(CTFontGetMatrix(menlo.font(for: .italic)).c == 0, "Menlo's real italic was slanted again")
    }

    @Test func selectionCompositesOverTheCellBackground() {
        // White at 20% over black is 51 grey, opaque.
        let blended = composite(FrameBuilder.defaultSelectionColor, over: 0xFF00_0000)
        #expect(blended == 0xFF33_3333, "got \(String(blended, radix: 16))")
        // Fully transparent changes nothing but the alpha.
        #expect(composite(0x00FF_FFFF, over: 0x0012_3456) == 0xFF12_3456)
    }
}

/// How many pixels further right the ink in a grayscale glyph's top quarter sits than the ink
/// in its bottom quarter. The bitmap's first row is its top.
private func inkLean(of glyph: RasterizedGlyph) -> Double {
    func centroid(of rows: Range<Int>) -> Double {
        var weighted = 0.0
        var total = 0.0
        for y in rows {
            for x in 0..<glyph.width {
                let ink = Double(glyph.pixels[y * glyph.bytesPerRow + x * glyph.bytesPerPixel])
                weighted += ink * Double(x)
                total += ink
            }
        }
        return total > 0 ? weighted / total : 0
    }
    let quarter = max(1, glyph.height / 4)
    return centroid(of: 0..<quarter) - centroid(of: (glyph.height - quarter)..<glyph.height)
}
