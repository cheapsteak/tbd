import Foundation

// MARK: - Params

/// Params for `supervise.brief` — `tbd supervise brief --project <name>` with
/// the briefing text on stdin.
///
/// **Pure text and nothing else.** There is no schema for `text` and there will
/// not be one: representation follows consumer
/// (`docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §1), and
/// the briefing's only reader is a desk — a model reading prose — so no parser
/// exists for a schema to serve. The daemon takes the text as given; it never
/// parses, edits, or ranks it. A structured evaluation report and the thinner
/// "small manifest riding beside the text" variant are both rejected
/// alternatives (§11).
///
/// **An empty `text` is still a submission** — the attested "looked, found
/// nothing" that keeps the project's liveness contact fresh while delivering
/// nothing. That is not a courtesy: it is what makes a quiet fleet
/// distinguishable from a dead sensor.
public struct SuperviseBriefParams: Codable, Sendable, Equatable {
    public let project: String
    public let text: String

    public init(project: String, text: String) {
        self.project = project
        self.text = text
    }
}

// MARK: - Outcome

/// What became of one briefing submission.
///
/// **This vocabulary is contract, pinned by
/// `docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §3.**
/// Values may be added; none may be renamed or repurposed. Programs branch on
/// these strings to decide what to do next, and a renamed value silently turns
/// a handled case into an unhandled one.
///
/// The values have to stay distinguishable rather than collapsing into a
/// generic failure because **TBD makes one full delivery attempt and never
/// retries a briefing** — adapter fallback included. Persistence is the
/// submitting program's, so the result is the whole basis of its continuation
/// policy, and the right continuation differs per value: `refused-paused` means
/// retry when supervision resumes, `refused-off` means stop submitting (off is
/// a standing state, not a pause), `refused-rate-limit` means wait out the
/// window, `refused-size` means compose something smaller, `transport-failed`
/// means re-evaluate on the next cycle, and `no-live-supervisor` means the
/// shipped program runs `on` (ensure) and resubmits in the same run. Collapsing
/// any pair of those would turn a specific next step into a guess.
public enum SupervisionBriefOutcome: String, Codable, Sendable, CaseIterable {
    /// Delivered to the project's supervisor, and recorded.
    case delivered = "delivered"
    /// The fleet brake is engaged. "Not now, retry later" — the CLI exits
    /// `SupervisionBriefing.pausedExitCode`.
    case refusedPaused = "refused-paused"
    /// The project's mark is off. Not covered, rather than not now: a program
    /// should stop submitting rather than retry.
    case refusedOff = "refused-off"
    /// Inside the per-project briefing rate-limit window
    /// (`SupervisionBriefing.rateLimitInterval`). `retryAfter` carries when the
    /// window lifts.
    case refusedRateLimit = "refused-rate-limit"
    /// Larger than `SupervisionBriefing.maxBriefingBytes`.
    case refusedSize = "refused-size"
    /// A live supervisor was resolved and the delivery attempt failed anyway.
    case transportFailed = "transport-failed"
    /// No supervisor is standing in the role, so there was nothing to deliver
    /// to. Distinct from `transport-failed`: nothing was attempted against a
    /// session, and the remedy is to establish a supervisor rather than to
    /// retry the send.
    case noLiveSupervisor = "no-live-supervisor"
}

// MARK: - Result

/// Result of `supervise.brief`: the synchronous, machine-readable answer to one
/// submission.
///
/// Synchronous is the design: TBD makes one full attempt while the caller
/// waits, and what happens next is the caller's policy (§3). There is no
/// asynchronous completion to poll for and no retry queue to inspect.
public struct SupervisionBriefResult: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let project: String
    public let result: SupervisionBriefOutcome
    /// When the submission was taken. Every submission updates the project's
    /// liveness record, refusals included, so this stamp is meaningful on every
    /// outcome rather than only on `delivered`.
    public let submittedAt: SupervisionInstant
    /// One sentence a human reads. Never parsed — the machine-readable answer
    /// is `result`, and a program that branches on this string is branching on
    /// prose that may be reworded.
    public let detail: String
    /// When the rate-limit window lifts. Set on `refused-rate-limit` only, and
    /// null on every other outcome — including the other refusals, whose
    /// remedies are not "wait".
    public let retryAfter: SupervisionInstant?

    public init(project: String, result: SupervisionBriefOutcome,
                submittedAt: SupervisionInstant, detail: String,
                retryAfter: SupervisionInstant?,
                schemaVersion: Int = SupervisionBriefResult.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.result = result
        self.submittedAt = submittedAt
        self.detail = detail
        self.retryAfter = retryAfter
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, project, result, submittedAt, detail, retryAfter
    }

    /// Written by hand because synthesized `Codable` *omits* a nil optional.
    /// "There is no time to retry after" is the answer on six of the seven
    /// outcomes, and it is stated rather than left out.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(project, forKey: .project)
        try container.encode(result, forKey: .result)
        try container.encode(submittedAt, forKey: .submittedAt)
        try container.encode(detail, forKey: .detail)
        try container.encode(retryAfter, forKey: .retryAfter)
    }
}

// MARK: - Compiled defaults

/// The compiled constants the briefing pipe stands on, from
/// `docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §10.
///
/// §10's table splits its numbers into two groups, and these are from the
/// compiled half — the ones TBD itself enforces, as against the thresholds that
/// ship as named constants inside the reference sweep program and belong to it
/// rather than to TBD. They live here, in shared code, so the daemon that
/// enforces them and the CLI that explains them quote one value.
public enum SupervisionBriefing {
    /// The `brief` stdin size bound: 256 KiB (§10). A submission larger than
    /// this is refused with `SupervisionBriefOutcome.refusedSize` rather than
    /// truncated — a briefing delivered with its tail missing would be a
    /// briefing whose omissions the desk cannot see.
    public static let maxBriefingBytes = 256 * 1024

    /// The per-project briefing rate limit: one delivered briefing per project
    /// per 2 minutes (§10).
    ///
    /// Identity-blind and enforced on timestamps alone, which is why it is the
    /// pipe's whole not-to-act check — the per-target reasons need a target,
    /// and a briefing names none. It paces *delivered* briefings only: quiet
    /// contact (an empty submission) is never rate-limited, because throttling
    /// the heartbeat would make a healthy sweep look like a dead one.
    public static let rateLimitInterval: TimeInterval = 120

    /// The exit code `tbd supervise brief` uses for a brake refusal: 75 (§10).
    ///
    /// It follows sysexits' `EX_TEMPFAIL` — "not now, retry later" — which is
    /// exactly what a brake refusal means, and is what lets a shell caller tell
    /// "not now" from "broken" without parsing anything.
    public static let pausedExitCode: Int32 = 75
}
