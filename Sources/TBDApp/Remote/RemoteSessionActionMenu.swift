import Foundation
import TBDShared

/// Typed, ordered action model for a remote-session row's context menu — the
/// pure composition behind `RemoteSessionRowView.contextMenu`. Mirrors
/// `RowActionMenu`'s split: no AppKit/SwiftUI here, so `items(capabilities:gone:)`
/// is a pure function directly unit-testable without any `AppState`.
///
/// Per the provider contract (`docs/remote-provider-contract.md`), only
/// `describe`/`create`/`list`/`stop` are required — `log`, `send`, `attach`,
/// `rename`, `events` are all optional and declared via `capabilities`. This
/// composition omits (never disables) an item whose capability is absent,
/// matching how `RowActionMenu` drops repo-only items on scratch rows rather
/// than graying them out.
enum RemoteSessionActionMenu {
    /// Stable typed identity for each action, so the view can dispatch to the
    /// right side effect without stringly-typed matching on titles.
    enum Kind: Equatable {
        case rename
        case attach
        case viewLog
        case sendText
        case copySessionID
        case stop
        /// Destroy the session on the provider
        /// (`docs/remote-provider-contract.md` § `delete <id>`). Behind the
        /// default-off `remote_delete_enabled` flag.
        case delete
        case dismiss
        case pin
        case unpin
    }

    /// Whether an action reads as destructive. Mapped by the view to SwiftUI's
    /// `ButtonRole.destructive`; kept AppKit/SwiftUI-free so the helper is pure.
    enum ActionRole: Equatable {
        case normal
        case destructive
    }

    struct Action: Equatable {
        let kind: Kind
        let title: String
        let role: ActionRole
        /// Whether the item can be chosen. Everything in this menu except
        /// Delete is either offered or omitted; see `deleteItem` for why that
        /// one action departs.
        let isEnabled: Bool
        /// Tooltip shown while `isEnabled` is false, naming what is missing.
        let disabledHelp: String?

        init(kind: Kind, title: String, role: ActionRole = .normal,
             isEnabled: Bool = true, disabledHelp: String? = nil) {
            self.kind = kind
            self.title = title
            self.role = role
            self.isEnabled = isEnabled
            self.disabledHelp = disabledHelp
        }
    }

    enum Item: Equatable {
        case action(Action)
        case divider
    }

    // MARK: - Copy

    static let renameLabel = "Rename…"
    static let attachLabel = "Attach"
    static let viewLogLabel = "View Log"
    static let sendTextLabel = "Send Text…"
    static let copySessionIDLabel = "Copy Session ID"
    static let stopLabel = "Stop"
    static let deleteLabel = "Delete"
    /// Delete's title when the provider has not declared `delete`. Wording and
    /// treatment taken from `RowActionMenu.archiveProviderCannotArchiveLabel`,
    /// not re-invented, so the same absence reads the same on both surfaces.
    static let deleteProviderCannotDeleteLabel = "Delete (provider can't delete)"
    /// Disabled-help paired with `deleteProviderCannotDeleteLabel`: names the
    /// capability that would need to exist, not an action for the user to take.
    static let deleteNeedsProviderCapabilityHelp =
        "This provider hasn't implemented the delete capability yet"
    static let dismissLabel = "Dismiss"
    /// Pin wording is taken from `RowActionMenu`, not re-typed, so a remote
    /// row and a worktree row can never drift into two different names for
    /// the same dock.
    static let pinLabel = RowActionMenu.pinLabel
    static let unpinLabel = RowActionMenu.unpinLabel

    /// The `describe.capabilities` string this composition checks for each
    /// optional verb — kept as named constants (not re-typed at each call
    /// site) so a typo can't silently make a capability gate always false.
    private static let attachCapability = "attach"
    private static let logCapability = "log"
    private static let sendCapability = "send"
    private static let deleteCapability = "delete"

    // MARK: - Composition

    /// The ordered context-menu items for one remote-session row.
    ///
    /// `gone` rows (absent from the provider's last two `list` snapshots —
    /// see the contract's "Identity & drift" section) collapse to exactly
    /// Copy Session ID + the pin toggle + Dismiss: every other action assumes
    /// a session verb the provider can still run against a row it no longer
    /// reports, and renaming/stopping a row that's already a caller-side
    /// tombstone isn't meaningful.
    ///
    /// For a live row: Rename…, then Attach/View Log/Send Text… gated on
    /// their respective capabilities, then Copy Session ID (always
    /// available — the id is known locally, no provider call needed), then
    /// the pin toggle, then a divider, then Stop as the last, destructive
    /// item.
    ///
    /// The pin toggle is offered in BOTH branches, right beside Copy Session
    /// ID, because it shares Copy's defining property: it is a purely local
    /// action needing no provider verb and no declared capability. When the
    /// provider inventory is stale, inspection/local actions remain while
    /// provider mutations are omitted. A pinned
    /// session that goes `gone` must stay unpinnable without the user having
    /// to dismiss it, which is why the collapsed branch carries it too.
    ///
    /// Delete, when `deleteEnabled` (the `remote_delete_enabled` flag), is
    /// composed after Stop as the last and strongest destructive item — and
    /// unlike every other capability-gated item here it is present-but-disabled
    /// rather than omitted when the provider has not declared `delete`. See
    /// `deleteItem` for why that departure is deliberate. It is not offered in
    /// the `gone` branch: the provider has stopped enumerating that session, so
    /// there is nothing left there to destroy, and Dismiss is that row's
    /// removal gesture. It is also omitted while the snapshot is stale, with
    /// Stop and for the same reason — provider mutations wait for a trustworthy
    /// inventory.
    ///
    /// Dismiss is offered for an `exited` row as well as a `gone` one, and
    /// that is the whole of `exited`'s job here. The contract asks providers
    /// to keep exited sessions listable for at least 24 hours so a
    /// disappearance can be told apart from transport drift, and a provider
    /// may keep one indefinitely — so an exited row is not `gone`, and on a
    /// provider that never implements `delete` there would otherwise be no
    /// gesture at all that removes a session the agent has finished with.
    /// Dismiss stays exactly what it already is: a LOCAL tombstone on TBD's
    /// mirror row that changes nothing on the provider, which is why it is
    /// safe to offer on a row the provider still reports. It is composed
    /// immediately after the pin toggle and before the divider, so Stop
    /// remains the last, destructive item.
    static func items(
        capabilities: [String], gone: Bool, snapshotFresh: Bool = true,
        isPinned: Bool, exited: Bool = false, deleteEnabled: Bool = false
    ) -> [Item] {
        let pinAction = isPinned
            ? Action(kind: .unpin, title: unpinLabel)
            : Action(kind: .pin, title: pinLabel)

        if gone {
            return [
                .action(Action(kind: .copySessionID, title: copySessionIDLabel)),
                .action(pinAction),
                .action(Action(kind: .dismiss, title: dismissLabel)),
            ]
        }

        var actions: [Action] = []
        if snapshotFresh {
            actions.append(Action(kind: .rename, title: renameLabel))
        }
        if capabilities.contains(attachCapability) {
            actions.append(Action(kind: .attach, title: attachLabel))
        }
        if capabilities.contains(logCapability) {
            actions.append(Action(kind: .viewLog, title: viewLogLabel))
        }
        if snapshotFresh, capabilities.contains(sendCapability) {
            actions.append(Action(kind: .sendText, title: sendTextLabel))
        }
        actions.append(Action(kind: .copySessionID, title: copySessionIDLabel))
        actions.append(pinAction)
        if exited {
            actions.append(Action(kind: .dismiss, title: dismissLabel))
        }

        var items = actions.map(Item.action)
        if snapshotFresh {
            items.append(.divider)
            items.append(.action(Action(kind: .stop, title: stopLabel, role: .destructive)))
            if deleteEnabled {
                items.append(.action(deleteItem(capabilities: capabilities)))
            }
        }
        return items
    }

    /// Delete, composed last — after Stop, which it strictly outranks: Stop
    /// ends compute, Delete ends compute *and* removes the record.
    ///
    /// **This one action is present-but-disabled when its capability is
    /// absent, and that departure from this menu's omit-when-absent convention
    /// is deliberate.** Attach, View Log and Send Text vanish when undeclared,
    /// because a user who cannot attach has nothing to learn from a grey
    /// "Attach" — the session simply works differently there. Delete is not
    /// like that: a fleet with no reclaim path is the problem this whole design
    /// exists to fix, and a user looking for the way to remove a session needs
    /// to be told that the way exists and this provider has not built it yet.
    /// The disabled item is also the hook a later design uses to offer
    /// implementing the capability, which an omitted item could not be.
    /// `RowActionMenu.archiveProviderCannotArchiveLabel` already gives an
    /// unarchivable lane exactly this treatment; this follows it rather than
    /// inventing a second idiom. Please do not "fix" it into consistency.
    private static func deleteItem(capabilities: [String]) -> Action {
        let declared = capabilities.contains(deleteCapability)
        return Action(
            kind: .delete,
            title: declared ? deleteLabel : deleteProviderCannotDeleteLabel,
            role: .destructive,
            isEnabled: declared,
            disabledHelp: declared ? nil : deleteNeedsProviderCapabilityHelp)
    }
}
