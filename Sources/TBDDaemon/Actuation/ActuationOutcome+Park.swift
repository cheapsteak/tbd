import Foundation

/// Classification of the park/wake coordinator's results into the outcome
/// vocabulary, spelled once so every hibernate and wake surface — the two
/// modern RPCs, their two legacy shims, the two worktree fan-outs and the idle
/// sweep — reads them the same way.
///
/// `refused` covers the idempotent no-ops (already parked, not parked) as well
/// as the outright declines, so each one names its `RefusedReason`: a reader
/// asking which acts the daemon's controls stopped must not have to tell those
/// apart by their detail strings. The RPC contract keeps returning success for
/// the no-ops, but the record must not claim an act happened when the daemon
/// never touched the transport.
extension ActuationOutcome {
    static func classify(_ result: HibernateResult) -> ActuationOutcome {
        switch result {
        case .ok: return .dispatched
        case .alreadyHibernated: return .refused(.noop)
        case .notEligible: return .refused(.notEligible)
        case .notFound: return .refused(.notFound)
        }
    }

    static func detail(_ result: HibernateResult) -> String? {
        switch result {
        case .ok: return nil
        case .alreadyHibernated: return "already parked"
        case .notEligible(let reason): return reason
        case .notFound: return "Terminal not found"
        }
    }

    static func classify(_ result: WakeResult) -> ActuationOutcome {
        switch result {
        case .ok: return .dispatched
        // The respawn reached tmux and tmux failed — the one wake path that is
        // a transport failure rather than a decline.
        case .respawnFailed: return .transportFailed
        // Waking something that was never parked is the wake's idempotent
        // no-op, not a decline.
        case .notHibernated: return .refused(.noop)
        case .inFlight: return .refused(.inFlight)
        // The terminal row is gone, or the directory its worktree named is.
        case .notFound, .worktreeMissing: return .refused(.notFound)
        // The row claims awake but its pane disagrees. A stale coordinate that
        // resolved to a live stranger is `targetMismatch` — the one reason that
        // can say so; a gone or exited pane is the named target genuinely being
        // absent.
        case .sessionGone(_, let detail):
            switch detail {
            case .paneBelongsToAnotherTerminal: return .refused(.targetMismatch)
            case .paneMissing, .processExited: return .refused(.notFound)
            }
        // The row is there but cannot be woken as asked: nothing to resume, or
        // the profile it was pinned to no longer exists.
        case .noSessionID, .profileMissing: return .refused(.notEligible)
        }
    }

    static func detail(_ result: WakeResult) -> String? {
        switch result {
        case .ok: return nil
        case .notHibernated: return "not parked"
        case .inFlight: return "a wake is already in flight"
        case .notFound: return "Terminal not found"
        case .noSessionID: return "No session ID to resume"
        case .respawnFailed(let reason): return reason
        case .worktreeMissing(let path): return "Worktree directory missing on disk: \(path)"
        case .sessionGone(let paneID, let detail):
            switch detail {
            case .paneMissing: return "Pane \(paneID) is gone"
            case .processExited: return "Pane \(paneID) survives but its process exited"
            case .paneBelongsToAnotherTerminal(let actual):
                return "Pane \(paneID) answers with a different terminal: \(actual)"
            }
        case .profileMissing(let profileID):
            return "Profile no longer exists: \(profileID.uuidString)"
        }
    }
}
