import CoreGraphics
import Foundation

/// Geometry of the prompt rail: one notch per prompt, packed at a pitch that
/// shrinks as prompts accumulate and scrolls once it hits the minimum.
/// Coordinates are flipped (y grows downward), matching NSTableView.
struct PromptRailLayout: Equatable {
    static let width: CGFloat = 20
    static let topInset: CGFloat = 12
    static let bottomInset: CGFloat = 12
    static let maxPitch: CGFloat = 8
    static let minPitch: CGFloat = 4
    static let notchLeading: CGFloat = 2
    static let inactiveNotch = CGSize(width: 14, height: 2)
    static let activeNotch = CGSize(width: 18, height: 3)
    static let edgeMargin: CGFloat = 40
    static let fadeHeight: CGFloat = 24

    let count: Int
    let railHeight: CGFloat

    /// Free height divided by count, clamped to `minPitch...maxPitch`.
    var pitch: CGFloat {
        guard count > 0 else { return Self.maxPitch }
        let free = railHeight - Self.topInset - Self.bottomInset
        return min(Self.maxPitch, max(Self.minPitch, free / CGFloat(count)))
    }

    var contentHeight: CGFloat {
        Self.topInset + CGFloat(count) * pitch + Self.bottomInset
    }

    var overflows: Bool { contentHeight > railHeight }

    /// Centre of a notch in content coordinates.
    func notchCenterY(_ index: Int) -> CGFloat {
        Self.topInset + (CGFloat(index) + 0.5) * pitch
    }

    /// Notch frame in content coordinates, centred on `notchCenterY`.
    func notchRect(_ index: Int, active: Bool) -> CGRect {
        let size = active ? Self.activeNotch : Self.inactiveNotch
        return CGRect(
            x: Self.notchLeading,
            y: notchCenterY(index) - size.height / 2,
            width: size.width,
            height: size.height
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
