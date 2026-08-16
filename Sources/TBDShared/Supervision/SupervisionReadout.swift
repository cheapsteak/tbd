import Foundation

// MARK: - Params

/// Params for `supervise.readout` — `tbd supervise readout --project <name>`.
///
/// Read-only and free to call: a sweep program's opening move, and equally an
/// operator checking one fact by hand. Nothing here selects or filters, because
/// the readout is the project's whole current picture and a program that got a
/// subset would have to know what it was missing.
public struct SuperviseReadoutParams: Codable, Sendable, Equatable {
    public let project: String

    public init(project: String) { self.project = project }
}

// MARK: - The readout

/// Result of `supervise.readout`: the fact surface of
/// `docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §3.
///
/// An instrument readout — the current values printed for whoever is consuming
/// them, implying no action. Three sections: the supervision machinery's own
/// state, the project's supervisor, and one entry per agent inside the
/// project's perimeter.
///
/// **There is no open-cases section, and there never will be one.** What has
/// already been briefed is the sweep program's own memory (§7), not TBD's — the
/// program's files say what it has raised, and the ledger (`supervise.ledger`)
/// says what the machinery did about it. A reader looking for a list of
/// still-open cases here is looking for a boundary this design drew
/// deliberately: TBD reports facts, and what a fact *means* — whether it is a
/// case, whether that case is still open — is authored territory.
///
/// Every timestamp is a `SupervisionInstant`, so the wire format is a property
/// of the value rather than of whichever encoder happens to touch it, and every
/// optional encodes as an explicit `null`. An unestablished fact says so; it is
/// never a fabricated zero.
public struct SupervisionReadout: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let project: String
    /// When this picture was taken. Every fact below was read at or before it.
    public let generatedAt: SupervisionInstant
    public let supervision: SupervisionReadoutMachinery
    public let supervisor: SupervisionReadoutSupervisor
    public let agents: [SupervisionReadoutAgent]

    public init(project: String, generatedAt: SupervisionInstant,
                supervision: SupervisionReadoutMachinery,
                supervisor: SupervisionReadoutSupervisor,
                agents: [SupervisionReadoutAgent],
                schemaVersion: Int = SupervisionReadout.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.generatedAt = generatedAt
        self.supervision = supervision
        self.supervisor = supervisor
        self.agents = agents
    }
}

// MARK: - Machinery

/// The supervision machinery's own state, as the readout reports it: the fleet
/// brake, the project's mark, and the project's mode.
///
/// This section is what lets a program see for itself when a submission would
/// be refused (§4) — an engaged brake or a cleared mark is the answer to "would
/// `supervise brief` take this", read before composing one rather than
/// discovered by the refusal.
public struct SupervisionReadoutMachinery: Codable, Sendable, Equatable {
    /// The fleet brake. Engaged binds TBD's own hand everywhere, whatever any
    /// project's mark says.
    public let brake: SupervisionBrakeState
    /// The project's mark. Coverage, never protection.
    public let on: Bool
    /// The project's active mode — the name, never a meaning. What a mode
    /// implies lives in the project's playbook.
    public let mode: String
    /// The names an operator may select for this project.
    public let declaredModes: [String]
    /// When the current coverage span opened, or null when the project is off
    /// or the record holds no opening line to pair with.
    public let spanStartedAt: SupervisionInstant?
    /// When a sweep program last made contact, or null when it never has.
    public let lastSweepContactAt: SupervisionInstant?

    public init(brake: SupervisionBrakeState, on: Bool, mode: String,
                declaredModes: [String], spanStartedAt: SupervisionInstant?,
                lastSweepContactAt: SupervisionInstant?) {
        self.brake = brake
        self.on = on
        self.mode = mode
        self.declaredModes = declaredModes
        self.spanStartedAt = spanStartedAt
        self.lastSweepContactAt = lastSweepContactAt
    }

    private enum CodingKeys: String, CodingKey {
        case brake, on, mode, declaredModes, spanStartedAt, lastSweepContactAt
    }

    /// Written by hand because synthesized `Codable` *omits* a nil optional.
    /// A span that never opened and a sweep that never made contact are honest
    /// answers, and they are present and null rather than absent — an absent
    /// key leaves a reader guessing whether the fact was unknown or the writer
    /// was an older build.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(brake, forKey: .brake)
        try container.encode(on, forKey: .on)
        try container.encode(mode, forKey: .mode)
        try container.encode(declaredModes, forKey: .declaredModes)
        try container.encode(spanStartedAt, forKey: .spanStartedAt)
        try container.encode(lastSweepContactAt, forKey: .lastSweepContactAt)
    }
}

// MARK: - Supervisor

/// The project's supervisor, as a session inside the sweep program's perimeter
/// (§3, design §9): what would supervise, and — separately — whether anything
/// does.
///
/// **The nulls here are honest, not stubs to be ignored.** No supervisor is
/// live until briefing delivery lands, so `live` is false and the four facts
/// below it are null on every readout this build produces. A consumer must read
/// `live` and must not infer liveness from a non-null `arrangement`:
/// `arrangement` says what *would* supervise this project — the operator's
/// appointed session where a binding stands, otherwise the hosted desk — and
/// never that anything is standing there now. Reading a present `arrangement`
/// as a running desk is the one mistake this split exists to prevent.
public struct SupervisionReadoutSupervisor: Codable, Sendable, Equatable {
    /// What would supervise this project. Always present, and never a claim
    /// that anything is.
    public let arrangement: SupervisionSupervisorArrangement
    /// The supervisor's session state, with its source and observed-at. Null
    /// while no supervisor is live.
    public let state: SessionState?
    /// When the supervisor last did something the record attests to. Null while
    /// no supervisor is live.
    public let lastAttestedAct: SupervisionInstant?
    /// How full the supervisor's context is, where known. Null while no
    /// supervisor is live.
    public let contextLoad: ContextLoad?
    /// Since when a delivered briefing has stood with no answering desk act —
    /// the age the program's continuation policy judges (§7). Null while no
    /// supervisor is live, and null when nothing is outstanding.
    public let unansweredBriefingSince: SupervisionInstant?
    /// Whether a supervisor is actually standing in the role right now. False
    /// until briefing delivery lands; the four facts above are null whenever it
    /// is false.
    public let live: Bool

    public init(arrangement: SupervisionSupervisorArrangement,
                state: SessionState?,
                lastAttestedAct: SupervisionInstant?,
                contextLoad: ContextLoad?,
                unansweredBriefingSince: SupervisionInstant?,
                live: Bool) {
        self.arrangement = arrangement
        self.state = state
        self.lastAttestedAct = lastAttestedAct
        self.contextLoad = contextLoad
        self.unansweredBriefingSince = unansweredBriefingSince
        self.live = live
    }

    private enum CodingKeys: String, CodingKey {
        case arrangement, state, lastAttestedAct, contextLoad
        case unansweredBriefingSince, live
    }

    /// Written by hand for the reason the whole section exists: these four
    /// nulls are the finding, so they are present and null rather than omitted.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(arrangement, forKey: .arrangement)
        try container.encode(state, forKey: .state)
        try container.encode(lastAttestedAct, forKey: .lastAttestedAct)
        try container.encode(contextLoad, forKey: .contextLoad)
        try container.encode(unansweredBriefingSince, forKey: .unansweredBriefingSince)
        try container.encode(live, forKey: .live)
    }
}

// MARK: - Agents

/// One agent inside the project's perimeter: who it is, what it is doing, what
/// its work looks like, and what stands in the way of acting on it.
public struct SupervisionReadoutAgent: Codable, Sendable, Equatable {
    public let terminal: UUID
    public let worktree: UUID
    public let repo: UUID
    /// What spawned the session — `claude`, `codex`, or `unknown`. A string
    /// rather than an enum because the set grows outside this type, and an
    /// unrecognized kind must survive the readout rather than collapse it.
    public let spawnSource: String
    /// The agent's transcript, or null when TBD does not know it.
    public let transcriptPath: String?
    /// What the agent is doing now, with the source and observed-at that
    /// established it.
    public let state: SessionState
    public let work: SupervisionReadoutWork
    /// The runaway-input counters, or null when the transcript could not be
    /// read. Null is the accurate answer; a zeroed counter block would read as
    /// "nothing happened".
    public let counters: SessionCounters?
    /// Whether the worktree is pinned.
    public let pinned: Bool
    public let notToAct: SupervisionReadoutNotToAct

    public init(terminal: UUID, worktree: UUID, repo: UUID, spawnSource: String,
                transcriptPath: String?, state: SessionState,
                work: SupervisionReadoutWork, counters: SessionCounters?,
                pinned: Bool, notToAct: SupervisionReadoutNotToAct) {
        self.terminal = terminal
        self.worktree = worktree
        self.repo = repo
        self.spawnSource = spawnSource
        self.transcriptPath = transcriptPath
        self.state = state
        self.work = work
        self.counters = counters
        self.pinned = pinned
        self.notToAct = notToAct
    }

    private enum CodingKeys: String, CodingKey {
        case terminal, worktree, repo, spawnSource, transcriptPath
        case state, work, counters, pinned, notToAct
    }

    /// Written by hand: an unknown transcript and an unreadable counter block
    /// are both explicit nulls, never absent keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(terminal, forKey: .terminal)
        try container.encode(worktree, forKey: .worktree)
        try container.encode(repo, forKey: .repo)
        try container.encode(spawnSource, forKey: .spawnSource)
        try container.encode(transcriptPath, forKey: .transcriptPath)
        try container.encode(state, forKey: .state)
        try container.encode(work, forKey: .work)
        try container.encode(counters, forKey: .counters)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(notToAct, forKey: .notToAct)
    }
}

/// What an agent's work looks like: its branch, whether the branch is in
/// conflict, when its commits stopped moving, and its pull request.
///
/// **This type carries no working-tree diff facts, and that is deliberate.**
/// There is no `uncommittedFiles` and no `branchAheadBy`. Every field here is
/// already resolved by the one `git for-each-ref` per repo the conflict sweep
/// runs anyway; answering the diff half would cost a `git status` subprocess
/// per worktree per cycle, which is exactly the per-agent cost this whole
/// readout exists to avoid. `BranchTipTracker`'s doc comment states the same
/// refusal one layer down, over the same evidence.
///
/// An unestablished fact is `null`, never a fabricated zero: a worktree whose
/// tip has only been seen once has no measured stillness to report, and
/// reporting `0` there would read as "changed just now".
public struct SupervisionReadoutWork: Codable, Sendable, Equatable {
    public let branch: String
    /// Whether the branch is in conflict, as the conflict sweep found it.
    public let hasConflicts: Bool
    /// Since when the worktree's commits have stood still, or null when that
    /// was never established — distinct from "changed just now".
    public let commitsUnchangedSince: SupervisionInstant?
    /// The outcome of the last attempt to learn the branch's pull-request
    /// state, or null when no attempt has been made. Carried whole rather than
    /// collapsed, because "the forge answered and there is no PR" and "we could
    /// not find out" are opposite facts.
    public let pr: PRObservation?
    /// The pull request the observation found, or null when it found none or
    /// found nothing out. Read it together with `pr`, never instead of it.
    public let prStatus: PRStatus?

    public init(branch: String, hasConflicts: Bool,
                commitsUnchangedSince: SupervisionInstant?,
                pr: PRObservation?, prStatus: PRStatus?) {
        self.branch = branch
        self.hasConflicts = hasConflicts
        self.commitsUnchangedSince = commitsUnchangedSince
        self.pr = pr
        self.prStatus = prStatus
    }

    private enum CodingKeys: String, CodingKey {
        case branch, hasConflicts, commitsUnchangedSince, pr, prStatus
    }

    /// Written by hand so ignorance is visible: each of the three optionals is
    /// present and null, never omitted.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(branch, forKey: .branch)
        try container.encode(hasConflicts, forKey: .hasConflicts)
        try container.encode(commitsUnchangedSince, forKey: .commitsUnchangedSince)
        try container.encode(pr, forKey: .pr)
        try container.encode(prStatus, forKey: .prStatus)
    }
}

/// The per-target reasons not to act on one agent right now (§3).
///
/// **`interventionInFlight` and `recheckPending` are different facts, and
/// collapsing them would hide the difference between "wait, something is in
/// flight" and "an act went unobserved".** Both come from the same query over
/// the actuation record's delivery rule
/// (`DeliveryRecord.statuses(in:now:deadline:)`):
///
/// - `interventionInFlight` — a verified send to this terminal was dispatched
///   and its observation deadline has not passed (`DeliveryStatus.awaitingObservation`).
///   Nothing is owed and nothing is wrong; another act would be a second act
///   against a target already being acted on.
/// - `recheckPending` — the deadline HAS passed with no confirming observation
///   (`DeliveryStatus.unconfirmed`). A re-check is owed and has not happened,
///   which is a finding a program may want to raise rather than a reason to
///   simply wait.
public struct SupervisionReadoutNotToAct: Codable, Sendable, Equatable {
    public let interventionInFlight: Bool
    public let recheckPending: Bool
    /// When the session's rate limit lifts, or null when it is not rate-limited
    /// or the limit announced no time.
    public let rateLimitedUntil: SupervisionInstant?

    public init(interventionInFlight: Bool, recheckPending: Bool,
                rateLimitedUntil: SupervisionInstant?) {
        self.interventionInFlight = interventionInFlight
        self.recheckPending = recheckPending
        self.rateLimitedUntil = rateLimitedUntil
    }

    private enum CodingKeys: String, CodingKey {
        case interventionInFlight, recheckPending, rateLimitedUntil
    }

    /// Written by hand: "not rate-limited" is an explicit null, not a missing
    /// key.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(interventionInFlight, forKey: .interventionInFlight)
        try container.encode(recheckPending, forKey: .recheckPending)
        try container.encode(rateLimitedUntil, forKey: .rateLimitedUntil)
    }
}
