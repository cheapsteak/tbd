import AppKit
import Combine
import SwiftTerm
import os

private let terminalViewLogger = Logger(subsystem: "com.tbd.app", category: "terminalRenderer")

private extension CharacterSet {
    /// Characters that require shell quoting when they appear in a file path.
    static let shellUnsafe = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "/_.-+@:,"))
        .inverted
}

/// Subclass of SwiftTerm's TerminalView that adds natural text editing support.
/// When enabled, macOS-native shortcuts (Cmd+Arrow, Cmd/Opt+Delete) are translated
/// to the escape sequences that shells expect.
class TBDTerminalView: TerminalView {
    enum PasteAction: Equatable {
        case text
        case codexImage
        case passthrough
    }

    enum KeyEquivalentAction: Equatable {
        case closeTab
    }
    var naturalTextEditing: Bool = true
    var onFilePathClicked: ((String) -> Void)?
    var worktreePath: String = ""
    var remoteURL: String?
    var onNotification: ((String, String) -> Void)?
    var onCloseTab: (() -> Void)?
    /// Includes the legacy label fallback through `Terminal.isCodexTerminal`.
    /// Set by `TerminalPanelRepresentable` from the terminal model.
    var isCodexTerminal = false

    /// Global appearance settings (font, color scheme, cursor style). The Combine
    /// subscription set up in `init` reapplies these whenever the user edits
    /// Settings → Terminal.
    ///
    /// Named `appearanceSettings` (not `appearance`) to avoid collision with
    /// `NSView.appearance: NSAppearance?` inherited from AppKit.
    let appearanceSettings: AppearanceSettings
    /// Holds the Combine subscription that reapplies appearance when settings change.
    private var appearanceCancellable: AnyCancellable?

    /// Called once when the view has been laid out with non-zero bounds.
    /// Used to start the tmux client as soon as the terminal has real dimensions.
    var onReady: (() -> Void)?
    private var didFireReady = false

    /// Intercept a pasteboard paste of ANY size (the paste ruling v2). Set while
    /// a control-mode attach is live; cleared on detach/cleanup. Returns true
    /// when the handler consumed `data` — shipped it as a `.paste` sidecar frame,
    /// or refused an oversize payload (logged + dropped) — in which case
    /// SwiftTerm's normal paste is skipped. Returns false ONLY when not attached:
    /// the sole case where `super.paste` (SwiftTerm's local bracketed paste) may
    /// run, because SwiftTerm's DECSET-2004 tracking can be stale after a
    /// re-attach and tmux must stay the bracketing authority while attached.
    var onControlModePaste: ((Data) -> Bool)?

    init(frame: CGRect, font: NSFont, appearance: AppearanceSettings) {
        self.appearanceSettings = appearance
        super.init(frame: frame, font: font)

        // Apply current values once so first render uses user settings.
        applyAll()

        // Reapply on any AppearanceSettings change. `objectWillChange` fires
        // *before* the property mutation lands on the published value, so we
        // dispatch async to main — by the time the sink runs, the new value
        // has been committed and `appearanceSettings.*` reads the right thing.
        self.appearanceCancellable = appearance.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyAll()
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — TBDTerminalView requires an AppearanceSettings")
    }

    /// Intercept pastes BEFORE SwiftTerm brackets the content. Reads the
    /// pasteboard the same way SwiftTerm's own `paste` does (general pasteboard,
    /// `.string`), hands the UTF-8 bytes to `onControlModePaste`; if that returns
    /// true the paste was consumed — shipped as a `.paste` sidecar frame (the
    /// daemon-side `paste-buffer -p` owns bracketed-paste wrapping) or refused
    /// as oversize. Fall through to SwiftTerm's normal three-call bracketed
    /// paste ONLY when no control-mode attach is live.
    ///
    /// That ownership is CONTINGENT, not unconditional: `-p` wraps in
    /// ESC[200~/ESC[201~ only because the pane's application has enabled
    /// bracketed-paste mode (DECSET 2004). Against a pane that has NOT, the
    /// same `-p` delivers the bytes verbatim with no markers — measured on
    /// tmux 3.6a (22 wrapped bytes vs 10 bare). If an agent TUI ever stops
    /// setting 2004, handing the paste to the daemon wraps nothing. Asserted
    /// nightly by probe P3 in `scripts/nightly-tmux-probes.sh` (PR #523), a
    /// two-arm probe: 2004 on → wrapped, 2004 off → verbatim.
    override func paste(_ sender: Any) {
        let pasteboard = NSPasteboard.general
        let text = pasteboard.string(forType: .string)
        switch Self.pasteAction(
            text: text,
            hasImage: pasteboard.canReadObject(forClasses: [NSImage.self]),
            isCodexTerminal: isCodexTerminal
        ) {
        case .text:
            if let text,
               let handler = onControlModePaste,
               handler(Data(text.utf8)) {
                return
            }
            super.paste(sender)
        case .codexImage:
            // Codex owns clipboard-image decoding. Its TUI binds that action
            // to Ctrl-V; AppKit consumes Cmd-V before it can reach the PTY, so
            // forward the equivalent raw control byte for image-only content.
            send([0x16])
        case .passthrough:
            super.paste(sender)
        }
    }

    /// Text always wins when the pasteboard advertises both text and an image,
    /// preserving ordinary Cmd-V and the existing control-mode paste route.
    nonisolated static func pasteAction(
        text: String?,
        hasImage: Bool,
        isCodexTerminal: Bool
    ) -> PasteAction {
        if text != nil {
            return .text
        }
        if hasImage && isCodexTerminal {
            return .codexImage
        }
        return .passthrough
    }

    override func layout() {
        super.layout()
        if !didFireReady && bounds.width > 0 && bounds.height > 0 {
            didFireReady = true
            let callback = onReady
            onReady = nil
            DispatchQueue.main.async { callback?() }
        }
    }

    // MARK: - Appearance application

    private func applyAll() {
        applyFont()
        applyScheme()
        applyCursor()
        applyFontSmoothing()
    }

    private func applyFontSmoothing() {
        // SwiftTerm's `fontSmoothing = false` is what produces iTerm's
        // "Thin Strokes" rendering, so we invert the user-facing toggle.
        self.fontSmoothing = !appearanceSettings.thinStrokes
        // Known limitation under the Metal flag, and TBD cannot close it from
        // here. `fontSmoothing`'s setter is a bare stored-property write, so
        // this `needsDisplay` is the only repaint — and it is a no-op under
        // Metal, where `draw(_:)` early-returns. Forcing a Metal frame instead
        // would not help: the renderer re-reads `fontSmoothing` every frame,
        // but the glyph atlas is keyed on (font, size, glyph) with smoothing
        // absent from the key, and nothing flushes it on a smoothing change.
        // So an already-open terminal keeps the glyphs it has drawn, and only
        // characters it has not yet rasterized pick the new setting up — a mix,
        // not a clean deferral. Rebuilding the renderer would fix it, at the
        // cost of a runtime shader compile per view; not worth it for a taste
        // toggle on an experimental flag. The Settings help says what happens,
        // and the durable fix is an upstream atlas-invalidation hook.
        self.needsDisplay = true
    }

    private func applyFont() {
        // Setting `self.font` triggers SwiftTerm's `resetFont()`, which
        // recomputes its internal `cellDimension`, calls `resize(cols:rows:)`,
        // and that in turn invokes `sizeChanged(source:newCols:newRows:)` on
        // our `TerminalViewDelegate`. The existing handler in
        // `TerminalPanelView.Coordinator.sizeChanged(...)` writes the new
        // dimensions to the PTY via `ioctl(TIOCSWINSZ)`, so tmux gets
        // SIGWINCH and reflows the pane. No explicit forwarding needed here.
        self.font = appearanceSettings.font
        // Our own cell-dimension cache is keyed off `self.font`, so it must
        // be invalidated whenever the font changes; otherwise click→grid
        // mapping in `mouseUp` would keep using stale metrics.
        cachedCellDimensions = nil
    }

    private func applyScheme() {
        let scheme = appearanceSettings.effectiveScheme
        // SwiftTerm's `installColors` takes `[SwiftTerm.Color]`; the per-view
        // foreground/background/caret/selection setters take `NSColor`. We can't
        // use SwiftTerm's internal `NSColor.make(color:)` bridge, so convert
        // inline. `SwiftTerm.Color` channels are UInt16 on a 65535 scale.
        self.installColors(scheme.ansi)
        self.nativeForegroundColor = Self.nsColor(from: scheme.foreground)
        let bg = Self.nsColor(from: scheme.background)
        // Setting `nativeBackgroundColor` is enough: at the pinned revision its
        // setter paints `layer.backgroundColor` itself, from
        // `effectiveNativeBackgroundColor` (which honours reverse video and
        // opacity) and installing `NSColor.clear` instead when Metal owns the
        // background. TBD used to write the layer colour again here, from a
        // time when upstream did not; that third write ignored reverse video
        // and, under Metal, painted over the transparency the CAMetalLayer
        // needs. `effectiveNativeBackgroundColor` is internal, so matching
        // upstream exactly is not possible from here — deferring to it is.
        self.nativeBackgroundColor = bg
        self.caretColor = Self.nsColor(from: scheme.cursor)
        self.selectedTextBackgroundColor = Self.nsColor(from: scheme.selection)

        // Force SwiftTerm to repaint every cell. `installColors` updates the
        // palette but does not invalidate cells already in the buffer; without
        // this, default-bg cells continue showing the bg color they were drawn
        // with at first paint (NSColor.textBackgroundColor = system gray).
        // `installColors` above already ran SwiftTerm's `colorsChanged()`,
        // which clears the attribute caches, calls `updateFullScreen()` and
        // queues a display — the deferred pass that rebuilds every visible row
        // against the new palette, on both renderers. This second
        // `updateFullScreen()` is belt and braces for the setters that ran
        // after it (foreground, caret, selection), which schedule nothing of
        // their own.
        //
        // Deliberately NOT a synchronous Metal frame here. The Metal renderer
        // caches per-row vertex data keyed on `BufferLine.generation`, and
        // installing a palette does not bump it, so an immediate frame would
        // re-emit every visible row with the OLD colours — a wasted GPU pass
        // whose only visible effect could be one stale frame ahead of the
        // correct deferred one.
        self.getTerminal().updateFullScreen()
        self.needsDisplay = true
    }

    private static func nsColor(from color: SwiftTerm.Color) -> NSColor {
        // Bundled scheme values are sRGB hex codes; use sRGB so wide-gamut
        // displays (Display P3) don't drift from the spec.
        NSColor(
            srgbRed: CGFloat(color.red) / 65535.0,
            green: CGFloat(color.green) / 65535.0,
            blue: CGFloat(color.blue) / 65535.0,
            alpha: 1.0
        )
    }

    private func applyCursor() {
        self.terminal.setCursorStyle(appearanceSettings.cursorStyle)
    }

    // MARK: - Cell dimension calculation

    /// Computes cell dimensions from font metrics, matching SwiftTerm's internal calculation.
    /// SwiftTerm uses `cellDimension` (internal) derived from CTFont metrics, not bounds/cols.
    /// Using bounds/cols gives wrong results because of scroller width and rounding.
    private var cachedCellDimensions: (width: CGFloat, height: CGFloat)?

    func cellDimensions() -> (width: CGFloat, height: CGFloat) {
        if let cached = cachedCellDimensions { return cached }
        let dims = Self.cellDimensions(for: self.font)
        cachedCellDimensions = dims
        return dims
    }

    /// The font SwiftTerm initializes a `TerminalView` with when no font is set.
    /// AppState uses this for px → cells conversion before any live view exists.
    static let defaultMonospaceFont: NSFont = NSFont.monospacedSystemFont(
        ofSize: 13, weight: .regular
    )

    /// Pure font-metric calculation, exposed so AppState can compute cols/rows
    /// for a px area without a live `TBDTerminalView` instance.
    ///
    /// APPROXIMATION, deliberately. SwiftTerm's own `computeFontDimensions()`
    /// snaps both axes to device pixels before using them, and this mirror
    /// cannot: it is static and view-less, so it has no `backingScaleFactor()`
    /// to snap against — which is the whole reason AppState can call it without
    /// a live view.
    ///
    ///     upstream width:  (advancement * scale).rounded() / scale
    ///     upstream height: ceil(h * scale) / scale
    ///     here:            raw advancement, and ceil(h) in POINTS
    ///
    /// So this runs up to one device pixel per cell small (<= 0.5pt at 2x)
    /// against what SwiftTerm actually renders. It has always diverged; the
    /// 16c5286 bump narrowed it, since upstream moved width from `ceil` to
    /// round-to-nearest (87a7888) and round sits closer to the raw advancement
    /// than ceil did.
    ///
    /// It matters because a cols/rows count computed here and sent to tmux is
    /// the same desync class `ControlModeGeometry` documents — SwiftTerm
    /// believing a size tmux never adopted. Fix it by threading the target
    /// screen's scale in and snapping identically, the moment anyone observes
    /// an off-by-one column against a real pane rather than a computed one.
    static func cellDimensions(for font: NSFont) -> (width: CGFloat, height: CGFloat) {
        let glyph = font.glyph(withName: "W")
        let cellWidth = font.advancement(forGlyph: glyph).width
        let cellHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        return (cellWidth, cellHeight)
    }

    /// What a capture has to do about the renderer before it can read pixels.
    enum CapturePreparation: Equatable {
        /// CoreGraphics is already drawing into the backing store.
        case captureDirectly
        /// Metal owns the pixels; drop to CoreGraphics and put it back after.
        case dropToCoreGraphicsThenRestore
    }

    /// The capture-time renderer decision, extracted so it can be asserted
    /// without a GPU.
    ///
    /// It cannot be asserted *with* one under `scripts/test.sh`: SwiftTerm
    /// resolves its shaders relative to `Bundle.main`, which in a test run is
    /// the toolchain's xctest helper rather than the build directory, so
    /// `setUseMetal(true)` throws `shaderSourceMissing` and the Metal branch is
    /// unreachable in-process. Splitting the decision out is what keeps that
    /// branch covered anyway — delete the drop-to-CoreGraphics and this goes
    /// red, GPU or no GPU.
    static func capturePreparation(isUsingMetalRenderer: Bool) -> CapturePreparation {
        isUsingMetalRenderer ? .dropToCoreGraphicsThenRestore : .captureDirectly
    }

    /// Requests SwiftTerm's Metal renderer for this view when `enabled`.
    ///
    /// Returns whether the GPU path is actually active afterwards, which is
    /// what tests assert on — `setUseMetal(_:)` throws on hardware without
    /// Metal or when the pipeline cannot be built, and degrading to the
    /// CoreGraphics path we shipped for years is always correct. The failure is
    /// logged at `.error` once per terminal view — not once per app run — and
    /// never retried: a per-frame retry would turn a hardware fact into a log
    /// flood, while one line per view stays proportionate and tells you which
    /// views degraded.
    ///
    /// With `enabled` false this makes no `setUseMetal` call at all, so the
    /// default branch is byte-for-byte the path that existed before the flag.
    @discardableResult
    func applyMetalRendererPreference(enabled: Bool) -> Bool {
        guard enabled else { return false }
        // Wait for a window. Enabling Metal on a view SwiftUI has not attached
        // yet stores `metalBoundWindow = nil`, and `viewDidMoveToWindow` then
        // rebinds — building a SECOND MTKView, renderer, glyph atlas and
        // pipeline set and discarding the first, synchronously on the main
        // thread. Renderer construction runs a runtime compile of SwiftTerm's
        // shader source (there is no `default.metallib` to short-circuit it)
        // and `makeLibrary` has no cache, so opening a worktree with six tabs
        // would pay twelve of those, half of them thrown away milliseconds
        // later. That is exactly the cost this flag exists to measure, so
        // paying it twice would contaminate the A/B it is here to inform.
        switch Self.metalActivation(hasWindow: window != nil) {
        case .deferUntilWindowed:
            wantsMetalRendererOnWindow = true
            return false
        case .now:
            return enableMetalRenderer()
        }
    }

    /// When a Metal request can be honoured.
    enum MetalActivation: Equatable {
        case now
        case deferUntilWindowed
    }

    /// Extracted so the deferral is assertable without a GPU — the same reason
    /// `capturePreparation(isUsingMetalRenderer:)` is. Losing it costs one
    /// wasted renderer build per terminal and nothing goes red, which is how
    /// it got shipped the first time.
    static func metalActivation(hasWindow: Bool) -> MetalActivation {
        hasWindow ? .now : .deferUntilWindowed
    }

    /// Set when the flag was on but the view had no window yet;
    /// `viewDidMoveToWindow` consumes it exactly once.
    private var wantsMetalRendererOnWindow = false

    private func enableMetalRenderer() -> Bool {
        do {
            try setUseMetal(true)
            // Positive confirmation. During the soak the question "is the GPU
            // path actually on?" has to be answerable from the log:
            // `setUseMetal` degrades silently by design, so the ABSENCE of the
            // error below is not evidence that Metal engaged — only this line
            // is.
            //
            // `.notice`, not `.info`, and the difference is the whole point.
            // `.info` lives in a memory ring buffer that `log show` loses
            // within minutes; this line was already unreadable ~15 minutes
            // after the launch that wrote it. `.notice` persists to disk, so
            // somebody can answer the question the next morning. It fires once
            // per terminal view, which is rare enough to afford that.
            terminalViewLogger.notice("Metal terminal renderer active for this terminal view")
            return true
        } catch {
            terminalViewLogger.error(
                "Metal terminal renderer unavailable; staying on CoreGraphics: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// Capture the current visible terminal content as an NSImage.
    /// Returns nil if the view has no dimensions yet.
    ///
    /// Runs the capture with the CoreGraphics renderer temporarily reinstated —
    /// see `withCoreGraphicsRendering(_:)` for why a Metal-backed view would
    /// otherwise hand back a blank image.
    func captureScreenshot() -> NSImage? {
        guard bounds.width > 0 && bounds.height > 0 else { return nil }
        return withCoreGraphicsRendering {
            guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            cacheDisplay(in: bounds, to: bitmapRep)
            guard let cgImage = bitmapRep.cgImage else { return nil }
            return NSImage(cgImage: cgImage, size: bounds.size)
        }
    }

    /// Runs `body` with this view on SwiftTerm's CoreGraphics draw path,
    /// restoring the Metal renderer afterwards if it was active.
    ///
    /// `bitmapImageRepForCachingDisplay` + `cacheDisplay` read the view's
    /// backing store by re-running `draw(_:)` down the subview tree. A
    /// Metal-backed `TerminalView` renders into a `CAMetalLayer` owned by an
    /// `MTKView` subview, which draws through its layer rather than through
    /// `draw(_:)` — so that capture path sees no glyphs and returns a blank
    /// image. A blank image is a *silent* regression: it still renders as an
    /// image, so nothing downstream reports the failure.
    ///
    /// `setUseMetal(_:)` is togglable in both directions at runtime, so the fix
    /// is to drop to CoreGraphics for the duration of the capture. The whole
    /// round trip happens inside one main-thread turn, so the compositor never
    /// commits the intermediate hierarchy and the swap is not visible; the
    /// `drawMetalFrameNow()` on the way back is belt and braces, forcing the
    /// freshly built `MTKView` to produce a frame synchronously rather than
    /// leaving it blank until the next runloop turn.
    ///
    /// Re-enabling rebuilds the `MTKView`, its renderer and its glyph atlas,
    /// which is not free — acceptable because captures are user-gestured and
    /// occasional, not per-frame.
    private func withCoreGraphicsRendering<T>(_ body: () -> T) -> T {
        guard Self.capturePreparation(isUsingMetalRenderer: isUsingMetalRenderer)
            == .dropToCoreGraphicsThenRestore
        else { return body() }
        do {
            try setUseMetal(false)
        } catch {
            terminalViewLogger.error(
                "Could not drop to CoreGraphics for capture; snapshot may be blank: \(String(describing: error), privacy: .public)"
            )
            return body()
        }
        defer {
            do {
                try setUseMetal(true)
                drawMetalFrameNow()
            } catch {
                terminalViewLogger.error(
                    "Could not restore the Metal renderer after capture; staying on CoreGraphics: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return body()
    }

    /// Converts a window-coordinate point to terminal grid (col, row).
    func gridPosition(atWindowLocation windowPoint: CGPoint) -> (col: Int, row: Int)? {
        let localPoint = convert(windowPoint, from: nil)
        let terminal = getTerminal()
        let cell = cellDimensions()

        let col = Int(localPoint.x / cell.width)
        let row = Int((bounds.height - localPoint.y) / cell.height)

        guard row >= 0 && row < terminal.rows && col >= 0 && col < terminal.cols else {
            return nil
        }
        return (col, row)
    }

    // MARK: - Mouse click pass-through
    // Track mouseDown position to distinguish clicks from drags.
    // Single clicks are forwarded to tmux for pane switching;
    // click-drags are handled locally by SwiftTerm for text selection.
    //
    // Because SwiftTerm's TerminalView declares its mouse overrides as
    // `public` (not `open`), we cannot override them from another module.
    // Instead we install a local event monitor that observes mouseDown /
    // mouseDragged / mouseUp and forwards clicks after SwiftTerm has
    // already processed them.
    private var mouseDownLocation: CGPoint = .zero
    private var didDrag: Bool = false
    private static let dragThreshold: CGFloat = 3.0
    nonisolated(unsafe) private var mouseMonitor: Any?

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }
            // Only handle events that target this view
            guard let eventWindow = event.window, eventWindow == self.window else { return event }
            let locationInSelf = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(locationInSelf) else { return event }

            switch event.type {
            case .leftMouseDown:
                self.mouseDownLocation = locationInSelf
                self.didDrag = false
            case .leftMouseDragged:
                let dx = locationInSelf.x - self.mouseDownLocation.x
                let dy = locationInSelf.y - self.mouseDownLocation.y
                if sqrt(dx * dx + dy * dy) > Self.dragThreshold {
                    self.didDrag = true
                }
            case .leftMouseUp:
                self.handleClickPassthrough(at: locationInSelf, modifiers: event.modifierFlags)
            default:
                break
            }
            return event  // always pass the event through
        }
    }

    private func removeMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // Deferred from `applyMetalRendererPreference`, which could not run
            // before the view had a window without costing a second renderer
            // build. Consumed once: a later reparent is upstream's rebind to
            // handle, not ours to re-request.
            if wantsMetalRendererOnWindow {
                wantsMetalRendererOnWindow = false
                _ = enableMetalRenderer()
            }
            installMouseMonitor()
            registerForDraggedTypes([.fileURL])
        } else {
            removeMouseMonitor()
        }
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else {
            return false
        }
        let quoted = urls.map { shellQuote($0.path) }
        deliverDroppedText(quoted.joined(separator: " "))
        return true
    }

    /// Route drag-drop-synthesized text (the shell-quoted dropped paths).
    /// While a control-mode attach is live, a drop is a paste-shaped bulk
    /// insert and MUST ride the same decision path as a pasteboard paste
    /// (R6-H3): `send()` would ship it as ONE `.input` sidecar frame, and an
    /// oversize drop would exceed the sidecar scanner's frame cap — desyncing
    /// (and tearing down) the app-wide shared sidecar connection. The handler
    /// consumes it (ships a `.paste` frame, or refuses oversize with the
    /// in-pane message); a nil handler or `false` (not attached) falls to the
    /// local keystroke path, exactly the pre-control-mode behavior. Split
    /// from `performDragOperation` so the routing branch is headlessly
    /// testable (`NSDraggingInfo` is not constructible in tests).
    func deliverDroppedText(_ text: String) {
        if let handler = onControlModePaste, handler(Data(text.utf8)) {
            return
        }
        send(Array(text.utf8))
    }

    /// Shell-quotes a path using single quotes, escaping embedded single quotes.
    private func shellQuote(_ path: String) -> String {
        if path.rangeOfCharacter(from: .shellUnsafe) == nil {
            return path
        }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    deinit {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Plain (unmodified) clicks are forwarded into the pane; clicks carrying
    /// a modifier belong to TBD's own file/link handling and must not also be
    /// forwarded — otherwise a Cmd+click both opens a file and clicks Claude.
    nonisolated static func clickPassthroughBlocked(by modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers
            .intersection(.deviceIndependentFlagsMask)
            .isDisjoint(with: [.command, .shift, .control, .option])
    }

    /// This monitor is one of two possible forwarders of a click to the pty —
    /// the other is SwiftTerm's own native mouseDown/mouseUp, gated by
    /// `allowMouseReporting`. Exactly one must be active at a time, or a
    /// single left click reaches the remote session twice. Callers with
    /// `allowMouseReporting == true` (e.g. `RemoteAttachTerminalView`) rely on
    /// SwiftTerm as the sole forwarder, so this monitor must stand down.
    nonisolated static func clickPassthroughActive(allowMouseReporting: Bool) -> Bool {
        !allowMouseReporting
    }

    private func handleClickPassthrough(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard !Self.clickPassthroughBlocked(by: modifiers) else { return }
        guard Self.clickPassthroughActive(allowMouseReporting: allowMouseReporting) else { return }
        // If this was a click (not a drag) and tmux has mouse mode enabled,
        // forward the click to tmux so it can handle pane switching.
        //
        // This won't produce duplicate events either way: the guard above
        // means exactly one of us is live. When `allowMouseReporting` is
        // false (e.g. `TerminalPanelView`), SwiftTerm's mouseDown/mouseUp
        // only handle local text selection — they never forward to the pty —
        // so we are the sole path that sends mouse events to tmux. When
        // `allowMouseReporting` is true (e.g. `RemoteAttachTerminalView`),
        // SwiftTerm's native reporting is the sole forwarder and we stand
        // down via the guard above.
        let term = getTerminal()
        guard !didDrag && term.mouseMode != .off else { return }

        let cell = cellDimensions()
        let col = Int(point.x / cell.width)
        let row = Int((bounds.height - point.y) / cell.height)

        let pressFlags = term.encodeButton(
            button: 0, release: false,
            shift: false, meta: false, control: false
        )
        term.sendEvent(buttonFlags: pressFlags, x: col, y: row)

        let releaseFlags = term.encodeButton(
            button: 0, release: true,
            shift: false, meta: false, control: false
        )
        term.sendEvent(buttonFlags: releaseFlags, x: col, y: row)
    }

    /// True if the cell at the given window point carries an OSC 8 hyperlink
    /// payload. SwiftTerm's `mouseUp` will dispatch these via
    /// `requestOpenLink`, so our local mouseDown monitor must not also handle
    /// them — otherwise a single cmd+click opens two viewer panes.
    ///
    /// `CharData.getPayload()` is `Any?` — SwiftTerm also uses it for sixel
    /// and iTerm2 inline image data. Cast to `String` so non-OSC-8 payloads
    /// (graphics) don't short-circuit our path-detection path.
    func hasOSC8Payload(atWindowLocation windowPoint: CGPoint) -> Bool {
        guard let pos = gridPosition(atWindowLocation: windowPoint) else { return false }
        let terminal = getTerminal()
        guard let line = terminal.getLine(row: pos.row) else { return false }
        guard pos.col < line.count else { return false }
        return line[pos.col].getPayload() as? String != nil
    }

    /// Extracts a file path from the terminal buffer at the given window-coordinate point.
    func extractFilePath(atWindowLocation windowPoint: CGPoint) -> String? {
        guard let pos = gridPosition(atWindowLocation: windowPoint) else { return nil }
        let col = pos.col
        let row = pos.row
        let terminal = getTerminal()

        guard let bufferLine = terminal.getLine(row: row) else { return nil }
        let lineText = bufferLine.translateToString()

        guard col < lineText.count else { return nil }

        // Find word boundaries around click position using path-valid characters
        let pathChars = ClickedPathResolver.pathTokenCharacters
        let chars = Array(lineText.unicodeScalars)
        var start = col
        var end = col

        while start > 0 && pathChars.contains(chars[start - 1]) {
            start -= 1
        }
        while end < chars.count - 1 && pathChars.contains(chars[end + 1]) {
            end += 1
        }

        guard start <= end else { return nil }

        let startIndex = lineText.index(lineText.startIndex, offsetBy: start)
        let endIndex = lineText.index(lineText.startIndex, offsetBy: end + 1)
        var candidate = String(lineText[startIndex..<endIndex])

        // Strip trailing :line:col suffix (e.g., "file.swift:10:5")
        let colonPattern = try? NSRegularExpression(pattern: ":\\d+(:\\d+)?$")
        if let match = colonPattern?.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) {
            candidate = String(candidate[candidate.startIndex..<candidate.index(candidate.startIndex, offsetBy: match.range.location)])
        }

        // The path-character word boundary includes '.', so a trailing sentence period gets absorbed
        // into the candidate (e.g., "see design.md."). Strip it before the existence check. Mid-path
        // dots are preserved — only trailing.
        while candidate.hasSuffix(".") {
            candidate.removeLast()
        }

        guard !candidate.isEmpty else { return nil }

        // Resolve relative paths against worktreePath; expand leading ~ as a home-relative path.
        let resolvedPath: String
        if candidate.hasPrefix("/") {
            resolvedPath = candidate
        } else if candidate.hasPrefix("~") {
            resolvedPath = NSString(string: candidate).expandingTildeInPath
        } else {
            resolvedPath = URL(fileURLWithPath: worktreePath).appendingPathComponent(candidate).path
        }

        // Validate it's a regular file (not a directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir), !isDir.boolValue else { return nil }

        return resolvedPath
    }

    /// Resolves a clicked terminal token to an absolute file path.
    ///
    /// Shares `ClickedPathResolver` with the transcript's link pass so the two
    /// click surfaces cannot disagree about what names a file.
    func resolveAsFilePath(_ link: String) -> String? {
        ClickedPathResolver.resolve(link, worktreePath: worktreePath)
    }

    /// Extracts a clickable URL from the terminal buffer at the given window-coordinate point.
    /// OSC 8 hyperlinks are dispatched by SwiftTerm's `mouseUp` /
    /// `requestOpenLink` path (see `hasOSC8Payload`); this function handles
    /// the residual non-OSC-8 patterns we recognize, currently just
    /// `PR #123`.
    func extractHyperlinkURL(atWindowLocation windowPoint: CGPoint) -> String? {
        guard let pos = gridPosition(atWindowLocation: windowPoint) else { return nil }
        let row = pos.row
        let terminal = getTerminal()

        guard let line = terminal.getLine(row: row) else { return nil }

        // Build visible text from line (translateToString may return empty for status bar lines)
        var visibleText = ""
        for c in 0..<line.count {
            let val = line[c].getCharacter().unicodeScalars.first?.value ?? 0
            visibleText.append(val > 0 ? line[c].getCharacter() : " ")
        }

        // Look for "PR #123" pattern anywhere on the line.
        // Wide/emoji chars (e.g. ▶▶) make positional matching unreliable,
        // so match anywhere on the row rather than checking click position.
        if let match = Self.prPattern.firstMatch(in: visibleText, range: NSRange(visibleText.startIndex..., in: visibleText)),
           let numRange = Range(match.range(at: 1), in: visibleText),
           let repoURL = gitHubBrowserURL() {
            return "\(repoURL)/pull/\(String(visibleText[numRange]))"
        }

        return nil
    }

    private static let prPattern = try! NSRegularExpression(pattern: "PR\\s+#(\\d+)")

    /// Converts the repo's remote URL to a GitHub browser URL.
    private func gitHubBrowserURL() -> String? {
        guard var remote = remoteURL, !remote.isEmpty else { return nil }
        if remote.hasSuffix(".git") { remote = String(remote.dropLast(4)) }
        if remote.hasPrefix("git@github.com:") {
            remote = "https://github.com/" + remote.dropFirst("git@github.com:".count)
        }
        return remote
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only handle key equivalents if this terminal is the first responder.
        // performKeyEquivalent walks the entire view hierarchy — without this
        // guard, the leftmost terminal always wins and steals Cmd+Arrow from
        // whichever terminal the user actually clicked on.
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        if event.type == .keyDown, let action = Self.keyEquivalentAction(for: event) {
            performKeyEquivalentAction(action)
            return true
        }
        if naturalTextEditing, event.type == .keyDown, handleNaturalTextEditing(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    nonisolated static func keyEquivalentAction(for event: NSEvent) -> KeyEquivalentAction? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command else { return nil }
        guard event.charactersIgnoringModifiers?.lowercased() == "w" else { return nil }
        return .closeTab
    }

    func performKeyEquivalentAction(_ action: KeyEquivalentAction) {
        switch action {
        case .closeTab:
            onCloseTab?()
        }
    }
    private func handleNaturalTextEditing(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let hasCmd = flags.contains(.command)
        let hasOpt = flags.contains(.option)
        let hasCtrl = flags.contains(.control)
        let hasShift = flags.contains(.shift)

        guard !hasCtrl, let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first else {
            return false
        }
        let key = Int(scalar.value)

        if hasCmd && !hasOpt && !hasShift {
            // Use Home/End escape sequences instead of Ctrl-A/Ctrl-E
            // to avoid conflict with tmux prefix key (commonly Ctrl-A)
            if key == NSLeftArrowFunctionKey {
                send([0x1B, 0x5B, 0x48]) // ESC [ H (Home)
                return true
            }
            if key == NSRightArrowFunctionKey {
                send([0x1B, 0x5B, 0x46]) // ESC [ F (End)
                return true
            }
            if scalar.value == 0x7F {
                send([0x15]) // Ctrl-U (delete to line start)
                return true
            }
        }

        if hasOpt && !hasCmd && !hasShift {
            if scalar.value == 0x7F {
                send([0x1B, 0x7F]) // ESC DEL (delete word back)
                return true
            }
            if key == NSDeleteFunctionKey {
                send([0x1B, 0x64]) // ESC d (delete word forward)
                return true
            }
        }

        return false
    }

    func notify(source: Terminal, title: String, body: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Only notify when this terminal is not focused
            guard self.window?.isKeyWindow != true else { return }
            self.onNotification?(title, body)
        }
    }

}
