import AppKit
import TBDShared

/// Selection, both ways: the outline's to `AppState.selectedWorktreeIDs`
/// through `SidebarSelectionBridge`, and `AppState`'s back to the outline.
extension SidebarOutlineController {
    // MARK: Selection

    /// `AppState`'s selection as the outline's row IDs: its selected
    /// worktrees and its selected remote session's row.
    var modelSelectionIDs: Set<SidebarNodeID> {
        let remote = appState.selectedRemoteSession.map {
            RemoteSessionIdentity.uuid(provider: $0.provider, sessionID: $0.sessionID)
        }
        return SidebarSelectionBridge.outlineIDs(
            selectedWorktreeIDs: appState.selectedWorktreeIDs, selectedRemoteSession: remote)
    }

    /// Selects the rows `AppState` names: its selected worktrees and its
    /// selected remote session. A row the outline does not show is skipped.
    /// A row view draws the selection from the list's own (`isSelected`), so
    /// a selection alone reconfigures no row view.
    func applyModelSelection() {
        var rows = IndexSet()
        for id in modelSelectionIDs {
            guard let item = items.existing(id) else { continue }
            let row = outline.row(forItem: item)
            if row >= 0 { rows.insert(row) }
        }
        if rows != outline.selectedRowIndexes {
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    /// Centres a row selected outside the sidebar — by back and forward, a
    /// notification, a shortcut, the jump menu, or the selection restored at
    /// launch — even when it is in view already, and the selection the first
    /// apply finds. Runs after `applyModelSelection()`.
    ///
    /// Only a row the outline had not shown selected counts: of those, the
    /// first in display order is centred. So a selection that only shrank —
    /// a row of several archived, an adopted lane's remote session pruned by
    /// a refresh — never scrolls, and neither does a rebuild that left the
    /// selection alone: the user may have scrolled away since. Nor does a
    /// creation placeholder's swap for its real row, which can land long
    /// after the user scrolled elsewhere; a placeholder the user navigated
    /// away from, still in the model, is an ordinary change.
    ///
    /// The first apply has no shown selection to compare with, so every row
    /// it finds selected counts: the list opens on the selected row, and an
    /// empty selection scrolls nothing. At launch it usually finds nothing:
    /// the saved selection is restored once the daemon's data has loaded,
    /// and the apply after that centres it as a change,
    /// `connectAndLoadInitialState` having expanded its repo so the row can
    /// be seen. Nothing orders the two, though: the restore can land first,
    /// and a controller made later, for a main window closed and opened
    /// again, finds a selection already set. The user has no scroll position
    /// to lose either way. A first apply that runs before the outline has a
    /// height leaves the centre to the first layout that gives it one
    /// (`centerRow`).
    ///
    /// A new row the outline does not show — in a collapsed section, filtered
    /// out, only in the dock — is skipped, and nothing is expanded for it.
    /// While structure is held, a change waits for the apply that ends the
    /// hold, as the pending scroll target does. A placeholder's swap does not
    /// wait: the first apply that sees it takes it, hold or not. Left for the
    /// apply that ends the hold, it would swallow a row selected later in the
    /// same hold as well; taken at once, that row counts as a change and is
    /// centred when the hold ends. A row selected elsewhere just after the
    /// swap, before any apply has seen it, lands in the same apply as the
    /// swap and is taken with it, uncentred: that apply cannot tell the two
    /// apart.
    func centerSelectionIfChanged() {
        let selection = modelSelectionIDs
        guard let shown = lastShownSelection else {
            recordShownSelection(selection)
            centerFirstShownRow(of: selection)
            return
        }
        guard selection != shown else { return }
        if lastShownPlaceholdersLeftTheModel() {
            recordShownSelection(selection)
            return
        }
        guard !isHoldingStructure else { return }
        let added = selection.subtracting(shown)
        recordShownSelection(selection)
        guard !added.isEmpty else { return }
        centerFirstShownRow(of: added)
    }

    /// Centres the first row of `ids`, in display order, that the outline
    /// shows. Nothing scrolls when it shows none of them.
    private func centerFirstShownRow(of ids: Set<SidebarNodeID>) {
        let rows = ids.compactMap { id -> Int? in
            guard let item = items.existing(id) else { return nil }
            let row = outline.row(forItem: item)
            return row >= 0 ? row : nil
        }
        guard let first = rows.min() else { return }
        centerRow(first)
    }

    /// Takes `AppState`'s selection as shown where the user is looking, so
    /// the apply that mirrors it leaves the scroll alone. Called for every
    /// selection the user makes in the sidebar — a click, a ⌘- or ⇧-click or
    /// an arrow key in the outline, a click in the dock — since moving the
    /// list under the pointer would lose the row just clicked.
    func markSelectionShown() {
        recordShownSelection(modelSelectionIDs)
    }

    /// Records `selection` as shown, and whether its worktrees were all
    /// creation placeholders.
    private func recordShownSelection(_ selection: Set<SidebarNodeID>) {
        lastShownSelection = selection
        var worktreeIDs: Set<UUID> = []
        for id in selection {
            if case .worktree(let uuid) = id { worktreeIDs.insert(uuid) }
        }
        let allPlaceholders = !worktreeIDs.isEmpty && worktreeIDs.isSubset(of: appState.pendingWorktreeIDs)
        lastShownPlaceholderIDs = allPlaceholders ? worktreeIDs : []
    }

    /// Whether the last shown selection was creation placeholders that are
    /// all gone from the model: swapped for their real rows (local create,
    /// remote lane adoption) or dropped by a failed create.
    private func lastShownPlaceholdersLeftTheModel() -> Bool {
        guard !lastShownPlaceholderIDs.isEmpty else { return false }
        let live = Set(appState.allWorktrees.map(\.id))
        return lastShownPlaceholderIDs.isDisjoint(with: live)
    }

    /// Tells `AppState`, once, when a selected worktree left the model during
    /// the apply — the daemon dropped it without `AppState` pruning the
    /// selection. A row merely out of view (a collapsed section, a filter)
    /// stays selected. The pruned selection only shrinks, so it never
    /// scrolls, and it records nothing as shown: a centre waiting for a hold
    /// to end still runs.
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
        // Read back after the `didSet` has routed it.
        markSelectionShown()
        isApplyingModelSelection = true
        applyModelSelection()
        isApplyingModelSelection = false
    }
}
