import AppKit
import TBDShared

/// Selection, both ways: the outline's to `AppState.selectedWorktreeIDs`
/// through `SidebarSelectionBridge`, and `AppState`'s back to the outline.
extension SidebarOutlineController {
    // MARK: Selection

    /// Selects the rows `AppState` names: its selected worktrees and its
    /// selected remote session. A row the outline does not show is skipped.
    /// A row view draws the selection from the list's own (`isSelected`), so
    /// a selection alone reconfigures no row view.
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

    /// Centres the first selected row, in display order, when `AppState`
    /// holds a selection the outline has not shown: one made outside the
    /// sidebar, by back and forward, a notification, a shortcut or the jump
    /// menu. Centred even when the row is in view already. Runs after
    /// `applyModelSelection()`.
    ///
    /// The first apply only takes the selection, so the first load never
    /// scrolls, and a rebuild that leaves the selection alone never does
    /// either: the user may have scrolled away since. A selected row the
    /// outline does not show — in a collapsed section, filtered out, only in
    /// the dock — is skipped, and nothing is expanded for it. While structure
    /// is held the change waits for the apply that ends the hold, as the
    /// pending scroll target does.
    func centerSelectionIfChanged() {
        let selection = SidebarSelectionKey(appState)
        guard let shown = lastShownSelection else {
            lastShownSelection = selection
            return
        }
        guard selection != shown, !isHoldingStructure else { return }
        lastShownSelection = selection
        guard let row = outline.selectedRowIndexes.first else { return }
        centerRow(row)
    }

    /// Takes `AppState`'s selection as shown where the user is looking, so
    /// the apply that mirrors it leaves the scroll alone. Called for every
    /// selection the user makes in the sidebar — a click, a ⌘- or ⇧-click or
    /// an arrow key in the outline, a click in the dock — since moving the
    /// list under the pointer would lose the row just clicked; and for a
    /// vanished row pruned from a selection already shown.
    func markSelectionShown() {
        lastShownSelection = SidebarSelectionKey(appState)
    }

    /// Tells `AppState`, once, when a selected worktree left the model during
    /// the apply — the daemon dropped it without `AppState` pruning the
    /// selection. A row merely out of view (a collapsed section, a filter)
    /// stays selected.
    func reconcileVanishedSelection() {
        let selected = appState.selectedWorktreeIDs
        let unshown = selected.filter { !tree.contains(.worktree($0)) }
        guard !unshown.isEmpty else { return }
        let known = Set(appState.allWorktrees.map(\.id))
        let vanished = unshown.filter { !known.contains($0) }
        guard !vanished.isEmpty else { return }
        writeSelection(selected.subtracting(vanished))
    }

    /// Every write here is the sidebar's own — the user's selection, or a
    /// vanished row pruned from one already shown — so the selection it
    /// leaves, read back after the `didSet` has routed it, is taken as shown.
    private func writeSelection(_ ids: Set<UUID>) {
        defer { markSelectionShown() }
        guard ids != appState.selectedWorktreeIDs else { return }
        appStateSelectionWriteCount += 1
        appState.selectedWorktreeIDs = ids
    }

    /// Headers run an action from a click instead of taking the selection.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? SidebarItem, item !== Self.orphan else { return false }
        return SidebarSelectionBridge.isSelectable(item.id)
    }

    /// A user's selection: written to `AppState.selectedWorktreeIDs` through
    /// `SidebarSelectionBridge`, then mirrored straight back, since the
    /// `didSet` may route it — a remote row's ID never rests in that set. A
    /// ⌘- or ⇧-click extends the selection, so selected rows the outline does
    /// not show — inside a collapsed section, or only in the dock — stay
    /// selected; a plain click replaces it. The dock follows the same rule
    /// (`SidebarSelectionBridge.userSelection`).
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModelSelection else {
            suppressedSelectionNotificationCount += 1
            return
        }
        let selected = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? SidebarItem)?.id }
        let ids = SidebarSelectionBridge.userSelection(
            selected: selected, current: appState.selectedWorktreeIDs,
            extending: SidebarSelectionBridge.extendsSelection(selectionModifiers()),
            isShown: { id in
                guard let item = self.items.existing(id) else { return false }
                return self.outline.row(forItem: item) >= 0
            })
        writeSelection(ids)
        isApplyingModelSelection = true
        applyModelSelection()
        isApplyingModelSelection = false
    }
}
