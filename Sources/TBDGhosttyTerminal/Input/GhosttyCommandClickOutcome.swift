// What a host made of a ⌘-press on plain text (`GhosttyTerminalView.onCommandClickText`).
//
// Two kinds of link open from a ⌘-click, at two different times, as on the SwiftTerm engine: what
// the host's own matcher finds opens at the press, and a link its link detection finds opens at
// the release, so a ⌘-drag that starts on it selects text instead of opening it.

/// What the host did with, or found in, the text under a left ⌘-press.
public enum GhosttyCommandClickOutcome {
    /// The host opened something at the press. The view consumes the press whole.
    case opened
    /// The host found a link that opens only if the press ends as a click: the view calls `open`
    /// at the release, unless the press became a drag first, or ⌘ was let go before the button.
    case opensOnRelease(open: @MainActor () -> Void)
    /// The host found nothing to open.
    case nothing
}
