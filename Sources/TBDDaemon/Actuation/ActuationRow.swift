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

/// What a later, independent observation established about a payload that was
/// already dispatched.
///
/// A different fact class from `ActuationResult`, and deliberately a different
/// type. `ActuationResult` says what the daemon saw as the act returned;
/// `ObservedResult` says what a second look at a machine interface — the
/// transcript, the session's state — found afterwards. **Only a value of this
/// type may claim a payload landed** (§12's never-claim).
///
/// Keeping the two vocabularies apart is what makes that claim unspellable
/// rather than merely forbidden: were `landedAndActing` a case of
/// `ActuationResult`, `appendOutcome(confirms:result: .landedAndActing)` would
/// compile from the synchronous send path and the never-claim would rest on
/// review instead of on the compiler. `RefusedReason` made "a refusal always
/// names why" a property of the type in exactly this way; this is the same move
/// one rung up the claims ladder.
///
/// New raw values are additive, as everywhere else in the record: see
/// `RecordedResult.unrecognized`.
enum ObservedResult: String, Codable, Sendable, CaseIterable, Equatable {
    /// Delivery confirmed and the session is working. Done.
    case landedAndActing = "landed-and-acting"
    /// Delivery confirmed and the session is blocked again — a fresh case.
    case landedButStillBlocked = "landed-but-still-blocked"
    /// Positive evidence of non-delivery: the transcript is readable, the
    /// envelope is absent, and the session is verifiably not mid-turn.
    case notLanded = "not-landed"
    /// The observation could not be made at all — transcript unreadable,
    /// session state unknown, adapter result ambiguous. Never retried:
    /// retrying into uncertainty risks double-instructing an agent that did
    /// receive the first copy.
    case undetermined
}

/// The one `result` field of an outcome row, as it appears on the wire.
///
/// §6's line shape puts both vocabularies in a single `result` string, so this
/// union codes as that string and nothing else — there is no discriminator key,
/// no nesting, and a row written before this type existed still decodes.
///
/// `unrecognized` is what makes §6's additive-raw-values promise real: a reader
/// on an older daemon meeting a name neither vocabulary knows learns a name it
/// did not know rather than failing to parse the row — and can still say so,
/// verbatim, in whatever it renders.
enum RecordedResult: Codable, Sendable, Equatable {
    /// What the daemon saw as the act returned. The only thing a synchronous
    /// path can produce.
    case synchronous(ActuationResult)
    /// What a later observation established. The only thing that may claim a
    /// payload landed.
    case observed(ObservedResult)
    /// A raw value neither vocabulary knows — a newer daemon's name, or a
    /// hand-edited row. Carried through verbatim.
    case unrecognized(String)

    var rawValue: String {
        switch self {
        case .synchronous(let result): return result.rawValue
        case .observed(let result): return result.rawValue
        case .unrecognized(let raw): return raw
        }
    }

    /// Classifies a wire string by trying each closed vocabulary in turn. The
    /// two raw-value sets are disjoint, so the order of the attempts is not a
    /// tiebreak — it is just a lookup.
    init(rawValue: String) {
        if let synchronous = ActuationResult(rawValue: rawValue) {
            self = .synchronous(synchronous)
        } else if let observed = ObservedResult(rawValue: rawValue) {
            self = .observed(observed)
        } else {
            self = .unrecognized(rawValue)
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The observed result, when this row carries one. The join the delivery
    /// query reads: a synchronous `dispatched` says nothing about delivery, so
    /// it must not answer here.
    var observed: ObservedResult? {
        if case .observed(let result) = self { return result }
        return nil
    }
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
    /// The coordinate resolved to a *different* session than the one named:
    /// the target answered with an identity that disagrees with the request's.
    ///
    /// Neither neighbour is honest about this. `notFound` would claim the named
    /// target is gone, and it is not — its row is right there. `notEligible`
    /// would claim the target is in the wrong state, and it is not — a
    /// perfectly healthy *other* target answered. tmux reuses pane ids, so a
    /// stale coordinate names a live stranger (issue #384); the record has to
    /// be able to say that is what happened.
    case targetMismatch = "target-mismatch"
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
    /// The tmux server an act reached, for the reconcile sweep's two
    /// server-scoped disposals. A dead server is killed precisely because no
    /// live row references it any more, and an orphaned window is swept
    /// precisely because no terminal row claims it — so neither has a worktree
    /// or terminal to name, and the coordinates that DO identify them are the
    /// server name and the window id. Repo-initiated sweeps also name the repo
    /// that found them; scratch-only sweeps have no repo to record.
    var server: String?
    var window: String?
    var repo: String?

    static func local(worktree: UUID, terminal: UUID?) -> ActuationTarget {
        ActuationTarget(worktree: worktree.uuidString, terminal: terminal?.uuidString)
    }

    static func remote(provider: String, session: String? = nil) -> ActuationTarget {
        ActuationTarget(provider: provider, session: session)
    }

    /// A whole tmux server, or one untracked window on it, found by a reconcile
    /// sweep. `repo` is absent when the scratch-only startup sweep found it.
    static func tmux(server: String, window: String? = nil, repo: UUID?) -> ActuationTarget {
        ActuationTarget(server: server, window: window, repo: repo?.uuidString)
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
    /// Set on a request row when the caller armed delivery verification, and
    /// only then. Without it the startup replay and the account cannot tell
    /// which sends owe an observation from the ones that never asked for one.
    var verify: Bool?
    var prompt: String?
    var agent: String?
    var profile: String?

    // Outcome-row body.
    /// The `id` of the request row this outcome confirms.
    var confirms: String?
    var result: RecordedResult?
    /// When the observation behind an `observed` result was made. Set on — and
    /// only on — observation rows, by `appendObservation`. It is the moment the
    /// machine facts were read, which can be materially earlier than `ts`, the
    /// moment the row was written.
    var observedAt: String?
    /// Set on — and only on — a `refused` outcome, by `appendOutcome` from the
    /// same `ActuationOutcome` that decided `result`.
    var reason: RefusedReason?
    var error: String?
}
