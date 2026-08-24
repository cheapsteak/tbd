import SwiftUI
import TBDShared

/// Indicator shown in the leading (identity / PR) slot of a sidebar row.
/// Mutually exclusive with `SuffixRowIndicator` — they occupy different
/// regions of the row and may both be present.
enum LeadingRowIndicator: Equatable {
    case pending
    case prStatus
    /// No cached PR, and the last attempt to learn whether there is one came
    /// back `.undetermined`. Distinct from showing nothing, which is what a
    /// worktree with a settled "no pull request" gets: a forge outage that
    /// rendered identically to a quiet fleet is the exact failure
    /// `PRObservation` exists to make visible.
    case prUnknown
    /// Tucked-away marker that a row's session runs on a remote-agent
    /// backend rather than a local worktree. Deliberately the lowest
    /// priority in the slot — see `RowStatusIndicator.leading(isPending:hasPRStatus:isRemote:)`.
    case remote
}

/// Indicator shown in the trailing (activity / attention) suffix slot.
enum SuffixRowIndicator: Equatable {
    case error
    case attention
    case working
    case suspended
    /// Session hibernated (claude process killed to reclaim memory; tmux window
    /// kept alive). A calm, whisper-quiet moon — deliberately NOT alarming: the
    /// session is safe and wakes automatically on focus.
    case hibernated

    /// SF Symbol for glyph-based suffixes. `.working` is `nil` because it is
    /// rendered as an animated `TypingDotsView`, not a static symbol.
    var systemImage: String? {
        switch self {
        case .error:      return "exclamationmark.octagon.fill"
        case .attention:  return "hand.raised.fill"
        case .working:    return nil
        case .suspended:  return "pause.circle.fill"
        case .hibernated: return "moon.zzz.fill"
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
            return .secondary
        case .suspended:
            return .secondary
        case .hibernated:
            // Tertiary — quieter than suspended, so it reads as "resting", not
            // "stopped". A whisper, not a flag.
            return Color.secondary.opacity(0.55)
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
    /// and clickable; a `.creating`/`.starting` row (which has no PR yet)
    /// shows the pending glyph. `hasPRStatus` is expected to already exclude
    /// the main worktree at the call site. `isRemote` is lowest priority —
    /// it's a quiet "elsewhere" marker, not an active-state signal, so PR
    /// status and the starting spinner both take the slot first when
    /// present. Defaults to `false` so existing local-row callers are
    /// unaffected.
    /// `hasUndeterminedPR` sits below `.pending` — a row still being created
    /// has nothing to have a pull request *for* yet, so its spinner is the more
    /// informative glyph — and above `.remote`, because "we could not find out"
    /// is an active-state signal while the remote marker is not. Defaults to
    /// `false` so existing callers are unaffected.
    static func leading(
        isPending: Bool,
        hasPRStatus: Bool,
        isRemote: Bool = false,
        hasUndeterminedPR: Bool = false
    ) -> LeadingRowIndicator? {
        if hasPRStatus {
            return .prStatus
        } else if isPending {
            return .pending
        } else if hasUndeterminedPR {
            return .prUnknown
        } else if isRemote {
            return .remote
        }
        return nil
    }

    /// Whether the worktree name should be bold for the given unread
    /// notification. Bold tracks "you should look here" — a completed response
    /// or an attention request. Shared by the sidebar row and the jump menu so
    /// they stay consistent.
    ///
    /// `hasPromptOnScreen` bolds on the same input that gives the suffix slot
    /// its attention glyph, and for the same reason: the notification saying
    /// the same thing is marked read the moment its worktree is selected, so
    /// without it the row this fix targets would show the raised hand beside a
    /// regular-weight name — half-escalated, a state the notification-only
    /// design could never produce.
    ///
    /// It does not outrank `.error`, because `suffix` does not either: an error
    /// takes the slot over a prompt, and `.error` deliberately does not bold.
    /// Bolding here regardless would put a bold name beside an error glyph —
    /// two severities at once, the same half-escalation in the other direction.
    static func shouldBoldName(
        _ notification: NotificationType?,
        hasPromptOnScreen: Bool = false
    ) -> Bool {
        if hasPromptOnScreen, notification != .error { return true }
        switch notification {
        case .responseComplete, .attentionNeeded, .focusRequest, .limitReached:
            return true
        case .error, .taskComplete, .none:
            return false
        }
    }

    /// Suffix slot. Priority (highest first): error > attention > working >
    /// suspended > hibernated. `taskComplete` produces no suffix;
    /// `responseComplete` is surfaced as a bold name in the view, not as a
    /// suffix. Hibernated is lowest — it's the calmest, safest state, so any
    /// louder signal wins the slot.
    ///
    /// `hasPromptOnScreen` shares the `.attention` rank with the notification
    /// that reports the same thing, and is the input that survives a glance.
    /// The two carriers are not interchangeable: a notification is unread mail
    /// and is marked read the moment its worktree is selected, so the selected
    /// (or pinned) row — the one the user is actually looking at — fell through
    /// to `isWorking` and animated the thinking dots at a session that was
    /// sitting on a permission prompt. This flag comes from the terminal's own
    /// `awaitingInputReason` and is independent of read state and of selection.
    ///
    /// It ranks above `isWorking` deliberately, and `activityState` is left
    /// alone: Claude Code raises a prompt in the middle of a turn, so the
    /// session genuinely IS working — that fact gates hibernation and must not
    /// be rewritten. The slot shows the louder of the two, which is the prompt.
    ///
    /// Only `.promptOnScreen` reaches this parameter. `.doneWaiting`,
    /// `.informational` and `.unrecognized` are no signal here — see
    /// `AwaitingInputClass`, where an unknown class is never guessed into a
    /// neighbouring one.
    static func suffix(
        notification: NotificationType?,
        isWorking: Bool,
        isSuspended: Bool,
        isHibernated: Bool = false,
        hasPromptOnScreen: Bool = false
    ) -> SuffixRowIndicator? {
        if notification == .error {
            return .error
        } else if notification == .attentionNeeded || notification == .focusRequest
                    || hasPromptOnScreen {
            return .attention
        } else if isWorking {
            return .working
        } else if isSuspended {
            return .suspended
        } else if isHibernated {
            return .hibernated
        }
        return nil
    }
}
