import Foundation
import TBDShared

/// Structured hover-card content for the Claude tab hover site: account + live
/// usage + spawn time. Pure `HoverCardModel` composition on top of
/// `ProfileUsagePresentation`'s formatting fragments — unit-testable without
/// any panel/AppKit machinery. The flat-string
/// `ProfileUsagePresentation.sessionTooltip` helper remains as the plain-text
/// form; this structured card supersedes it in the UI.
///
/// NOTE: The sidebar worktree ROW carries no account hover card — per-session
/// account facts and switching live in the tab bar (this card + the tab's
/// account menu).
enum AccountHoverCards {
    static let ambientAccountLabel = "ambient (terminal login)"
    static let ambientDriftCaption = "May drift to a different account on token refresh"
    static let removedProfileLabel = "Profile removed"
    static let removedProfileCaption = "Session keeps its spawn account"
    static let notLoggedInCaption = "Not logged in"

    // MARK: - Claude tab card

    /// Per-session tab card: title = account email (or the ambient/removed
    /// note), rows for profile, live usage windows, and spawn time. nil for
    /// non-Claude terminals (shells, Codex — no account concept), and nil when
    /// `enabled` is false (the "Show usage tooltip on Claude tabs" setting,
    /// `AppState.showClaudeTabUsageTooltipKey`) — the setting gate lives here
    /// so both branches are unit-testable without UserDefaults.
    ///
    /// For future iterations: https://github.com/hamed-elfayome/Claude-Usage-Tracker
    /// is a feature-rich, easy-to-skim take on session-usage display.
    static func claudeTabCard(terminal: Terminal,
                              profiles: [ModelProfileWithUsage],
                              resetStyle: ProfileUsagePresentation.ResetTimeStyle = .timeOfReset,
                              timeZone: TimeZone = .current,
                              now: Date = Date(),
                              enabled: Bool = true) -> HoverCardModel? {
        guard enabled else { return nil }
        guard terminal.kind == .claude || terminal.isClaudeResumable else { return nil }
        var model = HoverCardModel()
        if let profileID = terminal.profileID {
            if let entry = profiles.first(where: { $0.profile.id == profileID }) {
                if let identity = ProfileLoginPresentation.normalizedIdentity(entry.loginIdentity) {
                    model.title = identity
                    model.rows.append(HoverCardRow(label: "Profile", value: entry.profile.name))
                } else {
                    model.title = entry.profile.name
                    model.titleCaption = notLoggedInCaption
                }
                model.rows.append(contentsOf: usageRows(for: entry.usageSnapshot,
                                                        resetStyle: resetStyle,
                                                        timeZone: timeZone, now: now))
            } else {
                model.title = removedProfileLabel
                model.titleStyle = .mutedItalic
                model.titleCaption = removedProfileCaption
            }
        } else {
            model.title = ambientAccountLabel
            model.titleStyle = .mutedItalic
            model.titleCaption = ambientDriftCaption
        }
        model.rows.append(HoverCardRow(
            label: "Spawned",
            value: ProfileUsagePresentation.spawnTimeText(terminal.createdAt, timeZone: timeZone),
            monospacedDigits: true
        ))
        return model
    }

    /// Usage rows for a snapshot: 5h window (with reset time), weekly, and
    /// per-family scoped buckets. Numbers are monospaced digits; tinted per
    /// pace-aware fill level. Empty when the profile has no usage data.
    /// The weekly row now shows its reset countdown when available (closing
    /// a gap where it silently omitted the weekly reset).
    static func usageRows(for snapshot: ProfileUsageSnapshot?,
                          resetStyle: ProfileUsagePresentation.ResetTimeStyle = .timeOfReset,
                          timeZone: TimeZone = .current,
                          now: Date = Date()) -> [HoverCardRow] {
        guard let snapshot, !snapshot.buckets.isEmpty else { return [] }
        var rows: [HoverCardRow] = []
        if let session = ProfileUsagePresentation.sessionBucket(snapshot) {
            let presentation = ProfileUsagePresentation.bucketPresentation(session, style: resetStyle, now: now, timeZone: timeZone)
            var value = presentation.percentText
            if let resetPhrase = presentation.resetPhrase {
                value += " · \(resetPhrase)"
            }
            rows.append(HoverCardRow(label: "5h window", value: value,
                                     monospacedDigits: true, tint: tint(for: presentation)))
        }
        if let weekly = ProfileUsagePresentation.weeklyAllBucket(snapshot) {
            let presentation = ProfileUsagePresentation.bucketPresentation(weekly, style: resetStyle, now: now, timeZone: timeZone)
            var value = presentation.percentText
            if let resetPhrase = presentation.resetPhrase {
                value += " · \(resetPhrase)"
            }
            rows.append(HoverCardRow(label: "Week",
                                     value: value,
                                     monospacedDigits: true, tint: tint(for: presentation)))
        }
        for scoped in ProfileUsagePresentation.scopedBuckets(snapshot) {
            let presentation = ProfileUsagePresentation.bucketPresentation(scoped, now: now, timeZone: timeZone)
            rows.append(HoverCardRow(label: scoped.modelDisplayName ?? "Model",
                                     value: presentation.percentText,
                                     monospacedDigits: true, tint: tint(for: presentation)))
        }
        return rows
    }

    /// Map a bucket presentation's pace-aware fill to the card tint.
    /// The four-tier hierarchy (normal/caution/warning/critical) aligns with
    /// `FillLevel`, so pace-aware coloring is consistent across all surfaces.
    static func tint(for presentation: ProfileUsagePresentation.BucketPresentation) -> HoverCardTint {
        ProfileUsagePresentation.hoverCardTint(for: presentation.fill)
    }
}
