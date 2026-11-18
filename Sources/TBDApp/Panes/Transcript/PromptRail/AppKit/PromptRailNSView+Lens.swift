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
    var hoveredRow: Int?

    /// Whether the view wants frames: the lens is growing, shrinking or
    /// moving.
    var isRunningFrames = false
    var lastFrameTimestamp: TimeInterval?
    /// The pointer moved over the lens since the last frame.
    var stepRequested = false
    /// The last frame moved the lens, or held it still only for a flick, so
    /// the next may move it.
    var keepsStepping = false
    /// The last frame stepped the lens, so its pointer tracking is current.
    /// A frame that steps it after one that did not, or as frames start
    /// again after a pause, first resumes its tracking where the pointer is.
    var tracksPointer = false
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
    /// The row a mouse-down landed on, which the mouse-up jumps to.
    var mouseDownRow: Int?
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
///   moves, and pauses once it settles. `advanceFrame(to:)` is the link's
///   callback and the tests' seam.
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
    /// While it does, the display link runs; it is paused otherwise.
    var isRunningFrames: Bool { lensState.isRunningFrames }
    /// Whether a lens exists, so the overlay must be wide enough for its box.
    /// `onOpenWidthChange` reports each change.
    var wantsOpenWidth: Bool { lensState.lens != nil }

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

    /// Builds a lens on the row under the pointer, unless one is still
    /// shrinking, and grows it.
    private func openLens() {
        guard !entries.isEmpty else { return }
        if lensState.lens == nil {
            lensPainter.refreshTimeColumn(now: Date())
            lensState.openFraction = 0
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
        lensState.hoveredRow = nil
        lensState.stepRequested = false
        lensState.keepsStepping = false
        lensState.tracksPointer = false
        lensState.fade = .neither
        setLens(nil)
        // The resting rail sets its own fades, from its overflow offset.
        applyOffset(currentLayout())
        needsDisplay = true
        updateFrameDemand()
    }

    private func setLens(_ lens: PromptRailSteadyLens?) {
        let had = lensState.lens != nil
        lensState.lens = lens
        if had != (lens != nil) { onOpenWidthChange?() }
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
    private func rebaseLens() {
        guard let lens = lensState.lens else { return }
        let geometry = currentLensGeometry()
        if !Self.sameColumn(geometry, lens.geometry) { lensState.lens = lens.rebased(to: geometry) }
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
    /// box of an open lens, the lens's steady motion. The first frame that
    /// steps the lens after frames paused, or after the pointer was off both,
    /// resumes its tracking where the pointer is, so where the pointer went
    /// meanwhile does not read as a flick.
    func advanceFrame(to timestamp: TimeInterval) {
        let dt = lensState.lastFrameTimestamp.map { max(0, timestamp - $0) }
            ?? PromptRailLensAnimation.firstFrameInterval
        lensState.lastFrameTimestamp = timestamp
        guard var lens = lensState.lens else {
            updateFrameDemand()
            return
        }
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
            if !lensState.tracksPointer { lens.resumeTracking(pointerY: pointerY) }
            moved = lens.step(pointerY: pointerY, dt: dt)
            lensState.lens = lens
        }
        lensState.tracksPointer = driving
        // A flick holds the lens still without settling it: once the pointer
        // slows, the lens may still have to follow.
        lensState.keepsStepping = moved || (driving && lens.speed > PromptRailSteadyLens.flickSpeed)
        refreshLensDisplay()
        updateFrameDemand()
    }

    /// Runs frames exactly while the lens is growing, shrinking or moving.
    func updateFrameDemand() {
        let wants = lensState.lens != nil
            && (lensState.animation != nil || lensState.stepRequested || lensState.keepsStepping)
        guard wants != lensState.isRunningFrames else { return }
        lensState.isRunningFrames = wants
        // A run of frames starts afresh: its first frame measures from no
        // earlier one, and resumes the lens's pointer tracking.
        lensState.lastFrameTimestamp = nil
        lensState.tracksPointer = false
        if wants {
            resumeFrameLink()
        } else {
            lensState.frameLink?.isPaused = true
        }
    }

    /// Unpauses the display link, making one first if need be. Only in a
    /// window the rail is not leaving, since the link follows the window's
    /// screen: a link made on the way out would outlive the move.
    func resumeFrameLink() {
        guard usesDisplayLink, window != nil, !lensState.isLeavingWindow else { return }
        if lensState.frameLink == nil {
            let link = displayLink(
                target: PromptRailDisplayLinkProxy(self),
                selector: #selector(PromptRailDisplayLinkProxy.fired(_:)))
            link.add(to: .main, forMode: .common)
            lensState.frameLink = link
        }
        lensState.frameLink?.isPaused = false
    }

    /// Drops the display link: the rail is leaving its window, and a new
    /// window means a new link, or the rail is going away.
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
    private func refreshLensDisplay() {
        guard let lens = lensState.lens else { return }
        let fraction = lensState.openFraction
        let rows = PromptRailLensRows.resting(currentLensGeometry()).blended(toward: lens.rows, fraction: fraction)
        lensState.displayedRows = rows
        var shape = lensPainter.shape(for: rows, openFraction: fraction, maxWidth: boxMaxWidth)
        // While the pointer is over the box, the box never narrows: moving
        // through rows with shorter titles must not leave the pointer outside
        // it, which would close the lens. Over the rail column, which sits in
        // front of the box's leading end, no narrowing can leave the pointer
        // outside, so there, as anywhere off the box, the box fits its rows.
        if lensState.isPointerOverBox, !isPointerOverRail {
            shape = shape.widened(toAtLeast: min(lensState.shape.width, boxMaxWidth))
        }
        lensState.shape = shape
        // The box moves and grows under a still pointer, which sends no
        // event, so its hover follows the box here.
        if let point = lensState.lastPointer {
            setPointerOverBox(bounds.contains(point) && isOverBox(point))
        }
        lensState.hoveredRow = rowUnderPointer(in: rows)
        updateLensFade(rows)
        needsDisplay = true
    }

    private func rowUnderPointer(in rows: PromptRailLensRows) -> Int? {
        guard lensOpen, lensState.openFraction > PromptRailRowMetrics.hoverMinOpenFraction, isPointerOverLens,
              let row = rows.index(atY: pointerY),
              rows.heights[row] >= PromptRailRowMetrics.hoverMinRowHeight
        else { return nil }
        return row
    }

    /// Fades the notches at whichever end clips a row: a sliding column past
    /// the floor, or a windowed rail part way open. The painter fades them,
    /// not the layer mask the resting rail uses, which would fade the box
    /// and its text at that end too, so the mask comes off.
    private func updateLensFade(_ rows: PromptRailLensRows) {
        guard let first = rows.tops.first, let lastTop = rows.tops.last, let lastHeight = rows.heights.last
        else { return }
        if hasFadeMask { setFade(top: false, bottom: false) }
        lensState.fade = PromptRailEndFades(
            top: first < PromptRailLayout.topInset - 0.5,
            bottom: lastTop + lastHeight > bounds.height - PromptRailLayout.bottomInset + 0.5)
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
    /// lens's box, the displayed row there; over the bare rail, the resting
    /// notch there. nil anywhere else, the box of a closing lens among it.
    func clickRow(at point: NSPoint) -> Int? {
        guard !entries.isEmpty, isOverRailOrBox(point) else { return nil }
        if lensState.lens != nil, lensState.openFraction > 0 {
            return lensState.displayedRows.index(atY: point.y)
        }
        guard isInRailColumn(point) else { return nil }
        return currentLayout().index(atRailY: point.y, offset: offset)
    }

    /// Jumps to row `row`'s prompt and closes the lens, which then does not
    /// grow again until the pointer has left the rail.
    func jump(toRow row: Int) {
        guard entries.indices.contains(row) else { return }
        let id = entries[row].id
        lensLogger.debug("rail click jumps to id=\(id, privacy: .public)")
        onJump(id)
        hover.dismiss(.click)
    }
}
