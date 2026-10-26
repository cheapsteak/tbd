import AppKit
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "prompt-rail")

/// The prompt rail: one notch per prompt in the transcript's 20pt
/// gutter, the active prompt's notch accented. It is the coordinator's
/// `PromptRailPresenter`, so an active-prompt change goes straight from the
/// coordinator to a layer update, and it hands every outline change on
/// through `onOutlineChange` so the card stays in step.
///
/// - **Notches** – one reusable `CALayer` per entry, placed by
///   `PromptRailLayout`. Layer colours do not follow the appearance by
///   themselves, so they are re-resolved in `viewDidChangeEffectiveAppearance()`.
/// - **Overflow** – past the minimum pitch the notches are offset to keep the
///   active one `PromptRailLayout.edgeMargin` from either end, and a gradient
///   mask fades whichever edge clips a notch.
/// - **Hover** – an `NSTrackingArea` over the rail column feeds
///   `PromptRailHoverModel.railHoverChanged`, on entering and on every move,
///   and `pointedIndex`. A tracking area follows geometry, not hit-testing,
///   so the rail stays hovered while the open card covers it — which is what
///   keeps Escape and click suppression in force while the pointer is still
///   on the rail.
/// - **Wheel** – the rail never scrolls under the wheel; it hands wheel
///   events to the transcript's scroll view, so the gutter is not a dead zone.
/// - **Accessibility** – a group labelled "Prompts" with one button per entry,
///   labelled with its first line and time; pressing one jumps to it.
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

    /// The notch nearest the pointer while it is over the rail; nil otherwise.
    private(set) var pointedIndex: Int?
    /// The pointer's last y over the rail, in rail coordinates. The card
    /// scrolls its list on opening so the pointed row sits under it.
    private(set) var pointerY: CGFloat = 0
    /// How far the notches are shifted up to keep the active one in view.
    private(set) var offset: CGFloat = 0

    /// Called after every change of `entries` or `activeIndex`. The
    /// container forwards both to the card.
    var onOutlineChange: (@MainActor () -> Void)?
    /// The transcript's scroll view: wheel events over the rail go to it.
    weak var wheelTarget: NSView?

    /// Holds the notch layers and carries the fade mask.
    private let contentLayer = CALayer()
    /// Moved by `-offset`, so an offset change is one property write.
    private let notchesLayer = CALayer()
    private(set) var notchLayers: [CALayer] = []
    private let fadeMask = CAGradientLayer()
    private var hoverTrackingArea: NSTrackingArea?
    /// Built on the first accessibility query and dropped on an outline change.
    private var accessibilityButtons: [PromptRailAccessibilityButton]?

    init(hover: PromptRailHoverModel, onJump: @escaping @MainActor (String) -> Void) {
        self.hover = hover
        self.onJump = onJump
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        contentLayer.masksToBounds = true
        contentLayer.addSublayer(notchesLayer)
        layer?.addSublayer(contentLayer)

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

    /// Each notch layer's frame in rail coordinates, offset applied.
    var notchLayerFrames: [CGRect] {
        let origin = notchesLayer.frame.origin
        return notchLayers.map { $0.frame.offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// Whether the clipped-edge fade is installed (only while overflowing).
    var hasFadeMask: Bool { contentLayer.mask != nil }

    // MARK: PromptRailPresenter

    func promptRail(entriesDidChange entries: [PromptOutlineEntry]) {
        self.entries = entries
        accessibilityButtons = nil
        relayoutNotches()
        onOutlineChange?()
    }

    func promptRail(activeIndexDidChange index: Int?) {
        let previous = activeIndex
        deliveredActiveIndex = index
        let current = activeIndex
        guard previous != current else { return }
        withoutAnimation {
            let layout = currentLayout()
            for changed in [previous, current].compactMap({ $0 }) {
                styleNotch(changed, layout: layout)
            }
            applyOffset(layout)
        }
        onOutlineChange?()
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        let heightChanged = newSize.height != frame.height
        super.setFrameSize(newSize)
        if heightChanged {
            relayoutNotches()
            // The pitch follows the height, so the buttons' bands move even
            // when the overflow offset does not.
            updateAccessibilityFrames(currentLayout())
        } else {
            withoutAnimation { layoutContentLayer() }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withoutAnimation {
            let layout = currentLayout()
            for index in notchLayers.indices { styleNotch(index, layout: layout) }
        }
    }

    private func currentLayout() -> PromptRailLayout {
        PromptRailLayout(count: entries.count, railHeight: bounds.height)
    }

    /// Rebuilds every notch: one layer per entry, each framed and coloured.
    private func relayoutNotches() {
        withoutAnimation {
            layoutContentLayer()
            let count = entries.count
            while notchLayers.count < count {
                let notch = CALayer()
                notchesLayer.addSublayer(notch)
                notchLayers.append(notch)
            }
            while notchLayers.count > count {
                notchLayers.removeLast().removeFromSuperlayer()
            }
            let layout = currentLayout()
            for index in notchLayers.indices { styleNotch(index, layout: layout) }
            applyOffset(layout)
        }
    }

    private func layoutContentLayer() {
        contentLayer.frame = bounds
        fadeMask.frame = contentLayer.bounds
    }

    /// Frames and colours one notch, resolving its colour in this view's
    /// appearance: a `CGColor` is fixed the moment it is made.
    private func styleNotch(_ index: Int, layout: PromptRailLayout) {
        guard notchLayers.indices.contains(index), entries.indices.contains(index) else { return }
        let active = index == activeIndex
        let notch = notchLayers[index]
        let rect = layout.notchRect(index, active: active)
        notch.frame = rect
        notch.cornerRadius = rect.height / 2
        let color = PromptRailNotchStyle.color(for: entries[index].kind, active: active)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            notch.backgroundColor = color.cgColor
        }
    }

    /// Recomputes the overflow offset, moves the notches and refreshes the fade.
    private func applyOffset(_ layout: PromptRailLayout) {
        let previous = offset
        // A rail not yet laid out has no height to keep anything in view of;
        // an offset derived from it would carry into the first real layout.
        offset = bounds.height > 0 ? layout.scrollOffset(keepingVisible: activeIndex, current: offset) : 0
        notchesLayer.frame = CGRect(
            x: 0, y: -offset, width: bounds.width, height: max(layout.contentHeight, bounds.height))
        if layout.overflows, bounds.height > 0 {
            PromptRailFade.configure(
                fadeMask,
                height: bounds.height,
                fadesTop: offset > 0,
                fadesBottom: offset < layout.contentHeight - bounds.height)
            if contentLayer.mask !== fadeMask { contentLayer.mask = fadeMask }
        } else if contentLayer.mask != nil {
            contentLayer.mask = nil
        }
        if offset != previous { updateAccessibilityFrames(layout) }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === hoverTrackingArea else {
            super.mouseEntered(with: event)
            return
        }
        trackPointer(event)
        hover.railHoverChanged(true)
    }

    override func mouseMoved(with event: NSEvent) {
        trackPointer(event)
        // Every move re-asserts rail hover. `closeNow()` — the window
        // resigning key, the app deactivating — forgets it, and a pointer
        // resting on the rail sends no new enter, so without this the card
        // would not reopen until the pointer left the rail and came back.
        hover.railHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === hoverTrackingArea else {
            super.mouseExited(with: event)
            return
        }
        pointedIndex = nil
        hover.railHoverChanged(false)
    }

    private func trackPointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointerY = point.y
        pointedIndex = currentLayout().index(atRailY: point.y, offset: offset)
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

    override func accessibilityChildren() -> [Any]? {
        if let accessibilityButtons { return accessibilityButtons }
        let buttons = makeAccessibilityButtons()
        accessibilityButtons = buttons
        return buttons
    }

    /// One button per entry, labelled "<first line>, <time>".
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
            button.setAccessibilityLabel(PromptRailAccessibility.label(for: entry, now: now))
            button.setAccessibilityParent(self)
            button.setAccessibilityFrameInParentSpace(accessibilityFrame(index, layout: layout))
            return button
        }
        return buttons
    }

    private func updateAccessibilityFrames(_ layout: PromptRailLayout) {
        guard let accessibilityButtons else { return }
        for (index, button) in accessibilityButtons.enumerated() {
            button.setAccessibilityFrameInParentSpace(accessibilityFrame(index, layout: layout))
        }
    }

    /// The band of the rail a notch owns: the full rail width, one pitch tall.
    private func accessibilityFrame(_ index: Int, layout: PromptRailLayout) -> NSRect {
        NSRect(
            x: 0,
            y: layout.notchCenterY(index) - layout.pitch / 2 - offset,
            width: bounds.width,
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
    /// The Core Animation spelling of the fade both AppKit views use: fades
    /// the top and/or bottom `PromptRailLayout.fadeHeight` of a layer `height`
    /// tall. The mask lives in a flipped layer tree, so y 0 is the top edge.
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
