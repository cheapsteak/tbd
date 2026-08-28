import Foundation

// MARK: - The governing idea
//
// A fact TBD reports about a session is never a bare enumeration. It is a
// triple — the value, the source it came from, and the moment it was observed —
// so that a consumer can always ask two questions of anything it is told: *how
// do you know*, and *when did you learn it*. `ObservedFact` is that triple, and
// every state-shaped thing in this file either is one or is built out of them.
//
// The consequence that matters is what becomes unspellable. A value with no
// provenance cannot be constructed, so it cannot drift into a briefing, a
// threshold comparison, or a rendered surface pretending to be current. And
// because provenance is structural rather than conventional, `unknown` gets to
// be a first-class answer — "nothing could speak to this" is a fact with a
// source (`.unavailable`) and an observed-at like any other, not an error and
// not an excuse to substitute a confident value that happens to be at hand.
//
// This is the state-model half of the fleet-supervision design
// (`docs/specs/2026-07-26-fleet-supervision-design.md` §2). It defines shapes
// and says nothing about policy: no thresholds, no verdicts, no actions. What
// counts as too long, too many, or too full is a project's convention and lives
// in its sweep program.

// MARK: - FactSource

/// Where a fact came from.
///
/// Every case names a machine interface TBD already talks to, or the honest
/// absence of one. That is deliberate: a source vocabulary that could name a
/// *guess* would let a guess be recorded as an observation. `.derived` is the
/// closest thing to an exception and is fenced by its own doc comment.
///
/// The wire form is a tagged object — `{"kind": "hook", "detail":
/// "Notification"}` — rather than a bare string, so a source that carries a
/// qualifier (which hook event, specifically) does not have to smuggle it
/// through string concatenation.
///
/// New kinds are additive. A reader meeting a `kind` it does not know decodes
/// `.unrecognized(raw)` and carries the name through verbatim rather than
/// failing the whole record — the same forward-compatibility promise
/// `RecordedResult.unrecognized` makes for the actuation ledger. The one
/// bounded loss: an unrecognized kind's `detail` is not retained, because the
/// case has nowhere to put it. Nothing re-writes a stored fact in place — the
/// daemon replaces facts with fresh observations — so the loss cannot compound.
public enum FactSource: Sendable, Equatable, Hashable, Codable {
    /// A Claude Code hook event reported it; the associated value is the event
    /// name (`SessionStart`, `Stop`, `Notification`, …). The name is carried,
    /// never matched against a rendered screen.
    case hookEvent(String)
    /// An explicit action taken by the person operating TBD. The associated
    /// value names the action (`terminal-interrupt`, …), keeping user intent
    /// distinct from an agent hook that happens to report the same value.
    case userAction(String)
    /// The session's transcript JSONL, read from the tail.
    case transcriptTail
    /// The statusline wrapper's captured stdin JSON — the one surface on which
    /// Claude Code tells a third party its *resolved* context window.
    case statuslineTee
    /// TBD's own persisted record: the hibernation columns, the scheduled-resume
    /// rows, anything the daemon wrote down earlier and is now reading back.
    case database
    /// tmux pane and process liveness.
    case processLiveness
    /// The git forge — a pull-request query.
    case forge
    /// The daemon's git sweep.
    case gitSweep
    /// Composed by TBD from other facts.
    ///
    /// Not a laundering channel: a `.derived` fact must be a function of facts
    /// that were themselves observed, and its `observedAt` must be no later
    /// than the oldest input it was composed from. Deriving a value nobody
    /// observed and stamping it `.derived` is the one way to defeat everything
    /// this file exists to guarantee.
    case derived
    /// Nothing could speak to it. Pairs with an `unknown` value: this is what
    /// the source field says when the honest answer is "we do not know".
    case unavailable
    /// A `kind` this build does not know — written by a newer daemon, or by
    /// hand. Carried through verbatim so it can be reported rather than lost.
    case unrecognized(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case detail
    }

    /// The wire tag. `.unrecognized` reports the raw kind it was given, so a
    /// name a newer daemon wrote survives a decode/encode round trip.
    public var kind: String {
        switch self {
        case .hookEvent: return "hook"
        case .userAction: return "user-action"
        case .transcriptTail: return "transcript-tail"
        case .statuslineTee: return "statusline-tee"
        case .database: return "database"
        case .processLiveness: return "process-liveness"
        case .forge: return "forge"
        case .gitSweep: return "git-sweep"
        case .derived: return "derived"
        case .unavailable: return "unavailable"
        case .unrecognized(let raw): return raw
        }
    }

    /// The kind's qualifier, when it has one.
    public var detail: String? {
        switch self {
        case .hookEvent(let event), .userAction(let event): return event
        default: return nil
        }
    }

    /// One line, for composition into `ObservedFact.summary`.
    public var summary: String {
        guard let detail else { return kind }
        return "\(kind):\(detail)"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let detail = try c.decodeIfPresent(String.self, forKey: .detail)
        switch kind {
        case "hook":
            // `hook` without a `detail` is not a source: the qualifier IS the
            // provenance — which hook fired — and an empty one renders as the
            // bare `hook:` and satisfies every "does this fact name its source"
            // check while naming nothing. It is filed as unrecognized, which is
            // what this decoder already does with a kind it cannot make sense
            // of, and which round-trips back to the same bytes.
            if let detail, !detail.isEmpty { self = .hookEvent(detail) } else { self = .unrecognized(kind) }
        case "user-action":
            if let detail, !detail.isEmpty { self = .userAction(detail) } else { self = .unrecognized(kind) }
        case "transcript-tail": self = .transcriptTail
        case "statusline-tee": self = .statuslineTee
        case "database": self = .database
        case "process-liveness": self = .processLiveness
        case "forge": self = .forge
        case "git-sweep": self = .gitSweep
        case "derived": self = .derived
        case "unavailable": self = .unavailable
        default: self = .unrecognized(kind)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(detail, forKey: .detail)
    }
}

public extension FactSource {
    /// Provenance written when the user presses an agent's interrupt key.
    static let terminalInterrupt = FactSource.userAction("terminal-interrupt")
}

// MARK: - ObservedFact

/// A value that renders its own provenance.
///
/// Types conform so that `ObservedFact.summary` can print something better than
/// `String(describing:)` for values that have a human reading. Conformance is
/// optional — the default is the describing form — because the point of the
/// protocol is presentation, not correctness.
public protocol FactValueSummarizable {
    var factSummary: String { get }
}

/// The triple: a value, the source it came from, and when it was observed.
///
/// `observedAt` is the moment the machine facts were *read*, which is not the
/// moment anything was written down — the same distinction `ActuationRow` draws
/// between `observedAt` and `ts`. Downstream code that ages a fact must age it
/// by this field; a write timestamp would make a stale fact look fresh every
/// time the row was rewritten.
public struct ObservedFact<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public let value: Value
    public let source: FactSource
    public let observedAt: Date

    public init(value: Value, source: FactSource, observedAt: Date) {
        self.value = value
        self.source = source
        self.observedAt = observedAt
    }

    /// The whole triple on one line.
    ///
    /// There is deliberately no "just the value" rendering on this type. A
    /// surface that wants to print a fact gets its provenance whether it asked
    /// for it or not, which is what stops a bare value from reaching a reader
    /// who would then have no way to ask how old it is.
    public var summary: String {
        let rendered = (value as? FactValueSummarizable)?.factSummary ?? String(describing: value)
        return "\(rendered) (source: \(source.summary), observed \(FactTimestamp.string(from: observedAt)))"
    }
}

/// The one timestamp rendering used by every `summary` in this file: ISO 8601
/// in UTC, so a composed line is stable across machines and test runs.
public enum FactTimestamp {
    /// Built per call rather than cached in a `static let`:
    /// `ISO8601DateFormatter` is a mutable class and not `Sendable`, and these
    /// strings are composed for display and diagnostics, never in a hot loop.
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

// MARK: - Awaiting-input reason

/// The closed vocabulary a `Notification` payload's `notification_type` is
/// filed under.
///
/// Four classes, and the fourth is the important one. `notification_type` is
/// Claude Code's vocabulary, not TBD's: it gains values on their release
/// schedule, and a value this build has never heard of is filed as
/// `.unrecognized` and left there. It is **never** guessed into a neighbouring
/// class on the strength of its spelling — a "sounds like a prompt" heuristic
/// would be screen-scraping moved one layer inward, and would make TBD's
/// reading of a session change silently when a type is renamed.
///
/// The class is a *label on a recorded fact*, not a branch in a decision. What
/// a class means — whether `promptOnScreen` warrants waking someone, whether
/// `informational` is worth a line in a briefing — is a project's convention
/// and lives in its sweep program, exactly as the thresholds in this file's
/// other types do.
public enum AwaitingInputClass: String, Sendable, Equatable, Codable {
    /// A prompt is on screen now and a human has to answer it.
    case promptOnScreen = "prompt_on_screen"
    /// The agent finished its turn and is waiting for a next instruction.
    case doneWaiting = "done_waiting"
    /// Something happened worth reporting; nobody is being waited on.
    case informational = "informational"
    /// A type this build does not know, or no type at all. Recorded verbatim
    /// beside this label so a reader — human or program — can still see what
    /// arrived.
    case unrecognized

    /// File a `notification_type` under its class. Absent or unknown →
    /// `.unrecognized`.
    ///
    /// The three groups are the types Claude Code emits — a wider set than its
    /// published documentation lists — enumerated exhaustively so that adding
    /// one is a visible edit rather than a silent reclassification.
    public init(notificationType: String?) {
        switch notificationType {
        case "permission_prompt", "elicitation_dialog", "agent_needs_input",
             "worker_permission_prompt", "elicitation_url_dialog":
            self = .promptOnScreen
        case "idle_prompt":
            self = .doneWaiting
        case "auth_success", "elicitation_complete", "elicitation_response",
             "agent_completed", "computer_use_enter", "computer_use_exit",
             "push_notification", "quota_auto_resume_fired",
             "quota_auto_resume_stale", "quota_auto_resume_disabled":
            self = .informational
        default:
            // Absent, or a type this build has never heard of. It stops here:
            // no prefix match, no case folding, no "sounds like a prompt".
            self = .unrecognized
        }
    }

    /// A tag this build does not know decodes to `.unrecognized` rather than
    /// throwing.
    ///
    /// **This is not what makes an `AwaitingInputReason` forward-compatible,
    /// and it is worth being exact about which mechanism is load-bearing.**
    /// That type's decoder routes through its memberwise init and re-derives
    /// `classification` from the decoded `notificationType`, so the encoded
    /// class is never read and this initializer is never reached from there —
    /// a record written by a newer build survives because *this build's*
    /// vocabulary re-files it, not because the tag decoded leniently. This
    /// initializer covers the remaining case: someone decoding an
    /// `AwaitingInputClass` on its own, where a `rawValue` from a newer build
    /// must be an admission of ignorance rather than a thrown error that takes
    /// the enclosing record with it.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AwaitingInputClass(rawValue: raw) ?? .unrecognized
    }
}

/// A session transcript as it stood when a prompt was recorded against it.
///
/// Identity is the file, its size, and its modification time. Comparing a
/// stored fingerprint against a fresh one asks whether the file CHANGED since
/// the prompt was raised — a different and more durable question than whether
/// the file is newer than some timestamp. It depends on no ordering between
/// Claude Code's debounced notification timer and its own transcript flush,
/// and on no clock agreeing with another clock.
public struct TranscriptFingerprint: Codable, Sendable, Equatable {
    /// The transcript this was taken from. A terminal whose `transcriptPath`
    /// no longer matches has been retargeted — a `/clear`, a compaction, a
    /// resume — and a fingerprint cannot describe a file it was not taken from.
    public let path: String
    public let modifiedAt: Date
    public let size: Int64

    public init(path: String, modifiedAt: Date, size: Int64) {
        self.path = path
        self.modifiedAt = modifiedAt
        self.size = size
    }
}

/// The structured reason an agent is waiting, carried verbatim from Claude
/// Code's `Notification` hook.
///
/// **TBD never branches on `message`.** It is carried into a briefing, into a
/// question raised on a project's question route, and into the one-minute
/// re-check — and read by a human or by a project's own program, both of which
/// may interpret it however they like. Compiled TBD may not, because matching
/// on that text would be screen-scraping with an extra hop: the string is a
/// display artifact of one Claude Code version, and a reworded prompt would
/// silently change TBD's behavior.
///
/// `raw` keeps the payload JSON as it arrived, so a later consumer can read a
/// field this build does not model without waiting for a TBD release.
public struct AwaitingInputReason: Codable, Sendable, Equatable {
    /// The prompt text, verbatim. Carried, never parsed.
    public let message: String
    /// The hook event that delivered it, when known — `Notification` today.
    public let hookEventName: String?
    /// The verbatim payload JSON, when it was captured.
    public let raw: String?
    /// `notification_type` exactly as it arrived, or nil when the payload
    /// carried none (an older Claude Code). Stored unmodified even when this
    /// build does not recognize it.
    public let notificationType: String?
    /// The transcript as it stood when this reason was recorded, for a
    /// `.promptOnScreen` class only. Absent on every other class — there is no
    /// raised hand to take down — and absent on rows written before this
    /// existed, which `AwaitingInputSupersession` adopts rather than acts on.
    public let transcriptFingerprint: TranscriptFingerprint?
    /// Which class `notificationType` falls under.
    ///
    /// Derived from `notificationType` at construction and **re-derived on
    /// decode** rather than trusted from the wire, so the pair can never
    /// disagree: a stored row cannot claim a class its own type does not
    /// support, and this build's vocabulary is always the one that decides.
    /// It is encoded anyway, because a reader outside TBD — a briefing, a
    /// project's own program — should not have to reimplement the grouping to
    /// read the record.
    public let classification: AwaitingInputClass

    public init(
        message: String,
        hookEventName: String? = nil,
        raw: String? = nil,
        notificationType: String? = nil,
        transcriptFingerprint: TranscriptFingerprint? = nil
    ) {
        self.message = message
        self.hookEventName = hookEventName
        self.raw = raw
        self.notificationType = notificationType
        self.transcriptFingerprint = transcriptFingerprint
        self.classification = AwaitingInputClass(notificationType: notificationType)
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case hookEventName
        case raw
        case notificationType
        case transcriptFingerprint
        case classification
    }

    /// Decodes through the memberwise init so `classification` is recomputed
    /// from the decoded `notificationType`. The encoded `classification` is
    /// deliberately ignored — see the property's doc comment.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            message: try c.decode(String.self, forKey: .message),
            hookEventName: try c.decodeIfPresent(String.self, forKey: .hookEventName),
            raw: try c.decodeIfPresent(String.self, forKey: .raw),
            notificationType: try c.decodeIfPresent(String.self, forKey: .notificationType),
            transcriptFingerprint: try c.decodeIfPresent(
                TranscriptFingerprint.self, forKey: .transcriptFingerprint)
        )
    }
}

extension AwaitingInputReason: FactValueSummarizable {
    /// Class and verbatim type first, then the message — so a composed
    /// `ObservedFact.summary` line carries what was asked, how TBD filed it,
    /// where it came from, and when, and a reader can never see the message
    /// without the label TBD put on it.
    public var factSummary: String {
        "awaiting input [\(classification.rawValue)] type=\(notificationType ?? "none"): \(message)"
    }
}

// MARK: - Session state

/// The P0 session-state vocabulary: what an agent is doing now.
///
/// `.unknown` is a real answer, not an error path. Every other case asserts
/// something about the session, and asserting one of them wrongly is worse than
/// admitting ignorance — a supervisor that is told `idle` about a session
/// nobody could read will act on a session it cannot see. So `unknown` carries
/// `why`, rides the same triple as every other value, and is what a decoder
/// produces when it meets a tag it does not recognize. It is never repaired
/// into a confident value on the way through.
///
/// The wire form is a tagged object keyed on `state`. New tags are additive:
/// a reader meeting one it does not know decodes `.unknown(why:)` naming the
/// raw tag, rather than throwing and taking the whole record with it.
public enum SessionStateValue: Sendable, Equatable, Codable {
    /// Mid-turn.
    case working
    /// Finished a turn and waiting for nothing in particular.
    case idle
    /// Blocked on a human — a permission prompt or a question. The reason is
    /// present when the `Notification` hook supplied one.
    case awaitingInput(reason: AwaitingInputReason?)
    /// Stopped by a usage limit. `until` is absolute when the limit announced
    /// one, nil when it did not.
    case rateLimited(until: Date?)
    /// Parked by TBD — the agent's process was torn down deliberately. The
    /// reason is free text because who-parked-and-why is TBD's own vocabulary
    /// (`HibernateReason`) plus whatever a wake program adds.
    case parked(reason: String)
    /// The session no longer exists: the pane, the window, or the process is
    /// gone.
    case gone
    /// Nothing could establish the state. `why` says what was tried or what was
    /// missing.
    case unknown(why: String)

    private enum CodingKeys: String, CodingKey {
        case state
        case reason
        case until
        case why
    }

    private enum Tag {
        static let working = "working"
        static let idle = "idle"
        static let awaitingInput = "awaiting_input"
        static let rateLimited = "rate_limited"
        static let parked = "parked"
        static let gone = "gone"
        static let unknown = "unknown"
    }

    /// Short human reading. Stable enough to compose into a line; never parsed
    /// back.
    public var label: String {
        switch self {
        case .working: return "working"
        case .idle: return "idle"
        case .awaitingInput: return "awaiting input"
        case .rateLimited(let until):
            guard let until else { return "rate-limited" }
            return "rate-limited until \(FactTimestamp.string(from: until))"
        case .parked(let reason): return "parked (\(reason))"
        case .gone: return "gone"
        case .unknown(let why): return "unknown (\(why))"
        }
    }

    /// False for `.unknown` and true for everything else. The question a
    /// consumer asks before treating a state as something to act on.
    public var isConfident: Bool {
        if case .unknown = self { return false }
        return true
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .state)
        switch tag {
        case Tag.working: self = .working
        case Tag.idle: self = .idle
        case Tag.awaitingInput:
            self = .awaitingInput(reason: try c.decodeIfPresent(AwaitingInputReason.self, forKey: .reason))
        case Tag.rateLimited:
            self = .rateLimited(until: try c.decodeIfPresent(Date.self, forKey: .until))
        case Tag.parked:
            self = .parked(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case Tag.gone: self = .gone
        case Tag.unknown:
            self = .unknown(why: try c.decodeIfPresent(String.self, forKey: .why) ?? "")
        default:
            // Never a confident value, never a throw: an older build meeting a
            // newer daemon's tag learns that it does not know, and says so.
            self = .unknown(why: "unrecognized state tag '\(tag)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .working:
            try c.encode(Tag.working, forKey: .state)
        case .idle:
            try c.encode(Tag.idle, forKey: .state)
        case .awaitingInput(let reason):
            try c.encode(Tag.awaitingInput, forKey: .state)
            try c.encodeIfPresent(reason, forKey: .reason)
        case .rateLimited(let until):
            try c.encode(Tag.rateLimited, forKey: .state)
            try c.encodeIfPresent(until, forKey: .until)
        case .parked(let reason):
            try c.encode(Tag.parked, forKey: .state)
            try c.encode(reason, forKey: .reason)
        case .gone:
            try c.encode(Tag.gone, forKey: .state)
        case .unknown(let why):
            try c.encode(Tag.unknown, forKey: .state)
            try c.encode(why, forKey: .why)
        }
    }
}

extension SessionStateValue: FactValueSummarizable {
    public var factSummary: String { label }
}

/// A session state as it is always stored and reported: value, source, and the
/// moment it was observed.
///
/// The alias is the point. There is no other `SessionState` type, so there is
/// no way to hold a session state without its provenance — the triple is
/// structural, not a convention that a later call site can quietly drop.
public typealias SessionState = ObservedFact<SessionStateValue>

// MARK: - Context load

/// The size of a session's context window, as an observed fact or an honest
/// absence.
///
/// **There is no compiled model→window table, and there must never be one.**
/// The effective window is a session fact, not a model fact: Claude Code
/// resolves it per session from the model id, a `[1m]` suffix, a long-context
/// beta header, environment overrides, and a remote feature flag, so the same
/// model id can be a 200k session or a 1M session. Any out-of-band table
/// reports *capability*, and capability errs in the dangerous direction — a
/// table claiming 1M for a session actually running at 200k reads one-fifth
/// full at the boundary, which is exactly where being wrong costs the most.
///
/// The only party that knows the resolved window is Claude Code, and the one
/// surface where it tells a third party is the statusline's stdin JSON. Where
/// that tee has not fired, the answer is `.unknown` and the report carries raw
/// token counts with no percentage.
public enum ContextWindow: Codable, Sendable, Equatable {
    case observed(ObservedFact<Int>)
    case unknown(why: String)

    /// The window assumed when something needs a denominator anyway.
    ///
    /// It is a **labeled** assumption — every computation that uses it hands
    /// back `assumed: true` alongside the number, and no caller may drop that
    /// flag on the way to a surface. 200k is chosen because it errs early: if
    /// the real window is larger, a threshold fires sooner than it needed to,
    /// which costs attention. The opposite error costs a session.
    ///
    /// The same number is spelled again in Python as `ASSUMED_WINDOW`, in the
    /// `tick.py` body inside `NightwatchSkillContent.swift`. Two languages, one
    /// assumption and no way to share it, so it is stated twice on purpose —
    /// change one, change the other, and keep it labeled as an assumption in
    /// whatever a human reads.
    public static let assumedTokens = 200_000

    /// The denominator to use, and whether it was assumed.
    public func effectiveTokens() -> (tokens: Int, assumed: Bool) {
        switch self {
        case .observed(let fact): return (fact.value, false)
        case .unknown: return (Self.assumedTokens, true)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case window
        case fact
        case why
    }

    private enum Tag {
        static let observed = "observed"
        static let unknown = "unknown"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .window)
        switch tag {
        case Tag.observed:
            self = .observed(try c.decode(ObservedFact<Int>.self, forKey: .fact))
        case Tag.unknown:
            self = .unknown(why: try c.decodeIfPresent(String.self, forKey: .why) ?? "")
        default:
            // Same rule as `SessionStateValue`: an unfamiliar tag becomes an
            // admission of ignorance, never a number.
            self = .unknown(why: "unrecognized window tag '\(tag)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .observed(let fact):
            try c.encode(Tag.observed, forKey: .window)
            try c.encode(fact, forKey: .fact)
        case .unknown(let why):
            try c.encode(Tag.unknown, forKey: .window)
            try c.encode(why, forKey: .why)
        }
    }
}

/// How full a session's context is: a numerator that may be unknown over a
/// denominator that may be assumed.
///
/// The two halves are separately fallible and are modeled separately for that
/// reason. `used` comes from the last assistant record's `usage` block at the
/// transcript tail; the window comes from the statusline tee. Either can be
/// missing without the other, and collapsing them into one optional percentage
/// would lose which one was missing.
public struct ContextLoad: Codable, Sendable, Equatable {
    /// Tokens currently in the window. nil when the transcript tail could not
    /// be read or carried no usage block.
    public let used: ObservedFact<Int>?
    public let window: ContextWindow

    public init(used: ObservedFact<Int>?, window: ContextWindow) {
        self.used = used
        self.window = window
    }

    /// Whether numerator and denominator are one reading rather than two.
    ///
    /// True only when both halves came from the same source at the same
    /// instant — in practice, when the statusline tee's captured payload
    /// carried a `current_usage` and a `context_window_size` together, which is
    /// Claude Code computing both at once from its own state. False whenever
    /// the numerator was read from the transcript tail while the denominator
    /// came from an earlier capture, and false when the window is unknown.
    ///
    /// The distinction is not pedantry: a numerator and a denominator observed
    /// at different moments were never simultaneously true, so a percentage
    /// composed from them is an estimate and has to be shown as one. This is
    /// what lets a consumer say so instead of silently presenting the pair as
    /// one coherent fraction.
    public var isPairedReading: Bool {
        guard let used, case .observed(let windowFact) = window else { return false }
        return used.source == windowFact.source && used.observedAt == windowFact.observedAt
    }

    /// Fraction of the window in use, and whether the 200k assumption was used
    /// to get it.
    ///
    /// nil when the numerator is unknown — there is no percentage to report and
    /// none may be invented — or when the denominator is non-positive, which
    /// only a malformed observation can produce. `assumedWindow` is true
    /// exactly when the window was unknown, and callers must carry it onto
    /// whatever surface shows the number.
    public func percentUsed() -> (percent: Double, assumedWindow: Bool)? {
        guard let used else { return nil }
        let (tokens, assumed) = window.effectiveTokens()
        guard tokens > 0 else { return nil }
        return (Double(used.value) / Double(tokens) * 100, assumed)
    }
}

// MARK: - PR observation

/// The outcome of one attempt to learn a worktree's pull-request state — a
/// different fact from the PR value itself.
///
/// This type exists to prevent one specific bug: collapsing "the forge answered
/// and this branch has no PR" into "we could not find out". They are opposite
/// facts. The first is settled knowledge a program can act on; the second is
/// ignorance that must be retried or reported. A single nil `PRStatus` says
/// both, and a night spent treating an outage as "no PR anywhere" looks exactly
/// like a calm night.
public struct PRObservation: Codable, Sendable, Equatable {
    public enum Outcome: Sendable, Equatable, Codable {
        /// The forge answered and there is a PR; its value rides in `PRStatus`.
        case observed
        /// The forge answered; this branch has no PR.
        case none
        /// The attempt did not produce an answer. `cause` says why — a network
        /// failure, a missing credential, a query error.
        case undetermined(cause: String)

        private enum CodingKeys: String, CodingKey {
            case outcome
            case cause
        }

        private enum Tag {
            static let observed = "observed"
            static let none = "none"
            static let undetermined = "undetermined"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try c.decode(String.self, forKey: .outcome)
            switch tag {
            case Tag.observed: self = .observed
            case Tag.none: self = .none
            case Tag.undetermined:
                self = .undetermined(cause: try c.decodeIfPresent(String.self, forKey: .cause) ?? "")
            default:
                // An unfamiliar tag is ignorance, and ignorance is
                // `.undetermined`. Decoding it as `.none` would assert the
                // forge answered — the exact collapse this type prevents.
                self = .undetermined(cause: "unrecognized outcome tag '\(tag)'")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .observed:
                try c.encode(Tag.observed, forKey: .outcome)
            case .none:
                try c.encode(Tag.none, forKey: .outcome)
            case .undetermined(let cause):
                try c.encode(Tag.undetermined, forKey: .outcome)
                try c.encode(cause, forKey: .cause)
            }
        }
    }

    public let outcome: Outcome
    /// When the attempt was made. Carried so a persisted `PRStatus` can be
    /// labeled display-tier wherever it appears rather than rendered as current
    /// truth — that cache was measured showing "Ready to merge" for pull
    /// requests merged days earlier.
    public let observedAt: Date

    public init(outcome: Outcome, observedAt: Date) {
        self.outcome = outcome
        self.observedAt = observedAt
    }
}

// MARK: - Counters

/// Runaway-input counters for one session: how much has happened lately, and
/// how long the working tree has stood still.
///
/// Every number here is a count of *events*, never of content. `turnsInWindow`
/// counts records appended to the session's transcript JSONL without parsing a
/// single one of them — the file is a version-unstable internal format, and
/// counting appended lines is the one thing that stays true across its changes.
///
/// **Crossing any of these numbers causes nothing to happen here.** There are
/// no thresholds in this type and there will not be any: what counts as a
/// runaway is a project's convention and lives in its shipped sweep program.
/// This type reports numbers; something else decides what they mean.
public struct SessionCounters: Codable, Sendable, Equatable {
    /// Transcript JSONL records appended since `windowStart`.
    public let turnsInWindow: Int
    /// Hook events received since `windowStart`.
    public let hookEventsInWindow: Int
    /// Start of the window both counts are taken over.
    public let windowStart: Date
    /// When the counts were read.
    public let observedAt: Date
    /// Since when the worktree's commits have not changed. nil when that was
    /// not established — distinct from "changed just now".
    public let commitsUnchangedSince: Date?

    public init(
        turnsInWindow: Int,
        hookEventsInWindow: Int,
        windowStart: Date,
        observedAt: Date,
        commitsUnchangedSince: Date? = nil
    ) {
        self.turnsInWindow = turnsInWindow
        self.hookEventsInWindow = hookEventsInWindow
        self.windowStart = windowStart
        self.observedAt = observedAt
        self.commitsUnchangedSince = commitsUnchangedSince
    }
}

// MARK: - Report

/// Everything the state model knows about one terminal, at one moment.
///
/// The optionals are optional because their sources are separately fallible,
/// not because they are unimportant: a session whose transcript could not be
/// read still has a state, and reporting the state without the context load is
/// the honest shape. A caller that needs one of them must handle its absence
/// rather than receiving a filled-in default.
public struct SessionStateReport: Codable, Sendable, Equatable {
    public let terminalID: UUID
    public let worktreeID: UUID
    public let state: SessionState
    public let contextLoad: ContextLoad?
    public let counters: SessionCounters?

    public init(
        terminalID: UUID,
        worktreeID: UUID,
        state: SessionState,
        contextLoad: ContextLoad? = nil,
        counters: SessionCounters? = nil
    ) {
        self.terminalID = terminalID
        self.worktreeID = worktreeID
        self.state = state
        self.contextLoad = contextLoad
        self.counters = counters
    }
}
