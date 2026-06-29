import Foundation
import TBDShared

enum AutoTabLabelResolver {
    static func terminalLabel(
        terminal: Terminal?,
        fallbackIndex: Int,
        modelProfiles: [ModelProfileWithUsage],
        worktreeTabs: [Tab],
        worktreeTerminals: [Terminal]
    ) -> String {
        if let terminal,
           terminal.isClaudeResumable,
           let profileID = terminal.profileID,
           let entry = modelProfiles.first(where: { $0.profile.id == profileID }) {
            let sameProfileTerminalIDs = Set(
                worktreeTerminals
                    .filter { $0.profileID == profileID }
                    .map(\.id)
            )
            let sameProfileTabs = worktreeTabs.filter { tab in
                guard case .terminal(let terminalID) = tab.content else { return false }
                return sameProfileTerminalIDs.contains(terminalID)
            }
            let position = (sameProfileTabs.firstIndex { tab in
                guard case .terminal(let terminalID) = tab.content else { return false }
                return terminalID == terminal.id
            } ?? 0) + 1
            return "\(entry.profile.tabDisplayName) \(position)"
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
