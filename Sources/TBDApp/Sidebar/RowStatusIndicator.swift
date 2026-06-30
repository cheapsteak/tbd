import SwiftUI
import TBDShared

/// Indicator shown in the leading (identity / PR) slot of a sidebar row.
/// Mutually exclusive with `SuffixRowIndicator` — they occupy different
/// regions of the row and may both be present.
enum LeadingRowIndicator: Equatable {
    case pending
    case prStatus
}

/// Indicator shown in the trailing (activity / attention) suffix slot.
enum SuffixRowIndicator: Equatable {
    case error
    case attention
    case working
    case suspended

    /// SF Symbol for glyph-based suffixes. `.working` is `nil` because it is
    /// rendered as an animated `TypingDotsView`, not a static symbol.
    var systemImage: String? {
        switch self {
        case .error:     return "exclamationmark.octagon.fill"
        case .attention: return "hand.raised.fill"
        case .working:   return nil
        case .suspended: return "pause.circle.fill"
        }
    }

    /// Tint for the suffix glyph. `.working` reuses Claude's coral; the
    /// `TypingDotsView` reads this same value for its dots.
    var color: Color {
        switch self {
        case .error:
            return .red
        case .attention:
            // Light: amber #B7791F readable on light sidebar (~#F1F1F1).
            // Dark:  GitHub attention.fg #D29922 readable on dark sidebar.
            return adaptiveColor(
                light: NSColor(srgbRed: 183 / 255, green: 121 / 255, blue: 31 / 255, alpha: 1),
                dark: NSColor(srgbRed: 210 / 255, green: 153 / 255, blue: 34 / 255, alpha: 1)
            )
        case .working:
            return adaptiveColor(
                light: NSColor(srgbRed: 176 / 255, green: 87 / 255, blue: 48 / 255, alpha: 1),
                dark: NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
            )
        case .suspended:
            return .secondary
        }
    }
}

/// Pure resolvers for the two independent sidebar-row indicator regions.
///
/// The row no longer collapses every state onto one slot. PR status lives in
/// the leading region and is never hidden by activity; the suffix region shows
/// at most one of error / attention / working / suspended.
enum RowStatusIndicator {
    /// Leading slot. PR status (when present) always wins so it stays visible
    /// and clickable; a `.creating` worktree (which has no PR yet) shows the
    /// pending glyph. `hasPRStatus` is expected to already exclude the main
    /// worktree at the call site.
    static func leading(isPending: Bool, hasPRStatus: Bool) -> LeadingRowIndicator? {
        if hasPRStatus {
            return .prStatus
        } else if isPending {
            return .pending
        }
        return nil
    }

    /// Suffix slot. Priority (highest first): error > attention > working >
    /// suspended. `taskComplete` produces no suffix; `responseComplete` is
    /// surfaced as a bold name in the view, not as a suffix.
    static func suffix(
        notification: NotificationType?,
        isWorking: Bool,
        isSuspended: Bool
    ) -> SuffixRowIndicator? {
        if notification == .error {
            return .error
        } else if notification == .attentionNeeded || notification == .focusRequest {
            return .attention
        } else if isWorking {
            return .working
        } else if isSuspended {
            return .suspended
        }
        return nil
    }
}
