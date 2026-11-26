import Foundation
import TBDShared

/// The compact usage reading the daemon's notifications quote for an account:
/// "5h 61% · week 38%", from the session and weekly-all buckets.
///
/// A window that has ended, in a snapshot whose last fetch succeeded
/// (`ProfileUsageSnapshot.countsAsReset(_:at:)`), says so in place of its old
/// percent: "5h reset · week 38%". `ProfilePoolPicker` counts such a window as
/// 0%, so a notification that names an account for its room, or as the least
/// used, must not then quote it nearly full. A failing snapshot's windows
/// quote the percent they last read, which is what the picker ranked them by.
/// Callers pass the `now` their pick judged, so the text and the decision
/// agree.
///
/// Quoted by the limit-hit notification's suggestion
/// (`RPCRouter.handleRateLimitDetected`) and by `BalancingFallbackAlerts`.
enum ProfileUsageSummary {
    /// The reading at `now`, or nil when the snapshot carries neither a
    /// session nor a weekly-all bucket.
    static func text(of snapshot: ProfileUsageSnapshot, now: Date) -> String? {
        var parts: [String] = []
        if let session = snapshot.buckets.first(where: { $0.kind == "session" }) {
            parts.append(segment("5h", session, of: snapshot, now: now))
        }
        if let weekly = snapshot.buckets.first(where: { $0.kind == "weekly_all" }) {
            parts.append(segment("week", weekly, of: snapshot, now: now))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "5h reset" for a window `snapshot` counts as reset at `now`; "5h 61%"
    /// otherwise: an open window, one with no reset instant, or any window of
    /// a failing snapshot.
    private static func segment(
        _ label: String, _ bucket: ClaudeUsageLimitBucket,
        of snapshot: ProfileUsageSnapshot, now: Date
    ) -> String {
        snapshot.countsAsReset(bucket, at: now)
            ? "\(label) reset" : "\(label) \(Int(bucket.percent))%"
    }
}
