import Foundation
import TBDShared

/// App-side presentation of a model profile's OAuth usage snapshot — the
/// `ModelProfileWithUsage.usageSnapshot` buckets the daemon's poller maintains.
///
/// Pure string/ordering composition, extracted from the views (the "+" new-tab
/// menu, the spawn-time account picker, the per-session tab tooltips) so the
/// suffix/sort/severity rules are unit-testable without UI. Companion to
/// `ProfileLoginPresentation`, which owns the identity ("— email") fragments.
enum ProfileUsagePresentation {
    // Bucket kinds as the Claude OAuth usage API names them.
    static let sessionKind = "session"
    static let weeklyAllKind = "weekly_all"
    static let weeklyScopedKind = "weekly_scoped"

    // MARK: - Bucket access

    /// The 5-hour rolling window bucket, if present.
    static func sessionBucket(_ snapshot: ProfileUsageSnapshot?) -> ClaudeUsageLimitBucket? {
        snapshot?.buckets.first { $0.kind == sessionKind }
    }

    /// The weekly all-models bucket, if present.
    static func weeklyAllBucket(_ snapshot: ProfileUsageSnapshot?) -> ClaudeUsageLimitBucket? {
        snapshot?.buckets.first { $0.kind == weeklyAllKind }
    }

    /// Per-model-family weekly buckets (e.g. "Fable"), in API order. A family
    /// absent from this list simply has no data for that account — render nothing.
    static func scopedBuckets(_ snapshot: ProfileUsageSnapshot?) -> [ClaudeUsageLimitBucket] {
        snapshot?.buckets.filter { $0.kind == weeklyScopedKind } ?? []
    }

    // MARK: - Severity

    /// Severity tiers for coloring usage bars/percentages.
    enum SeverityLevel {
        case normal
        case warning
        case critical
    }

    /// Map the API's severity label to a tier. When the API omits severity,
    /// fall back to percent thresholds (>=90 critical, >=75 warning) so
    /// exhausted buckets never render as healthy.
    static func severityLevel(severity: String?, percent: Double) -> SeverityLevel {
        switch severity {
        case "critical": return .critical
        case "warning": return .warning
        case "normal": return .normal
        default:
            if percent >= 90 { return .critical }
            if percent >= 75 { return .warning }
            return .normal
        }
    }

    // MARK: - Formatting fragments

    /// "76%" — usage percents render as whole numbers everywhere.
    static func percentText(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    /// "23:10" — reset times are compact 24h clock times (menu width is precious).
    static func resetTimeText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// "F" for "Fable" — single-letter family abbreviation for menu rows.
    static func familyAbbreviation(_ displayName: String?) -> String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    /// Compact usage summary without a leading separator:
    /// "5h 0% ↺23:10 · wk 76% · F 100%". nil when there is no snapshot or it
    /// has no buckets (never logged in / poller hasn't fetched yet).
    static func usageSummary(for snapshot: ProfileUsageSnapshot?,
                             timeZone: TimeZone = .current) -> String? {
        guard let snapshot, !snapshot.buckets.isEmpty else { return nil }
        var parts: [String] = []
        if let session = sessionBucket(snapshot) {
            var part = "5h \(percentText(session.percent))"
            if let resets = session.resetsAt {
                part += " ↺\(resetTimeText(resets, timeZone: timeZone))"
            }
            parts.append(part)
        }
        if let weekly = weeklyAllBucket(snapshot) {
            parts.append("wk \(percentText(weekly.percent))")
        }
        for scoped in scopedBuckets(snapshot) {
            parts.append("\(familyAbbreviation(scoped.modelDisplayName)) \(percentText(scoped.percent))")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// "+"-menu suffix form of `usageSummary` — " · 5h 0% ↺23:10 · …", or ""
    /// when there is nothing to show (profiles without a snapshot keep their
    /// plain identity title).
    static func usageSuffix(for snapshot: ProfileUsageSnapshot?,
                            timeZone: TimeZone = .current) -> String {
        guard let summary = usageSummary(for: snapshot, timeZone: timeZone) else { return "" }
        return " · " + summary
    }

    /// Full "+"-menu row title: `ProfileLoginPresentation.menuItemTitle` plus
    /// the compact usage suffix, e.g.
    /// "Gmail — gmail@… · 5h 0% ↺23:10 · wk 76% · F 100%".
    static func menuItemTitle(for entry: ModelProfileWithUsage,
                              timeZone: TimeZone = .current) -> String {
        ProfileLoginPresentation.menuItemTitle(for: entry)
            + usageSuffix(for: entry.usageSnapshot, timeZone: timeZone)
    }

    // MARK: - Picker ordering & row state

    /// oauth profiles with no detected login render as disabled "not logged in"
    /// rows in the picker — they cannot be spawned onto meaningfully.
    static func isSelectable(_ entry: ModelProfileWithUsage) -> Bool {
        !ProfileLoginPresentation.needsLogin(kind: entry.profile.kind,
                                             loginIdentity: entry.loginIdentity)
    }

    /// Display order for the account picker: selectable profiles with session
    /// data first — healthiest (lowest 5h percent) first, ties broken by the
    /// window that resets soonest — then selectable profiles without usage
    /// data, then not-logged-in rows last. Display-only heuristic: the picker
    /// never auto-selects.
    static func sortedForPicker(_ entries: [ModelProfileWithUsage]) -> [ModelProfileWithUsage] {
        func rank(_ entry: ModelProfileWithUsage) -> (Int, Double, TimeInterval) {
            guard isSelectable(entry) else {
                return (2, 0, .greatestFiniteMagnitude)
            }
            guard let session = sessionBucket(entry.usageSnapshot) else {
                return (1, 0, .greatestFiniteMagnitude)
            }
            let reset = session.resetsAt?.timeIntervalSinceReferenceDate
                ?? .greatestFiniteMagnitude
            return (0, session.percent, reset)
        }
        return entries
            .enumerated()
            .sorted { lhs, rhs in
                let (lg, lp, lr) = rank(lhs.element)
                let (rg, rp, rr) = rank(rhs.element)
                if lg != rg { return lg < rg }
                if lp != rp { return lp < rp }
                if lr != rr { return lr < rr }
                return lhs.offset < rhs.offset   // stable
            }
            .map(\.element)
    }

    /// Threshold past which snapshot data is called out as stale in the picker.
    /// The daemon poller sweeps ~every 90s, so 5 minutes means several misses.
    static let staleAge: TimeInterval = 300

    /// Staleness note for a picker row. nil = data is fresh and healthy (no
    /// note). A failing snapshot surfaces the daemon's status string verbatim
    /// (it already reads "stale since …; fetch failed: …").
    static func stalenessNote(for snapshot: ProfileUsageSnapshot?,
                              now: Date = Date()) -> String? {
        guard let snapshot else { return nil }
        guard snapshot.isOK else { return snapshot.status }
        guard let fetchedAt = snapshot.fetchedAt else { return "no usage data yet" }
        let age = now.timeIntervalSince(fetchedAt)
        guard age >= staleAge else { return nil }
        return "updated \(Int(age / 60))m ago"
    }

    // MARK: - Per-session tooltips

    /// "2026-07-03 14:05" — fixed format so tooltips are locale-stable.
    static func spawnTimeText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// Human account descriptor for a Claude terminal, resolved against the
    /// current profile list: "email (Profile)" for pinned + logged-in,
    /// "Profile (not logged in)" for pinned pre-login, "ambient (terminal
    /// login)" for NULL-profile legacy sessions, and a removed-profile note
    /// when the id no longer resolves.
    static func accountDescriptor(profileID: UUID?,
                                  profiles: [ModelProfileWithUsage]) -> String {
        guard let profileID else { return "ambient (terminal login)" }
        guard let entry = profiles.first(where: { $0.profile.id == profileID }) else {
            return "profile removed — session keeps its spawn account"
        }
        if let identity = ProfileLoginPresentation.normalizedIdentity(entry.loginIdentity) {
            return "\(identity) (\(entry.profile.name))"
        }
        return "\(entry.profile.name) (not logged in)"
    }

    /// Hover tooltip for a terminal tab. nil for non-Claude terminals (shells,
    /// Codex — no account concept). Multi-line: account, drift note (ambient
    /// only), current usage numbers (when the pinned account has a snapshot),
    /// spawn time. Sessions are pinned to their spawn account for life, so
    /// this reflects what the session is actually consuming.
    static func sessionTooltip(terminal: Terminal,
                               profiles: [ModelProfileWithUsage],
                               timeZone: TimeZone = .current) -> String? {
        guard terminal.kind == .claude || terminal.isClaudeResumable else { return nil }
        var lines = ["Account: \(accountDescriptor(profileID: terminal.profileID, profiles: profiles))"]
        if terminal.profileID == nil {
            lines.append("May drift to a different account on token refresh")
        } else if let entry = profiles.first(where: { $0.profile.id == terminal.profileID }),
                  let summary = usageSummary(for: entry.usageSnapshot, timeZone: timeZone) {
            lines.append("Usage: \(summary)")
        }
        lines.append("Spawned: \(spawnTimeText(terminal.createdAt, timeZone: timeZone))")
        return lines.joined(separator: "\n")
    }

    /// Sidebar worktree-row tooltip aggregating the accounts of its Claude
    /// sessions, deduped in tab order: "Claude accounts: a@b.co (Work),
    /// ambient (terminal login)". nil when the worktree has no Claude sessions.
    static func worktreeAccountsTooltip(terminals: [Terminal],
                                        profiles: [ModelProfileWithUsage]) -> String? {
        var seen = Set<String>()
        var descriptors: [String] = []
        for terminal in terminals where terminal.kind == .claude || terminal.isClaudeResumable {
            let descriptor = accountDescriptor(profileID: terminal.profileID, profiles: profiles)
            if seen.insert(descriptor).inserted {
                descriptors.append(descriptor)
            }
        }
        guard !descriptors.isEmpty else { return nil }
        return "Claude accounts: " + descriptors.joined(separator: ", ")
    }
}
