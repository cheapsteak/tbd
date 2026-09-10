import Foundation
import TBDShared

/// Pure model for the terminal limit-hit banner (§7.1 of design).
///
/// Computes the copy and UI state for displaying a limit-hit condition:
/// the warning banner showing which profile the limit hit on, when it resets,
/// and optionally a suggested profile to swap to or confirmation that a swap
/// already happened.
struct LimitBannerModel {
    /// The profile name the limit hit on (for display).
    let limitedProfileName: String

    /// "resets <ResumeTimeFormatter or the app's existing time formatting>"
    let resetsText: String

    /// When `suggestedProfileID` is non-nil and present in the app's profiles,
    /// the name of the profile to switch to.
    let suggestedProfileName: String?

    /// When `suggestedProfileID` is non-nil and present, the usage summary
    /// to show on the "Switch to" button, e.g. "5h 12% · 2 live".
    let suggestedUsageSummary: String?

    /// The number of live sessions on the suggested profile, when present.
    /// Used to construct the button suffix " · 2 live".
    let suggestedLiveSessions: Int?

    /// True when the limit hit has already been rotated to another profile.
    /// In this case, show "— switched to <name>" instead of the action button.
    let isRotated: Bool

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
            let usagePart = ProfileUsagePresentation.usageSummary(for: suggestedProfile.usageSnapshot) ?? ""
            let liveCount = suggestedLiveCount ?? 0
            let livePart = liveCount > 0 ? " · \(liveCount) live" : ""
            suggestedUsageSummary = usagePart.isEmpty ? livePart.trimmingCharacters(in: CharacterSet(charactersIn: " ·")) : usagePart + livePart
            suggestedLiveSessions = suggestedLiveCount
        } else {
            suggestedUsageSummary = nil
            suggestedLiveSessions = nil
        }

        // Check if already rotated
        let isRotated = limitHit.rotatedToProfileID != nil

        return LimitBannerModel(
            limitedProfileName: limitedProfileName,
            resetsText: resetsText,
            suggestedProfileName: suggestedProfileName,
            suggestedUsageSummary: suggestedUsageSummary,
            suggestedLiveSessions: suggestedLiveSessions,
            isRotated: isRotated
        )
    }
}
