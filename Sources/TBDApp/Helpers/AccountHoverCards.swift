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
                              timeZone: TimeZone = .current,
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
                                                        timeZone: timeZone))
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
    /// per-family scoped buckets. Numbers are monospaced digits; tinted only
    /// when the bucket is warning/critical — calm otherwise. Empty when the
    /// profile has no usage data.
    static func usageRows(for snapshot: ProfileUsageSnapshot?,
                          timeZone: TimeZone = .current) -> [HoverCardRow] {
        guard let snapshot, !snapshot.buckets.isEmpty else { return [] }
        var rows: [HoverCardRow] = []
        if let session = ProfileUsagePresentation.sessionBucket(snapshot) {
            var value = ProfileUsagePresentation.percentText(session.percent)
            if let resets = session.resetsAt {
                value += " · resets \(ProfileUsagePresentation.resetTimeText(resets, timeZone: timeZone))"
            }
            rows.append(HoverCardRow(label: "5h window", value: value,
                                     monospacedDigits: true, tint: tint(for: session)))
        }
        if let weekly = ProfileUsagePresentation.weeklyAllBucket(snapshot) {
            rows.append(HoverCardRow(label: "Week",
                                     value: ProfileUsagePresentation.percentText(weekly.percent),
                                     monospacedDigits: true, tint: tint(for: weekly)))
        }
        for scoped in ProfileUsagePresentation.scopedBuckets(snapshot) {
            rows.append(HoverCardRow(label: scoped.modelDisplayName ?? "Model",
                                     value: ProfileUsagePresentation.percentText(scoped.percent),
                                     monospacedDigits: true, tint: tint(for: scoped)))
        }
        return rows
    }

    /// Map a bucket's severity to the card tint. `.normal` renders in the
    /// calm primary color — color appears only for warning/critical.
    static func tint(for bucket: ClaudeUsageLimitBucket) -> HoverCardTint {
        switch ProfileUsagePresentation.severityLevel(severity: bucket.severity,
                                                      percent: bucket.percent) {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        }
    }
}
