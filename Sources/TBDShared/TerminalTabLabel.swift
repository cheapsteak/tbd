import Foundation

/// The automatic label of a terminal tab, as a pure function of the terminal,
/// the model profiles and the tab order, so the app's tab bar and any other
/// surface that lists a worktree's tabs name them the same way.
public enum TerminalTabLabel {
    /// A profile-bound Claude tab is named by its profile and its position
    /// among the tabs of that profile; other Claude tabs are "Claude", Codex
    /// tabs are `TerminalLabel.codex`, the setup tab is "Setup", and anything
    /// else is numbered from `fallbackIndex`.
    ///
    /// `orderedTerminalIDs` is the worktree's terminal tabs' terminal IDs in
    /// tab order.
    public static func automatic(
        terminal: Terminal?,
        fallbackIndex: Int,
        profiles: [ModelProfile],
        orderedTerminalIDs: [UUID],
        worktreeTerminals: [Terminal]
    ) -> String {
        if let terminal,
           terminal.isClaudeResumable,
           let profileID = terminal.profileID,
           let profile = profiles.first(where: { $0.id == profileID }) {
            let sameProfileTerminalIDs = Set(
                worktreeTerminals
                    .filter { $0.profileID == profileID }
                    .map(\.id)
            )
            let sameProfileTabs = orderedTerminalIDs.filter { sameProfileTerminalIDs.contains($0) }
            let position = (sameProfileTabs.firstIndex { $0 == terminal.id } ?? 0) + 1
            return "\(profile.tabDisplayName) \(position)"
        }

        if terminal?.isClaudeResumable == true {
            return "Claude"
        }

        if terminal?.isCodexTerminal == true {
            return TerminalLabel.codex
        }

        if terminal?.label == "setup" {
            return "Setup"
        }

        return "Terminal \(fallbackIndex + 1)"
    }
}
