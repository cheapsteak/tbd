// Adapted from tkzmux c961533 Sources/TkzTerminalRender/TerminalRenderer.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// TerminalRenderer — the three-pass Metal renderer.
// See TBDGhosttyShaderTypes.h for the contract.
//
// One instance per font and backing scale: it owns the pipelines, the shared `GlyphCache` (both
// atlases) and the `FrameBuilder`. Terminals come and go through `TerminalSurface`, each with its
// own ring of instance buffers; the renderer itself never changes.
//
// Draw order, all into one `.bgra8Unorm` attachment (see `TerminalShaderSource.metal`):
//
//   1. background   full-screen triangle, blending OFF, `TkzBgCell[cols*rows]`
//   2. rects-below  filled cursor                       `.triangleStrip` × 4, instanced
//   3. glyphs       one quad per glyph                   both atlases bound, always
//   4. rects-above  underline / strike / hollow cursor   the *same* rect pipeline again
//
// ## The idle guarantee
//
// `dirty == FALSE` and no overlay change ⇒ **no drawable is acquired, not one byte is written to an
// instance buffer, and `render` returns early**. It is instrumented rather than asserted: `stats`
// counts bytes written, drawables acquired, frames encoded and frames skipped, and the tests read
// those counters.

import CoreGraphics
import Foundation
import Metal
import QuartzCore
import TBDGhosttyShaderTypes

// MARK: - Stats

/// Instrumentation for the idle guarantee. Reset with `TerminalRenderer.resetStats()`.
struct RenderStats: Sendable, Hashable {
    /// Frames actually encoded and committed.
    var framesEncoded = 0
    /// Frames that returned early because nothing changed (or nothing was attached).
    var framesSkipped = 0
    /// Frames that got as far as asking for a render target (`nextDrawable()` on the layer path).
    /// The idle guarantee is `drawableRequests == 0` for a skipped frame.
    var drawableRequests = 0
    /// `CAMetalLayer.nextDrawable()` calls that returned a drawable.
    var drawablesAcquired = 0
    /// Bytes copied into the bg / glyph / rect instance buffers.
    var instanceBytesWritten = 0
    /// Bytes of `TkzUniforms` pushed with `setVertexBytes` / `setFragmentBytes`.
    var uniformBytesWritten = 0
    /// Frames dropped because the layer had no drawable to give.
    var nilDrawables = 0

    init() {}
}

/// What one `render` call did. Not `Sendable`: it carries the `MTLCommandBuffer` so the caller can
/// `waitUntilCompleted()` (offscreen readback) or simply drop it (on-screen presentation).
struct RenderOutcome {
    let didEncode: Bool
    let commandBuffer: MTLCommandBuffer?
    let update: FrameUpdate
    let glyphCount: Int
    let rectCount: Int

    /// The frame was skipped because nothing changed.
    var wasSkipped: Bool { !didEncode }
}

// MARK: - TerminalRenderer

final class TerminalRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let glyphCache: GlyphCache
    let frameBuilder: FrameBuilder

    /// The selection tint, packed RGBA with straight alpha. See `FrameBuilder.selectionColor`.
    var selectionColor: UInt32 {
        get { frameBuilder.selectionColor }
        set { frameBuilder.selectionColor = newValue }
    }

    /// `TkzUniforms.minContrast`: the WCAG contrast ratio a program-coloured glyph is pushed to.
    /// 1 turns the fix off.
    var minimumContrast: Float = 1

    private(set) var stats = RenderStats()

    private let bgPipeline: MTLRenderPipelineState
    private let rectPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState

    // The instance-buffer ring lives on the `TerminalSurface`, not here: one ring per renderer
    // would make N panes in one tick contend for N of its 3 slots, and a fourth pane would block
    // the main thread on the GPU (see `FrameRing`).

    // MARK: - Init

    /// Throws `GhosttyError.renderInit` for anything Metal refuses: the command queue, a shader
    /// function, or the pipeline compile (whose own error is carried in the string).
    init(device: MTLDevice, glyphCache: GlyphCache) throws {
        self.device = device
        self.glyphCache = glyphCache
        self.frameBuilder = FrameBuilder(glyphCache: glyphCache)
        guard let queue = device.makeCommandQueue() else {
            throw GhosttyError.renderInit("MTLDevice.makeCommandQueue returned nil")
        }
        self.commandQueue = queue
        // The glyph pipeline declares both atlas textures; Metal validation faults on an unbound
        // argument even when the branch that samples it is not taken, so a CPU-only GlyphCache
        // (`device: nil`) can never drive a real renderer.
        guard glyphCache.grayscale.texture != nil, glyphCache.color.texture != nil else {
            throw GhosttyError.renderInit("TerminalRenderer needs a GlyphCache built with a device")
        }

        do {
            let library = try TerminalRenderer.makeLibrary(device: device)
            bgPipeline = try device.makeRenderPipelineState(
                descriptor: TerminalRenderer.descriptor(
                    vertex: try TerminalRenderer.function(TKZ_FN_BG_VERTEX, in: library),
                    fragment: try TerminalRenderer.function(TKZ_FN_BG_FRAGMENT, in: library),
                    blending: false))
            rectPipeline = try device.makeRenderPipelineState(
                descriptor: TerminalRenderer.descriptor(
                    vertex: try TerminalRenderer.function(TKZ_FN_RECT_VERTEX, in: library),
                    fragment: try TerminalRenderer.function(TKZ_FN_RECT_FRAGMENT, in: library),
                    blending: true))
            glyphPipeline = try device.makeRenderPipelineState(
                descriptor: TerminalRenderer.descriptor(
                    vertex: try TerminalRenderer.function(TKZ_FN_GLYPH_VERTEX, in: library),
                    fragment: try TerminalRenderer.function(TKZ_FN_GLYPH_FRAGMENT, in: library),
                    blending: true))
        } catch let error as GhosttyError {
            throw error
        } catch {
            throw GhosttyError.renderInit("shader pipeline: \(error.localizedDescription)")
        }
    }

    /// Compiles the shaders from `TerminalShaderSource`.
    ///
    /// There is no bundle and no prebuilt `default.metallib`, so the source is compiled at start-up.
    /// `makeLibrary(source:)` has no include search path, so the header's text is prepended; the
    /// shader guards its `#include` with `#if !defined(TKZ_SHADER_TYPES_H)`, which is why the header
    /// uses a classic include guard and not `#pragma once`.
    static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        try device.makeLibrary(source: TerminalShaderSource.source, options: nil)
    }

    private static func function(_ name: String, in library: MTLLibrary) throws -> MTLFunction {
        guard let function = library.makeFunction(name: name) else {
            throw GhosttyError.renderInit("the shader library has no function \(name)")
        }
        return function
    }

    private static func descriptor(
        vertex: MTLFunction, fragment: MTLFunction, blending: Bool
    ) -> MTLRenderPipelineDescriptor {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        // Quads come from [[vertex_id]] + [[instance_id]]; there is no vertex buffer to describe.
        descriptor.vertexDescriptor = nil
        let attachment: MTLRenderPipelineColorAttachmentDescriptor = descriptor.colorAttachments[0]
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = blending
        if blending {
            // Every fragment function returns premultiplied.
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return descriptor
    }

    func resetStats() { stats = RenderStats() }

    // MARK: - Public render entry points

    /// Renders `surface` into an offscreen texture (tests).
    ///
    /// The command buffer is committed but **not** waited on — call `waitUntilCompleted()` on
    /// `RenderOutcome.commandBuffer` before reading the texture back.
    @discardableResult
    func render(surface: TerminalSurface, to texture: MTLTexture) throws -> RenderOutcome {
        try renderFrame(
            surface: surface,
            width: texture.width,
            height: texture.height,
            presentViaCommandBuffer: true,
            willEncode: {},
            forceEncode: false,
            acquire: { (texture, nil) })
    }

    /// Renders `surface` into `layer`'s next drawable and presents it. The seam the view uses.
    ///
    /// A skipped frame never calls `nextDrawable()`, so an idle terminal holds no drawable and the
    /// display link can stay parked.
    ///
    /// When `layer.presentsWithTransaction` is true — the live-resize path — a drawable must NOT be
    /// presented by the command buffer. Core Animation requires the caller to wait for scheduling
    /// and then present on the calling thread, inside the same CATransaction as the layer-bounds
    /// change, or the resize tears. `renderFrame` therefore skips `commandBuffer.present` and this
    /// method does the `waitUntilScheduled()` + `drawable.present()` itself, so the caller does not
    /// have to reach around the renderer to acquire drawables (which would also lose the
    /// `drawablesAcquired` accounting).
    ///
    /// - Parameters:
    ///   - willEncode: called once the frame is known to be drawn, before anything is encoded.
    ///     The view's draw-start hook.
    ///   - onPresented: given to the drawable's `addPresentedHandler`, so it runs on whatever
    ///     thread Metal reports the present on. Not called for a skipped frame.
    @discardableResult
    func render(
        surface: TerminalSurface,
        layer: CAMetalLayer,
        willEncode: () -> Void = {},
        onPresented: (@Sendable () -> Void)? = nil
    ) throws -> RenderOutcome {
        let size = layer.drawableSize
        let synchronous = layer.presentsWithTransaction
        var acquired: (any CAMetalDrawable)?
        let outcome = try renderFrame(
            surface: surface,
            width: Int(size.width),
            height: Int(size.height),
            presentViaCommandBuffer: !synchronous,
            willEncode: willEncode,
            // `presentsWithTransaction` is a promise to Core Animation that this transaction will
            // be completed by an explicit `present()`. Skipping the frame breaks that promise: the
            // transaction never completes, and a live resize visibly stalls until the flag goes
            // back off on mouse-up. So while it is set, the idle guarantee is suspended and every
            // frame is encoded. It is only ever set during a live resize, so idle cost is unchanged.
            forceEncode: synchronous,
            acquire: { [weak self] in
                guard let drawable = layer.nextDrawable() else { return (nil, nil) }
                self?.stats.drawablesAcquired += 1
                if let onPresented { drawable.addPresentedHandler { _ in onPresented() } }
                acquired = drawable
                return (drawable.texture, drawable)
            })
        if synchronous, let drawable = acquired, let buffer = outcome.commandBuffer {
            buffer.waitUntilScheduled()
            drawable.present()
        }
        return outcome
    }

    /// A `.bgra8Unorm` `.shared` texture suitable for `render(surface:to:)` and `bgraBytes(of:)`.
    func makeOffscreenTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: max(1, width), height: max(1, height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    /// The drawable size a `columns × rows` grid needs at the current cell metrics.
    func drawableSize(columns: Int, rows: Int) -> (width: Int, height: Int) {
        (max(1, columns * glyphCache.metrics.width), max(1, rows * glyphCache.metrics.height))
    }

    // MARK: - The frame

    private func renderFrame(
        surface: TerminalSurface,
        width: Int,
        height: Int,
        presentViaCommandBuffer: Bool,
        willEncode: () -> Void,
        forceEncode: Bool,
        acquire: () -> (MTLTexture?, CAMetalDrawable?)
    ) throws -> RenderOutcome {
        // ---- The idle guarantee. Everything below this point is skipped when nothing changed. ---
        guard surface.isAttached else {
            stats.framesSkipped += 1
            return RenderOutcome(didEncode: false, commandBuffer: nil,
                                 update: FrameUpdate(dirty: .none, rowsRebuilt: 0,
                                                     glyphCount: 0, rectCount: 0),
                                 glyphCount: 0, rectCount: 0)
        }
        let update = try frameBuilder.update(surface)
        guard surface.needsDisplay || forceEncode, width > 0, height > 0 else {
            stats.framesSkipped += 1
            return RenderOutcome(didEncode: false, commandBuffer: nil, update: update,
                                 glyphCount: surface.glyphCount, rectCount: surface.rectCount)
        }

        willEncode()
        let metrics = glyphCache.metrics
        let geometry = GridGeometry(metrics: metrics, viewportWidth: width, viewportHeight: height)
        let rectsBelow = surface.rectInstancesBelow(geometry: geometry)

        // One `replace(region:)` per atlas per frame, before anything is encoded.
        glyphCache.flushUploads()

        // Lazily, because a `TerminalSurface` has no `MTLDevice` of its own: it holds the ring,
        // the renderer creates it on first encode.
        let ring = surface.frameRing ?? { let fresh = FrameRing(); surface.frameRing = fresh; return fresh }()
        let slot = ring.acquire()

        let backgroundBuffer = upload(surface.backgroundCells, into: &slot.background)
        // Borrowed, not returned: the surface flattens into a buffer it keeps and we upload
        // straight out of it, so an encoded frame no longer allocates a whole-screen array twice.
        var glyphInstanceCount = 0
        let glyphBuffer = surface.withGlyphInstances { instances -> MTLBuffer? in
            glyphInstanceCount = instances.count
            return upload(instances, into: &slot.glyphs)
        }
        var aboveCount = 0
        let aboveBuffer = surface.withRectInstancesAbove(geometry: geometry) { instances -> MTLBuffer? in
            aboveCount = instances.count
            return upload(instances, into: &slot.rectsAbove)
        }
        let belowBuffer = upload(rectsBelow, into: &slot.rectsBelow)

        // The command buffer is created *before* the drawable is acquired. A drawable that is
        // acquired and never presented is only returned to the layer's pool when it deallocates,
        // and with `maximumDrawableCount = 2` a couple of those make `nextDrawable()` block for
        // about a second each — which looks exactly like a frozen window.
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            ring.release()
            stats.framesSkipped += 1
            return RenderOutcome(didEncode: false, commandBuffer: nil, update: update,
                                 glyphCount: glyphInstanceCount,
                                 rectCount: rectsBelow.count + aboveCount)
        }
        stats.drawableRequests += 1
        let (target, drawable) = acquire()
        guard let target else {
            ring.release()
            stats.framesSkipped += 1
            stats.nilDrawables += 1
            return RenderOutcome(didEncode: false, commandBuffer: nil, update: update,
                                 glyphCount: glyphInstanceCount,
                                 rectCount: rectsBelow.count + aboveCount)
        }

        var uniforms = makeUniforms(surface: surface, geometry: geometry)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor(surface.colors.background)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            ring.release()
            stats.framesSkipped += 1
            return RenderOutcome(didEncode: false, commandBuffer: nil, update: update,
                                 glyphCount: glyphInstanceCount,
                                 rectCount: rectsBelow.count + aboveCount)
        }
        encoder.label = "libghostty terminal frame"

        // 1. Background: one triangle covering the drawable, no blending.
        if let backgroundBuffer, !surface.backgroundCells.isEmpty {
            encoder.setRenderPipelineState(bgPipeline)
            setUniforms(&uniforms, on: encoder)
            encoder.setFragmentBuffer(backgroundBuffer, offset: 0, index: Int(TKZ_BUFFER_INDEX_INSTANCES))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // 2. Rects below the text: the filled cursor.
        drawRects(belowBuffer, count: rectsBelow.count, uniforms: &uniforms, encoder: encoder)

        // 3. Glyphs. Both atlas textures are always bound — Metal validation faults on an unbound
        //    argument the function declares, even when the branch that samples it is not taken.
        if let glyphBuffer, glyphInstanceCount > 0 {
            encoder.setRenderPipelineState(glyphPipeline)
            setUniforms(&uniforms, on: encoder)
            encoder.setVertexBuffer(glyphBuffer, offset: 0, index: Int(TKZ_BUFFER_INDEX_INSTANCES))
            encoder.setFragmentTexture(glyphCache.grayscale.texture, index: Int(TKZ_TEXTURE_INDEX_GRAYSCALE))
            encoder.setFragmentTexture(glyphCache.color.texture, index: Int(TKZ_TEXTURE_INDEX_COLOR))
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: glyphInstanceCount)
        }

        // 4. Rects above the text: underline, strikethrough, hollow cursor. Same pipeline.
        drawRects(aboveBuffer, count: aboveCount, uniforms: &uniforms, encoder: encoder)

        encoder.endEncoding()

        commandBuffer.addCompletedHandler { [releaser = ring.releaser] _ in releaser.release() }
        if presentViaCommandBuffer, let drawable { commandBuffer.present(drawable) }
        commandBuffer.commit()

        surface.clearNeedsDisplay()
        stats.framesEncoded += 1
        return RenderOutcome(didEncode: true, commandBuffer: commandBuffer, update: update,
                             glyphCount: glyphInstanceCount,
                             rectCount: rectsBelow.count + aboveCount)
    }

    private func drawRects(
        _ buffer: MTLBuffer?, count: Int,
        uniforms: inout TkzUniforms, encoder: MTLRenderCommandEncoder
    ) {
        guard let buffer, count > 0 else { return }
        encoder.setRenderPipelineState(rectPipeline)
        setUniforms(&uniforms, on: encoder)
        encoder.setVertexBuffer(buffer, offset: 0, index: Int(TKZ_BUFFER_INDEX_INSTANCES))
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: count)
    }

    private func setUniforms(_ uniforms: inout TkzUniforms, on encoder: MTLRenderCommandEncoder) {
        withUnsafeBytes(of: &uniforms) { raw in
            guard let base = raw.baseAddress else { return }
            encoder.setVertexBytes(base, length: raw.count, index: Int(TKZ_BUFFER_INDEX_UNIFORMS))
            encoder.setFragmentBytes(base, length: raw.count, index: Int(TKZ_BUFFER_INDEX_UNIFORMS))
            stats.uniformBytesWritten += raw.count * 2
        }
    }

    private func makeUniforms(surface: TerminalSurface, geometry: GridGeometry) -> TkzUniforms {
        var uniforms = TkzUniforms()
        uniforms.viewportSizePx = geometry.viewportSizePx
        uniforms.cellSizePx = geometry.cellSizePx
        uniforms.gridOriginPx = geometry.originPx
        uniforms.grayscaleAtlasSizePx = SIMD2<Float>(repeating: Float(glyphCache.grayscale.size))
        uniforms.colorAtlasSizePx = SIMD2<Float>(repeating: Float(glyphCache.color.size))
        uniforms.gridSize = SIMD2<UInt32>(UInt32(surface.columns), UInt32(surface.rowCount))
        uniforms.defaultBackground = surface.colors.background
        uniforms.defaultForeground = surface.colors.foreground
        uniforms.cursorColor = surface.colors.effectiveCursor
        // Text under a filled cursor is drawn in the background colour — the classic inversion.
        uniforms.cursorTextColor = surface.colors.background
        uniforms.minContrast = minimumContrast
        uniforms.reserved0 = 0
        uniforms.reserved1 = 0
        uniforms.reserved2 = 0
        return uniforms
    }

    /// Copies `values` into `buffer`, growing it when needed, and counts the bytes.
    /// Returns `nil` (writing nothing) for an empty array — a zero-length buffer must never be bound.
    private func upload<T>(_ values: [T], into buffer: inout MTLBuffer?) -> MTLBuffer? {
        values.withUnsafeBufferPointer { upload($0, into: &buffer) }
    }

    /// The borrowed-buffer form, used on the hot path so `TerminalSurface`'s reused flatten buffers
    /// never have to be copied into an `Array` just to be handed over.
    private func upload<T>(
        _ values: UnsafeBufferPointer<T>, into buffer: inout MTLBuffer?
    ) -> MTLBuffer? {
        guard !values.isEmpty, let base = values.baseAddress else { return nil }
        let length = MemoryLayout<T>.stride * values.count
        if buffer == nil || buffer!.length < length {
            // Round up so a growing screen does not reallocate on every frame.
            let capacity = max(length, (buffer?.length ?? 0) * 2)
            buffer = device.makeBuffer(length: capacity, options: .storageModeShared)
        }
        guard let target = buffer else { return nil }
        target.contents().copyMemory(from: base, byteCount: length)
        stats.instanceBytesWritten += length
        return target
    }

    private func clearColor(_ packed: UInt32) -> MTLClearColor {
        MTLClearColor(
            red: Double(packed & 0xFF) / 255,
            green: Double((packed >> 8) & 0xFF) / 255,
            blue: Double((packed >> 16) & 0xFF) / 255,
            alpha: 1)
    }

    // MARK: - Readback

    /// A `CGImage` of a `.bgra8Unorm` `.shared` texture.
    static func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Raw BGRA bytes of a `.shared` texture, for pixel-level assertions.
    static func bgraBytes(of texture: MTLTexture) -> [UInt8] {
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }
}
