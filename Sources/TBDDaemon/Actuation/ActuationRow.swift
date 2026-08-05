import Foundation
import TBDShared

/// The closed vocabulary of act names. Everything else about a row may grow;
/// this set is contract. `outcome` is the synchronous confirmation rung — it
/// says only what the daemon observed as it returned, and never that anything
/// *landed*.
enum ActuationKind: String, Codable, Sendable {
    case send
    case wake
    case hibernate
    case spawn
    case dispose
    case outcome
}

/// What the daemon observed synchronously, immediately after the act returned.
enum ActuationResult: String, Codable, Sendable {
    /// The act reached the transport and the transport reported no failure.
    case dispatched
    /// The daemon declined before touching the transport — target missing,
    /// busy, profile missing, feature disabled.
    case refused
    /// The tmux/provider command itself failed.
    case transportFailed = "transport-failed"
}

/// Why a refusal refused, as a closed vocabulary beside the free-text detail.
///
/// `refused` alone covers two opposite facts: a genuine decline ("this may not
/// happen") and an idempotent no-op ("this was already true"). Telling them
/// apart is a question the record has to answer — *which acts did my controls
/// stop?* — and answering it by matching the human-facing detail string would
/// make every reworded message a silent break. The detail stays; this is what
/// a query reads.
///
/// New raw values are additive: the field is just a string in JSON, so a reader
/// that meets an unfamiliar reason on a newer daemon's file learns a name it
/// did not know rather than failing to parse the row.
enum RefusedReason: String, Codable, Sendable, CaseIterable {
    /// The act was already true — parked when asked to park, not parked when
    /// asked to wake. Nothing was declined and nothing was wrong.
    case noop
    /// The named target does not exist: the terminal, worktree, or repo row is
    /// gone, or the directory it named is missing on disk.
    case notFound = "not-found"
    /// The target exists but is not in a state this act may touch — a safety
    /// rail, a session-kind mismatch, a profile the session needs and lacks.
    case notEligible = "not-eligible"
    /// The same act is already running on this target.
    case inFlight = "in-flight"
}

/// The synchronous outcome of one act, as the daemon classifies it just before
/// it writes the row.
///
/// The reason rides as `refused`'s associated value rather than a sibling
/// parameter, which is what makes "present on every refusal, absent on every
/// other result" a property of the type instead of a comment: there is no way
/// to spell a refusal without naming why, and no way to attach a reason to a
/// dispatch. `ActuationResult` stays the wire vocabulary; this is how callers
/// speak it.
enum ActuationOutcome: Sendable, Equatable {
    case dispatched
    case refused(RefusedReason)
    case transportFailed

    var result: ActuationResult {
        switch self {
        case .dispatched: return .dispatched
        case .refused: return .refused
        case .transportFailed: return .transportFailed
        }
    }

    var reason: RefusedReason? {
        switch self {
        case .refused(let reason): return reason
        case .dispatched, .transportFailed: return nil
        }
    }
}

/// The thing an actuation acted on. Local sessions carry `worktree`/`terminal`
/// (full uppercase UUID strings, matching the DB); remote sessions carry
/// `provider` and, once known, `session`.
struct ActuationTarget: Codable, Sendable, Equatable {
    var worktree: String?
    var terminal: String?
    var provider: String?
    var session: String?

    static func local(worktree: UUID, terminal: UUID?) -> ActuationTarget {
        ActuationTarget(worktree: worktree.uuidString, terminal: terminal?.uuidString)
    }

    static func remote(provider: String, session: String? = nil) -> ActuationTarget {
        ActuationTarget(provider: provider, session: session)
    }
}

/// One line of the record. The envelope (`id`, `ts`, `actor`, `kind`) is
/// shared by every row; the rest is per-kind body, absent when it does not
/// apply. `ActuationLog` mints `id` and stamps `ts` — callers leave both empty.
///
/// Decodable as well as Encodable so tests (and later readers) can parse the
/// file back without a second model.
struct ActuationRow: Codable, Sendable, Equatable {
    var id: String = ""
    var ts: String = ""
    var actor: ActuationActor
    var kind: ActuationKind

    /// The exact public surface that carried the request. Present on every
    /// RPC-initiated row, absent on daemon-internal actuations — which is what
    /// lets the kind vocabulary stay small while the surface list grows.
    var method: String?
    var target: ActuationTarget?
    /// Payload verbatim, never filtered: a stale premise has to stay visible.
    var message: String?
    var submit: Bool?
    var prompt: String?
    var agent: String?
    var profile: String?

    // Outcome-row body.
    /// The `id` of the request row this outcome confirms.
    var confirms: String?
    var result: ActuationResult?
    /// Set on — and only on — a `refused` outcome, by `appendOutcome` from the
    /// same `ActuationOutcome` that decided `result`.
    var reason: RefusedReason?
    var error: String?
}
