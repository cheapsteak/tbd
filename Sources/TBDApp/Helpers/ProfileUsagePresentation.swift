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

    // MARK: - Pace-aware fill tier

    /// Fill tiers for the usage bars, ordered by urgency. A superset of
    /// `SeverityLevel` with one extra `caution` (yellow) tier between normal
    /// and warning that only pace projection can produce — "you're burning
    /// faster than the window, but not yet alarmingly so".
    enum FillLevel: Int, Comparable {
        case normal
        case caution
        case warning
        case critical

        static func < (lhs: FillLevel, rhs: FillLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Minimum elapsed fraction before pace projection kicks in — earlier than
    /// this the projection is too noisy to color by (a single request at
    /// minute one would scream red). Matches the reference tracker's gate.
    static let paceGateElapsedFraction = 0.15

    /// Pace-aware fill tier for a usage bar: project end-of-window usage from
    /// the current burn rate (`projected = (percent/100) / elapsedFraction`)
    /// and tier it —
    ///
    /// - projected < 0.75 → `.normal` (green: sustainable pace)
    /// - 0.75 ..< 0.90 → `.caution` (yellow: warming — on track to land close)
    /// - 0.90 ..< 1.00 → `.warning` (orange: will likely graze the limit)
    /// - >= 1.00 → `.critical` (red: on pace to exceed)
    ///
    /// The plain `severityLevel(severity:percent:)` result acts as a FLOOR:
    /// the final tier is `max(paceTier, floor)`, so an API "warning"/
    /// "critical" (or the >=75%/>=90% used fallback) never renders healthier
    /// than it does today. Projection only runs when an elapsed fraction is
    /// available, is within `[paceGateElapsedFraction, 1)`, and percent > 0;
    /// otherwise (no reset date, window barely started, window over) the
    /// result is exactly the floor — today's behavior.
    static func fillLevel(severity: String?,
                          percent: Double,
                          elapsedFraction: Double?) -> FillLevel {
        let floor: FillLevel
        switch severityLevel(severity: severity, percent: percent) {
        case .normal: floor = .normal
        case .warning: floor = .warning
        case .critical: floor = .critical
        }
        guard let elapsed = elapsedFraction,
              elapsed >= paceGateElapsedFraction, elapsed < 1.0,
              percent > 0 else { return floor }
        let projected = (percent / 100) / elapsed
        let pace: FillLevel
        switch projected {
        case ..<0.75: pace = .normal
        case 0.75..<0.90: pace = .caution
        case 0.90..<1.00: pace = .warning
        default: pace = .critical
        }
        return max(pace, floor)
    }

    // MARK: - Pace projection

    /// The 5-hour rolling session window, in seconds — the denominator for the
    /// 5h bar's time marker.
    static let sessionWindow: TimeInterval = 5 * 60 * 60
    /// The 7-day weekly window, in seconds — the denominator for the wk bar's
    /// time marker.
    static let weeklyWindow: TimeInterval = 7 * 24 * 60 * 60

    /// How far through a usage window we are right now, as a `0...1` fraction —
    /// the position of the "time marker" tick on a usage bar. Derived from the
    /// window's reset instant: `elapsed = duration - timeRemaining`.
    ///
    /// Returns nil (draw no marker) when there is no reset date, the duration
    /// is non-positive, or the reset is already at/behind `now` — the latter
    /// means the period is over and the daemon simply hasn't refreshed a new
    /// window yet, so there is no meaningful "now" position to draw. `now` is
    /// injectable for deterministic tests/previews.
    static func elapsedFraction(resetsAt: Date?,
                                windowDuration: TimeInterval,
                                now: Date = Date()) -> Double? {
        guard let resetsAt, windowDuration > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let elapsed = windowDuration - remaining
        return min(max(elapsed / windowDuration, 0), 1)
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

    /// Full family name for the roomier two-line menu secondary line, e.g.
    /// "Fable". Falls back to "?" when the daemon reported no display name.
    static func familyName(_ displayName: String?) -> String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "?" : trimmed
    }

    /// Full phrase for relative "how long until" a reset, including the leading
    /// "in " prefix: "in 2d 5h", "in 5h", "in 43m", "now". Returns nil if the
    /// date is nil; otherwise always returns a string (even "now" for immediate resets).
    /// Used for display contexts that want a complete phrase without additional
    /// wrapping text.
    ///
    /// Granularity rules: >= 1 day → "in Nd Nh" (hours dropped when zero: "in 2d");
    /// >= 1 hour but < 1 day → "in Nh"; < 1 hour → "in Nm"; already past / <1 min →
    /// "now". `now` is injectable for deterministic tests.
    static func relativeResetPhrase(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds >= 60 else { return "now" }
        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60
        if days >= 1 {
            return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d"
        }
        if hours >= 1 {
            return "in \(hours)h"
        }
        return "in \(minutes)m"
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

    // MARK: - Two-line menu composition

    /// A menu row rendered on two lines: an identity `primary` ("Name — email")
    /// and an optional `secondary` usage line drawn smaller and indented
    /// underneath. `secondary` is nil for profiles with no snapshot (never
    /// logged in / poller hasn't fetched yet), which keeps their single-line
    /// identity treatment. All surfaces (the "+" NSMenu, the switch-account
    /// SwiftUI submenu) compose from `menuLine` so the two-line rules live in
    /// one place; `menuItemTitle`/`usageSuffix` remain for anything still
    /// single-line.
    struct MenuLineModel: Equatable {
        let primary: String
        let secondary: String?
    }

    /// Spelled-out usage line for the roomier second row: "5h 16% used ·
    /// resets 23:09 · week 79% · resets in 2d 5h · Fable 100%". Unlike
    /// `usageSummary` this drops the ↺ glyph in favor of "resets " and uses
    /// full family names instead of the single-letter abbreviation — the
    /// second line has the width. nil when there is no snapshot or it has no
    /// buckets.
    static func usageDetailLine(for snapshot: ProfileUsageSnapshot?,
                                timeZone: TimeZone = .current,
                                now: Date = Date()) -> String? {
        guard let snapshot, !snapshot.buckets.isEmpty else { return nil }
        var parts: [String] = []
        // Percentages are UTILIZATION ("% used", matching claude.ai's
        // phrasing). The word rides the FIRST percentage only — it establishes
        // the reading for the whole line without per-segment repetition.
        var usedLabelPending = true
        func percentPart(_ prefix: String, _ percent: Double) -> String {
            let label = usedLabelPending ? " used" : ""
            usedLabelPending = false
            return "\(prefix) \(percentText(percent))\(label)"
        }
        if let session = sessionBucket(snapshot) {
            var part = percentPart("5h", session.percent)
            // Reset granularity matches window scale: the 5h window resets
            // today, so absolute clock time reads best.
            if let resets = session.resetsAt {
                part += " · resets \(resetTimeText(resets, timeZone: timeZone))"
            }
            parts.append(part)
        }
        if let weekly = weeklyAllBucket(snapshot) {
            var part = percentPart("week", weekly.percent)
            // The weekly window is a planning horizon — "how long until the
            // week ends" — so it shows a relative countdown. Weekly buckets
            // share one reset instant, so it appears once, here.
            if let resets = weekly.resetsAt,
               let relative = compactResetCountdown(resets, now: now) {
                part += " · resets in \(relative)"
            }
            parts.append(part)
        }
        for scoped in scopedBuckets(snapshot) {
            parts.append(percentPart(familyName(scoped.modelDisplayName), scoped.percent))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    /// Compact relative countdown for planning-scale resets without a leading
    /// prefix: "2d 5h", "3h", "48m". Returns nil when the instant is not in the
    /// future (a stale snapshot shouldn't render a nonsense countdown). Used as
    /// a building block for contexts that need just the duration, which they can
    /// wrap in their own "resets in" or similar text. Minutes appear only under an
    /// hour; hour-scale drops minutes; day-scale carries the hour remainder.
    static func compactResetCountdown(_ resetsAt: Date, now: Date = Date()) -> String? {
        let interval = resetsAt.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        let totalMinutes = Int((interval / 60).rounded(.up))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(max(totalMinutes % 60, 1))m"
    }

    /// Two-line menu-row model for a profile: identity on the primary line, and
    /// a secondary line that is the spelled-out usage when a fresh healthy
    /// snapshot exists, otherwise an EXPLICIT honest state — "needs re-login",
    /// "usage unavailable — retrying · last data 2h ago", "updated 6m ago" —
    /// so a logged-in profile whose fetch is failing never renders a silent
    /// blank second line. nil only when there is genuinely nothing to say (not
    /// logged in / no snapshot yet), which keeps the single-line identity
    /// treatment for those rows.
    static func menuLine(for entry: ModelProfileWithUsage,
                         timeZone: TimeZone = .current,
                         now: Date = Date()) -> MenuLineModel {
        MenuLineModel(
            primary: ProfileLoginPresentation.menuItemTitle(for: entry),
            secondary: secondaryLine(for: entry.usageSnapshot,
                                     timeZone: timeZone, now: now)
        )
    }

    /// The secondary menu line: fresh usage numbers when healthy, else the
    /// honest staleness/failure note (which already appends the last-known age
    /// when older data exists). Detail line wins when present AND healthy so a
    /// rate-limited profile with old numbers still shows the retry note rather
    /// than silently presenting stale figures as current.
    static func secondaryLine(for snapshot: ProfileUsageSnapshot?,
                              timeZone: TimeZone = .current,
                              now: Date = Date()) -> String? {
        // Healthy + fresh: numbers.
        if let snapshot, snapshot.isOK,
           let detail = usageDetailLine(for: snapshot, timeZone: timeZone, now: now) {
            // A fresh healthy snapshot may still be aging; append the age note
            // when it crosses the stale threshold so "5h 12% used …" doesn't
            // masquerade as up-to-the-second.
            if let note = stalenessNote(for: snapshot, now: now) {
                return "\(detail) · \(note)"
            }
            return detail
        }
        // Otherwise the honest note carries the row (nil for no-snapshot rows).
        return stalenessNote(for: snapshot, now: now)
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

    /// Compact "how long ago" for a fetch timestamp: "just now", "3m", "2h",
    /// "1d". Used to age both fresh-but-old and stale-with-old-data rows.
    static func ageText(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// Staleness / health note for a picker or menu row. Every logged-in
    /// profile that lacks a fresh, healthy snapshot gets an EXPLICIT note —
    /// never a silent blank — so the three failure modes read differently:
    ///
    /// - fresh & healthy → nil (no note; the usage line speaks for itself)
    /// - fresh but aging (>= staleAge) → "updated 6m ago"
    /// - `needsLogin` → "needs re-login" (actionable: the user must `/login`)
    /// - `noCredentials` → "not logged in"
    /// - `rateLimited` → "usage unavailable — retrying" (+ "· last data 2h ago"
    ///   when we still have older numbers to show alongside)
    /// - network/decode/unknown failure → "usage unavailable — retrying"
    ///   (again suffixed with the last-known age when present)
    ///
    /// The daemon's verbose `status` string is no longer surfaced verbatim
    /// (it leaked ISO timestamps into the UI); the typed `statusKind` drives
    /// the copy instead.
    static func stalenessNote(for snapshot: ProfileUsageSnapshot?,
                              now: Date = Date()) -> String? {
        guard let snapshot else { return nil }

        if snapshot.isOK {
            guard let fetchedAt = snapshot.fetchedAt else { return "no usage data yet" }
            let age = now.timeIntervalSince(fetchedAt)
            guard age >= staleAge else { return nil }
            return "updated \(ageText(since: fetchedAt, now: now)) ago"
        }

        // Failing snapshot: classify by the typed kind.
        switch snapshot.statusKind {
        case .ok:
            // status text says failure but kind says ok — shouldn't happen;
            // fall through to a generic note.
            return retryingNote(for: snapshot, now: now)
        case .needsLogin:
            return "needs re-login"
        case .noCredentials:
            return "not logged in"
        case .rateLimited, .networkError, .decodeError, .unknown:
            return retryingNote(for: snapshot, now: now)
        }
    }

    /// "usage unavailable — retrying", plus "· last data Nago" when the profile
    /// has older buckets to show alongside the note.
    private static func retryingNote(for snapshot: ProfileUsageSnapshot,
                                     now: Date) -> String {
        let base = "usage unavailable — retrying"
        if let fetchedAt = snapshot.fetchedAt, !snapshot.buckets.isEmpty {
            return "\(base) · last data \(ageText(since: fetchedAt, now: now)) ago"
        }
        return base
    }

    // MARK: - Per-session tooltips
    //
    // NOTE: `sessionTooltip` / `worktreeAccountsTooltip` are the flat-string
    // form. The UI now renders these two sites as structured `HoverCardModel`s
    // (see `AccountHoverCards`); the string form is kept as the plain-text
    // fallback/composition reference.

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
