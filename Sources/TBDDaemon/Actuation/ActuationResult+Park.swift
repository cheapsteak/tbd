import Foundation

/// Classification of the park/wake coordinator's results into the outcome
/// vocabulary, spelled once so every hibernate and wake surface — the two
/// modern RPCs, their two legacy shims, the two worktree fan-outs and the idle
/// sweep — reads them the same way.
///
/// `refused` covers the idempotent no-ops (already parked, not parked, a wake
/// already in flight) as well as the outright declines. The RPC contract keeps
/// returning success for those, but the record must not claim an act happened
/// when the daemon never touched the transport.
extension ActuationResult {
    static func classify(_ result: HibernateResult) -> ActuationResult {
        switch result {
        case .ok: return .dispatched
        case .alreadyHibernated, .notEligible, .notFound: return .refused
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

    static func classify(_ result: WakeResult) -> ActuationResult {
        switch result {
        case .ok: return .dispatched
        // The respawn reached tmux and tmux failed — the one wake path that is
        // a transport failure rather than a decline.
        case .respawnFailed: return .transportFailed
        case .notHibernated, .inFlight, .notFound, .noSessionID,
             .worktreeMissing, .profileMissing:
            return .refused
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
        case .profileMissing(let profileID):
            return "Profile no longer exists: \(profileID.uuidString)"
        }
    }
}
