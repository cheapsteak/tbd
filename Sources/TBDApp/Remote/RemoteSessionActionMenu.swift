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

        init(kind: Kind, title: String, role: ActionRole = .normal) {
            self.kind = kind
            self.title = title
            self.role = role
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
    static func items(
        capabilities: [String], gone: Bool, snapshotFresh: Bool = true, isPinned: Bool
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

        var items = actions.map(Item.action)
        if snapshotFresh {
            items.append(.divider)
            items.append(.action(Action(kind: .stop, title: stopLabel, role: .destructive)))
        }
        return items
    }
}
