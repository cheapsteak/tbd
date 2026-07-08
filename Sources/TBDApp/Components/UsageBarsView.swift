import SwiftUI
import TBDShared

/// A compact two-row usage meter for a Claude OAuth profile: the 5-hour session
/// window and the weekly all-models window, each drawn as a thin bar with a
/// severity-colored fill, a neutral "time marker" tick showing how far
/// through the window we are, and a trailing percent.
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
                            usesRelativeReset: false,
                            now: now,
                            timeZone: timeZone)
            }
            if let weekly = ProfileUsagePresentation.weeklyAllBucket(snapshot) {
                UsageBarRow(bucket: weekly,
                            label: "wk:",
                            windowLabel: "Weekly window",
                            windowDuration: ProfileUsagePresentation.weeklyWindow,
                            usesRelativeReset: true,
                            now: now,
                            timeZone: timeZone)
            }
        }
    }
}

// MARK: - One bar row

/// A single window's row: a fixed-width label, the flexible bar (fill + time
/// marker), and a fixed-width trailing percent — the three fixed columns keep
/// bars vertically aligned across rows.
private struct UsageBarRow: View {
    let bucket: ClaudeUsageLimitBucket
    /// Leading label ("5h:" / "wk:").
    let label: String
    /// Spelled-out window name for the `.help` tooltip ("5-hour window").
    let windowLabel: String
    /// Window length feeding the time marker's elapsed fraction.
    let windowDuration: TimeInterval
    /// The 5h window shows an absolute reset clock; the weekly window shows a
    /// relative countdown ("resets in 2d 5h").
    let usesRelativeReset: Bool
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
        }
        .help(helpText)
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

    /// Usage-severity fill: green (adaptive) when healthy, orange at warning,
    /// red at critical.
    private var fillColor: Color {
        switch ProfileUsagePresentation.severityLevel(severity: bucket.severity,
                                                      percent: bucket.percent) {
        case .normal: return Self.adaptiveGreen(colorScheme)
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

    // MARK: Tooltip

    /// The spelled-out reset info the compact form omits, kept as a `.help`
    /// tooltip so nothing is lost: "5-hour window: 12% used · resets 23:10".
    private var helpText: String {
        var text = "\(windowLabel): \(ProfileUsagePresentation.percentText(bucket.percent)) used"
        if let resets = bucket.resetsAt {
            if usesRelativeReset {
                if let relative = ProfileUsagePresentation.relativeResetText(resets, now: now) {
                    text += " · resets in \(relative)"
                }
            } else {
                text += " · resets \(ProfileUsagePresentation.resetTimeText(resets, timeZone: timeZone))"
            }
        }
        return text
    }
}

// MARK: - Preview

#Preview("Usage bars") {
    // Fixed clock so the previewed markers land deterministically.
    let now = Date(timeIntervalSince1970: 1_720_000_000)

    func bucket(_ kind: String, _ percent: Double, severity: String? = nil,
                resetsIn: TimeInterval? = nil) -> ClaudeUsageLimitBucket {
        ClaudeUsageLimitBucket(kind: kind, percent: percent, severity: severity,
                               resetsAt: resetsIn.map { now.addingTimeInterval($0) })
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

        // Mid usage, over pace — the marker sits behind the fill (burning fast).
        UsageBarsView(snapshot: snap([
            bucket("session", 70, severity: "normal", resetsIn: 3.5 * 3600),
            bucket("weekly_all", 55, severity: "warning", resetsIn: 5 * 24 * 3600),
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
    .frame(width: 220)
    .padding()
}
