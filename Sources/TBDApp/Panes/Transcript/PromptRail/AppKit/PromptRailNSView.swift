import AppKit
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "prompt-rail")

/// The prompt rail: one notch per prompt in the transcript's 20pt gutter,
/// each as long as its turn was busy, the active prompt's notch accented.
/// Hovering it grows the lens (`PromptRailNSView+Lens.swift`): the notches
/// near the pointer become readable rows over a box. The view is an overlay
/// as tall as the rail, laid over the transcript's leading edge: the rail
/// column alone while no lens exists, and wide enough for the box while one
/// does (`wantsOpenWidth`, which the container frames it by). It is the
/// coordinator's `PromptRailPresenter`, so an active-prompt change goes
/// straight from the coordinator to a redraw.
///
/// - **Drawing** – at rest the notches are drawn in `draw(_:)`, placed by
///   `PromptRailLayout` and as long as `PromptRailWorkScale` says, the active
///   one last so it sits on top. The active notch keeps its length and is
///   thicker and accented instead. While a lens exists, `PromptRailLensPainter`
///   draws the box, the notches and the rows' text instead. Colours resolve
///   in each draw, so an appearance change only has to redraw.
/// - **Overflow** – past the minimum pitch the notches are offset to keep the
///   active one `PromptRailLayout.edgeMargin` from either end. At rest a
///   gradient mask on the view's own layer fades whichever edge clips a
///   notch; while a lens exists the painter fades the notches alone, so the
///   box and its text keep their full opacity at the rail's ends.
/// - **Hit-testing** – the overlay answers over the rail column, and over the
///   lens's box while it shows. Clicks and the wheel anywhere else fall
///   through to the transcript, whatever the overlay's frame covers.
/// - **Hover** – one `NSTrackingArea` covers the whole overlay, and code
///   decides whether the pointer is over the rail column or the box. Entering
///   the column and every move inside it report
///   `PromptRailHoverModel.railHoverChanged` true, and leaving it reports
///   false. The box reports `boxHoverChanged`. A tracking area follows
///   geometry, not hit-testing, so the rail stays hovered under the lens's
///   box — which is what keeps Escape and click suppression in force while
///   the pointer is still on the rail.
/// - **Lens** – the hover model's open state arrives through
///   `lensOpenChanged(_:)`. The lens is on screen while it is open and there
///   is a prompt to show; `onLensShownChange` reports that, and the container
///   runs the Escape monitor off it.
/// - **Clicks** – a click on a row, or on a notch of the bare rail, jumps to
///   its prompt.
/// - **Wheel** – the rail never scrolls under the wheel; it hands wheel
///   events to the transcript's scroll view, so the gutter and the box are
///   not dead zones.
/// - **Accessibility** – a group labelled "Prompts", framed over the rail
///   column, with one button per entry, labelled with its first line, time
///   and tool-call count; pressing one jumps to it.
///
/// Hit-testing, clicks, hover and the wheel live in
/// `PromptRailNSView+Pointer.swift`. Coordinates are flipped (y grows
/// downward), matching `PromptRailLayout`.
final class PromptRailNSView: NSView, PromptRailPresenter {
    let hover: PromptRailHoverModel
    let onJump: @MainActor (String) -> Void
    /// Whether the lens should open and close at once; read as each starts.
    let reduceMotion: @MainActor () -> Bool
    /// Whether frames come from a display link. Tests turn it off and drive
    /// frames with `advanceFrame(to:)`, so no live link runs in their windows.
    let usesDisplayLink: Bool

    /// The outline last delivered by the coordinator.
    private(set) var entries: [PromptOutlineEntry] = []
    /// The active index as delivered. Between `entriesDidChange` and
    /// `activeIndexDidChange` it can name a row past a list that shrank, so
    /// nothing reads it except through `activeIndex`.
    private var deliveredActiveIndex: Int?
    /// The active entry, or nil when the delivered index is out of range.
    var activeIndex: Int? {
        deliveredActiveIndex.flatMap { entries.indices.contains($0) ? $0 : nil }
    }
    /// The work counts last delivered, as the scale that turns them into
    /// notch lengths.
    private(set) var workScale = PromptRailWorkScale(counts: [])
    /// Each entry's work, parallel to `entries`, as last delivered.
    var workCounts: [Int] { workScale.counts }

    /// Whether the pointer was last seen over the rail column. The pointer
    /// handlers in `PromptRailNSView+Pointer.swift` keep it.
    var isPointerOverRail = false
    /// The pointer's last y over the rail column or the box, in rail
    /// coordinates. The lens opens on the row under it and follows it. The
    /// pointer handlers keep it.
    var pointerY: CGFloat = 0
    /// How far the notches are shifted up to keep the active one in view.
    private(set) var offset: CGFloat = 0

    /// Whether the hover model has the lens open. An open lens with no
    /// prompts is not on screen; `isLensShown` says whether it is.
    private(set) var lensOpen = false
    /// Whether the lens is on screen: open, with at least one prompt.
    private(set) var isLensShown = false
    /// Called on every change of `isLensShown`, and only on a change — when
    /// the lens opens or closes with prompts, and when an open lens gains its
    /// first prompt or loses its last. The container runs the Escape monitor
    /// off it, so Escape is taken only while there is a lens to dismiss.
    var onLensShownChange: (@MainActor (Bool) -> Void)?
    /// The transcript's scroll view: wheel events over the rail go to it.
    weak var wheelTarget: NSView?

    /// The widest the lens's box may grow, which the pane's width sets
    /// (`PromptRailRowMetrics.boxMaxWidth(paneWidth:)`). The container keeps
    /// it; a rail outside one keeps `maxWidth`.
    var boxMaxWidth: CGFloat = PromptRailRowMetrics.maxWidth {
        didSet {
            if boxMaxWidth != oldValue { lensBoxMaxWidthChanged() }
        }
    }
    /// Called on every change of `wantsOpenWidth`: when a lens starts to open
    /// and when it has closed. The container reframes the overlay off it.
    var onOpenWidthChange: (@MainActor () -> Void)?
    /// The lens's state; `PromptRailNSView+Lens.swift` keeps it.
    var lensState = PromptRailLensState()
    let lensPainter = PromptRailLensPainter()

    /// The notch colours the last draw resolved, in the appearance it drew in.
    private(set) var lastDrawnPalette: PromptRailNotchPalette?

    /// The overflow fade, installed as the view's own layer mask while the
    /// notches overflow.
    private let fadeMask = CAGradientLayer()
    /// The one tracking area, over the whole overlay.
    private(set) var hoverTrackingArea: NSTrackingArea?
    /// Built on the first accessibility query and dropped on an outline change.
    private var accessibilityButtons: [PromptRailAccessibilityButton]?

    init(
        hover: PromptRailHoverModel,
        onJump: @escaping @MainActor (String) -> Void,
        reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        usesDisplayLink: Bool = true
    ) {
        self.hover = hover
        self.onJump = onJump
        self.reduceMotion = reduceMotion
        self.usesDisplayLink = usesDisplayLink
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Prompts")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        // The run loop keeps a display link until it is invalidated, and a
        // paused one never fires to find its rail gone.
        MainActor.assumeIsolated { invalidateFrameLink() }
    }

    override var isFlipped: Bool { true }

    // MARK: Test seams

    /// Each notch's rectangle as drawn, in rail coordinates, offset applied:
    /// in the lens's displayed rows while a lens exists.
    var displayedNotchRects: [CGRect] {
        if lensState.lens != nil {
            let rows = lensState.displayedRows
            return rows.heights.indices.map { index in
                PromptRailLensPainter.notchRect(
                    row: index, in: rows, active: index == activeIndex, length: workScale.length(at: index))
            }
        }
        let layout = currentLayout()
        return entries.indices.map { displayedNotchRect($0, active: $0 == activeIndex, layout: layout) }
    }

    /// Whether the layer mask that fades a clipped edge is installed: only at
    /// rest, and only while overflowing. While a lens exists the painter
    /// fades the notches itself.
    var hasFadeMask: Bool { layer?.mask != nil }

    // MARK: Lens

    /// The hover model opened or closed the lens: it grows or shrinks.
    func lensOpenChanged(_ open: Bool) {
        lensOpen = open
        updateLensShown()
        lensOpenStateChanged()
    }

    private func updateLensShown() {
        let shown = lensOpen && !entries.isEmpty
        guard shown != isLensShown else { return }
        isLensShown = shown
        onLensShownChange?(shown)
    }

    // MARK: PromptRailPresenter

    func promptRail(entriesDidChange entries: [PromptOutlineEntry]) {
        self.entries = entries
        accessibilityButtons = nil
        lensPainter.setEntries(entries, activeIndex: activeIndex)
        applyOffset(currentLayout())
        invalidateRail()
        // The accessibility children were just invalidated; tell assistive
        // clients to re-query them rather than keep a stale list. A no-op when
        // no assistive client is running.
        NSAccessibility.post(element: self, notification: .layoutChanged)
        updateLensShown()
        lensOutlineChanged()
    }

    /// Redraws when any notch's length moved: every one when the busiest turn
    /// changed, which rescales them all, and otherwise those whose own count
    /// changed. Relabels only the buttons whose count changed, since a label
    /// carries the count and not the length.
    func promptRail(workCountsDidChange counts: [Int]) {
        let previous = workScale
        workScale = PromptRailWorkScale(counts: counts)
        guard workScale != previous else { return }
        invalidateRail()
        updateAccessibilityLabels { previous.count(at: $0) != workScale.count(at: $0) }
    }

    func promptRail(activeIndexDidChange index: Int?) {
        let previous = activeIndex
        deliveredActiveIndex = index
        guard previous != activeIndex else { return }
        lensPainter.setActiveIndex(activeIndex)
        applyOffset(currentLayout())
        invalidateRail()
        lensActiveChanged()
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        let heightChanged = newSize.height != frame.height
        super.setFrameSize(newSize)
        if heightChanged {
            let layout = currentLayout()
            applyOffset(layout)
            // The pitch follows the height, so the buttons' bands move even
            // when the overflow offset does not.
            updateAccessibilityFrames(layout)
            lensGeometryChanged()
        } else {
            withoutAnimation { fadeMask.frame = bounds }
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // The display link follows its window's screen. Until the move is
        // done no link may start: the container closes the lens as it leaves
        // its window, which can ask for frames after this has run.
        if newWindow !== window {
            lensState.isLeavingWindow = true
            invalidateFrameLink()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lensState.isLeavingWindow = false
        if window == nil {
            finishLensAnimation()
        } else if isRunningFrames {
            lensState.lastFrameTimestamp = nil
            resumeFrameLink()
        }
    }

    func currentLayout() -> PromptRailLayout {
        PromptRailLayout(count: entries.count, railHeight: bounds.height)
    }

    /// The rail column, in rail coordinates.
    var railColumnRect: NSRect {
        NSRect(x: 0, y: 0, width: min(PromptRailLayout.width, bounds.width), height: bounds.height)
    }

    /// What a change to the notches redraws: the rail column alone while no
    /// lens exists, since the notches are all that is drawn then, and the
    /// whole overlay while one does.
    var notchRedrawRect: NSRect {
        lensState.lens == nil ? railColumnRect : bounds
    }

    /// Marks the notches for redraw, over `notchRedrawRect`.
    private func invalidateRail() {
        setNeedsDisplay(notchRedrawRect)
    }

    /// Recomputes the overflow offset and, at rest, refreshes the fade. While
    /// a lens exists it sets the fade from the rows it shows.
    func applyOffset(_ layout: PromptRailLayout) {
        let previous = offset
        // A rail not yet laid out has no height to keep anything in view of;
        // an offset derived from it would carry into the first real layout.
        offset = bounds.height > 0 ? layout.scrollOffset(keepingVisible: activeIndex, current: offset) : 0
        if lensState.lens == nil {
            setFade(
                top: layout.overflows && offset > 0,
                bottom: layout.overflows && offset < layout.contentHeight - bounds.height)
        }
        if offset != previous {
            invalidateRail()
            updateAccessibilityFrames(layout)
        }
    }

    /// Installs the fade over whichever ends clip a notch, or removes it when
    /// neither does.
    func setFade(top: Bool, bottom: Bool) {
        withoutAnimation {
            fadeMask.frame = bounds
            if top || bottom, bounds.height > 0 {
                PromptRailFade.configure(fadeMask, height: bounds.height, fadesTop: top, fadesBottom: bottom)
                if layer?.mask !== fadeMask { layer?.mask = fadeMask }
            } else if layer?.mask != nil {
                layer?.mask = nil
            }
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !entries.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        // A `CGColor` is fixed the moment it is made, so each draw resolves
        // the palette in this view's appearance.
        let drawsLens = lensState.lens != nil
        var resolved: PromptRailNotchPalette?
        var lensColors: PromptRailLensPalette?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = PromptRailNotchPalette.resolvedInCurrentAppearance()
            if drawsLens { lensColors = PromptRailLensPalette.resolvedInCurrentAppearance() }
        }
        guard let palette = resolved else { return }
        lastDrawnPalette = palette

        if let lensColors {
            lensPainter.draw(
                rows: lensState.displayedRows,
                shape: lensState.shape,
                openFraction: lensState.openFraction,
                hoveredRow: lensState.hoveredRow,
                workScale: workScale,
                notchColors: palette,
                colors: lensColors,
                railHeight: bounds.height,
                fades: lensState.fade,
                dirtyRect: dirtyRect,
                in: context)
            return
        }

        let layout = currentLayout()
        let active = activeIndex
        if let range = notchIndices(reaching: dirtyRect, layout: layout) {
            for index in range where index != active {
                fillNotch(index, active: false, layout: layout, palette: palette, in: context)
            }
        }
        // The active notch is thicker; drawn last, it sits on top.
        if let active {
            fillNotch(active, active: true, layout: layout, palette: palette, in: context)
        }
    }

    /// The entries whose notches can reach into `rect`, in rail coordinates:
    /// each notch lies inside its own band of the rail, so the bands `rect`
    /// touches, widened by a notch's thickness.
    private func notchIndices(reaching rect: NSRect, layout: PromptRailLayout) -> ClosedRange<Int>? {
        let margin = PromptRailLayout.activeNotchHeight
        guard let first = layout.index(atRailY: rect.minY - margin, offset: offset),
              let last = layout.index(atRailY: rect.maxY + margin, offset: offset)
        else { return nil }
        return first...max(first, last)
    }

    private func displayedNotchRect(_ index: Int, active: Bool, layout: PromptRailLayout) -> CGRect {
        layout.notchRect(index, active: active, length: workScale.length(at: index))
            .offsetBy(dx: 0, dy: -offset)
    }

    private func fillNotch(
        _ index: Int, active: Bool, layout: PromptRailLayout, palette: PromptRailNotchPalette, in context: CGContext
    ) {
        guard entries.indices.contains(index) else { return }
        let rect = displayedNotchRect(index, active: active, layout: layout)
        let radius = min(rect.width, rect.height) / 2
        context.setFillColor(palette.color(for: entries[index].kind, active: active))
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    // MARK: Accessibility

    /// The group covers the rail column, not the whole overlay.
    override func accessibilityFrame() -> NSRect {
        NSAccessibility.screenRect(fromView: self, rect: railColumnRect)
    }

    override func accessibilityChildren() -> [Any]? {
        if let accessibilityButtons { return accessibilityButtons }
        let buttons = makeAccessibilityButtons()
        accessibilityButtons = buttons
        return buttons
    }

    /// One button per entry, labelled "<first line>, <time>, <work>".
    private func makeAccessibilityButtons() -> [PromptRailAccessibilityButton] {
        let now = Date()
        let layout = currentLayout()
        let buttons = entries.enumerated().map { index, entry in
            let id = entry.id
            let button = PromptRailAccessibilityButton { [weak self] in
                logger.debug("rail accessibility press id=\(id, privacy: .public)")
                self?.onJump(id)
            }
            button.setAccessibilityElement(true)
            button.setAccessibilityRole(.button)
            button.setAccessibilityLabel(
                PromptRailAccessibility.label(for: entry, workCount: workScale.count(at: index), now: now))
            button.setAccessibilityParent(self)
            button.setAccessibilityFrameInParentSpace(accessibilityFrame(index, layout: layout))
            return button
        }
        return buttons
    }

    /// Relabels in place the buttons whose index `changed` accepts, for new
    /// work counts. The buttons are built from `entries` and dropped when it
    /// changes, so they match it one for one.
    private func updateAccessibilityLabels(where changed: (Int) -> Bool) {
        guard let accessibilityButtons else { return }
        let now = Date()
        for (index, button) in accessibilityButtons.enumerated()
        where entries.indices.contains(index) && changed(index) {
            button.setAccessibilityLabel(
                PromptRailAccessibility.label(for: entries[index], workCount: workScale.count(at: index), now: now))
        }
    }

    private func updateAccessibilityFrames(_ layout: PromptRailLayout) {
        guard let accessibilityButtons else { return }
        for (index, button) in accessibilityButtons.enumerated() {
            button.setAccessibilityFrameInParentSpace(accessibilityFrame(index, layout: layout))
        }
    }

    /// The band of the rail a notch owns: the rail column's width, one pitch
    /// tall.
    private func accessibilityFrame(_ index: Int, layout: PromptRailLayout) -> NSRect {
        NSRect(
            x: 0,
            y: layout.notchCenterY(index) - layout.pitch / 2 - offset,
            width: PromptRailLayout.width,
            height: layout.pitch)
    }
}

/// One rail entry as an accessibility button. Pressing it runs `press`.
///
/// `NSAccessibilityElement` is not main-actor isolated, so neither is this
/// subclass or its `accessibilityPerformPress` override. `press` is
/// `@Sendable` so the override can hand it to the main actor without
/// capturing the (non-`Sendable`) element itself.
final class PromptRailAccessibilityButton: NSAccessibilityElement {
    private let press: @MainActor @Sendable () -> Void

    init(press: @escaping @MainActor @Sendable () -> Void) {
        self.press = press
        super.init()
    }

    // Accessibility clients call in on the main thread, which is what
    // `assumeIsolated` asserts.
    override func accessibilityPerformPress() -> Bool {
        let press = self.press
        MainActor.assumeIsolated { press() }
        return true
    }
}

extension PromptRailFade {
    /// The Core Animation spelling of the rail's fade: fades the top and/or
    /// bottom `PromptRailLayout.fadeHeight` of a layer `height` tall. The mask
    /// lives in a flipped view's layer, so y 0 is the top edge.
    static func configure(_ mask: CAGradientLayer, height: CGFloat, fadesTop: Bool, fadesBottom: Bool) {
        let fraction = edgeFraction(height: height)
        let opaque = CGColor(gray: 0, alpha: 1)
        let clear = CGColor(gray: 0, alpha: 0)
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.colors = [fadesTop ? clear : opaque, opaque, opaque, fadesBottom ? clear : opaque]
        mask.locations = [0, NSNumber(value: Double(fraction)), NSNumber(value: Double(1 - fraction)), 1]
    }
}
