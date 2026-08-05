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
    var error: String?
}
