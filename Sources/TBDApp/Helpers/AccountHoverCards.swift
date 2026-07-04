import Foundation
import TBDShared

/// Structured hover-card content for the two account/usage hover sites: the
/// sidebar worktree row (which accounts this worktree's Claude sessions run
/// on) and the Claude tab (account + live usage + spawn time).
///
/// Pure `HoverCardModel` composition on top of `ProfileUsagePresentation`'s
/// formatting fragments — unit-testable without any panel/AppKit machinery.
/// The flat-string `ProfileUsagePresentation.sessionTooltip` /
/// `worktreeAccountsTooltip` helpers remain as the plain-text form; these
/// structured cards supersede them in the UI.
enum AccountHoverCards {
    static let worktreeCardTitle = "Claude accounts"
    static let ambientAccountLabel = "ambient (terminal login)"
    static let ambientDriftCaption = "May drift to a different account on token refresh"
    static let removedProfileLabel = "Profile removed"
    static let removedProfileCaption = "Session keeps its spawn account"
    static let notLoggedInCaption = "Not logged in"

    // MARK: - Worktree row card

    /// Sidebar worktree-row card aggregating the accounts of its Claude
    /// sessions, deduped in tab order. nil when the worktree has no Claude
    /// sessions (no card).
    static func worktreeCard(terminals: [Terminal],
                             profiles: [ModelProfileWithUsage]) -> HoverCardModel? {
        var rows: [HoverCardRow] = []
        for terminal in terminals where terminal.kind == .claude || terminal.isClaudeResumable {
            let row = accountRow(profileID: terminal.profileID, profiles: profiles)
            if !rows.contains(row) {
                rows.append(row)
            }
        }
        guard !rows.isEmpty else { return nil }
        return HoverCardModel(title: worktreeCardTitle, rows: rows)
    }

    /// One account line: email with a profile-name chip for pinned +
    /// logged-in sessions; muted-italic "ambient (terminal login)" with the
    /// drift warning as a caption for NULL-profile legacy sessions.
    static func accountRow(profileID: UUID?,
                           profiles: [ModelProfileWithUsage]) -> HoverCardRow {
        guard let profileID else {
            return HoverCardRow(value: ambientAccountLabel,
                                valueStyle: .mutedItalic,
                                caption: ambientDriftCaption)
        }
        guard let entry = profiles.first(where: { $0.profile.id == profileID }) else {
            return HoverCardRow(value: removedProfileLabel,
                                valueStyle: .mutedItalic,
                                caption: removedProfileCaption)
        }
        if let identity = ProfileLoginPresentation.normalizedIdentity(entry.loginIdentity) {
            return HoverCardRow(value: identity, chip: entry.profile.name)
        }
        return HoverCardRow(value: entry.profile.name, caption: notLoggedInCaption)
    }

    // MARK: - Claude tab card

    /// Per-session tab card: title = account email (or the ambient/removed
    /// note), rows for profile, live usage windows, and spawn time. nil for
    /// non-Claude terminals (shells, Codex — no account concept).
    static func claudeTabCard(terminal: Terminal,
                              profiles: [ModelProfileWithUsage],
                              timeZone: TimeZone = .current) -> HoverCardModel? {
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
