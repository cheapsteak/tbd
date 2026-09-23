import Foundation
import TBDShared

/// What `RemoteSessionDetailView` fills its pane with. There is no picker:
/// the attach terminal is the pane, exactly as a local session's terminal
/// is. The log view exists only so a session that cannot be attached to
/// still shows something rather than a blank pane.
enum RemoteSessionDetailContent: Equatable {
    /// The live attach terminal (or, while detached, the Reattach / auth
    /// prompt that stands in for it).
    case attach
    /// Read-only scrollback — only when attach is unavailable.
    case log
    /// The provider offers neither.
    case unsupported
}

/// Pure capability gates behind `RemoteSessionDetailView` and the window
/// toolbar's remote-session buttons. Mirrors `RemoteSessionActionMenu`'s
/// split: no SwiftUI here, so every gate is directly unit-testable without a
/// view hierarchy or `AppState`.
///
/// The view derives what to render from `content` on every `body`
/// evaluation rather than from separately-tracked `@State`, so no timing of
/// `onAppear`/`onChange` can leave a provider with a usable capability
/// looking at a blank pane.
enum RemoteSessionDetailGates {
    /// The `describe.capabilities` string each gate checks — named constants
    /// (not re-typed at each call site) so a typo can't silently make a gate
    /// always false.
    private static let attachCapability = "attach"
    private static let logCapability = "log"
    private static let sendCapability = "send"

    /// Whether a live attach terminal can be offered for the session.
    ///
    /// `gone` blocks attach even when the provider declares the capability —
    /// consistent with `RemoteSessionActionMenu.items(gone:)`, which
    /// collapses a tombstone row's context menu to Copy Session ID + Dismiss:
    /// starting a new interactive attach against a session the provider no
    /// longer reports isn't meaningful. `exited` blocks it for the same
    /// reason: the provider reports the session's process as finished, so a
    /// fresh `attach` has nothing to connect to and a Reattach button could
    /// only fail. A session that exits while attached therefore drops out of
    /// attach eligibility and its pane falls back to the log; nothing tries
    /// to re-attach it.
    static func canAttach(capabilities: [String], gone: Bool, exited: Bool) -> Bool {
        !gone && !exited && capabilities.contains(attachCapability)
    }

    /// What fills the detail pane. Attach whenever it is possible; otherwise
    /// the log, which stays readable for a `gone` or exited session — its
    /// last scrollback is still useful; otherwise the unsupported message.
    static func content(capabilities: [String], gone: Bool, exited: Bool) -> RemoteSessionDetailContent {
        if canAttach(capabilities: capabilities, gone: gone, exited: exited) { return .attach }
        if capabilities.contains(logCapability) { return .log }
        return .unsupported
    }

    /// Whether the pane carries a send-text footer. Only while no live
    /// attached terminal is showing: an attached terminal takes typing
    /// directly, so a separate field would be a second, redundant input
    /// path. Whenever the pane shows anything else — the log fallback, the
    /// Detached prompt, the provider-authentication prompt — the footer is
    /// the only way to send input. Withheld for a `gone` session, which the
    /// provider no longer reports, and on a stale snapshot, where mutating a
    /// session is unsafe — the same conditions under which the context menu
    /// withholds Send Text….
    static func showsSendFooter(
        capabilities: [String], gone: Bool, snapshotFresh: Bool, hasLiveAttachedPane: Bool
    ) -> Bool {
        snapshotFresh && !gone && !hasLiveAttachedPane
            && capabilities.contains(sendCapability)
    }

    /// Whether the toolbar offers Stop. Needs a session actually present in
    /// the mirror, one the provider still reports, and a fresh inventory:
    /// mutating a session from a stale snapshot is unsafe — the context menu
    /// withholds Stop under the same condition.
    static func showsStop(sessionExists: Bool, gone: Bool, snapshotFresh: Bool) -> Bool {
        sessionExists && !gone && snapshotFresh
    }
}
