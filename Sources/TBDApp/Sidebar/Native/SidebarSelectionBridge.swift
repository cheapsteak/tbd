import AppKit

/// Maps the native outline's selection to `AppState` and back.
///
/// Outline to `AppState`: the same IDs the SwiftUI `List`'s row tags write into
/// `selectedWorktreeIDs` — worktree IDs and remote session IDs, never a header.
/// That property's `didSet` stays the one place selection is routed: it strips
/// a remote ID back out, sends a pure-remote selection to
/// `selectRemoteSession`, and keeps a mixed selection's local rows.
///
/// A user's selection in either list — the outline or the pinned dock — goes
/// through `userSelection`, so both follow one rule: a plain click replaces
/// the selection, and a ⌘- or ⇧-click extends it, keeping selected rows the
/// list does not show (a collapsed section's, a row only the other list has).
///
/// `AppState` to outline: the selected worktrees, plus the selected remote
/// session's row. A remote selection never rests in `selectedWorktreeIDs`, so
/// the outline reads it from `selectedRemoteSession`; that is what keeps a
/// remote row selected in the outline, so arrow keys move on from it.
enum SidebarSelectionBridge {
    /// The IDs to write to `AppState.selectedWorktreeIDs` for the outline's
    /// selected rows.
    static func appStateIDs(for selected: [SidebarNodeID]) -> Set<UUID> {
        var ids: Set<UUID> = []
        for id in selected {
            switch id {
            case .worktree(let uuid), .remoteSession(let uuid):
                ids.insert(uuid)
            case .scratchHeader, .scratchPrompt, .repoHeader, .providerHeader, .group:
                break
            }
        }
        return ids
    }

    /// What a user's selection in one list writes to
    /// `AppState.selectedWorktreeIDs`: the list's selected rows, plus, when
    /// the gesture extends the selection, every selected worktree in
    /// `current` the list does not show. A row the list shows and the user
    /// deselected leaves; one it cannot show could not have been deselected
    /// there, so it stays.
    /// - Parameters:
    ///   - selected: the list's selected rows.
    ///   - current: `AppState.selectedWorktreeIDs` before the change.
    ///   - extending: whether the change came from a ⌘- or ⇧-click
    ///     (`extendsSelection(_:)`).
    ///   - isShown: whether the list shows a row for an ID.
    static func userSelection(selected: [SidebarNodeID], current: Set<UUID>, extending: Bool,
                              isShown: (SidebarNodeID) -> Bool) -> Set<UUID> {
        var ids = appStateIDs(for: selected)
        guard extending else { return ids }
        for id in current where !isShown(.worktree(id)) {
            ids.insert(id)
        }
        return ids
    }

    /// Whether a selection change made with `modifiers` held extends the
    /// selection rather than replacing it.
    static func extendsSelection(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.isDisjoint(with: [.command, .shift])
    }

    /// The rows the outline selects for `AppState`'s selection.
    /// - Parameter selectedRemoteSession: the selected session's row ID,
    ///   `RemoteSessionIdentity.uuid` of `AppState.selectedRemoteSession`.
    static func outlineIDs(selectedWorktreeIDs: Set<UUID>, selectedRemoteSession: UUID?) -> Set<SidebarNodeID> {
        var ids = Set(selectedWorktreeIDs.map { SidebarNodeID.worktree($0) })
        if let selectedRemoteSession {
            ids.insert(.remoteSession(selectedRemoteSession))
        }
        return ids
    }

    /// Worktree, scratch and remote session rows are selectable; headers, the
    /// scratch prompt and group disclosures run an action instead.
    static func isSelectable(_ id: SidebarNodeID) -> Bool {
        switch id {
        case .worktree, .remoteSession: true
        case .scratchHeader, .scratchPrompt, .repoHeader, .providerHeader, .group: false
        }
    }
}
