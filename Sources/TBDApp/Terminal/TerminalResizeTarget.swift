import Foundation

/// Which daemon-side size authority a panel's debounced `pane.resize` is
/// addressed to, or nil when the panel has none to tell.
///
/// Extracted for the same reason as `ControlModeResizeGate`: the branch in
/// `sizeChanged` picks between two keying schemes, and a holder row cannot be
/// keyed the control-mode way. Its `windowID` is the empty string, so a
/// `pane.resize` addressed by window resolves nothing and is dropped without a
/// word — which is exactly how a holder panel's resize came to be a no-op.
enum TerminalResizeTarget: Equatable, Sendable {
    /// A control-mode panel. The daemon sizes per tmux WINDOW, because one
    /// server hosts other windows' viewers.
    case controlModeWindow(worktreeID: UUID, windowID: String)
    /// A holder-backed panel. There is no window, so the session names itself.
    case holderSession(worktreeID: UUID, terminalID: UUID)

    /// - Parameter holderPTYIsOwned: whether this panel holds a writable
    ///   duplicate of the session's pty master. It is the app's claim on
    ///   `TIOCSWINSZ` for that session, so it is also what decides whether the
    ///   daemon is asked to resize the grid only.
    ///
    ///   A panel whose duplicate could not be taken is read-only and makes no
    ///   claim: it keeps the size it attached at until it detaches, the same
    ///   degradation already accepted for its writes.
    /// - Parameter worktreeID: nil when the panel's row cannot be resolved, in
    ///   which case there is nothing to address.
    static func resolve(
        holderPTYIsOwned: Bool,
        worktreeID: UUID?,
        terminalID: UUID,
        controlMode: (worktreeID: UUID, windowID: String)?
    ) -> TerminalResizeTarget? {
        // The holder arm comes first: the two are mutually exclusive by
        // construction (`handleHolderTransport` returns before the control-mode
        // client is ever started), so the order is documentation rather than
        // arbitration — but a panel that somehow held both must be addressed as
        // what it actually owns a descriptor for.
        if holderPTYIsOwned, let worktreeID {
            return .holderSession(worktreeID: worktreeID, terminalID: terminalID)
        }
        if let controlMode {
            return .controlModeWindow(
                worktreeID: controlMode.worktreeID, windowID: controlMode.windowID)
        }
        return nil
    }
}
