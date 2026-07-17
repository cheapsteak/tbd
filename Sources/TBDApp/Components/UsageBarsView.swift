import SwiftUI
import TBDShared

/// A compact usage meter for a Claude OAuth profile: the 5-hour session
/// window, the weekly all-models window, and per-model-family weekly windows,
/// each drawn as a thin bar with a pace-aware colored fill (green/yellow/
/// orange/red — projection of end-of-window usage from the current burn rate,
/// floored by the API severity so a warning/critical bucket never reads
/// healthy), a neutral "time marker" tick showing how far through the window
/// we are, and a trailing percent (and inline reset countdown on the weekly
/// all-models row).
///
/// Pure presentation over a `ProfileUsageSnapshot` (no picker/tab state), so it
/// is reusable anywhere a snapshot is in hand. `now`/`timeZone` are injectable
/// for previews and deterministic layout. A row is skipped entirely when its
/// bucket is absent; the whole view collapses to nothing when there is no usage
/// data at all.
struct UsageBarsView: View {
    let snapshot: ProfileUsageSnapshot?
    let now: Date
    let timeZone: TimeZone

    init(snapshot: ProfileUsageSnapshot?,
         now: Date = Date(),
         timeZone: TimeZone = .current) {
        self.snapshot = snapshot
        self.now = now
        self.timeZone = timeZone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let session = ProfileUsagePresentation.sessionBucket(snapshot) {
                UsageBarRow(bucket: session,
                            label: "5h:",
                            windowLabel: "5-hour window",
                            windowDuration: ProfileUsagePresentation.sessionWindow,
                            resetDisplay: .clock,
                            now: now,
                            timeZone: timeZone)
            }
            if let weekly = ProfileUsagePresentation.weeklyAllBucket(snapshot) {
                UsageBarRow(bucket: weekly,
                            label: "wk:",
                            windowLabel: "Weekly window",
                            windowDuration: ProfileUsagePresentation.weeklyWindow,
                            resetDisplay: .countdown,
                            now: now,
                            timeZone: timeZone)
            }
            ForEach(Array(ProfileUsagePresentation.scopedBuckets(snapshot).enumerated()), id: \.offset) { _, scoped in
                UsageBarRow(bucket: scoped,
                            label: ProfileUsagePresentation.familyAbbreviation(scoped.modelDisplayName) + ":",
                            windowLabel: ProfileUsagePresentation.familyName(scoped.modelDisplayName) + " weekly",
                            windowDuration: ProfileUsagePresentation.weeklyWindow,
                            resetDisplay: .tooltipOnly,
                            now: now,
                            timeZone: timeZone)
            }
        }
    }
}

// MARK: - One bar row

/// How a row expresses its window's reset, inline and in the tooltip.
private enum ResetDisplay {
    /// "· 23:10" inline; tooltip "resets 23:10" (absolute clock, for 5h window).
    case clock
    /// "· 2d 5h" inline; tooltip "resets in 2d 5h" (relative countdown, for wk window).
    case countdown
    /// nothing inline; tooltip "resets in 2d 5h" (relative countdown, for scoped/F: rows).
    case tooltipOnly
}

/// A single window's row: a fixed-width label, the flexible bar (fill + time
/// marker), a fixed-width trailing percent, and a fixed-width trailing hint
/// column. The four fixed columns keep bars vertically aligned across rows.
private struct UsageBarRow: View {
    let bucket: ClaudeUsageLimitBucket
    /// Leading label ("5h:" / "wk:" / "F:").
    let label: String
    /// Spelled-out window name for the `.help` tooltip ("5-hour window" / "Fable weekly").
    let windowLabel: String
    /// Window length feeding the time marker's elapsed fraction.
    let windowDuration: TimeInterval
    /// How this row displays its reset time (clock, countdown, or tooltip-only).
    let resetDisplay: ResetDisplay
    let now: Date
    let timeZone: TimeZone

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            bar
            Text(ProfileUsagePresentation.percentText(bucket.percent))
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(fillColor)
                .frame(width: 30, alignment: .trailing)
            trailingResetHint
        }
        .help(helpText)
    }

    // MARK: Trailing reset hint

    /// Fourth column: reset display inline (clock for 5h, countdown for wk) on rows
    /// where resetDisplay shows inline; empty but space-reserving on other rows
    /// to keep bars aligned. The 46pt width reserves space for both "· 23:10" and
    /// "· 2d 5h" at 9pt monospacedDigit.
    private var trailingResetHint: some View {
        let hintText: String = {
            guard let resetsAt = bucket.resetsAt else { return "" }
            switch resetDisplay {
            case .clock:
                return "· \(ProfileUsagePresentation.resetTimeText(resetsAt, timeZone: timeZone))"
            case .countdown:
                guard let compact = ProfileUsagePresentation.compactResetCountdown(resetsAt, now: now) else {
                    return ""
                }
                return "· \(compact)"
            case .tooltipOnly:
                return ""
            }
        }()

        return Text(hintText)
            .font(.system(size: 9, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(width: 46, alignment: .leading)
    }

    // MARK: Bar geometry

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track.
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.primary.opacity(0.08))
                // Usage fill.
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(fillColor)
                    .frame(width: geo.size.width * min(bucket.percent / 100, 1))
            }
            .frame(height: 5)
            // Time marker: a 9pt tick centered on the 5pt bar (overhangs 2pt
            // each side) at the current position within the window. Drawn only
            // when the window has a live elapsed fraction.
            .overlay(alignment: .leading) {
                if let fraction = elapsedFraction {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary)
                        .frame(width: 2.5, height: 9)
                        .offset(x: round(geo.size.width * fraction) - 0.75)
                }
            }
        }
        .frame(height: 5)
    }

    // MARK: Colors

    /// Pace-aware fill (shared by the bar and the trailing percent): green
    /// (adaptive) when on a sustainable pace, yellow (adaptive) when the
    /// projected end-of-window usage is warming (75–90%), orange when it will
    /// likely graze the limit (90–100%), red when on pace to exceed. The API
    /// severity (or the >=75/>=90 percent fallback) floors the tier, so a
    /// warning/critical bucket never renders healthier than before; without
    /// pace data (no reset date, <15% elapsed) this is exactly the old
    /// severity coloring.
    private var fillColor: Color {
        switch ProfileUsagePresentation.fillLevel(severity: bucket.severity,
                                                  percent: bucket.percent,
                                                  elapsedFraction: elapsedFraction) {
        case .normal: return Self.adaptiveGreen(colorScheme)
        case .caution: return Self.adaptiveYellow(colorScheme)
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var elapsedFraction: Double? {
        ProfileUsagePresentation.elapsedFraction(resetsAt: bucket.resetsAt,
                                                 windowDuration: windowDuration,
                                                 now: now)
    }

    /// Green that reads on both appearances: a brighter mint in dark mode, a
    /// deeper forest in light mode (the light default green washes out on a
    /// pale bar track).
    private static func adaptiveGreen(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 60 / 255, green: 199 / 255, blue: 95 / 255)
            : Color(red: 27 / 255, green: 107 / 255, blue: 52 / 255)
    }

    /// Yellow that reads on both appearances: a bright warm yellow in dark
    /// mode, a deeper amber in light mode (pure yellow washes out against the
    /// pale bar track).
    private static func adaptiveYellow(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 235 / 255, green: 194 / 255, blue: 52 / 255)
            : Color(red: 158 / 255, green: 110 / 255, blue: 6 / 255)
    }

    // MARK: Tooltip

    /// The spelled-out reset info the compact form omits, kept as a `.help`
    /// tooltip so nothing is lost: "5-hour window: 12% used · resets 23:10".
    private var helpText: String {
        var text = "\(windowLabel): \(ProfileUsagePresentation.percentText(bucket.percent)) used"
        if let resets = bucket.resetsAt {
            switch resetDisplay {
            case .clock:
                text += " · resets \(ProfileUsagePresentation.resetTimeText(resets, timeZone: timeZone))"
            case .countdown, .tooltipOnly:
                if let relative = ProfileUsagePresentation.compactResetCountdown(resets, now: now) {
                    text += " · resets in \(relative)"
                }
            }
        }
        return text
    }
}

// MARK: - Preview

#if XCODE_PREVIEWS
#Preview("Usage bars") {
    // Fixed clock so the previewed markers land deterministically.
    let now = Date(timeIntervalSince1970: 1_720_000_000)

    func bucket(_ kind: String, _ percent: Double, severity: String? = nil,
                resetsIn: TimeInterval? = nil) -> ClaudeUsageLimitBucket {
        ClaudeUsageLimitBucket(kind: kind, percent: percent, severity: severity,
                               resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }
    func scopedBucket(_ name: String, _ percent: Double, severity: String? = nil,
                      resetsIn: TimeInterval? = nil) -> ClaudeUsageLimitBucket {
        ClaudeUsageLimitBucket(kind: "weekly_scoped", percent: percent, severity: severity,
                               resetsAt: resetsIn.map { now.addingTimeInterval($0) },
                               modelDisplayName: name)
    }
    func snap(_ buckets: [ClaudeUsageLimitBucket]) -> ProfileUsageSnapshot {
        ProfileUsageSnapshot(buckets: buckets, fetchedAt: now,
                             lastAttemptAt: now, status: "ok", statusKind: .ok)
    }

    return VStack(alignment: .leading, spacing: 16) {
        // Healthy, low usage, early in both windows.
        UsageBarsView(snapshot: snap([
            bucket("session", 6, severity: "normal", resetsIn: 4 * 3600),
            bucket("weekly_all", 12, severity: "normal", resetsIn: 6 * 24 * 3600),
        ]), now: now)

        // Mid usage — the projection lands in the caution/warning bands even
        // while the marker sits just ahead of the fill. Session projects to
        // ~85% (yellow "warming"); weekly projects to ~95% (orange) despite
        // the API still saying "normal".
        UsageBarsView(snapshot: snap([
            bucket("session", 55, severity: "normal", resetsIn: 1.75 * 3600),
            bucket("weekly_all", 55, severity: "normal", resetsIn: 2.95 * 24 * 3600),
            scopedBucket("Fable", 15, severity: "normal", resetsIn: 2.95 * 24 * 3600),
        ]), now: now)

        // Near limit.
        UsageBarsView(snapshot: snap([
            bucket("session", 94, severity: "critical", resetsIn: 0.5 * 3600),
            bucket("weekly_all", 88, severity: "warning", resetsIn: 24 * 3600),
        ]), now: now)

        // No reset date → no time marker.
        UsageBarsView(snapshot: snap([
            bucket("session", 40, severity: "normal"),
            bucket("weekly_all", 30, severity: "normal"),
        ]), now: now)
    }
    .frame(width: 260)
    .padding()
}
#endif
