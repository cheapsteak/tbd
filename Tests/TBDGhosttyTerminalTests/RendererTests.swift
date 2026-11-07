import AppKit
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
        let headerEnd = source.range(of: TerminalShaderSource.header)?.upperBound
        let guardStart = source.range(of: "#if !defined(TKZ_SHADER_TYPES_H)")?.lowerBound
        #expect(headerEnd != nil, "the source does not start with the header")
        #expect(guardStart != nil, "the shader's include is not guarded")
        if let headerEnd, let guardStart {
            #expect(headerEnd <= guardStart, "the header must come before the shader's guarded include")
        }
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

    @Test func selectionCompositesOverTheCellBackground() {
        // White at 20% over black is 51 grey, opaque.
        let blended = composite(FrameBuilder.defaultSelectionColor, over: 0xFF00_0000)
        #expect(blended == 0xFF33_3333, "got \(String(blended, radix: 16))")
        // Fully transparent changes nothing but the alpha.
        #expect(composite(0x00FF_FFFF, over: 0x0012_3456) == 0xFF12_3456)
    }
}
