import AppKit
import TBDShared

/// Selection, both ways: the outline's to `AppState.selectedWorktreeIDs`
/// through `SidebarSelectionBridge`, and `AppState`'s back to the outline.
extension SidebarOutlineController {
    // MARK: Selection

    /// Selects the rows `AppState` names: its selected worktrees and its
    /// selected remote session. A row the outline does not show is skipped.
    func applyModelSelection() {
        let remote = appState.selectedRemoteSession.map {
            RemoteSessionIdentity.uuid(provider: $0.provider, sessionID: $0.sessionID)
        }
        let wanted = SidebarSelectionBridge.outlineIDs(
            selectedWorktreeIDs: appState.selectedWorktreeIDs, selectedRemoteSession: remote)
        var rows = IndexSet()
        for id in wanted {
            guard let item = items.existing(id) else { continue }
            let row = outline.row(forItem: item)
            if row >= 0 { rows.insert(row) }
        }
        if rows != outline.selectedRowIndexes {
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    /// Tells `AppState`, once, when a selected worktree left the model during
    /// the apply — the daemon dropped it without `AppState` pruning the
    /// selection. A row merely out of view (a collapsed section, a filter)
    /// stays selected, as it does in the `List`.
    func reconcileVanishedSelection() {
        let selected = appState.selectedWorktreeIDs
        let unshown = selected.filter { !tree.contains(.worktree($0)) }
        guard !unshown.isEmpty else { return }
        let known = Set(appState.allWorktrees.map(\.id))
        let vanished = unshown.filter { !known.contains($0) }
        guard !vanished.isEmpty else { return }
        writeSelection(selected.subtracting(vanished))
    }

    private func writeSelection(_ ids: Set<UUID>) {
        guard ids != appState.selectedWorktreeIDs else { return }
        appStateSelectionWriteCount += 1
        appState.selectedWorktreeIDs = ids
    }

    /// Headers run an action from a click instead of taking the selection.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? SidebarItem, item !== Self.orphan else { return false }
        return SidebarSelectionBridge.isSelectable(item.id)
    }

    /// A user's selection: written to `AppState.selectedWorktreeIDs` as the
    /// `List`'s tags would write it, then mirrored straight back, since the
    /// `didSet` may route it — a remote row's ID never rests in that set.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModelSelection else {
            suppressedSelectionNotificationCount += 1
            return
        }
        let selected = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarItem)?.id }
        writeSelection(SidebarSelectionBridge.appStateIDs(for: selected))
        isApplyingModelSelection = true
        applyModelSelection()
        isApplyingModelSelection = false
    }
}
