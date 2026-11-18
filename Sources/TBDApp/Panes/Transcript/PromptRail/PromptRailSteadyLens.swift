import CoreGraphics
import Foundation

/// The open lens's motion (lens spec, "The lens" → "Steady motion"): it holds
/// still while the pointer moves near its centre and follows when pushed, but
/// not during a flick. The caller notes each move of the pointer with its
/// event time and steps the lens on each frame by the time since the last;
/// it reads time only from what it is given, so a 60Hz and a 120Hz display
/// move it the same way in the same time.
///
/// A port of the approved HTML mock's `initLens`, `trackSpeed`, `steady` and
/// `steadyTarget`, with the ease and the speed smoothing made time-based, and
/// the speed measured from the pointer's own moves rather than from frames.
struct PromptRailSteadyLens: Equatable, Sendable {
    /// The dead zone's half-width, as a share of the lens radius: 2.7 rows.
    static let deadZoneShare: CGFloat = 0.45
    /// The ease's time constant, `1 / (60 × ln(1 / 0.88))` ≈ 0.1304s: 12% of
    /// the remaining distance per 60Hz frame.
    static let easeTimeConstant: TimeInterval = 1 / (60 * log(1 / 0.88))
    /// A smoothed pointer speed above this, in pt per ms, is a flick, and the
    /// lens holds still.
    static let flickSpeed: CGFloat = 0.45
    /// Once the centre is within this many rows of its target, it moves onto
    /// the target and stops there.
    static let settleRows: CGFloat = 0.002
    /// The shortest time a move's speed is measured over. Moves that arrive
    /// closer together, or with the same time, count as this far apart.
    static let shortestMoveGap: TimeInterval = 0.004
    /// The speed smoothing keeps this share of the old speed per 60Hz
    /// frame's worth of time: `v ← 0.6 × v + 0.4 × instantaneous`.
    private static let speedKeptPerFrame: CGFloat = 0.6
    /// Bisection steps for the target the centre eases toward, and for the
    /// one it settles on, which runs until the interval stops shrinking, so
    /// that the settled centre does not depend on where the bisection
    /// started.
    private static let followSteps = 24
    private static let settleSteps = 64

    private(set) var geometry: PromptRailLensGeometry
    private(set) var anchor: PromptRailLensAnchor
    /// The fractional row the lens is centred on.
    private(set) var centre: CGFloat
    /// The open lens's rows at `centre`.
    private(set) var rows: PromptRailLensRows
    /// The pointer's smoothed speed, in pt per ms.
    private(set) var speed: CGFloat = 0
    /// The pointer's height at its last noted move, or where the lens opened.
    private(set) var pointerY: CGFloat
    /// The last noted move's event time; nil before the first.
    private var lastMoveTime: TimeInterval?
    /// Whether the next move is measured against the last. Not from the
    /// lens's opening, nor from the pointer leaving the rail column and the
    /// box, until a move starts a new run.
    private var measuresNextMove = false
    /// A move was noted since the last step, so that step does not decay the
    /// speed.
    private var movedSinceStep = false
    /// How much of the time since the last move the steps have decayed the
    /// speed over already.
    private var decayedSinceMove: TimeInterval = 0
    /// The centre sits on its target for the pointer where it is. No step
    /// moves it until the pointer moves or the lens is rebased.
    private var isSettled = false

    /// Opens the lens on the centre whose own layout puts the pointed row
    /// under the pointer.
    init(geometry: PromptRailLensGeometry, pointerY: CGFloat) {
        let anchor = geometry.anchor(pointerY: pointerY)
        let centre = geometry.openingCentre(pointerY: pointerY, anchor: anchor)
        self.geometry = geometry
        self.anchor = anchor
        self.centre = centre
        rows = geometry.rows(centre: centre, anchor: anchor)
        self.pointerY = pointerY
    }

    /// Notes a move of the pointer over the rail column or the box, to `y`
    /// in rail coordinates, at `time` seconds on the events' clock
    /// (`NSEvent.timestamp`).
    ///
    /// The move's speed is its distance over the time since the last move,
    /// at least `shortestMoveGap`, and the smoothing runs over that same
    /// time, so a move after a pause reads as slow as it was. The steps since
    /// the last move have already decayed the speed over part of that time,
    /// and the old speed decays over only the rest. The first move after the
    /// lens opens or the pointer leaves starts a new run: it decays the
    /// speed over the time since the last move and reads none of its own,
    /// since where the pointer went meanwhile was no move over the rail.
    mutating func notePointer(y: CGFloat, time: TimeInterval) {
        guard !y.isNaN, !time.isNaN else { return }
        if y != pointerY { isSettled = false }
        if let lastMoveTime {
            let gap = max(Self.shortestMoveGap, time - lastMoveTime)
            let kept = Self.speedKept(over: max(0, gap - decayedSinceMove))
            if measuresNextMove {
                let instant = abs(y - pointerY) / CGFloat(gap * 1000)
                speed = speed * kept + instant * (1 - Self.speedKept(over: gap))
            } else {
                speed *= kept
            }
        }
        pointerY = y
        lastMoveTime = time
        measuresNextMove = true
        movedSinceStep = true
        decayedSinceMove = 0
    }

    /// The pointer left the rail column and the box: its next move starts a
    /// new run.
    mutating func pointerLeft() {
        measuresNextMove = false
    }

    /// The pointer is at `y` with no move of its own: the box grew under a
    /// still pointer, which now points into the lens. The lens follows it as
    /// after a move, but reads no speed from it, and the pointer's next move
    /// starts a new run.
    mutating func placePointer(y: CGFloat) {
        guard !y.isNaN else { return }
        if y != pointerY { isSettled = false }
        pointerY = y
        measuresNextMove = false
    }

    /// Advances the lens by `dt` seconds of frame time. Returns true when the
    /// centre moved.
    ///
    /// A step with no move noted since the last decays the speed toward zero
    /// over `dt`, by the smoothing's own factor: the pointer is still. A rail
    /// that keeps its resting rows (spec step 0) never moves. Otherwise the
    /// lens holds still during a flick, and while the pointer is within the
    /// dead zone of its centre. Past the dead zone, the centre eases toward
    /// the centre whose layout puts the pointer exactly on the dead zone's
    /// edge, by `1 − exp(−dt / easeTimeConstant)` of the way. Once within
    /// `settleRows` of it, the centre moves onto it and stops there, so it
    /// settles in the same place at any frame rate.
    ///
    /// A step during which the decaying speed falls to `flickSpeed` eases
    /// only for the part of `dt` after it did, worked out from the decay
    /// curve: until then the lens was held still by the flick. So a late
    /// frame after a flick moves the lens as far as the frames it stands
    /// for would have.
    mutating func step(dt: TimeInterval) -> Bool {
        guard dt > 0 else { return false }
        var easeTime = dt
        if movedSinceStep {
            movedSinceStep = false
        } else {
            let before = speed
            speed *= Self.speedKept(over: dt)
            decayedSinceMove += dt
            if before > Self.flickSpeed, speed <= Self.flickSpeed {
                easeTime = dt - min(dt, Self.decayTime(from: before, to: Self.flickSpeed))
            }
        }
        guard !geometry.keepsRestingRows, !isSettled, speed <= Self.flickSpeed else { return false }

        let pointed = rows.fraction(atY: pointerY)
        let deadZone = Self.deadZoneShare * PromptRailLayout.lensRadius
        let below: Bool
        if pointed > centre + deadZone {
            below = true
        } else if pointed < centre - deadZone {
            below = false
        } else {
            return false
        }
        let target = steadyTarget(below: below, steps: Self.followSteps)
        guard abs(target - centre) >= Self.settleRows else {
            isSettled = true
            let settled = steadyTarget(below: below, steps: Self.settleSteps)
            guard settled != centre else { return false }
            moveCentre(to: settled)
            return true
        }
        moveCentre(to: centre + (target - centre) * CGFloat(1 - exp(-easeTime / Self.easeTimeConstant)))
        return true
    }

    /// The lens on a new geometry, after the outline or the rail's height
    /// changed: the same centre, held to `0...count`, re-anchored on that
    /// centre at the height it is drawn at now, held to the new column. On a
    /// windowed rail the drawn height is not the resting one, because the
    /// anchor the lens opened with bends the mapping, so anchoring on the
    /// resting height would move the centre out from under a still pointer.
    func rebased(to geometry: PromptRailLensGeometry) -> PromptRailSteadyLens {
        let centre = PromptRailLensMath.clamp(self.centre, 0, CGFloat(max(0, geometry.count)))
        let anchor = geometry.anchor(row: centre, atY: rows.y(ofFraction: centre))
        var lens = self
        lens.geometry = geometry
        lens.anchor = anchor
        lens.isSettled = false
        lens.moveCentre(to: centre)
        return lens
    }

    private mutating func moveCentre(to centre: CGFloat) {
        self.centre = centre
        rows = geometry.rows(centre: centre, anchor: anchor)
    }

    /// The share of the speed the smoothing keeps over `time` seconds.
    private static func speedKept(over time: TimeInterval) -> CGFloat {
        pow(speedKeptPerFrame, CGFloat(time) * 60)
    }

    /// The time, in seconds, over which the smoothing decays a speed `from`
    /// to `to`, both positive and `to` no more than `from`: the inverse of
    /// `speedKept(over:)`.
    private static func decayTime(from: CGFloat, to: CGFloat) -> TimeInterval {
        TimeInterval(log(to / from) / (60 * log(speedKeptPerFrame)))
    }

    /// The centre whose own layout puts the pointer exactly on the dead
    /// zone's edge: below the centre when `below`, above it otherwise. A
    /// bisection of at most `steps` steps between the centre and that end of
    /// the rail.
    private func steadyTarget(below: Bool, steps: Int) -> CGFloat {
        let edge = (below ? 1 : -1) * Self.deadZoneShare * PromptRailLayout.lensRadius
        var low = below ? centre : 0
        var high = below ? CGFloat(geometry.count) : centre
        for _ in 0..<steps {
            let middle = (low + high) / 2
            guard middle > low, middle < high else { break }
            let pointed = geometry.rows(centre: middle, anchor: anchor).fraction(atY: pointerY)
            if pointed - middle - edge > 0 { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }
}
