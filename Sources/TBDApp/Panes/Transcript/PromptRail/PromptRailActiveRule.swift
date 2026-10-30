import CoreGraphics
import Foundation

/// Picks which prompt the rail marks active for the current scroll position.
enum PromptRailActiveRule {
    /// The probe line sits this fraction of the way down the viewport.
    static let probeFraction: CGFloat = 0.2
    /// Within this distance of the document bottom, the last prompt is active.
    static let bottomSlack: CGFloat = 8

    struct Viewport: Equatable {
        let minY: CGFloat
        let height: CGFloat
        let documentHeight: CGFloat
    }

    /// `rowTop` is called O(log n) times. Order: empty is nil; a valid held
    /// jump target wins; near the bottom the last entry wins; otherwise the
    /// last entry at or above the probe line, or the first when none is.
    static func activeIndex(
        count: Int,
        rowTop: (Int) -> CGFloat,
        viewport: Viewport,
        heldIndex: Int?
    ) -> Int? {
        guard count > 0 else { return nil }
        if let heldIndex, (0..<count).contains(heldIndex) { return heldIndex }
        if viewport.documentHeight - (viewport.minY + viewport.height) <= bottomSlack {
            return count - 1
        }
        let probe = viewport.minY + probeFraction * viewport.height
        var low = 0
        var high = count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if rowTop(mid) <= probe {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}
