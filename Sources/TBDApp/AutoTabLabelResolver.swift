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
        var orderedTerminalIDs: [UUID] = []
        for tab in worktreeTabs {
            if case .terminal(let terminalID) = tab.content { orderedTerminalIDs.append(terminalID) }
        }
        return TerminalTabLabel.automatic(
            terminal: terminal,
            fallbackIndex: fallbackIndex,
            profiles: modelProfiles.map(\.profile),
            orderedTerminalIDs: orderedTerminalIDs,
            worktreeTerminals: worktreeTerminals
        )
    }
}
