import SwiftUI
import TBDShared

/// A compact usage meter for a Claude OAuth profile: the 5-hour session
/// window, the weekly all-models window, and per-model-family weekly windows,
/// each drawn as a thin bar with a pace-aware colored fill (green/yellow/
/// orange/red — projection of end-of-window usage from the current burn rate,
/// floored by the API severity so a warning/critical bucket never reads
/// healthy), a neutral "time marker" tick showing how far through the window
/// we are, and a trailing percent. Reset info renders as ONE compact line
/// below the bars ("resets 14:59 · wk 4d 7h") instead of a per-row trailing
/// column, so the bars get the full width.
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
                UsageBarRow(presentation: ProfileUsagePresentation.bucketPresentation(session, now: now, timeZone: timeZone),
                            label: "5h:",
                            windowLabel: "5-hour window",
                            now: now,
                            timeZone: timeZone)
            }
            if let weekly = ProfileUsagePresentation.weeklyAllBucket(snapshot) {
                UsageBarRow(presentation: ProfileUsagePresentation.bucketPresentation(weekly, now: now, timeZone: timeZone),
                            label: "wk:",
                            windowLabel: "Weekly window",
                            now: now,
                            timeZone: timeZone)
            }
            ForEach(Array(ProfileUsagePresentation.scopedBuckets(snapshot).enumerated()), id: \.offset) { _, scoped in
                UsageBarRow(presentation: ProfileUsagePresentation.bucketPresentation(scoped, now: now, timeZone: timeZone),
                            label: ProfileUsagePresentation.familyAbbreviation(scoped.modelDisplayName) + ":",
                            windowLabel: ProfileUsagePresentation.familyName(scoped.modelDisplayName) + " weekly",
                            now: now,
                            timeZone: timeZone)
            }
            if let resetLine {
                Text(resetLine)
                    .font(.system(size: 9, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// One compact line combining the session clock and weekly countdown,
    /// e.g. "resets 14:59 · wk 4d 7h". Segments without reset data are
    /// omitted; nil (no line) when neither window has any. Scoped ("F:")
    /// buckets stay tooltip-only, as before.
    private var resetLine: String? {
        var parts: [String] = []
        if let session = ProfileUsagePresentation.sessionBucket(snapshot),
           let inline = ProfileUsagePresentation.bucketPresentation(session, now: now, timeZone: timeZone).resetInline {
            parts.append("resets \(inline)")
        }
        if let weekly = ProfileUsagePresentation.weeklyAllBucket(snapshot),
           let inline = ProfileUsagePresentation.bucketPresentation(weekly, now: now, timeZone: timeZone).resetInline {
            parts.append("wk \(inline)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - One bar row

/// A single window's row: a fixed-width label, the flexible bar (fill + time
/// marker), and a fixed-width trailing percent. The fixed columns keep bars
/// vertically aligned across rows; reset info lives on the shared line below
/// the bars (and in each row's tooltip).
private struct UsageBarRow: View {
    let presentation: ProfileUsagePresentation.BucketPresentation
    /// Leading label ("5h:" / "wk:" / "F:").
    let label: String
    /// Spelled-out window name for the `.help` tooltip ("5-hour window" / "Fable weekly").
    let windowLabel: String
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
            Text(presentation.percentText)
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
                    .frame(width: geo.size.width * min(presentation.percent / 100, 1))
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
        presentation.fill.barColor(colorScheme)
    }

    private var elapsedFraction: Double? {
        presentation.elapsedFraction
    }

    // MARK: Tooltip

    /// The spelled-out reset info the compact form omits, kept as a `.help`
    /// tooltip so nothing is lost: "5-hour window: 12% used · resets 23:10".
    private var helpText: String {
        var text = "\(windowLabel): \(presentation.percentText) used"
        if let resetPhrase = presentation.resetPhrase {
            text += " · \(resetPhrase)"
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
