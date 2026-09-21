import Foundation
import TBDShared

/// Pure model for the terminal limit-hit banner (§7.1 of design).
///
/// Computes the copy and UI state for displaying a limit-hit condition:
/// the warning banner showing which profile the limit hit on, when it resets,
/// and optionally a suggested profile to switch to. Switching is always the
/// person's click; the daemon never switches a session on its own.
struct LimitBannerModel {
    /// The profile name the limit hit on (for display).
    let limitedProfileName: String

    /// "resets <ResumeTimeFormatter or the app's existing time formatting>"
    let resetsText: String

    /// When `suggestedProfileID` is non-nil and present in the app's profiles,
    /// the name of the profile to switch to.
    let suggestedProfileName: String?

    /// When `suggestedProfileID` is non-nil and present, the usage summary
    /// to show on the "Switch to" button, e.g. "5h 12% · 2 live". Nil when
    /// there is nothing to show, so the button carries no dangling separator.
    let suggestedUsageSummary: String?

    /// The number of live sessions on the suggested profile, when present.
    /// Used to construct the button suffix " · 2 live".
    let suggestedLiveSessions: Int?

    /// The switch button's title — "Switch to <name> — <summary>", or just
    /// "Switch to <name>" when there is no summary — or nil when there is no
    /// suggested profile to offer.
    var switchButtonTitle: String? {
        guard let name = suggestedProfileName else { return nil }
        guard let summary = suggestedUsageSummary else { return "Switch to \(name)" }
        return "Switch to \(name) — \(summary)"
    }

    /// Static helper to build the banner model from state.
    /// - `limitHit`: The `TerminalLimitHit` from `AppState.limitHits[terminalID]`.
    /// - `limitedProfile`: The profile the limit hit on, looked up from the app's list.
    /// - `suggestedProfile`: The profile to suggest, when `suggestedProfileID` is present.
    /// - `suggestedLiveCount`: Live sessions on the suggested profile, when present.
    /// - `now`: Current date for time formatting.
    static func build(
        limitHit: TerminalLimitHit,
        limitedProfile: ModelProfileWithUsage?,
        suggestedProfile: ModelProfileWithUsage?,
        suggestedLiveCount: Int?,
        now: Date = Date()
    ) -> LimitBannerModel {
        // Limited profile name: lookup or fallback to generic copy
        let limitedProfileName = limitedProfile?.profile.name ?? "this account"

        // Reset time: use the limit's resetsAt, formatted as clock time
        let resetsText = "resets \(ProfileUsagePresentation.resetTimeText(limitHit.resetsAt))"

        // Suggested profile name and usage
        let suggestedProfileName = suggestedProfile?.profile.name
        let suggestedUsageSummary: String?
        let suggestedLiveSessions: Int?

        if let suggestedProfile {
            // Build usage summary for the suggested profile
            var parts: [String] = []
            if let usage = ProfileUsagePresentation.usageSummary(for: suggestedProfile.usageSnapshot),
               !usage.isEmpty {
                parts.append(usage)
            }
            let liveCount = suggestedLiveCount ?? 0
            if liveCount > 0 { parts.append("\(liveCount) live") }
            suggestedUsageSummary = parts.isEmpty ? nil : parts.joined(separator: " · ")
            suggestedLiveSessions = suggestedLiveCount
        } else {
            suggestedUsageSummary = nil
            suggestedLiveSessions = nil
        }

        return LimitBannerModel(
            limitedProfileName: limitedProfileName,
            resetsText: resetsText,
            suggestedProfileName: suggestedProfileName,
            suggestedUsageSummary: suggestedUsageSummary,
            suggestedLiveSessions: suggestedLiveSessions
        )
    }
}
