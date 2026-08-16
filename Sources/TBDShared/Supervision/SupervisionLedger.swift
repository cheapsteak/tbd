import Foundation

/// The kinds of line `ledger.jsonl` carries (design §6). This slice writes
/// `lifecycle` only.
public enum SupervisionLedgerKind: String, Codable, Sendable {
    case lifecycle
    case delivery
    case enrollment
    case anomaly
}

/// The lifecycle events a line can carry.
public enum SupervisionLifecycleEvent: String, Codable, Sendable {
    case projectOn
    case projectOff
    case brakeEngaged
    case brakeReleased
    case modeChanged
}

/// One agent inside a project's perimeter, as the `projectOn` roster snapshot
/// records it. Mechanical facts only.
public struct SupervisionRosterEntry: Codable, Sendable, Equatable {
    public let worktree: UUID
    public let terminal: UUID
    public let repo: UUID
    /// The project the agent's repo resolved to.
    public let project: String
    public let spawnSource: String
    /// The agent's transcript, or null when TBD does not know it. Null is the
    /// accurate answer; the key is always present.
    public let transcriptPath: String?

    public init(worktree: UUID, terminal: UUID, repo: UUID, project: String,
                spawnSource: String, transcriptPath: String?) {
        self.worktree = worktree
        self.terminal = terminal
        self.repo = repo
        self.project = project
        self.spawnSource = spawnSource
        self.transcriptPath = transcriptPath
    }

    private enum CodingKeys: String, CodingKey {
        case worktree, terminal, repo, project, spawnSource, transcriptPath
    }

    /// Written by hand because synthesized `Codable` *omits* a nil optional,
    /// and an unknown transcript has to read as an explicit null: a missing key
    /// leaves a reader guessing whether the field was unknown or the writer was
    /// an older build.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(worktree, forKey: .worktree)
        try container.encode(terminal, forKey: .terminal)
        try container.encode(repo, forKey: .repo)
        try container.encode(project, forKey: .project)
        try container.encode(spawnSource, forKey: .spawnSource)
        try container.encode(transcriptPath, forKey: .transcriptPath)
    }
}

/// The coverage summary the line ending a span carries (design §6).
///
/// The counters are real fields fed by counters this slice never increments, so
/// zero is accurate rather than fabricated. `spanStartedAt` is null when the
/// record holds no `projectOn` to pair with — a daemon that was not running
/// when the span opened cannot invent one.
public struct SupervisionCoverageSummary: Codable, Sendable, Equatable {
    public let spanStartedAt: SupervisionInstant?
    public let spanEndedAt: SupervisionInstant
    public let durationSeconds: Int?
    public let sweepContacts: Int
    public let briefingsDelivered: Int

    public init(spanStartedAt: SupervisionInstant?, spanEndedAt: SupervisionInstant,
                sweepContacts: Int, briefingsDelivered: Int) {
        self.spanStartedAt = spanStartedAt
        self.spanEndedAt = spanEndedAt
        self.durationSeconds = spanStartedAt.map {
            Int(spanEndedAt.date.timeIntervalSince($0.date).rounded())
        }
        self.sweepContacts = sweepContacts
        self.briefingsDelivered = briefingsDelivered
    }

    private enum CodingKeys: String, CodingKey {
        case spanStartedAt, spanEndedAt, durationSeconds, sweepContacts, briefingsDelivered
    }

    /// Explicit nulls, for the same reason as `SupervisionRosterEntry`: an
    /// unpaired span says so rather than leaving the key out.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(spanStartedAt, forKey: .spanStartedAt)
        try container.encode(spanEndedAt, forKey: .spanEndedAt)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encode(sweepContacts, forKey: .sweepContacts)
        try container.encode(briefingsDelivered, forKey: .briefingsDelivered)
    }
}

/// What a lifecycle line carries beyond its envelope.
public enum SupervisionLedgerPayload: Sendable, Equatable {
    case projectOn(roster: [SupervisionRosterEntry])
    case projectOff(coverage: SupervisionCoverageSummary)
    case brakeEngaged
    case brakeReleased
    case modeChanged(from: String, to: String)
    /// A line whose envelope this build understands and whose body it does
    /// not — a `delivery`, `enrollment` or `anomaly` line, or a lifecycle event
    /// a later build writes.
    ///
    /// **The record is append-only and documented, so a reader will meet lines
    /// it did not write.** Failing to decode them would report a healthy record
    /// as damaged — `Skipped N unreadable line(s)` on every boot, with real
    /// corruption buried in the false alarm. The envelope (`id`, `ts`, `mode`,
    /// `project`, `kind`) is still read, which is all a windowing or grouping
    /// query needs; only the body is skipped.
    case unrecognized

    /// The lifecycle event, or nil for a line this build does not model.
    public var event: SupervisionLifecycleEvent? {
        switch self {
        case .projectOn: return .projectOn
        case .projectOff: return .projectOff
        case .brakeEngaged: return .brakeEngaged
        case .brakeReleased: return .brakeReleased
        case .modeChanged: return .modeChanged
        case .unrecognized: return nil
        }
    }
}

/// One line of `ledger.jsonl`: the envelope `{id, ts, mode, project, kind}`
/// with the payload's fields beside it in the same object.
///
/// **A line is built by the factory for its event, never by a free-form
/// initializer.** `project` and `mode` are null on the lines the daemon writes
/// on its own behalf — the brake's — and null there is the accurate answer, not
/// a gap. Making the brake factories take no project is what keeps a caller
/// from synthesizing one onto a fleet-wide line.
public struct SupervisionLedgerLine: Codable, Sendable, Equatable {
    /// An opaque unique id: a lowercased UUID with the dashes removed.
    public let id: String
    public let ts: SupervisionInstant
    /// The project's active mode at write time; null on fleet-wide lines.
    public let mode: String?
    /// The acting project; null on fleet-wide lines.
    public let project: String?
    public let kind: SupervisionLedgerKind
    public let payload: SupervisionLedgerPayload

    private init(id: String, ts: SupervisionInstant, mode: String?, project: String?,
                 kind: SupervisionLedgerKind, payload: SupervisionLedgerPayload) {
        self.id = id
        self.ts = ts
        self.mode = mode
        self.project = project
        self.kind = kind
        self.payload = payload
    }

    /// A fresh opaque line id.
    public static func newID() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    // MARK: Factories
    //
    // `at:` is required rather than defaulted so no call site can reach for
    // `Date()` inline: persisted timestamps come from the writer's date seam.

    public static func projectOn(
        project: String, mode: String, roster: [SupervisionRosterEntry],
        at date: Date, id: String = SupervisionLedgerLine.newID()
    ) -> SupervisionLedgerLine {
        SupervisionLedgerLine(
            id: id, ts: SupervisionInstant(date), mode: mode, project: project,
            kind: .lifecycle, payload: .projectOn(roster: roster))
    }

    public static func projectOff(
        project: String, mode: String, coverage: SupervisionCoverageSummary,
        at date: Date, id: String = SupervisionLedgerLine.newID()
    ) -> SupervisionLedgerLine {
        SupervisionLedgerLine(
            id: id, ts: SupervisionInstant(date), mode: mode, project: project,
            kind: .lifecycle, payload: .projectOff(coverage: coverage))
    }

    public static func modeChanged(
        project: String, from: String, to: String,
        at date: Date, id: String = SupervisionLedgerLine.newID()
    ) -> SupervisionLedgerLine {
        SupervisionLedgerLine(
            id: id, ts: SupervisionInstant(date), mode: to, project: project,
            kind: .lifecycle, payload: .modeChanged(from: from, to: to))
    }

    /// Fleet-wide: takes no project and no mode, because the brake has neither.
    public static func brakeEngaged(
        at date: Date, id: String = SupervisionLedgerLine.newID()
    ) -> SupervisionLedgerLine {
        SupervisionLedgerLine(
            id: id, ts: SupervisionInstant(date), mode: nil, project: nil,
            kind: .lifecycle, payload: .brakeEngaged)
    }

    /// Fleet-wide: takes no project and no mode, because the brake has neither.
    public static func brakeReleased(
        at date: Date, id: String = SupervisionLedgerLine.newID()
    ) -> SupervisionLedgerLine {
        SupervisionLedgerLine(
            id: id, ts: SupervisionInstant(date), mode: nil, project: nil,
            kind: .lifecycle, payload: .brakeReleased)
    }

    // MARK: Wire form

    private enum CodingKeys: String, CodingKey {
        case id, ts, mode, project, kind
        case event, roster, coverage, from, to
    }

    /// Encoding a `.unrecognized` line throws rather than writing a line whose
    /// body was never parsed: this build only ever writes lines it composed
    /// itself, and re-emitting a half-understood one would silently truncate
    /// somebody else's record. A reader that must reproduce such a line copies
    /// its original bytes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ts, forKey: .ts)
        // `encode`, not `encodeIfPresent`: a fleet-wide line says null rather
        // than leaving the reader to guess why a key is missing.
        try container.encode(mode, forKey: .mode)
        try container.encode(project, forKey: .project)
        try container.encode(kind, forKey: .kind)
        switch payload {
        case .projectOn(let roster):
            try container.encode(SupervisionLifecycleEvent.projectOn, forKey: .event)
            try container.encode(roster, forKey: .roster)
        case .projectOff(let coverage):
            try container.encode(SupervisionLifecycleEvent.projectOff, forKey: .event)
            try container.encode(coverage, forKey: .coverage)
        case .brakeEngaged:
            try container.encode(SupervisionLifecycleEvent.brakeEngaged, forKey: .event)
        case .brakeReleased:
            try container.encode(SupervisionLifecycleEvent.brakeReleased, forKey: .event)
        case .modeChanged(let from, let to):
            try container.encode(SupervisionLifecycleEvent.modeChanged, forKey: .event)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
        case .unrecognized:
            throw EncodingError.invalidValue(payload, EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "a ledger line this build did not parse cannot be re-encoded; "
                    + "copy its original bytes instead"))
        }
    }

    /// Reads the envelope first and the body only for the kinds and events this
    /// build models. A `delivery`, `enrollment` or `anomaly` line — or a
    /// lifecycle event added by a later build — decodes as `.unrecognized`
    /// rather than throwing, because throwing would report an intact
    /// append-only record as corrupt.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        ts = try container.decode(SupervisionInstant.self, forKey: .ts)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        kind = try container.decode(SupervisionLedgerKind.self, forKey: .kind)

        guard kind == .lifecycle else {
            payload = .unrecognized
            return
        }
        let name = try container.decodeIfPresent(String.self, forKey: .event)
        switch name.flatMap(SupervisionLifecycleEvent.init(rawValue:)) {
        case .projectOn:
            payload = .projectOn(
                roster: try container.decodeIfPresent(
                    [SupervisionRosterEntry].self, forKey: .roster) ?? [])
        case .projectOff:
            payload = .projectOff(
                coverage: try container.decode(
                    SupervisionCoverageSummary.self, forKey: .coverage))
        case .brakeEngaged:
            payload = .brakeEngaged
        case .brakeReleased:
            payload = .brakeReleased
        case .modeChanged:
            payload = .modeChanged(
                from: try container.decode(String.self, forKey: .from),
                to: try container.decode(String.self, forKey: .to))
        case nil:
            payload = .unrecognized
        }
    }
}
