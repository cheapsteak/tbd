import AppKit
import os

private let lensLogger = Logger(subsystem: "com.tbd.app", category: "prompt-rail")

/// The lens's open fraction moving toward 0 or 1 (lens spec, "Opening and
/// closing"): over `fullDuration × |to − from|`, easing out.
struct PromptRailLensAnimation: Equatable {
    /// A whole grow or shrink, from closed to open or back.
    static let fullDuration: TimeInterval = 0.15
    /// The time a frame counts when no frame came before it to measure from.
    static let firstFrameInterval: TimeInterval = 1.0 / 60

    let from: CGFloat
    let target: CGFloat
    let duration: TimeInterval
    /// Frame time spent on it so far.
    var elapsed: TimeInterval = 0

    var isFinished: Bool { duration <= 0 || elapsed >= duration - 1e-9 }

    /// The open fraction `elapsed` into it: `from + (target − from) ×
    /// (1 − (1 − t)³)`, exactly `target` once finished.
    var value: CGFloat {
        guard !isFinished else { return target }
        let t = CGFloat(elapsed / duration)
        return from + (target - from) * (1 - pow(1 - t, 3))
    }
}

/// The lens's state on a `PromptRailNSView`. The view stores it; this file
/// keeps it.
struct PromptRailLensState {
    /// The lens, from the moment it starts opening until it has closed.
    var lens: PromptRailSteadyLens?
    /// How far open the lens is, `e` in the spec: 0 closed, 1 open.
    var openFraction: CGFloat = 0
    var animation: PromptRailLensAnimation?
    /// The rows as drawn: the resting rows blended toward the lens's by
    /// `openFraction`.
    var displayedRows = PromptRailLensRows.empty
    var shape = PromptRailLensShape.closed
    /// Whether `shape` was laid out holding the box's width under the
    /// pointer. A frame on which this changes lays the rows out again.
    var heldBoxWidth = false
    var hoveredRow: Int?

    /// Whether the view wants frames: the lens is growing, shrinking or
    /// moving.
    var isRunningFrames = false
    var lastFrameTimestamp: TimeInterval?
    /// A frame is due: the pointer moved over the lens, or the lens moved
    /// onto a new column, since the last frame.
    var stepRequested = false
    /// The last frame moved the lens, or held it still only for a flick, so
    /// the next may move it.
    var keepsStepping = false
    /// The display link, only while frames run: it is released whenever they
    /// stop, and the next run makes a new one. One still running when its
    /// rail goes away stops itself on its next fire
    /// (`PromptRailDisplayLinkProxy`).
    var frameLink: CADisplayLink?
    /// The rail is moving to another window, or out of one: no display link
    /// may start until it has arrived.
    var isLeavingWindow = false

    /// Whether the pointer was last seen over the box, as reported to the
    /// hover model.
    var isPointerOverBox = false
    /// The pointer's last position over the overlay, in rail coordinates;
    /// nil once it has left.
    var lastPointer: NSPoint?
    /// The prompt a mouse-down landed on, which the mouse-up jumps to. Its
    /// id, not its row: an outline change between the two can give the row
    /// to another prompt.
    var mouseDownID: String?
    /// The ends whose notches the painter fades, because a displayed row
    /// runs past them.
    var fade = PromptRailEndFades.neither
}

/// The display link's target. A link retains its target, so it targets this
/// proxy, which holds the rail weakly: the rail and its link never keep each
/// other alive. `GhosttyTerminalView`'s `DisplayLinkProxy` is the precedent.
@MainActor
final class PromptRailDisplayLinkProxy: NSObject {
    weak var rail: PromptRailNSView?

    init(_ rail: PromptRailNSView) {
        self.rail = rail
    }

    /// A link outliving its rail stops itself: the run loop keeps a link
    /// alive until it is invalidated.
    @objc func fired(_ link: CADisplayLink) {
        guard let rail else {
            link.invalidate()
            return
        }
        rail.advanceFrame(to: link.timestamp)
    }
}

/// The lens (lens spec, "The lens"): the rail grows into readable rows near
/// the pointer, over a box that keeps them legible over the transcript.
///
/// - **Opening** – the hover model's open builds a `PromptRailSteadyLens` on
///   the row under the pointer and grows the open fraction to 1; its close
///   shrinks it to 0 and drops the lens. Reduce Motion, and a rail with no
///   window to animate in, do either at once.
/// - **Frames** – a display link drives them while the lens grows, shrinks or
///   moves, and is released once it settles. `advanceFrame(to:)` is the
///   link's callback and the tests' seam.
/// - **Speed** – the pointer's moves over the rail column and the box reach
///   the lens with their event times, which it measures the pointer's speed
///   from, so a flick freezes it whether or not frames are running.
/// - **Hover** – the pointer over the box reports box hover, so the lens
///   stays open over its own rows, and the box never narrows under it.
/// - **Clicks** – a click on a row jumps to its prompt and closes the lens.
extension PromptRailNSView {
    // MARK: State

    /// How far open the lens is, `e` in the spec: 0 closed, 1 open.
    var openFraction: CGFloat { lensState.openFraction }
    /// The lens, from the moment it starts opening until it has closed; nil
    /// when fully closed.
    var lens: PromptRailSteadyLens? { lensState.lens }
    /// The rows as drawn: the resting rows, blended toward the lens's by the
    /// open fraction while a lens exists.
    var displayedRows: PromptRailLensRows {
        lensState.lens == nil ? .resting(currentLensGeometry()) : lensState.displayedRows
    }
    /// The box behind the readable rows, in rail coordinates; nil when no row
    /// shows text.
    var boxRect: CGRect? { lensState.shape.box }
    /// The row the pointer is on, while the lens is more than
    /// `hoverMinOpenFraction` open and the row at least `hoverMinRowHeight`
    /// tall; it draws the hover fill.
    var hoveredRow: Int? { lensState.hoveredRow }
    /// Whether the view wants frames: a lens is growing, shrinking or moving.
    /// While it does, a display link runs; otherwise there is none.
    var isRunningFrames: Bool { lensState.isRunningFrames }
    /// Whether the lens is drawn: from when it starts to grow until it has
    /// shrunk away, however soon it was dismissed. `onOpenWidthChange`
    /// reports each change.
    var isLensDrawn: Bool { lensState.lens != nil }
    /// Whether a lens is drawn, so the overlay must be wide enough for its
    /// box. `onOpenWidthChange` reports each change.
    var wantsOpenWidth: Bool { isLensDrawn }

    func currentLensGeometry() -> PromptRailLensGeometry {
        PromptRailLensGeometry(layout: currentLayout(), restOffset: offset)
    }

    // MARK: Opening and closing

    /// The hover model's open state changed: grow the lens, or shrink it.
    func lensOpenStateChanged() {
        if lensOpen {
            openLens()
        } else {
            // The hover model forgets box hover on every close that can leave
            // the pointer over the box (Escape, a click, `closeNow()`), and
            // closes after its grace only with the box unhovered, so this
            // forgets it too, without a report.
            lensState.isPointerOverBox = false
            if lensState.lens != nil { animateOpenFraction(to: 0) }
        }
    }

    /// Builds a lens on the row under the pointer, with the time column
    /// worked out afresh, and grows it. A lens still shrinking is built
    /// afresh too, at the pointer where it is now, and grows on from the
    /// open fraction the shrink reached, so the box does not pop (lens spec,
    /// "Opening").
    private func openLens() {
        guard !entries.isEmpty else { return }
        let shrinking = lensState.animation?.target == 0
        if lensState.lens == nil || shrinking {
            if lensState.lens == nil { lensState.openFraction = 0 }
            lensPainter.refreshTimeColumn(now: now())
            setLens(PromptRailSteadyLens(geometry: currentLensGeometry(), pointerY: pointerY))
        }
        animateOpenFraction(to: 1)
    }

    private func animateOpenFraction(to target: CGFloat) {
        let from = lensState.openFraction
        let duration = PromptRailLensAnimation.fullDuration * TimeInterval(abs(target - from))
        if duration <= 0 || reduceMotion() || window == nil {
            lensState.animation = nil
            lensState.openFraction = target
            if target == 0 {
                dropLens()
                return
            }
        } else {
            lensState.animation = PromptRailLensAnimation(from: from, target: target, duration: duration)
        }
        refreshLensDisplay()
        updateFrameDemand()
    }

    /// The lens has closed: back to the resting rail, in the gutter alone.
    private func dropLens() {
        // Only an open lens losing its last prompt can still have box hover
        // reported; the box goes with it.
        setPointerOverBox(false)
        lensState.animation = nil
        lensState.openFraction = 0
        lensState.displayedRows = .empty
        lensState.shape = .closed
        lensState.heldBoxWidth = false
        lensState.hoveredRow = nil
        lensState.stepRequested = false
        lensState.keepsStepping = false
        lensState.fade = .neither
        setLens(nil)
        // The resting rail sets its own fades, from its overflow offset.
        applyOffset(currentLayout())
        needsDisplay = true
        updateFrameDemand()
    }

    /// Builds or drops the lens. Either one redraws the whole overlay: the
    /// rail switches between its resting drawing and the lens's, which
    /// `lensRedrawRect` does not bound.
    private func setLens(_ lens: PromptRailSteadyLens?) {
        let had = lensState.lens != nil
        lensState.lens = lens
        guard had != (lens != nil) else { return }
        needsDisplay = true
        onOpenWidthChange?()
    }

    /// Finishes a grow or shrink at once: the rail has left its window, where
    /// no frame will come to finish it.
    func finishLensAnimation() {
        guard let animation = lensState.animation else { return }
        lensState.animation = nil
        lensState.openFraction = animation.target
        if animation.target == 0 {
            dropLens()
        } else {
            refreshLensDisplay()
            updateFrameDemand()
        }
    }

    // MARK: Changes while open

    /// A new outline. No prompts close the lens at once; otherwise a lens
    /// moves onto the new outline keeping its centre, and an open lens with
    /// no lens yet, opened over an empty rail, now builds one.
    func lensOutlineChanged() {
        if entries.isEmpty {
            if lensState.lens != nil { dropLens() }
        } else if lensState.lens != nil {
            rebaseLens()
        } else if lensOpen {
            openLens()
        }
    }

    /// The rail's height changed: a lens moves onto the new column.
    func lensGeometryChanged() {
        rebaseLens()
    }

    /// A new active prompt restyles the rows in place. It can also move the
    /// resting rail's overflow offset, which the rows blend from as the lens
    /// grows and shrinks; the open lens's own rows stay where they are.
    func lensActiveChanged() {
        if lensState.lens != nil { refreshLensDisplay() }
    }

    /// The pane's width changed what the box may grow to.
    func lensBoxMaxWidthChanged() {
        if lensState.lens != nil { refreshLensDisplay() }
    }

    /// Moves the lens onto the rail's current column when its count, height or
    /// pitch changed, re-anchored at the current overflow offset, and lays the
    /// rows out again either way: an outline of the same count can still bring
    /// new titles, and with them a new box width.
    ///
    /// The offset alone never rebases the lens. It moves under an open lens
    /// whenever the active prompt does, as on a row click or Previous and
    /// Next Prompt; re-anchoring on it would move the open rows at some later,
    /// unrelated outline change.
    ///
    /// A rebased lens may no longer sit on its target for a still pointer, so
    /// an open one asks for a frame, which steps it there.
    private func rebaseLens() {
        guard let lens = lensState.lens else { return }
        let geometry = currentLensGeometry()
        if !Self.sameColumn(geometry, lens.geometry) {
            lensState.lens = lens.rebased(to: geometry)
            if lensOpen { lensState.stepRequested = true }
        }
        refreshLensDisplay()
        updateFrameDemand()
    }

    /// Whether two geometries lay out the same column, whatever their
    /// overflow offsets.
    private static func sameColumn(_ a: PromptRailLensGeometry, _ b: PromptRailLensGeometry) -> Bool {
        a.count == b.count && a.railHeight == b.railHeight && a.restPitch == b.restPitch
    }

    // MARK: Frames

    /// One frame, at `timestamp` seconds on any fixed clock: the display
    /// link's callback, and the tests' seam. The time since the last frame
    /// (`firstFrameInterval` on the first since frames started) advances the
    /// open fraction and, while the pointer is over the rail column or the
    /// box of an open lens, the lens's steady motion. The lens measures the
    /// pointer's speed from its moves' own event times
    /// (`PromptRailNSView+Pointer.swift` notes them), so a pause in the
    /// frames neither hides a flick nor makes one.
    ///
    /// A frame on which the lens did not move, the open fraction did not
    /// change and the box's hold under the pointer did not either lays
    /// nothing out again: only the hovered row can change.
    func advanceFrame(to timestamp: TimeInterval) {
        let dt = lensState.lastFrameTimestamp.map { max(0, timestamp - $0) }
            ?? PromptRailLensAnimation.firstFrameInterval
        lensState.lastFrameTimestamp = timestamp
        guard var lens = lensState.lens else {
            updateFrameDemand()
            return
        }
        let fraction = lensState.openFraction
        if var animation = lensState.animation {
            animation.elapsed += dt
            lensState.openFraction = animation.value
            lensState.animation = animation.isFinished ? nil : animation
            if animation.isFinished, animation.target == 0 {
                dropLens()
                return
            }
        }
        lensState.stepRequested = false
        var moved = false
        let driving = lensOpen && isPointerOverLens
        if driving {
            moved = lens.step(dt: dt)
            lensState.lens = lens
        }
        // A flick holds the lens still without settling it: once the pointer
        // slows, the lens may still have to follow. A lens that keeps the
        // resting rows never follows, so a flick over it wants no frames.
        lensState.keepsStepping = moved
            || (driving && !lens.geometry.keepsRestingRows && lens.speed > PromptRailSteadyLens.flickSpeed)
        if moved || lensState.openFraction != fraction || holdsBoxWidth != lensState.heldBoxWidth {
            refreshLensDisplay()
        } else {
            refreshHoveredRow()
        }
        updateFrameDemand()
    }

    /// Runs frames exactly while the lens is growing, shrinking or moving,
    /// with a display link that exists only for that run.
    func updateFrameDemand() {
        let wants = lensState.lens != nil
            && (lensState.animation != nil || lensState.stepRequested || lensState.keepsStepping)
        guard wants != lensState.isRunningFrames else { return }
        lensState.isRunningFrames = wants
        // A run of frames starts afresh: its first frame measures from no
        // earlier one.
        lensState.lastFrameTimestamp = nil
        if wants {
            startFrameLink()
        } else {
            invalidateFrameLink()
        }
    }

    /// Makes the display link for a run of frames, unless one exists. Only in
    /// a window the rail is not leaving, since the link follows the window's
    /// screen: a link made on the way out would outlive the move.
    func startFrameLink() {
        guard usesDisplayLink, window != nil, !lensState.isLeavingWindow, lensState.frameLink == nil else { return }
        let link = displayLink(
            target: PromptRailDisplayLinkProxy(self),
            selector: #selector(PromptRailDisplayLinkProxy.fired(_:)))
        link.add(to: .main, forMode: .common)
        lensState.frameLink = link
    }

    /// Drops the display link: the frames stopped, the rail is leaving its
    /// window, where a new window means a new link, or the rail is going
    /// away.
    func invalidateFrameLink() {
        lensState.frameLink?.invalidate()
        lensState.frameLink = nil
    }

    /// Lays the displayed rows out for the current open fraction and lens,
    /// and with them the box, box hover, the hovered row and the edge fades.
    ///
    /// The rows blend from the rail's resting rows as they are now, at the
    /// current overflow offset, not at the offset the lens opened with: a row
    /// click moves the active prompt, and with it the offset, before the lens
    /// shrinks, and a shrink toward the old resting rows would end in a jump
    /// to the new ones when the lens drops.
    ///
    /// A fully open lens shows its own rows, so the resting rows are built
    /// only while it grows or shrinks.
    private func refreshLensDisplay() {
        guard let lens = lensState.lens else { return }
        let previousBox = lensState.shape.box
        let fraction = lensState.openFraction
        let rows = fraction >= 1 && lens.rows.tops.count == entries.count
            ? lens.rows
            : PromptRailLensRows.resting(currentLensGeometry()).blended(toward: lens.rows, fraction: fraction)
        lensState.displayedRows = rows
        var shape = lensPainter.shape(for: rows, openFraction: fraction, maxWidth: boxMaxWidth)
        // While the pointer is over the box, the box never narrows: moving
        // through rows with shorter titles must not leave the pointer outside
        // it, which would close the lens. Over the rail column, which sits in
        // front of the box's leading end, no narrowing can leave the pointer
        // outside, so there, as anywhere off the box, the box fits its rows.
        let holds = holdsBoxWidth
        if holds {
            shape = shape.widened(toAtLeast: min(lensState.shape.width, boxMaxWidth))
        }
        lensState.shape = shape
        lensState.heldBoxWidth = holds
        // The box moves and grows under a still pointer, which sends no
        // event, so its hover follows the box here.
        if let point = lensState.lastPointer {
            setPointerOverBox(bounds.contains(point) && isOverBox(point))
        }
        lensState.hoveredRow = rowUnderPointer(in: rows)
        updateLensFade(rows)
        setNeedsDisplay(Self.lensRedrawRect(railColumn: railColumnRect, previousBox: previousBox, box: shape.box))
    }

    /// Whether the box holds its width: the pointer is over the box and off
    /// the rail column.
    private var holdsBoxWidth: Bool { lensState.isPointerOverBox && !isPointerOverRail }

    /// A frame on which no row moved: the hovered row is all that can change,
    /// and only its fill redraws, where it was and where it is. The notches,
    /// the box and the text stay where they were.
    private func refreshHoveredRow() {
        let previous = lensState.hoveredRow
        let rows = lensState.displayedRows
        let row = rowUnderPointer(in: rows)
        guard row != previous else { return }
        lensState.hoveredRow = row
        for changed in [previous, row].compactMap({ $0 }) where rows.heights.indices.contains(changed) {
            setNeedsDisplay(Self.hoverRedrawRect(row: changed, in: rows, width: lensState.shape.width))
        }
    }

    /// What the hovered fill of `row` in `rows` covers, in a box `width`
    /// wide, with a point to spare for its antialiased edge.
    static func hoverRedrawRect(row: Int, in rows: PromptRailLensRows, width: CGFloat) -> NSRect {
        let band = PromptRailLensPainter.textBand(row: row, in: rows)
        return NSRect(x: 0, y: band.minY, width: width, height: band.height).insetBy(dx: -1, dy: -1)
    }

    /// What one step of an existing lens redraws: the rail column, where the
    /// notches move and fade, and the box before and after the step, each
    /// widened by `PromptRailRowMetrics.boxDrawingOutset` for the taper and
    /// the shadow. The hovered row's fill and the row text lie inside the
    /// box, so nothing else the lens draws changes. Building or dropping the
    /// lens redraws the whole overlay instead (`setLens`), as does an
    /// appearance change.
    static func lensRedrawRect(railColumn: NSRect, previousBox: CGRect?, box: CGRect?) -> NSRect {
        let outset = PromptRailRowMetrics.boxDrawingOutset
        var rect = railColumn
        for drawn in [previousBox, box].compactMap({ $0 }) {
            rect = rect.union(drawn.insetBy(dx: -outset, dy: -outset))
        }
        return rect
    }

    private func rowUnderPointer(in rows: PromptRailLensRows) -> Int? {
        guard lensOpen, lensState.openFraction > PromptRailRowMetrics.hoverMinOpenFraction, isPointerOverLens,
              let row = rows.pointedRow(atY: pointerY),
              rows.heights[row] >= PromptRailRowMetrics.hoverMinRowHeight
        else { return nil }
        return row
    }

    /// Fades the notches at whichever end clips a row: a sliding column past
    /// the floor, or a windowed rail part way open. The painter fades them,
    /// not the layer mask the resting rail uses, which would fade the box
    /// and its text at that end too, so the mask comes off.
    private func updateLensFade(_ rows: PromptRailLensRows) {
        guard let column = rows.columnSpan else { return }
        if hasFadeMask { setFade(top: false, bottom: false) }
        lensState.fade = PromptRailEndFades(
            top: column.top < PromptRailLayout.topInset - 0.5,
            bottom: column.bottom > bounds.height - PromptRailLayout.bottomInset + 0.5)
    }

    // MARK: Hover

    /// Whether the pointer is over the rail column or the box.
    var isPointerOverLens: Bool { isPointerOverRail || lensState.isPointerOverBox }

    /// Whether `point`, in rail coordinates, is over the lens's box.
    func isOverBox(_ point: NSPoint) -> Bool {
        lensState.shape.box?.contains(point) ?? false
    }

    /// Reports box hover to the hover model on a change, and only while the
    /// lens is open: box hover only keeps an open lens open. A shrinking box
    /// sends no exit event, so a report made while it shrank could be left
    /// standing after it is gone, and hold the next lens open after the
    /// pointer had left both.
    func setPointerOverBox(_ over: Bool) {
        let over = over && lensOpen
        guard over != lensState.isPointerOverBox else { return }
        lensState.isPointerOverBox = over
        hover.boxHoverChanged(over)
    }

    /// The pointer moved over the overlay: a lens may follow it, and its
    /// hovered row may change, so a frame is due.
    func lensPointerMoved() {
        guard lensState.lens != nil else { return }
        lensState.stepRequested = true
        updateFrameDemand()
    }

    // MARK: Clicks

    /// The row a click at `point`, in rail coordinates, lands on: over the
    /// rail column of a lens that has started to grow, or over an open
    /// lens's box, the displayed row whose text band holds it; over the bare
    /// rail, the resting notch whose band holds it, since the bare rail draws
    /// its notches alike at any pitch. nil anywhere else: the box of a
    /// closing lens, above the first row or below the last, where the column
    /// has ended, and between a few-prompts lens's text bands.
    func clickRow(at point: NSPoint) -> Int? {
        guard !entries.isEmpty, isOverRailOrBox(point) else { return nil }
        if lensState.lens != nil, lensState.openFraction > 0 {
            return lensState.displayedRows.pointedRow(atY: point.y)
        }
        guard isInRailColumn(point) else { return nil }
        return currentLayout().indexInColumn(atRailY: point.y, offset: offset)
    }

    /// Jumps to the prompt `id` names and closes the lens, which then does
    /// not grow again until the pointer has left the rail. Nothing happens
    /// when the outline no longer holds `id`.
    func jump(toID id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        lensLogger.debug("rail click jumps to id=\(id, privacy: .public)")
        onJump(id)
        hover.dismiss(.click)
    }
}
