import Foundation
import SwiftUI
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Tabs")

/// Edge of a tab where a drop should insert the dragged tab.
enum DropEdge: Sendable, Equatable {
    case leading, trailing
}

extension AppState {

    // MARK: - Tab metadata loading

    /// Pull stored label overrides and tab order from the daemon for a worktree.
    /// Called the first time a worktree's tabs appear in memory.
    func loadTabStates(worktreeID: UUID) async {
        do {
            let response = try await daemonClient.listTabs(worktreeID: worktreeID)
            worktreeTabOrders[worktreeID] = response.order
            // Apply stored labels to any in-memory tabs that already exist.
            if var arr = tabs[worktreeID] {
                let labelByID = Dictionary(uniqueKeysWithValues: response.tabs.map { ($0.id, $0.label) })
                for i in arr.indices {
                    if let label = labelByID[arr[i].id] {
                        arr[i].label = label
                    }
                }
                tabs[worktreeID] = arr
                applyStoredOrder(worktreeID: worktreeID)
            }
            // Hydrate the persisted active tab. Must run AFTER applyStoredOrder
            // so the resolved index reflects the persisted order. If the stored
            // ID no longer exists (tab was deleted), gracefully fall through and
            // leave activeTabIndices unchanged (defaults to 0 at the view layer).
            if let activeID = response.activeTabID,
               let arr = tabs[worktreeID],
               let idx = arr.firstIndex(where: { $0.id == activeID }) {
                activeTabIndices[worktreeID] = idx
            }
        } catch {
            logger.error("loadTabStates failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
            handleConnectionError(error)
        }
    }

    // MARK: - Active tab persistence

    /// Update the in-memory active tab index for a worktree AND persist the
    /// underlying tab.id to the daemon. Use this anywhere the UI changes the
    /// active selection so the choice survives a restart.
    func setActiveTab(worktreeID: UUID, tabIndex: Int) {
        activeTabIndices[worktreeID] = tabIndex
        guard let arr = tabs[worktreeID], arr.indices.contains(tabIndex) else { return }
        // Activating a tab clears its unread-completion bold.
        unreadTerminals.subtract(terminalIDs(in: arr[tabIndex]))
        let tabID = arr[tabIndex].id
        Task {
            do {
                try await daemonClient.setActiveTab(worktreeID: worktreeID, tabID: tabID)
            } catch {
                logger.error("setActiveTab persist failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
                handleConnectionError(error)
            }
        }
    }

    /// Sort `tabs[worktreeID]` against `worktreeTabOrders[worktreeID]`. Unknown
    /// tab IDs (e.g. newly-created since last save) go to the end, preserving
    /// their current relative order.
    func applyStoredOrder(worktreeID: UUID) {
        guard let storedOrder = worktreeTabOrders[worktreeID], !storedOrder.isEmpty,
              var arr = tabs[worktreeID] else { return }
        let storedIndex = Dictionary(uniqueKeysWithValues: storedOrder.enumerated().map { ($1, $0) })
        // Capture which tab.id is currently active so we can re-point activeTabIndices.
        let activeID: UUID? = activeTabIndices[worktreeID].flatMap { idx in
            arr.indices.contains(idx) ? arr[idx].id : nil
        }
        // Stable sort: known first (by stored position), unknown after (in input order).
        // Use enumerated original index as a tiebreaker so unknown tabs keep their input order.
        let withIndex = arr.enumerated().map { (origIdx: $0.offset, tab: $0.element) }
        let sorted = withIndex.sorted { a, b in
            switch (storedIndex[a.tab.id], storedIndex[b.tab.id]) {
            case let (ai?, bi?): return ai < bi
            case (_?, nil):      return true
            case (nil, _?):      return false
            case (nil, nil):     return a.origIdx < b.origIdx
            }
        }
        arr = sorted.map(\.tab)
        tabs[worktreeID] = arr
        // Keep active index pointing at the same tab.id.
        if let activeID, let newIdx = arr.firstIndex(where: { $0.id == activeID }) {
            activeTabIndices[worktreeID] = newIdx
        }
    }

    // MARK: - Rename

    /// Rename a tab. Empty / whitespace-only string clears the override
    /// (tab reverts to auto-derived label). Same-as-displayed is a no-op.
    ///
    /// Synchronous so the in-memory label mutation and SwiftUI's exit-from-edit-mode
    /// re-render batch into a single frame — otherwise the tab briefly flashes the
    /// pre-rename label before the update lands. Persistence is fire-and-forget.
    func renameTab(tabID: UUID, worktreeID: UUID, newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        guard var arr = tabs[worktreeID],
              let idx = arr.firstIndex(where: { $0.id == tabID }) else { return }
        let newValue: String? = trimmed.isEmpty ? nil : trimmed
        // No-op if value is identical to what's stored.
        if arr[idx].label == newValue {
            return
        }
        arr[idx].label = newValue
        tabs[worktreeID] = arr
        Task {
            do {
                try await daemonClient.setTabLabel(tabID: tabID, worktreeID: worktreeID, label: newValue)
            } catch {
                logger.error("renameTab persist failed for \(tabID, privacy: .public): \(error, privacy: .public)")
                handleConnectionError(error)
            }
        }
    }

    // MARK: - Close

    /// Close one tab and clean up resources owned by that tab. This is shared
    /// by the tab bar close button and the Cmd-W menu shortcut.
    func closeTab(worktreeID: UUID, index: Int) {
        guard var arr = tabs[worktreeID],
              arr.indices.contains(index) else { return }

        let tab = arr[index]
        let layout = layouts[tab.id] ?? .pane(tab.content)
        let terminalIDsInTab = Set(layout.allTerminalIDs())

        if focusedTabCloseContext?.worktreeID == worktreeID,
           focusedTabCloseContext?.tabID == tab.id {
            focusedTabCloseContext = nil
        }

        // Drop any pending unread-completion bold for this tab's terminals so a
        // background tab that completed and was closed without being activated
        // doesn't leak stale UUIDs into `unreadTerminals`.
        unreadTerminals.subtract(terminalIDsInTab)

        layouts.removeValue(forKey: tab.id)
        arr.remove(at: index)
        tabs[worktreeID] = arr
        worktreeTabOrders[worktreeID] = arr.map(\.id)

        for terminalID in terminalIDsInTab {
            Task {
                await deleteTerminal(terminalID: terminalID, worktreeID: worktreeID)
            }
        }

        if case .note(let noteID) = tab.content {
            Task {
                await deleteNote(noteID: noteID, worktreeID: worktreeID)
            }
        }

        let remaining = arr.count
        activeTabIndices[worktreeID] = remaining > 0 ? min(index, remaining - 1) : 0

        let snapshot = arr.map(\.id)
        Task {
            do {
                try await daemonClient.setTabOrder(worktreeID: worktreeID, tabIDs: snapshot)
            } catch {
                logger.error("closeTab persist order failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
                handleConnectionError(error)
            }
        }
    }

    func closeTab(worktreeID: UUID, tabID: UUID) {
        guard let arr = tabs[worktreeID],
              let index = arr.firstIndex(where: { $0.id == tabID }) else {
            if focusedTabCloseContext?.worktreeID == worktreeID,
               focusedTabCloseContext?.tabID == tabID {
                focusedTabCloseContext = nil
            }
            return
        }
        closeTab(worktreeID: worktreeID, index: index)
    }

    var canCloseFocusedTab: Bool {
        guard let context = resolvedFocusedTabCloseContext(),
              let arr = tabs[context.worktreeID] else { return false }
        return arr.contains(where: { $0.id == context.tabID })
    }

    func closeFocusedTab() {
        guard let context = resolvedFocusedTabCloseContext() else { return }
        closeTab(worktreeID: context.worktreeID, tabID: context.tabID)
    }

    // MARK: - Reorder

    /// Move `draggedID` to land next to `targetID`. `edge == .leading` inserts
    /// before the target; `.trailing` inserts after. Dropping a tab on itself
    /// is a no-op. Active selection follows the moved tab.
    func reorderTab(draggedID: UUID, in worktreeID: UUID,
                    relativeTo targetID: UUID, edge: DropEdge) {
        guard draggedID != targetID,
              var arr = tabs[worktreeID],
              let from = arr.firstIndex(where: { $0.id == draggedID }) else { return }
        // Capture which tab.id is currently active so we can re-point activeTabIndices.
        let activeID: UUID? = activeTabIndices[worktreeID].flatMap { idx in
            arr.indices.contains(idx) ? arr[idx].id : nil
        }
        let item = arr.remove(at: from)
        // Look up target's index *after* removal (it may have shifted left by 1).
        guard let targetIdx = arr.firstIndex(where: { $0.id == targetID }) else {
            // Target gone (rare race). Restore and bail.
            arr.insert(item, at: from)
            return
        }
        let insertAt = (edge == .trailing) ? targetIdx + 1 : targetIdx
        arr.insert(item, at: insertAt)
        tabs[worktreeID] = arr
        worktreeTabOrders[worktreeID] = arr.map(\.id)
        if let activeID, let newIdx = arr.firstIndex(where: { $0.id == activeID }) {
            activeTabIndices[worktreeID] = newIdx
        }
        let snapshot = arr.map(\.id)
        Task {
            do {
                try await daemonClient.setTabOrder(worktreeID: worktreeID, tabIDs: snapshot)
            } catch {
                logger.error("reorderTab persist failed for \(worktreeID, privacy: .public): \(error, privacy: .public)")
                handleConnectionError(error)
            }
        }
    }
}
