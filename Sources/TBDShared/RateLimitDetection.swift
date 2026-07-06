import Foundation

/// A hard usage-limit hit extracted from a Claude Code transcript.
public struct DetectedRateLimit: Equatable, Sendable {
    /// Absolute reset instant. Parsed ONCE and persisted — never re-derived
    /// from display text later (spec: autoclaude's flagship bug).
    public let resetsAt: Date
    /// Structured `rateLimitType` when available, else the qualifier words
    /// captured from "hit your <qualifier> limit", else "unknown".
    public let limitType: String
    /// Verbatim display text from the transcript record.
    public let rawMessage: String

    public init(resetsAt: Date, limitType: String, rawMessage: String) {
        self.resetsAt = resetsAt
        self.limitType = limitType
        self.rawMessage = rawMessage
    }
}

/// Pure detection logic shared by the CLI (`tbd hooks stop-failure`), the
/// daemon (actuator's user-already-continued check), and tests.
///
/// Spec: docs/specs/2026-07-03-session-limit-auto-resume-design.md §Detection.
public enum RateLimitDetection {

    // MARK: - Entry point

    /// Scan transcript JSONL for the last `isApiErrorMessage == true` record
    /// and decide whether it is a schedulable hard limit.
    ///
    /// Order (spec): structured `rate_limit_info` first (`status == "rejected"`
    /// + epoch `resetsAt` taken verbatim); else text fallback (hard-limit
    /// wording + parseable reset clause). Transient wordings and unparseable
    /// times return nil — the caller keeps its plain error notification.
    public static func detect(
        transcriptData: Data,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> DetectedRateLimit? {
        guard let entry = lastApiErrorEntry(in: transcriptData) else { return nil }
        let text = entry.text ?? ""

        // 1. Structured first.
        if let info = entry.rateLimitInfo,
           (info["status"] as? String) == "rejected" {
            let epoch: Double?
            if let d = info["resetsAt"] as? Double {
                epoch = d
            } else if let i = info["resetsAt"] as? Int {
                epoch = Double(i)
            } else {
                epoch = nil
            }
            if let epoch {
                return DetectedRateLimit(
                    resetsAt: Date(timeIntervalSince1970: epoch),
                    limitType: (info["rateLimitType"] as? String) ?? "unknown",
                    rawMessage: text
                )
            }
        }

        // 2. Text fallback.
        guard !text.isEmpty,
              !isTransientMessage(text),
              isHardLimitMessage(text),
              let resetsAt = parseResetTime(from: text, now: now, defaultTimeZone: timeZone)
        else { return nil }

        return DetectedRateLimit(
            resetsAt: resetsAt,
            limitType: qualifier(in: text) ?? "unknown",
            rawMessage: text
        )
    }

    // MARK: - Wording discrimination

    /// Transient wordings Claude Code retries itself. Racing its internal
    /// retry loop was a documented community-tool failure mode — exclude.
    public static func isTransientMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("not your usage limit") { return true }
        if lower.contains("temporarily limiting requests") { return true }
        // Bare HTTP-status API errors (429/5xx/529) with no limit wording.
        if lower.range(of: #"api error:?\s*(429|5\d\d)"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Hard-limit wordings. Qualifier drifts (session / weekly / 5-hour /
    /// future words) — allow up to a few arbitrary words before "limit"
    /// (spec, per claude-auto-retry issue #15).
    public static func isHardLimitMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.range(of: #"hit your(?:\s+\S+){0,5}?\s+limit"#, options: .regularExpression) != nil {
            return true
        }
        if lower.contains("limit reached") { return true }
        if lower.contains("out of extra usage") { return true }
        return false
    }

    /// Qualifier words between "hit your" and "limit", for `limitType`.
    static func qualifier(in text: String) -> String? {
        let lower = text.lowercased()
        guard let regex = try? NSRegularExpression(pattern: #"hit your((?:\s+\S+){0,5}?)\s+limit"#),
              let m = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: lower)
        else { return nil }
        let q = lower[r].trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? nil : q
    }

    // MARK: - Reset-time text parsing

    /// Parse "resets 3pm (America/Toronto)" / "Resets at 2pm" / "resets 4:50pm"
    /// into an absolute instant using Foundation Calendar + TimeZone — never
    /// offset arithmetic (spec: claude-auto-retry's nastiest bug).
    ///
    /// Rules (spec):
    /// - no am/pm and hour 1–12 → compute both candidates, take nearest future;
    /// - parsed instant already past → add a day;
    /// - unparseable (incl. unknown IANA zone) → nil.
    public static func parseResetTime(
        from text: String, now: Date, defaultTimeZone: TimeZone
    ) -> Date? {
        let pattern = #"resets(?:\s+at)?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?:\s*\(([^)]+)\))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        func group(_ i: Int) -> String? {
            guard m.numberOfRanges > i, let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r])
        }
        guard let hourStr = group(1), let hour = Int(hourStr), hour <= 23 else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        guard minute <= 59 else { return nil }
        let ampm = group(3)?.lowercased()

        let zone: TimeZone
        if let zoneID = group(4) {
            guard let z = TimeZone(identifier: zoneID.trimmingCharacters(in: .whitespaces)) else {
                return nil  // unknown zone → unparseable → notify-only
            }
            zone = z
        } else {
            zone = defaultTimeZone
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        /// Today's instant at hour24:minute in `zone`, rolled +1 day if past.
        func futureCandidate(hour24: Int) -> Date? {
            var comps = calendar.dateComponents([.year, .month, .day], from: now)
            comps.hour = hour24
            comps.minute = minute
            comps.second = 0
            guard var candidate = calendar.date(from: comps) else { return nil }
            if candidate <= now {
                guard let rolled = calendar.date(byAdding: .day, value: 1, to: candidate) else {
                    return nil
                }
                candidate = rolled
            }
            return candidate
        }

        if let ampm {
            let hour24: Int
            switch (ampm, hour) {
            case ("am", 12): hour24 = 0
            case ("am", _):  hour24 = hour
            case ("pm", 12): hour24 = 12
            default:         hour24 = hour + 12
            }
            guard hour24 <= 23 else { return nil }
            return futureCandidate(hour24: hour24)
        }

        if (1...12).contains(hour) {
            // Ambiguous: both interpretations, nearest future wins.
            let candidates = [hour % 12, (hour % 12) + 12].compactMap(futureCandidate(hour24:))
            return candidates.min()
        }
        return futureCandidate(hour24: hour)
    }

    // MARK: - JSONL scanning

    /// Last `isApiErrorMessage == true` record: first non-empty text block +
    /// the top-level `rate_limit_info` object when present.
    static func lastApiErrorEntry(in data: Data) -> (text: String?, rateLimitInfo: [String: Any]?)? {
        guard let contents = String(data: data, encoding: .utf8) else { return nil }
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["isApiErrorMessage"] as? Bool == true
            else { continue }
            var text: String?
            if let message = obj["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "text" {
                    if let t = block["text"] as? String,
                       !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        text = t
                        break
                    }
                }
            }
            return (text: text, rateLimitInfo: obj["rate_limit_info"] as? [String: Any])
        }
        return nil
    }

    /// True when the newest timestamped transcript record is newer than
    /// `cutoff`. Used at fire time: any record after the limit hit means the
    /// user already continued — cancel, send nothing (spec §Actuation 2).
    public static func hasRecord(newerThan cutoff: Date, in data: Data) -> Bool {
        guard let contents = String(data: data, encoding: .utf8) else { return false }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let ts = obj["timestamp"] as? String
            else { continue }

            var date: Date?
            // Try ISO8601 with fractional seconds first
            if let parsed = isoFractional.date(from: ts) {
                date = parsed
            } else if let parsed = isoPlain.date(from: ts) {
                date = parsed
            }

            if let parsedDate = date {
                return parsedDate > cutoff
            }
        }
        return false
    }
}

/// Formats reset/fire instants for notification + badge copy: "1:01pm",
/// minutes dropped when zero ("1pm"). Locale-pinned so copy is stable.
public enum ResumeTimeFormatter {
    public static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.component(.minute, from: date) == 0 ? "ha" : "h:mma"
        return formatter.string(from: date).lowercased()
    }
}
