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

    /// Whether a live attach terminal can be offered for the session.
    ///
    /// `gone` blocks attach even when the provider declares the capability —
    /// consistent with `RemoteSessionActionMenu.items(gone:)`, which
    /// collapses a tombstone row's context menu to Copy Session ID + Dismiss:
    /// starting a new interactive attach against a session the provider no
    /// longer reports isn't meaningful.
    static func canAttach(capabilities: [String], gone: Bool) -> Bool {
        !gone && capabilities.contains(attachCapability)
    }

    /// What fills the detail pane. Attach whenever it is possible; otherwise
    /// the log, which stays readable for a `gone` session — its last
    /// scrollback is still useful; otherwise the unsupported message.
    static func content(capabilities: [String], gone: Bool) -> RemoteSessionDetailContent {
        if canAttach(capabilities: capabilities, gone: gone) { return .attach }
        if capabilities.contains(logCapability) { return .log }
        return .unsupported
    }

    /// Whether the toolbar offers Stop. Needs a session actually present in
    /// the mirror, one the provider still reports, and a fresh inventory:
    /// mutating a session from a stale snapshot is unsafe — the context menu
    /// withholds Stop under the same condition.
    static func showsStop(sessionExists: Bool, gone: Bool, snapshotFresh: Bool) -> Bool {
        sessionExists && !gone && snapshotFresh
    }
}
