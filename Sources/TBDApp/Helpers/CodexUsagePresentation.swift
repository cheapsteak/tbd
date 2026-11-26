import Foundation
import TBDShared

/// What the worktree picker's Codex row draws (`CodexUsageBarsView`): each
/// rate-limit window's bar, and whether its "Limit reached" label shows. Kept
/// out of the view so the ended-window rules are testable.
enum CodexUsagePresentation {
    struct Window: Equatable {
        /// Percent used: the window's own while it is open, 0 once it has ended.
        let percent: Int
        /// The trailing reset column: "at 7:00 PM" while the window is open,
        /// "reset 2h ago" once it has ended, and empty with no reset time.
        let resetLabel: String
        /// Whether the window has ended (`CodexRateLimitWindow.windowHasEnded(at:)`).
        let windowEnded: Bool
    }

    /// The bar for `window` at `now`. A window whose reset is at or before
    /// `now` went back to zero then, so it draws as a fresh one: 0%, and words
    /// saying when the limit reset in place of a reset time that has passed.
    /// Those words are `ProfileUsagePresentation.endedResetPhrase`'s relative
    /// form, "reset 2h ago", which fits the 74 pt column these bars share
    /// with the Claude rows' bars; the clock form, "reset at 10:47pm", can
    /// overflow it.
    static func window(_ window: CodexRateLimitWindow,
                       now: Date = Date(),
                       timeZone: TimeZone = .current) -> Window {
        guard let resetDate = window.resetDate else {
            return Window(percent: window.usedPercent, resetLabel: "", windowEnded: false)
        }
        if window.windowHasEnded(at: now) {
            let phrase = ProfileUsagePresentation.endedResetPhrase(
                resetDate, display: .countdown, now: now, timeZone: timeZone)
            return Window(percent: 0, resetLabel: phrase, windowEnded: true)
        }
        let time = resetDate.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone))
        return Window(percent: window.usedPercent, resetLabel: "at \(time)", windowEnded: false)
    }

    /// The `rateLimitReachedType` Codex sends when the limit reached is one of
    /// the snapshot's own windows, `primary` or `secondary`. Codex's other
    /// types name credits running out or a workspace's usage limit.
    static let windowLimitReachedType = "rate_limit_reached"

    /// Whether the row shows "Limit reached" over its bars at `now`, the
    /// instant the bars are drawn at.
    ///
    /// - **Spend control** (`spendControlReached`) shows the label whatever
    ///   the windows say. It is a cap a workspace puts on spending, not one of
    ///   the windows, so no window's reset lifts it.
    /// - **A window's limit** (`windowLimitReachedType`) shows it until every
    ///   window the snapshot has, primary and secondary, has ended
    ///   (`CodexRateLimitWindow.windowHasEnded(at:)`). The limit was read
    ///   before those resets, and the bars then draw each window as a fresh
    ///   one at 0%. A snapshot with neither window, or with a window that
    ///   gives no reset time, keeps the label, since nothing says the limit
    ///   has reset.
    /// - **Any other limit type** shows it whatever the windows say, because
    ///   the limit it names is not one of the windows.
    static func showsLimitReached(_ snapshot: CodexRateLimitSnapshot,
                                  now: Date = Date()) -> Bool {
        if snapshot.spendControlReached == true { return true }
        guard let reachedType = snapshot.rateLimitReachedType else { return false }
        guard reachedType == windowLimitReachedType else { return true }
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        guard !windows.isEmpty else { return true }
        return !windows.allSatisfy { $0.windowHasEnded(at: now) }
    }
}
