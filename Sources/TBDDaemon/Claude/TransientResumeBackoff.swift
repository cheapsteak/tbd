import Foundation

/// Backoff ladder for transient API-error auto-continue (spec
/// 2026-07-08 §Backoff). A transient API error (5xx, overloaded, network
/// blip) is not a hard usage limit — Claude can often just be re-poked —
/// but repeatedly failing the same way within a short window signals
/// something more persistent, so each consecutive failure widens the delay
/// until the ladder gives up and leaves the row for a human.
public enum TransientResumeBackoff {

    /// Delay (seconds) for the 1st, 2nd, 3rd, 4th consecutive attempt.
    public static let steps: [TimeInterval] = [60, 120, 300, 600]

    /// Once this many consecutive attempts have landed within `lookback`,
    /// stop retrying — `delay(consecutiveAttempts:)` returns nil.
    public static let maxAttempts = 4

    /// Window `countRecentApiErrorAttempts` looks back over to count
    /// "consecutive" attempts — resets the ladder once a terminal has gone
    /// this long without a transient error.
    public static let lookback: TimeInterval = 30 * 60

    /// Delay for the NEXT attempt given how many consecutive attempts the
    /// lookback window already holds. nil == give up (cap reached).
    public static func delay(consecutiveAttempts: Int) -> TimeInterval? {
        guard consecutiveAttempts >= 0, consecutiveAttempts < maxAttempts else { return nil }
        return steps[consecutiveAttempts]
    }

    /// Notification copy: 60 -> "60s", 120 -> "2m", 300 -> "5m", 600 -> "10m".
    public static func copy(forDelay delay: TimeInterval) -> String {
        if delay < 120 {
            return "\(Int(delay))s"
        }
        return "\(Int(delay / 60))m"
    }
}
