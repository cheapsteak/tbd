// Adapted from tkzmux c961533 Sources/TkzTerminalRender/GlyphAtlas.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// GlyphAtlas + GlyphCache — one app-wide pair of Metal glyph atlases.
//
// `.grayscale` is `r8Unorm` 2048², `.color` is `bgra8Unorm` 1024² growing to 2048². Packing is a
// shelf packer over a CPU staging buffer; the staging copy is what makes regrow cheap (re-upload,
// no re-rasterization), gives "one `replace(region:)` per frame" (a single dirty bounding box), and
// provides the `--png` dump for free.
//
// Every slot carries the atlas `generation`. It increments whenever coordinates or texture identity
// change — on regrow (UVs change because the atlas got bigger) and on rebuild after overflow (the
// contents are gone). Holders of slots must check `isValid(_:)` and re-insert when it fails.
//
// `GlyphCache` is the explicit single owner of the pair: there is one per app, shared by all
// sessions, and nothing else should construct a `GlyphAtlas`.

import CoreGraphics
import Foundation
import Metal

enum AtlasKind: Sendable, Hashable {
    case grayscale
    case color

    var bytesPerPixel: Int { self == .grayscale ? 1 : 4 }
    var pixelFormat: MTLPixelFormat { self == .grayscale ? .r8Unorm : .bgra8Unorm }
    var defaultInitialSize: Int { self == .grayscale ? 2048 : 1024 }
    var maxSize: Int { 2048 }
}

/// Where a glyph lives in an atlas, stamped with the generation it was packed in.
struct AtlasSlot: Sendable, Equatable, Hashable {
    let kind: AtlasKind
    let generation: UInt64
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    /// Atlas edge length when the slot was packed, so UVs can be recomputed without asking the atlas.
    let atlasSize: Int

    /// Normalized texture coordinates of the slot's top-left / bottom-right corners.
    var uvOrigin: (Float, Float) {
        (Float(x) / Float(atlasSize), Float(y) / Float(atlasSize))
    }
    var uvSize: (Float, Float) {
        (Float(width) / Float(atlasSize), Float(height) / Float(atlasSize))
    }
}

/// A shelf-packed glyph atlas backed by a CPU staging buffer and (optionally) an `MTLTexture`.
///
/// Not `Sendable` (`MTLTexture` is not); owned by `GlyphCache` on the render thread.
final class GlyphAtlas {
    let kind: AtlasKind
    private(set) var size: Int
    private(set) var generation: UInt64 = 1
    /// The generation the pixels were last thrown away at. A slot from at or after this generation
    /// still points at its own pixels, even if the atlas has since grown.
    private(set) var rebuildGeneration: UInt64 = 1
    /// Increments every time the atlas is cleared because it ran out of room at max size.
    private(set) var rebuildCount: Int = 0
    /// Increments every time the atlas doubled.
    private(set) var growCount: Int = 0

    /// The GPU texture. `nil` on a machine with no Metal device — everything else still works, which
    /// is what makes the packer and the PNG dump testable headlessly.
    private(set) var texture: MTLTexture?
    private let device: MTLDevice?

    private var staging: [UInt8]
    private var shelves: [Shelf] = []
    private var dirty: CGRect = .null

    private struct Shelf {
        var y: Int
        var height: Int
        var nextX: Int
    }

    /// - Parameters:
    ///   - device: Metal device, or `nil` for a CPU-only atlas (tests, headless dumps).
    ///   - initialSize: edge length to start at; defaults to the kind's design value. Tests use a
    ///     small value to exercise regrow without allocating megabytes.
    init(kind: AtlasKind, device: MTLDevice?, initialSize: Int? = nil) {
        self.kind = kind
        self.device = device
        let start = min(max(initialSize ?? kind.defaultInitialSize, 16), kind.maxSize)
        self.size = start
        self.staging = [UInt8](repeating: 0, count: start * start * kind.bytesPerPixel)
        self.texture = GlyphAtlas.makeTexture(device: device, kind: kind, size: start)
    }

    private static func makeTexture(device: MTLDevice?, kind: AtlasKind, size: Int) -> MTLTexture? {
        guard let device else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: kind.pixelFormat, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: - Validity

    /// True when `slot` is usable as-is: same atlas, current generation.
    func isValid(_ slot: AtlasSlot) -> Bool {
        slot.kind == kind && slot.generation == generation
    }

    /// Re-stamps a stale slot when its pixels survived.
    ///
    /// A *regrow* copies every packed pixel into the larger texture, so the x/y/w/h stay correct and
    /// only the normalization changes — such a slot is refreshed here without re-rasterizing.
    /// A *rebuild* throws the pixels away, and slots from before it return `nil`.
    func revalidate(_ slot: AtlasSlot) -> AtlasSlot? {
        guard slot.kind == kind else { return nil }
        if slot.generation == generation { return slot }
        guard slot.generation >= rebuildGeneration else { return nil }
        guard slot.x + slot.width <= size, slot.y + slot.height <= size else { return nil }
        return AtlasSlot(kind: kind, generation: generation, x: slot.x, y: slot.y,
                         width: slot.width, height: slot.height, atlasSize: size)
    }

    // MARK: - Insertion

    /// Packs `width * height` pixels, growing or rebuilding as needed.
    /// Returns `nil` only when the glyph cannot fit an empty max-size atlas.
    @discardableResult
    func insert(pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int) -> AtlasSlot? {
        guard width > 0, height > 0 else { return nil }

        while true {
            if let slot = pack(width: width, height: height) {
                blit(pixels: pixels, bytesPerRow: bytesPerRow, slot: slot)
                return slot
            }
            if size < kind.maxSize {
                grow()
            } else if !shelves.isEmpty {
                rebuild()
            } else {
                return nil  // does not fit an empty max-size atlas
            }
        }
    }

    private func pack(width: Int, height: Int) -> AtlasSlot? {
        guard width <= size, height <= size else { return nil }
        // Best fit: the shortest shelf that is still tall enough.
        var bestIndex: Int?
        for (i, shelf) in shelves.enumerated()
        where shelf.height >= height && shelf.nextX + width <= size {
            if bestIndex == nil || shelf.height < shelves[bestIndex!].height { bestIndex = i }
        }
        if let i = bestIndex {
            let slot = AtlasSlot(kind: kind, generation: generation, x: shelves[i].nextX,
                                 y: shelves[i].y, width: width, height: height, atlasSize: size)
            shelves[i].nextX += width
            return slot
        }
        // New shelf on top of the tallest used row.
        let top = shelves.reduce(0) { max($0, $1.y + $1.height) }
        guard top + height <= size else { return nil }
        shelves.append(Shelf(y: top, height: height, nextX: width))
        return AtlasSlot(kind: kind, generation: generation, x: 0, y: top,
                         width: width, height: height, atlasSize: size)
    }

    private func blit(pixels: [UInt8], bytesPerRow: Int, slot: AtlasSlot) {
        let bpp = kind.bytesPerPixel
        let stride = size * bpp
        let rowBytes = slot.width * bpp
        for row in 0..<slot.height {
            let src = row * bytesPerRow
            let dst = (slot.y + row) * stride + slot.x * bpp
            guard src + rowBytes <= pixels.count, dst + rowBytes <= staging.count else { break }
            staging.replaceSubrange(dst..<(dst + rowBytes), with: pixels[src..<(src + rowBytes)])
        }
        dirty = dirty.union(CGRect(x: slot.x, y: slot.y, width: slot.width, height: slot.height))
    }

    // MARK: - Grow / rebuild

    private func grow() {
        let newSize = min(size * 2, kind.maxSize)
        guard newSize > size else { return }
        let bpp = kind.bytesPerPixel
        var newStaging = [UInt8](repeating: 0, count: newSize * newSize * bpp)
        let oldStride = size * bpp
        let newStride = newSize * bpp
        for row in 0..<size {
            let src = row * oldStride
            let dst = row * newStride
            newStaging.replaceSubrange(dst..<(dst + oldStride), with: staging[src..<(src + oldStride)])
        }
        staging = newStaging
        size = newSize
        texture = GlyphAtlas.makeTexture(device: device, kind: kind, size: newSize)
        // Pixel coordinates survive, but UVs and the texture identity do not: bump the generation
        // so every holder re-reads its slot.
        generation &+= 1
        growCount += 1
        dirty = CGRect(x: 0, y: 0, width: size, height: size)
    }

    private func rebuild() {
        staging = [UInt8](repeating: 0, count: staging.count)
        shelves.removeAll(keepingCapacity: true)
        // A new texture, as `grow()` makes: frames already encoded may still be sampling the old
        // one on the GPU, and clearing it in place would tear their glyphs.
        texture = GlyphAtlas.makeTexture(device: device, kind: kind, size: size)
        generation &+= 1
        rebuildGeneration = generation
        rebuildCount += 1
        dirty = CGRect(x: 0, y: 0, width: size, height: size)
    }

    // MARK: - Upload

    /// True when there are staged pixels the GPU has not seen.
    var hasPendingUpload: Bool { !dirty.isNull }

    /// Uploads everything staged since the last flush as a single `replace(region:)`.
    /// Call once per frame, before encoding.
    func flush() {
        guard let texture, !dirty.isNull else { dirty = .null; return }
        let x = Int(dirty.minX), y = Int(dirty.minY)
        let w = Int(dirty.width), h = Int(dirty.height)
        guard w > 0, h > 0 else { dirty = .null; return }
        let bpp = kind.bytesPerPixel
        let stride = size * bpp
        staging.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(x, y, w, h),
                mipmapLevel: 0,
                withBytes: base.advanced(by: y * stride + x * bpp),
                bytesPerRow: stride)
        }
        dirty = .null
    }

    // MARK: - Dump

    /// The whole atlas as a `CGImage`, for tests and eyeball checks.
    func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(staging) as CFData) else { return nil }
        let bpp = kind.bytesPerPixel
        if kind == .color {
            return CGImage(
                width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: size * bpp, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: size * bpp, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Reads one staged pixel's bytes (diagnostics and tests).
    func stagedPixel(x: Int, y: Int) -> [UInt8] {
        let bpp = kind.bytesPerPixel
        guard x >= 0, y >= 0, x < size, y < size else { return [] }
        let offset = y * size * bpp + x * bpp
        return Array(staging[offset..<(offset + bpp)])
    }
}

// MARK: - GlyphCache

/// A glyph placed in an atlas: everything `FrameBuilder` needs for one instance.
struct CachedGlyph: Sendable, Equatable {
    let slot: AtlasSlot
    let bearingX: Int
    let bearingTop: Int
    let cellSpan: Int
    var isColor: Bool { slot.kind == .color }
}

/// The single app-wide owner of the grayscale + colour atlases, the font set, the shaper and the
/// rasterizer. Construct one; pass it around; never build a `GlyphAtlas` yourself.
///
/// Not `Sendable`; lives on the render thread.
final class GlyphCache {
    let fontSet: FontSet
    let metrics: CellMetrics
    let shaper: GraphemeShaper
    let rasterizer: GlyphRasterizer
    /// Box-drawing and block-element sprites, drawn instead of the font's own glyphs so they tile.
    let sprites: BoxSprites
    let grayscale: GlyphAtlas
    let color: GlyphAtlas

    /// The cache key for one grapheme cluster.
    ///
    /// Split into `scalar` + `rest` rather than one `[UInt32]` so the common case carries no array:
    /// a single-scalar cluster — all ASCII, and most everything else — hashes as three integers,
    /// where a `[UInt32]`-backed key had to allocate the array and then walk it to hash it. On a
    /// 125×40 grid that allocation happened once per cell per rebuilt row.
    private struct Key: Hashable {
        let scalar: UInt32
        /// The scalars after the first, or `nil` for a single-scalar cluster.
        let rest: [UInt32]?
        let style: FontStyle
        let span: Int

        init(scalar: Unicode.Scalar, style: FontStyle, span: Int) {
            self.scalar = scalar.value
            self.rest = nil
            self.style = style
            self.span = span
        }

        init(scalars: [Unicode.Scalar], style: FontStyle, span: Int) {
            self.scalar = scalars.first?.value ?? 0
            self.rest = scalars.count > 1 ? scalars.dropFirst().map(\.value) : nil
            self.style = style
            self.span = span
        }
    }

    /// What the cache knows about a cluster.
    ///
    /// `.empty` is the load-bearing case. A space — and any control character, and anything else
    /// whose glyph bounds come back empty from `GlyphRasterizer.rasterize` — has nothing to draw,
    /// and the obvious spelling `entries[key] = nil` does not record that: in Swift it *removes*
    /// the key. So every blank-but-written cell used to re-shape and re-rasterize on every rebuilt
    /// row, re-entering CoreText (`CTFontGetBoundingRectsForGlyphs`) each time. Measured upstream
    /// on a 125×40 grid of spaces, that was **4.40 ms per frame** for a screen that draws nothing
    /// at all — over half the 8.3 ms budget at 120 Hz.
    private enum CacheEntry {
        case glyph(CachedGlyph)
        /// Shaped and rasterized, and there is nothing to draw. Holds no atlas pixels, so unlike
        /// `.glyph` it survives an atlas rebuild untouched.
        case empty
    }
    private var entries: [Key: CacheEntry] = [:]

    /// - Parameter thicken: font smoothing on grayscale glyphs (`GlyphRasterizer.thicken`). Off by
    ///   default, and `TerminalRenderContext` passes none, so text has SwiftTerm's stroke weight.
    init(fontSet: FontSet,
         device: MTLDevice?,
         grayscaleInitialSize: Int? = nil,
         colorInitialSize: Int? = nil,
         thicken: Bool = false) {
        let metrics = CellMetrics(fontSet: fontSet)
        let rasterizer = GlyphRasterizer(fontSet: fontSet, metrics: metrics, thicken: thicken)
        self.fontSet = fontSet
        self.metrics = metrics
        self.shaper = GraphemeShaper(fontSet: fontSet)
        self.rasterizer = rasterizer
        self.sprites = BoxSprites(metrics: metrics, padding: rasterizer.padding)
        self.grayscale = GlyphAtlas(kind: .grayscale, device: device, initialSize: grayscaleInitialSize)
        self.color = GlyphAtlas(kind: .color, device: device, initialSize: colorInitialSize)
    }

    func atlas(for kind: AtlasKind) -> GlyphAtlas {
        kind == .grayscale ? grayscale : color
    }

    /// Shapes, rasterizes and packs a single-scalar grapheme, or returns the cached placement.
    ///
    /// The hot entry point: `FrameBuilder` calls this for every cell whose cluster is one scalar,
    /// which avoids building a `[Unicode.Scalar]` per cell on top of avoiding the key array.
    /// Returns `nil` for anything with nothing to draw (space, control characters).
    ///
    /// Spelled `forScalar:` rather than `for:` on purpose: a string literal like `"A"` satisfies
    /// both `Unicode.Scalar` and `Character`, so a `for:` overload would make every existing
    /// `glyph(for: "A")` call ambiguous.
    func glyph(forScalar scalar: Unicode.Scalar,
               style: FontStyle = .regular,
               cellSpan: Int? = nil) -> CachedGlyph? {
        if BoxSprites.covers(scalar) {
            let key = Key(scalar: scalar, style: .regular, span: 1)
            switch validated(key) {
            case .glyph(let entry): return entry
            case .empty: return nil
            case nil: break
            }
            if let raster = sprites.rasterize(scalar) {
                return pack(raster, cellSpan: 1, key: key)
            }
            // No sprite for this scalar after all: fall through to the font.
        }
        if let cellSpan {
            switch validated(Key(scalar: scalar, style: style, span: cellSpan)) {
            case .glyph(let entry): return entry
            case .empty: return nil
            case nil: break
            }
        }
        // Miss: build the array the shaper and rasterizer need and take the general path.
        return glyph(for: [scalar], style: style, cellSpan: cellSpan)
    }

    /// Shapes, rasterizes and packs a grapheme, or returns the cached placement.
    /// Returns `nil` for clusters with nothing to draw (space, control characters).
    func glyph(for scalars: [Unicode.Scalar],
               style: FontStyle = .regular,
               cellSpan: Int? = nil) -> CachedGlyph? {
        // Box drawing and block elements are drawn, not shaped: same sprite for every style, and one
        // cell wide by definition. Keyed as `.regular` so bold text does not cache a second copy.
        let isSprite = BoxSprites.covers(scalars)
        if isSprite {
            let key = Key(scalars: scalars, style: .regular, span: 1)
            switch validated(key) {
            case .glyph(let entry): return entry
            case .empty: return nil
            case nil: break
            }
            if let raster = sprites.rasterize(scalars[0]) {
                return pack(raster, cellSpan: 1, key: key)
            }
            // No sprite for this scalar after all: fall through to the font.
        }

        // The span decides the key, and when the caller already knows it — `FrameBuilder` always
        // does, from libghostty's authoritative WIDE flag — the key is fully determined here. So
        // the cache is consulted *before* the shaper, which on a hit skips the shaper's own
        // dictionary lookup and the key array it would have built for it.
        if let cellSpan {
            switch validated(Key(scalars: scalars, style: style, span: cellSpan)) {
            case .glyph(let entry): return entry
            case .empty: return nil
            case nil: break
            }
        }

        let shaped = shaper.shape(scalars, style: style, cellSpan: cellSpan)
        let key = Key(scalars: scalars, style: style, span: shaped.cellSpan)
        if cellSpan == nil {
            switch validated(key) {
            case .glyph(let entry): return entry
            case .empty: return nil
            case nil: break
            }
        }
        guard let raster = rasterizer.rasterize(shaped, style: style) else {
            entries[key] = .empty
            return nil
        }
        return pack(raster, cellSpan: shaped.cellSpan, key: key)
    }

    /// What the cache holds for `key`, re-stamped after a regrow. `nil` means "not cached, draw it";
    /// `.empty` means "cached, and there is nothing to draw".
    private func validated(_ key: Key) -> CacheEntry? {
        guard let cached = entries[key] else { return nil }
        guard case .glyph(let glyph) = cached else { return .empty }
        let target = atlas(for: glyph.slot.kind)
        if target.isValid(glyph.slot) { return cached }
        // A regrow moved the goalposts but kept the pixels: just re-stamp the slot.
        guard let refreshed = target.revalidate(glyph.slot) else { return nil }
        let entry = CachedGlyph(slot: refreshed, bearingX: glyph.bearingX,
                                bearingTop: glyph.bearingTop, cellSpan: glyph.cellSpan)
        entries[key] = .glyph(entry)
        return .glyph(entry)
    }

    /// Packs a freshly drawn bitmap into its atlas and records the placement.
    private func pack(_ raster: RasterizedGlyph, cellSpan: Int, key: Key) -> CachedGlyph? {
        let target = atlas(for: raster.isColor ? .color : .grayscale)
        let generationBefore = target.generation
        guard let slot = target.insert(pixels: raster.pixels, width: raster.width,
                                       height: raster.height, bytesPerRow: raster.bytesPerRow)
        else { return nil }
        if target.rebuildGeneration > generationBefore {
            // The atlas was cleared while packing: every other entry in it lost its pixels.
            dropEntries(in: target.kind, keeping: key)
        }
        let entry = CachedGlyph(slot: slot, bearingX: raster.bearingX,
                                bearingTop: raster.bearingTop, cellSpan: cellSpan)
        entries[key] = .glyph(entry)
        return entry
    }

    func glyph(for character: Character,
               style: FontStyle = .regular,
               cellSpan: Int? = nil) -> CachedGlyph? {
        glyph(for: Array(character.unicodeScalars), style: style, cellSpan: cellSpan)
    }

    /// Drops every entry whose pixels lived in the atlas that was just cleared. `.empty` entries
    /// hold no pixels, so they are deliberately kept — re-deriving them is the expensive thing this
    /// cache exists to avoid.
    private func dropEntries(in kind: AtlasKind, keeping key: Key) {
        for (k, v) in entries {
            guard case .glyph(let glyph) = v, glyph.slot.kind == kind, k != key else { continue }
            entries.removeValue(forKey: k)
        }
    }

    /// One `replace(region:)` per atlas per frame. Call before encoding.
    func flushUploads() {
        grayscale.flush()
        color.flush()
    }

    /// Number of cached clusters (diagnostics and tests).
    ///
    /// Counts `.empty` entries too — a cluster with nothing to draw is a cached answer like any
    /// other, and the whole point of keeping it is that it is never re-derived.
    var cachedCount: Int { entries.count }
}
