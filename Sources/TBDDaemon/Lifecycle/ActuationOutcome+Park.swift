import Foundation
import TBDShared

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
        // A row live on tmux is declined like any other ineligible row.
        case .notEligible, .onTmux: return .refused(.notEligible)
        case .notFound: return .refused(.notFound)
        }
    }

    static func detail(_ result: HibernateResult) -> String? {
        switch result {
        case .ok: return nil
        case .alreadyHibernated: return "already parked"
        case .notEligible(let reason), .onTmux(let reason): return reason
        case .notFound: return "Terminal not found"
        }
    }

    static func classify(_ result: WakeResult) -> ActuationOutcome {
        switch result {
        case .ok: return .dispatched
        // Every wake that stopped for a cause with no case of its own: a
        // failed or refused holder spawn, but also declines that start
        // nothing — the Codex prompt refusal, which comes before the worktree,
        // condition, directory and profile checks, a Codex resume that could
        // not be prepared, a row that changed under the wake, and the answers
        // that keep a row parked over a live holder. All of them are recorded
        // as transport failures.
        case .respawnFailed: return .transportFailed
        // The row is on tmux, which TBD no longer drives. Declined with
        // nothing touched, as a send to such a row is.
        case .onTmux: return .refused(.notEligible)
        // Waking something that was never parked is the wake's idempotent
        // no-op, not a decline.
        case .notHibernated: return .refused(.noop)
        case .inFlight: return .refused(.inFlight)
        // The terminal row is gone, or the directory its worktree named is.
        case .notFound, .worktreeMissing: return .refused(.notFound)
        // The row claims awake but its holder's job has exited: the named
        // target is genuinely absent.
        case .sessionGone: return .refused(.notFound)
        // The row is there but cannot be woken as asked: nothing to resume, a
        // tab that is not Claude's, or the profile it was pinned to no longer
        // exists.
        case .noSessionID, .notAClaudeTab, .profileMissing: return .refused(.notEligible)
        // The row is parked, but no longer the one the caller chose. Declined
        // with nothing touched.
        case .conditionNotMet: return .refused(.notEligible)
        }
    }

    static func detail(_ result: WakeResult) -> String? {
        switch result {
        case .ok: return nil
        case .notHibernated: return "not parked"
        case .inFlight: return "a wake is already in flight"
        case .notFound: return "Terminal not found"
        case .noSessionID: return "No session ID to resume"
        case .notAClaudeTab(let kind): return ClaudeResumeDecision.notAClaudeTabReason(kind)
        case .respawnFailed(let reason): return reason
        case .onTmux(let reason): return reason
        case .worktreeMissing(let path): return "Worktree directory missing on disk: \(path)"
        case .sessionGone: return "The session's process has exited"
        case .profileMissing(let profileID):
            return "Profile no longer exists: \(profileID.uuidString)"
        case .conditionNotMet: return "the row no longer meets this wake's condition"
        }
    }
}
