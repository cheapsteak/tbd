import Foundation
import TBDShared

/// What the worktree picker's Codex row draws for one rate-limit window
/// (`CodexUsageBarsView`), kept out of the view so the ended-window rule is
/// testable.
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
}
