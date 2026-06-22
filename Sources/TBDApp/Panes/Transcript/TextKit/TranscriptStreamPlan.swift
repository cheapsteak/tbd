import CoreGraphics

/// The kind of TextKit edit a new poll result implies, derived purely from the
/// node arrays so it is unit-testable away from the live STTextView. (#129)
enum TranscriptStreamStep: Equatable {
    case noop
    case rebuild
    case append(fromIndex: Int)
    case updateLast
}

@MainActor
enum TranscriptStreamPlan {
    static func step(previous: [TranscriptRenderNode], next: [TranscriptRenderNode]) -> TranscriptStreamStep {
        if next.isEmpty { return previous.isEmpty ? .noop : .rebuild }
        if previous.isEmpty { return .append(fromIndex: 0) }

        // Pure append (or no-op): previous is an id+version-stable prefix of next.
        if next.count >= previous.count {
            var prefixStable = true
            for i in previous.indices where i < next.count {
                if previous[i].id != next[i].id || previous[i].contentVersion != next[i].contentVersion {
                    prefixStable = false
                    break
                }
            }
            if prefixStable {
                return next.count == previous.count ? .noop : .append(fromIndex: previous.count)
            }
        }

        // Tail-only re-render: same ids, every node except the last unchanged,
        // last node's contentVersion differs (streaming text grew / result landed).
        if next.count == previous.count {
            var headStable = true
            for i in previous.indices.dropLast() {
                if previous[i].id != next[i].id || previous[i].contentVersion != next[i].contentVersion {
                    headStable = false
                    break
                }
            }
            let last = previous.count - 1
            if headStable,
               previous[last].id == next[last].id,
               previous[last].contentVersion != next[last].contentVersion {
                return .updateLast
            }
        }

        return .rebuild
    }

    static func isNearBottom(documentMaxY: CGFloat, visibleMaxY: CGFloat, threshold: CGFloat = 120) -> Bool {
        documentMaxY - visibleMaxY <= threshold
    }
}
