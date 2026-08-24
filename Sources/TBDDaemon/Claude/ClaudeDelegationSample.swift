import Foundation

/// Reads the newest `turn_duration` record out of a transcript tail and
/// reports how many background subagents Claude Code says are still live.
///
/// The field is a LEVEL, not an edge: Claude Code restates it at every turn
/// end and omits it entirely when no agents remain. Sampling only the newest
/// value is therefore correct however many earlier values went unread, which
/// is what makes this rail immune to the drift a start/stop counter carries.
///
/// Every unreadable, absent, or malformed case collapses to `nil` — make no
/// claim — because the rail may only ever fail toward the behavior that ships
/// without it.
enum ClaudeDelegationSample {
    /// Records larger than this are skipped rather than parsed.
    private static let recordByteLimit = 1 << 20

    static func pendingCount(inTail tail: Data) -> Int? {
        guard !tail.isEmpty else { return nil }
        var newest: Int?
        // A bounded tail almost always begins mid-record, but a leading
        // fragment does not need to be singled out and discarded: a byte
        // range that starts mid-object is not valid JSON, so it already fails
        // to parse below and is skipped like any other unreadable line. A
        // tail that happens to start exactly at a record boundary — the
        // common case for a short transcript read whole — keeps that record
        // instead of losing it to a blind drop.
        let lines = tail.split(separator: UInt8(ascii: "\n"),
                               omittingEmptySubsequences: true)
        for line in lines {
            guard line.count <= recordByteLimit else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let record = object as? [String: Any],
                  record["subtype"] as? String == "turn_duration" else { continue }
            // Present-and-positive is the only shape that claims. An omitted
            // field is how Claude Code spells zero, and it retracts a claim an
            // older record made.
            if let count = record["pendingBackgroundAgentCount"] as? Int, count > 0 {
                newest = count
            } else {
                newest = nil
            }
        }
        return newest
    }
}
