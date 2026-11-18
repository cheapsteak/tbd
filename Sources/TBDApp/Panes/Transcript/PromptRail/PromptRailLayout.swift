import CoreGraphics
import Foundation

/// Geometry of the prompt rail: one notch per prompt, packed at a pitch that
/// shrinks as prompts accumulate and scrolls once it hits the minimum. A short
/// session spreads its notches so the resting column is tall enough to hold
/// the lens. Coordinates are flipped (y grows downward), matching NSTableView.
struct PromptRailLayout: Equatable {
    static let width: CGFloat = 20
    static let topInset: CGFloat = 12
    static let bottomInset: CGFloat = 12
    /// The pitch of a mid-length session. A shorter one rests wider apart so
    /// its column holds the lens; see `pitch`.
    static let maxPitch: CGFloat = 8
    static let minPitch: CGFloat = 4
    /// The open lens's peak row height, `T` in the lens spec's "Strength".
    static let lensPeak: CGFloat = 26
    /// Rows on each side of the lens centre that grow, `R` in the lens spec's
    /// "Strength".
    static let lensRadius: CGFloat = 6
    /// The column height the lens needs to show its rows at full size,
    /// `lensPeak × lensRadius / 0.85`: about 184pt.
    static let lensNeed: CGFloat = lensPeak * lensRadius / 0.85
    static let notchLeading: CGFloat = 2
    static let inactiveNotchHeight: CGFloat = 2
    /// The active notch keeps its length and is marked by thickness instead.
    static let activeNotchHeight: CGFloat = 3
    static let edgeMargin: CGFloat = 40
    static let fadeHeight: CGFloat = 24

    let count: Int
    let railHeight: CGFloat

    /// The resting pitch, `max(minPitch, min(max(maxPitch, lensNeed / N),
    /// free / N))` for `N` prompts and the rail's free height (lens spec,
    /// "The resting rail"). A short session spreads its notches over the
    /// height the lens needs, capped at the free height, so the lens can open
    /// without moving either end of the column. Mid-length sessions keep
    /// `maxPitch`; long ones shrink toward `minPitch` and then window.
    var pitch: CGFloat {
        guard count > 0 else { return Self.maxPitch }
        let free = railHeight - Self.topInset - Self.bottomInset
        let n = CGFloat(count)
        return max(Self.minPitch, min(max(Self.maxPitch, Self.lensNeed / n), free / n))
    }

    var contentHeight: CGFloat {
        Self.topInset + CGFloat(count) * pitch + Self.bottomInset
    }

    var overflows: Bool { contentHeight > railHeight }

    /// Centre of a notch in content coordinates.
    func notchCenterY(_ index: Int) -> CGFloat {
        Self.topInset + (CGFloat(index) + 0.5) * pitch
    }

    /// A notch's thickness: `activeNotchHeight` for the active one,
    /// `inactiveNotchHeight` for the rest.
    static func notchHeight(active: Bool) -> CGFloat {
        active ? activeNotchHeight : inactiveNotchHeight
    }

    /// Notch frame in content coordinates, centred on `notchCenterY`, starting
    /// at `notchLeading` and `length` long (`PromptRailWorkScale`) whether or
    /// not it is active.
    func notchRect(_ index: Int, active: Bool, length: CGFloat) -> CGRect {
        let height = Self.notchHeight(active: active)
        return CGRect(
            x: Self.notchLeading,
            y: notchCenterY(index) - height / 2,
            width: length,
            height: height
        )
    }

    /// The smallest change from `current` that keeps the active notch at least
    /// `edgeMargin` from either end of the rail, clamped to the scrollable range.
    func scrollOffset(keepingVisible active: Int?, current: CGFloat) -> CGFloat {
        guard overflows else { return 0 }
        let maxOffset = contentHeight - railHeight
        var offset = current
        if let active {
            let center = notchCenterY(active)
            let top = Self.edgeMargin
            let bottom = railHeight - Self.edgeMargin
            if center - offset < top {
                offset = center - top
            } else if center - offset > bottom {
                offset = center - bottom
            }
        }
        return min(max(offset, 0), maxOffset)
    }

    /// Nearest notch to a point in rail coordinates, or nil when there are none.
    func index(atRailY y: CGFloat, offset: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        let raw = ((y + offset - Self.topInset) / pitch).rounded(.down)
        return min(max(Int(raw), 0), count - 1)
    }
}
