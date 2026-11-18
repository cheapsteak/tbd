import AppKit

/// The rail's pointer handling: hit-testing, clicks, hover and the wheel.
///
/// - **Hit-testing** – the overlay answers over the rail column, and over the
///   lens's box, inside its drawn shape, taper included, while the lens is
///   open. Clicks and
///   the wheel anywhere else, the clear area outside the box's rounded
///   corners and the box of a closing lens among them, fall through to the
///   transcript, whatever the overlay's frame covers.
/// - **Clicks** – a mouse-up over the rail column or the open lens's box
///   jumps to the prompt its mouse-down landed on. Above the first row and
///   below the last, the column has ended, and a click there lands on none;
///   so does one between a few-prompts lens's text bands.
/// - **Hover** – the one tracking area covers the whole overlay, and
///   `trackPointer` decides whether the pointer is over the rail column or
///   the box, and reports each to the hover model. Only a move over either,
///   or one that changes which the pointer is over, asks the lens for a
///   frame.
/// - **Wheel** – the rail never scrolls itself; it hands wheel events to the
///   transcript's scroll view.
extension PromptRailNSView {
    // MARK: Hit-testing

    /// The overlay answers only over the rail column and the open lens's
    /// box, so the transcript keeps its clicks and its wheel everywhere else.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return isOverRailOrBox(convert(point, from: superview)) ? self : nil
    }

    /// Whether `point`, in this view's coordinates, is over the rail column.
    func isInRailColumn(_ point: NSPoint) -> Bool {
        point.x >= 0 && point.x < PromptRailLayout.width
    }

    /// Whether `point`, in this view's coordinates, lies inside the overlay
    /// and over the rail column or the open lens's box. Once the lens starts
    /// to close, its shrinking box takes no clicks: they reach the
    /// transcript.
    func isOverRailOrBox(_ point: NSPoint) -> Bool {
        bounds.contains(point) && (isInRailColumn(point) || (lensOpen && isOverBox(point)))
    }

    // MARK: Clicks

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let row = clickRow(at: convert(event.locationInWindow, from: nil))
        lensState.mouseDownID = row.flatMap { entries.indices.contains($0) ? entries[$0].id : nil }
    }

    /// A mouse-up over the rail column or the open lens's box jumps to the
    /// prompt its mouse-down landed on. The rows can move between the two,
    /// under a still pointer, as the lens grows, eases or follows, so the
    /// mouse-up does not look for its own row: on a moving row it would not
    /// find the pressed one, and the click would be lost. The press keeps
    /// the prompt's id, so an outline change in between still jumps to the
    /// pressed prompt, or nowhere once it is gone.
    override func mouseUp(with event: NSEvent) {
        let pressed = lensState.mouseDownID
        lensState.mouseDownID = nil
        guard let pressed, isOverRailOrBox(convert(event.locationInWindow, from: nil)) else { return }
        jump(toID: pressed)
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
        pointerExitedOverlay()
    }

    /// The pointer left the overlay: it is over neither the rail column nor
    /// the box, and no row is hovered. The hovered row's fill goes at once,
    /// since no frame may come to clear it.
    func pointerExitedOverlay() {
        isPointerOverRail = false
        lensState.lastPointer = nil
        lensState.lens?.pointerLeft()
        setPointerOverBox(false)
        hover.railHoverChanged(false)
        if lensState.hoveredRow != nil {
            lensState.hoveredRow = nil
            needsDisplay = true
        }
    }

    /// Follows the pointer across the overlay: over the rail column it
    /// reports rail hover, over the box it reports box hover, and leaving
    /// either reports that. Gains are reported before losses, so a move
    /// between the rail and the box never passes through hovering neither,
    /// which would start the close grace. A frame is asked for only for a
    /// move over the rail column or the box, where the lens may follow and
    /// the hovered row may change, or one that changes the hover; a move
    /// across the rest of a widened overlay needs none.
    ///
    /// A move over the rail column or the box reaches the lens with its
    /// event time, which the lens measures the pointer's speed from; a move
    /// off both tells the lens the pointer has left.
    private func trackPointer(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inside = bounds.contains(point)
        let overRail = inside && isInRailColumn(point)
        let overBox = inside && isOverBox(point)
        let wasOverRail = isPointerOverRail
        let wasOverBox = lensState.isPointerOverBox
        lensState.lastPointer = point
        if overRail || overBox {
            pointerY = point.y
            lensState.lens?.notePointer(y: point.y, time: event.timestamp)
        } else {
            lensState.lens?.pointerLeft()
        }

        if overBox { setPointerOverBox(true) }
        if overRail {
            isPointerOverRail = true
            // Every move over the rail re-asserts rail hover. `closeNow()` —
            // the window resigning key, the app deactivating — forgets it, and
            // a pointer resting on the rail sends no new enter, so without
            // this the lens would not reopen until the pointer left the rail
            // and came back.
            hover.railHoverChanged(true)
        }
        if !overBox { setPointerOverBox(false) }
        if !overRail, isPointerOverRail {
            isPointerOverRail = false
            hover.railHoverChanged(false)
        }
        let hoverChanged = isPointerOverRail != wasOverRail || lensState.isPointerOverBox != wasOverBox
        if overRail || overBox || hoverChanged { lensPointerMoved() }
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
}
