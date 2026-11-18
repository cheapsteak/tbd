import AppKit
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "prompt-rail")

/// The prompt rail: one notch per prompt in the transcript's 20pt gutter,
/// each as long as its turn was busy, the active prompt's notch accented. The
/// view is an overlay as tall as the rail and as wide as the lens's box can
/// grow (`PromptRailRowMetrics.overlayWidth(paneWidth:)`), laid over the
/// transcript's leading edge. It is the coordinator's `PromptRailPresenter`,
/// so an active-prompt change goes straight from the coordinator to a redraw.
///
/// - **Drawing** – the notches are drawn in `draw(_:)`, placed by
///   `PromptRailLayout` and as long as `PromptRailWorkScale` says, the active
///   one last so it sits on top. The active notch keeps its length and is
///   thicker and accented instead. Colours resolve in each draw, so an
///   appearance change only has to redraw.
/// - **Overflow** – past the minimum pitch the notches are offset to keep the
///   active one `PromptRailLayout.edgeMargin` from either end, and a gradient
///   mask on the view's own layer fades whichever edge clips a notch.
/// - **Hit-testing** – the overlay answers only over the rail column. Clicks
///   and the wheel anywhere else fall through to the transcript, whatever
///   the overlay's frame covers.
/// - **Hover** – one `NSTrackingArea` covers the whole overlay, and code
///   decides whether the pointer is over the rail column. Entering the column
///   and every move inside it report `PromptRailHoverModel.railHoverChanged`
///   true, and leaving it reports false; `pointedIndex` follows the pointer
///   inside it. A tracking area follows geometry, not hit-testing, so the rail
///   stays hovered under the lens's box — which is what keeps Escape and click
///   suppression in force while the pointer is still on the rail.
/// - **Lens** – the hover model's open state arrives through
///   `lensOpenChanged(_:)`. The lens is on screen while it is open and there
///   is a prompt to show; `onLensShownChange` reports that, and the container
///   runs the Escape monitor off it.
/// - **Wheel** – the rail never scrolls under the wheel; it hands wheel
///   events to the transcript's scroll view, so the gutter is not a dead zone.
/// - **Accessibility** – a group labelled "Prompts", framed over the rail
///   column, with one button per entry, labelled with its first line, time
///   and tool-call count; pressing one jumps to it.
///
/// Coordinates are flipped (y grows downward), matching `PromptRailLayout`.
final class PromptRailNSView: NSView, PromptRailPresenter {
    private let hover: PromptRailHoverModel
    private let onJump: @MainActor (String) -> Void

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

    /// Whether the pointer was last seen over the rail column.
    private(set) var isPointerOverRail = false
    /// The notch nearest the pointer while it is over the rail column; nil
    /// otherwise.
    private(set) var pointedIndex: Int?
    /// The pointer's last y over the rail column, in rail coordinates. The
    /// lens opens on the row under it.
    private(set) var pointerY: CGFloat = 0
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

    /// The notch colours the last draw resolved, in the appearance it drew in.
    private(set) var lastDrawnPalette: PromptRailNotchPalette?

    /// The overflow fade, installed as the view's own layer mask while the
    /// notches overflow.
    private let fadeMask = CAGradientLayer()
    private var hoverTrackingArea: NSTrackingArea?
    /// Built on the first accessibility query and dropped on an outline change.
    private var accessibilityButtons: [PromptRailAccessibilityButton]?

    init(hover: PromptRailHoverModel, onJump: @escaping @MainActor (String) -> Void) {
        self.hover = hover
        self.onJump = onJump
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

    override var isFlipped: Bool { true }

    // MARK: Test seams

    /// Each notch's rectangle as drawn, in rail coordinates, offset applied.
    var displayedNotchRects: [CGRect] {
        let layout = currentLayout()
        return entries.indices.map { displayedNotchRect($0, active: $0 == activeIndex, layout: layout) }
    }

    /// Whether the clipped-edge fade is installed (only while overflowing).
    var hasFadeMask: Bool { layer?.mask != nil }

    // MARK: Lens

    /// The hover model opened or closed the lens.
    func lensOpenChanged(_ open: Bool) {
        lensOpen = open
        updateLensShown()
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
        applyOffset(currentLayout())
        needsDisplay = true
        // The accessibility children were just invalidated; tell assistive
        // clients to re-query them rather than keep a stale list. A no-op when
        // no assistive client is running.
        NSAccessibility.post(element: self, notification: .layoutChanged)
        updateLensShown()
    }

    /// Redraws when any notch's length moved: every one when the busiest turn
    /// changed, which rescales them all, and otherwise those whose own count
    /// changed. Relabels only the buttons whose count changed, since a label
    /// carries the count and not the length.
    func promptRail(workCountsDidChange counts: [Int]) {
        let previous = workScale
        workScale = PromptRailWorkScale(counts: counts)
        guard workScale != previous else { return }
        needsDisplay = true
        updateAccessibilityLabels { previous.count(at: $0) != workScale.count(at: $0) }
    }

    func promptRail(activeIndexDidChange index: Int?) {
        let previous = activeIndex
        deliveredActiveIndex = index
        guard previous != activeIndex else { return }
        applyOffset(currentLayout())
        needsDisplay = true
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
        } else {
            withoutAnimation { fadeMask.frame = bounds }
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func currentLayout() -> PromptRailLayout {
        PromptRailLayout(count: entries.count, railHeight: bounds.height)
    }

    /// Recomputes the overflow offset and refreshes the fade.
    private func applyOffset(_ layout: PromptRailLayout) {
        let previous = offset
        // A rail not yet laid out has no height to keep anything in view of;
        // an offset derived from it would carry into the first real layout.
        offset = bounds.height > 0 ? layout.scrollOffset(keepingVisible: activeIndex, current: offset) : 0
        withoutAnimation {
            fadeMask.frame = bounds
            if layout.overflows, bounds.height > 0 {
                PromptRailFade.configure(
                    fadeMask,
                    height: bounds.height,
                    fadesTop: offset > 0,
                    fadesBottom: offset < layout.contentHeight - bounds.height)
                if layer?.mask !== fadeMask { layer?.mask = fadeMask }
            } else if layer?.mask != nil {
                layer?.mask = nil
            }
        }
        if offset != previous {
            needsDisplay = true
            updateAccessibilityFrames(layout)
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
        var resolved: PromptRailNotchPalette?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = PromptRailNotchPalette.resolvedInCurrentAppearance()
        }
        guard let palette = resolved else { return }
        lastDrawnPalette = palette

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

    // MARK: Hit-testing

    /// The overlay answers only over the rail column, so the transcript
    /// keeps its clicks and its wheel everywhere else.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) && isInRailColumn(local) ? self : nil
    }

    /// Whether `point`, in this view's coordinates, is over the rail column.
    private func isInRailColumn(_ point: NSPoint) -> Bool {
        point.x >= 0 && point.x < PromptRailLayout.width
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverTrackingArea else {
            super.mouseEntered(with: event)
            return
        }
        trackPointer(event)
    }

    override func mouseMoved(with event: NSEvent) {
        trackPointer(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverTrackingArea else {
            super.mouseExited(with: event)
            return
        }
        isPointerOverRail = false
        pointedIndex = nil
        hover.railHoverChanged(false)
    }

    /// Follows the pointer across the overlay: over the rail column it keeps
    /// `pointedIndex` and reports rail hover, and moving off the column
    /// reports that the pointer left the rail.
    private func trackPointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isInRailColumn(point) else {
            pointedIndex = nil
            if isPointerOverRail {
                isPointerOverRail = false
                hover.railHoverChanged(false)
            }
            return
        }
        isPointerOverRail = true
        pointerY = point.y
        pointedIndex = currentLayout().index(atRailY: point.y, offset: offset)
        // Every move over the rail re-asserts rail hover. `closeNow()` — the
        // window resigning key, the app deactivating — forgets it, and a
        // pointer resting on the rail sends no new enter, so without this the
        // lens would not reopen until the pointer left the rail and came back.
        hover.railHoverChanged(true)
    }

    // MARK: Wheel

    /// The rail never scrolls itself; the wheel scrolls the transcript.
    override func scrollWheel(with event: NSEvent) {
        if let wheelTarget {
            wheelTarget.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: Accessibility

    /// The group covers the rail column, not the whole overlay.
    override func accessibilityFrame() -> NSRect {
        let column = NSRect(
            x: 0, y: 0, width: min(PromptRailLayout.width, bounds.width), height: bounds.height)
        return NSAccessibility.screenRect(fromView: self, rect: column)
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
