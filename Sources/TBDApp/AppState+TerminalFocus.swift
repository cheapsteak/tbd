import AppKit
import Foundation

@MainActor
final class TerminalFocusTarget {
    weak var view: TBDTerminalView?

    init(_ view: TBDTerminalView) {
        self.view = view
    }
}

extension AppState {
    func registerTerminalView(_ view: TBDTerminalView, for terminalID: UUID) {
        terminalFocusTargets[terminalID] = TerminalFocusTarget(view)
    }

    func registerTerminalCloseContext(_ context: TabCloseContext?, for terminalID: UUID) {
        if let context {
            terminalTabCloseContexts[terminalID] = context
        } else {
            terminalTabCloseContexts.removeValue(forKey: terminalID)
        }
    }

    func unregisterTerminalView(_ view: TBDTerminalView, for terminalID: UUID) {
        guard terminalFocusTargets[terminalID]?.view === view else { return }
        terminalFocusTargets.removeValue(forKey: terminalID)
        terminalTabCloseContexts.removeValue(forKey: terminalID)
    }

    func resolvedFocusedTabCloseContext() -> TabCloseContext? {
        if terminalFocusTargets.isEmpty {
            return focusedTabCloseContext
        }
        guard let terminalView = NSApp.keyWindow?.firstResponder as? TBDTerminalView else {
            return nil
        }
        guard let terminalID = terminalFocusTargets.first(where: { $0.value.view === terminalView })?.key else {
            return nil
        }
        return terminalTabCloseContexts[terminalID]
    }

    func terminalIDForAutofocus(worktreeID: UUID) -> UUID? {
        guard !historyActiveWorktrees.contains(worktreeID),
              let worktreeTabs = tabs[worktreeID],
              !worktreeTabs.isEmpty
        else {
            return nil
        }

        let rawIndex = activeTabIndices[worktreeID] ?? 0
        let activeIndex = min(max(rawIndex, 0), worktreeTabs.count - 1)
        let activeTab = worktreeTabs[activeIndex]
        let activeLayout = layouts[activeTab.id] ?? .pane(activeTab.content)

        return activeLayout.allTerminalIDs().first
    }

    func focusTerminalAfterSelectionChange(worktreeID: UUID) {
        guard let terminalID = terminalIDForAutofocus(worktreeID: worktreeID) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let terminalView = self.terminalFocusTargets[terminalID]?.view,
                  terminalView.window != nil
            else {
                return
            }

            terminalView.window?.makeFirstResponder(terminalView)
            self.focusedTabCloseContext = self.terminalTabCloseContexts[terminalID]
        }
    }
}
