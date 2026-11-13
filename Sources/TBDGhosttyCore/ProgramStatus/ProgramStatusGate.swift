import os

/// The holder-vs-tmux switch for the Program Status Protocol (OSC 7501) that
/// both engines read: on for a holder-transport panel, off for a tmux one. Set
/// on main from the panel's transport, read on the parse thread inside the
/// synchronous OSC handling, hence a lock rather than a plain `Bool`.
public final class ProgramStatusGate: Sendable {
    private let state: OSAllocatedUnfairLock<Bool>

    public init() {
        state = OSAllocatedUnfairLock(initialState: false)
    }

    public var isEnabled: Bool {
        state.withLock { $0 }
    }

    public func set(_ enabled: Bool) {
        state.withLock { $0 = enabled }
    }
}
