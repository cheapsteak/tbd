import Foundation

/// The servers a `server.start` or `server.stop` is acting on right now, per
/// worktree and server name. A request claims each server before it reads
/// that server's state and releases it when done, so two requests for one
/// server — a double click, the CLI racing the toolbar — never both act: the
/// second is told the first is in flight instead of spawning a second tab or
/// signalling mid-start. Requests for different servers do not contend.
actor DevServerActionClaims {
    enum Action: Sendable, Equatable {
        case start
        case stop
    }

    private struct Key: Hashable {
        let worktreeID: UUID
        let name: String
    }

    private var inFlight: [Key: Action] = [:]

    /// Claims every name not already claimed. Returns the names this call now
    /// holds, and for each name it could not take, the action holding it.
    /// Duplicate names are claimed once.
    func claim(
        _ names: [String], in worktreeID: UUID, for action: Action
    ) -> (claimed: [String], busy: [String: Action]) {
        var claimed: [String] = []
        var busy: [String: Action] = [:]
        for name in names {
            let key = Key(worktreeID: worktreeID, name: name)
            if let holder = inFlight[key] {
                if !claimed.contains(name) { busy[name] = holder }
                continue
            }
            inFlight[key] = action
            claimed.append(name)
        }
        return (claimed, busy)
    }

    func release(_ names: [String], in worktreeID: UUID) {
        for name in names { inFlight[Key(worktreeID: worktreeID, name: name)] = nil }
    }
}
