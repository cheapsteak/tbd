import CoreGraphics
import Foundation

/// The open lens's motion (lens spec, "The lens" → "Steady motion"): it holds
/// still while the pointer moves near its centre and follows when pushed. The
/// pointer's height and the elapsed time go in, and the new centre comes out;
/// it reads time only from what it is given, so a 60Hz and a 120Hz display
/// move it the same way in the same time.
///
/// A port of the approved HTML mock's `initLens`, `trackSpeed`, `steady` and
/// `steadyTarget`, with the ease and the speed smoothing made time-based.
struct PromptRailSteadyLens: Equatable, Sendable {
    /// The dead zone's half-width, as a share of the lens radius: 2.7 rows.
    static let deadZoneShare: CGFloat = 0.45
    /// The ease's time constant, `1 / (60 × ln(1 / 0.88))` ≈ 0.1304s: 12% of
    /// the remaining distance per 60Hz frame.
    static let easeTimeConstant: TimeInterval = 1 / (60 * log(1 / 0.88))
    /// A smoothed pointer speed above this, in pt per ms, is a flick, and the
    /// lens holds still.
    static let flickSpeed: CGFloat = 0.45
    /// A step that would move the centre less than this many rows moves it
    /// not at all, so the lens settles.
    static let settleRows: CGFloat = 0.002
    /// The speed smoothing keeps this share of the old speed per 60Hz frame:
    /// `v ← 0.6 × v + 0.4 × instantaneous`.
    private static let speedKeptPerFrame: CGFloat = 0.6

    private(set) var geometry: PromptRailLensGeometry
    private(set) var anchor: PromptRailLensAnchor
    /// The fractional row the lens is centred on.
    private(set) var centre: CGFloat
    /// The open lens's rows at `centre`.
    private(set) var rows: PromptRailLensRows
    /// The pointer's smoothed speed, in pt per ms.
    private(set) var speed: CGFloat = 0
    private var lastPointerY: CGFloat

    /// Opens the lens on the centre whose own layout puts the pointed row
    /// under the pointer.
    init(geometry: PromptRailLensGeometry, pointerY: CGFloat) {
        let anchor = geometry.anchor(pointerY: pointerY)
        let centre = geometry.openingCentre(pointerY: pointerY, anchor: anchor)
        self.geometry = geometry
        self.anchor = anchor
        self.centre = centre
        rows = geometry.rows(centre: centre, anchor: anchor)
        lastPointerY = pointerY
    }

    /// Advances the lens by `dt` seconds with the pointer at `pointerY`.
    /// Returns true when the centre moved.
    ///
    /// The lens holds still during a flick, and while the pointer is within
    /// the dead zone of its centre. Past the dead zone, the centre eases
    /// toward the centre whose layout puts the pointer exactly on the dead
    /// zone's edge, by `1 − exp(−dt / easeTimeConstant)` of the way.
    mutating func step(pointerY: CGFloat, dt: TimeInterval) -> Bool {
        guard dt > 0, !pointerY.isNaN else { return false }
        let elapsed = CGFloat(dt)
        let instant = abs(pointerY - lastPointerY) / (elapsed * 1000)
        speed += (instant - speed) * (1 - pow(Self.speedKeptPerFrame, elapsed * 60))
        lastPointerY = pointerY
        guard speed <= Self.flickSpeed else { return false }

        let pointed = rows.fraction(atY: pointerY)
        let deadZone = Self.deadZoneShare * PromptRailLayout.lensRadius
        let target: CGFloat
        if pointed > centre + deadZone {
            target = steadyTarget(pointerY: pointerY, below: true)
        } else if pointed < centre - deadZone {
            target = steadyTarget(pointerY: pointerY, below: false)
        } else {
            return false
        }
        let moved = centre + (target - centre) * CGFloat(1 - exp(-dt / Self.easeTimeConstant))
        guard abs(moved - centre) >= Self.settleRows else { return false }
        centre = moved
        rows = geometry.rows(centre: moved, anchor: anchor)
        return true
    }

    /// The lens on a new geometry, after the outline or the rail's height
    /// changed: the same centre, held to `0...count`, re-anchored on that
    /// centre's resting y.
    func rebased(to geometry: PromptRailLensGeometry) -> PromptRailSteadyLens {
        let centre = PromptRailLensMath.clamp(self.centre, 0, CGFloat(max(0, geometry.count)))
        let restingY = PromptRailLayout.topInset + centre * geometry.restPitch - geometry.restOffset
        let anchor = geometry.anchor(pointerY: restingY)
        var lens = self
        lens.geometry = geometry
        lens.anchor = anchor
        lens.centre = centre
        lens.rows = geometry.rows(centre: centre, anchor: anchor)
        return lens
    }

    /// The centre whose own layout puts `pointerY` exactly on the dead zone's
    /// edge: below the centre when `below`, above it otherwise. A 24-step
    /// bisection between the centre and that end of the rail.
    private func steadyTarget(pointerY: CGFloat, below: Bool) -> CGFloat {
        let edge = (below ? 1 : -1) * Self.deadZoneShare * PromptRailLayout.lensRadius
        var low = below ? centre : 0
        var high = below ? CGFloat(geometry.count) : centre
        for _ in 0..<24 {
            let middle = (low + high) / 2
            let pointed = geometry.rows(centre: middle, anchor: anchor).fraction(atY: pointerY)
            if pointed - middle - edge > 0 { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }
}
