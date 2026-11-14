import Foundation

/// The holder session a panel's debounced `pane.resize` is addressed to, or
/// nil when the panel has none to tell.
///
/// A holder row has no tmux window — its `windowID` is the empty string — so a
/// `pane.resize` addressed by window would resolve nothing and be dropped
/// without a word. The session names itself by terminal ID instead.
struct TerminalResizeTarget: Equatable, Sendable {
    let worktreeID: UUID
    let terminalID: UUID

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
        terminalID: UUID
    ) -> TerminalResizeTarget? {
        guard holderPTYIsOwned, let worktreeID else { return nil }
        return TerminalResizeTarget(worktreeID: worktreeID, terminalID: terminalID)
    }
}
