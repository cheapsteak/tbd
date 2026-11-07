// Adapted from tkzmux c961533 Sources/TkzTerminalView/TkzTerminalView.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// TkzTerminalView — the AppKit half of the terminal engine.
//
// This file holds the module marker and `TerminalRenderContext`: the one app-wide owner of the
// font set, glyph atlases and `TerminalRenderer`. It lives here rather than in `TerminalMetalView`
// because it outlives any individual view — M2 puts several views (or a view that is torn down and
// rebuilt) in front of the same context.

import AppKit
import Foundation
import Metal

// MARK: - TerminalRenderContext

/// The app-wide render context: one `FontSet` → one `GlyphCache` → one `TerminalRenderer`, plus the
/// registry of live `TerminalSurface`s that must be re-attached when any of those are rebuilt.
///
/// ## Why this type exists: the backing-scale trap
///
/// A `GlyphCache` rasterizes at `pointSize * scale` and hands out **atlas positions**. Those
/// positions are cached inside every `TerminalSurface`'s per-row glyph instances. Move the window
/// from a 2x display to a 1x display and the atlas must be rebuilt at the new pixel size — at which
/// point every cached position in every surface points at the wrong pixels. There is no way to
/// patch that up: the only correct answer is a new `FontSet`, a new `GlyphCache`, a new
/// `TerminalRenderer`, and a **re-attach of every surface** (an attach always produces
/// `DIRTY_FULL`, so the next frame rebuilds every row from scratch).
///
/// `setScale(_:)` does exactly that, in that order, and is the reason surfaces register here.
///
/// Everything it owns (`FontSet`, `GlyphCache`, `TerminalSurface`) is render-thread-only and not
/// internally synchronized, so the whole type is `@MainActor` — in tkzmux the main thread *is* the
/// render thread.
@MainActor
public final class TerminalRenderContext {
    public private(set) var renderer: TerminalRenderer
    public private(set) var fontSet: FontSet
    /// Backing scale factor the font set and atlases were built at.
    public private(set) var scale: CGFloat
    /// How many times `setScale(_:)` actually rebuilt. Diagnostics and tests.
    public private(set) var rebuildCount: Int = 0

    public var theme: Theme {
        didSet {
            guard theme != oldValue else { return }
            renderer.theme = theme
            for surface in liveSurfaces() { surface.markNeedsDisplay() }
        }
    }

    /// Surfaces are owned by their views; the context only needs to reach them on a rebuild.
    private final class WeakSurface {
        weak var surface: TerminalSurface?
        init(_ surface: TerminalSurface) { self.surface = surface }
    }
    private var registry: [WeakSurface] = []

    public init(
        theme: Theme = .default,
        scale: CGFloat = 2,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        guard let device else {
            throw RenderError(result: -1, operation: "MTLCreateSystemDefaultDevice")
        }
        self.theme = theme
        self.scale = scale
        let fontSet = TerminalRenderContext.makeFontSet(theme: theme, scale: scale)
        self.fontSet = fontSet
        self.renderer = try TerminalRenderer(
            device: device,
            glyphCache: GlyphCache(fontSet: fontSet, device: device, thicken: theme.fontMono.thicken),
            theme: theme)
    }

    private static func makeFontSet(theme: Theme, scale: CGFloat) -> FontSet {
        FontSet(
            family: theme.fontMono.family,
            fallback: theme.fontMono.fallback,
            pointSize: theme.fontMono.terminal,
            scale: max(1, scale))
    }

    /// Cell geometry of the current atlas, in **device pixels**.
    public var metrics: CellMetrics { renderer.glyphCache.metrics }

    public var device: MTLDevice { renderer.device }

    // MARK: Surface registry

    public func register(_ surface: TerminalSurface) {
        compact()
        guard !registry.contains(where: { $0.surface === surface }) else { return }
        registry.append(WeakSurface(surface))
    }

    public func unregister(_ surface: TerminalSurface) {
        registry.removeAll { $0.surface === surface || $0.surface == nil }
    }

    /// Registered surfaces that are still alive.
    public func liveSurfaces() -> [TerminalSurface] {
        compact()
        return registry.compactMap(\.surface)
    }

    private func compact() { registry.removeAll { $0.surface == nil } }

    // MARK: Scale

    /// Rebuilds the font set, atlases and renderer at `newScale` and re-attaches every registered
    /// surface. Returns `true` when a rebuild happened.
    ///
    /// Re-attaching preserves the session; it throws away render state, row caches and stale atlas
    /// positions, and guarantees the next frame is a `DIRTY_FULL` rebuild.
    @discardableResult
    public func setScale(_ newScale: CGFloat) throws -> Bool {
        let clamped = max(1, newScale)
        guard clamped != scale else { return false }
        let device = renderer.device
        let fontSet = TerminalRenderContext.makeFontSet(theme: theme, scale: clamped)
        let renderer = try TerminalRenderer(
            device: device,
            glyphCache: GlyphCache(fontSet: fontSet, device: device, thicken: theme.fontMono.thicken),
            theme: theme)

        self.fontSet = fontSet
        self.renderer = renderer
        self.scale = clamped
        rebuildCount += 1
        try reattachAll()
        return true
    }

    /// Detaches and re-attaches every live surface. Public because a theme change that alters the
    /// font would need the same treatment (M2).
    public func reattachAll() throws {
        for surface in liveSurfaces() {
            guard let session = surface.session else { continue }
            // `attach` detaches first, so this frees the old render state before allocating a new one.
            try surface.attach(session)
        }
    }
}
