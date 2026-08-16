import Foundation

// MARK: - Params

/// Params for `supervise.ledger` — `tbd supervise ledger --project <name>
/// --since <t>`.
///
/// `since` is absolute rather than a duration: a program asking "what happened
/// since my last evaluation" holds the instant of that evaluation, and a
/// duration would make the answer depend on how long the call took to make.
public struct SuperviseLedgerParams: Codable, Sendable, Equatable {
    public let project: String
    public let since: SupervisionInstant

    public init(project: String, since: SupervisionInstant) {
        self.project = project
        self.since = since
    }
}

// MARK: - The view

/// Result of `supervise.ledger`: the joined per-project view of TBD's own
/// record since a timestamp
/// (`docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §3).
///
/// Two records join here — the actuation record (`~/tbd/actuations.jsonl`),
/// carrying every identified caller's acts against the project's sessions, and
/// the supervision ledger (`ledger.jsonl`), carrying briefing deliveries,
/// lifecycle, enrollment and anomalies. It is how a sweep program closes its
/// loop: which briefings were delivered, whether the desk acted, what came of
/// the acts, and the interventions supervision did *not* make.
///
/// **Lines are passed through verbatim rather than re-modelled, and that is the
/// load-bearing decision in this file.** The actuation record's field list is
/// documented as growing — design §6 pins "the envelope, the set of kinds, and
/// the never-claims" as the contract, not the field list — and the supervision
/// ledger is append-only with kinds this build does not write
/// (`SupervisionLedgerPayload.unrecognized` exists for exactly that). Modelling
/// either one here would mean a later build's `delivery` line, or any field a
/// later build adds, silently vanishing from a query whose entire job is
/// showing a program everything that touched the fleet. So each line is carried
/// as its own JSON object plus the two fields this build computes.
public struct SupervisionLedgerView: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let project: String
    /// The window's lower bound, echoed back so a program can confirm what it
    /// asked for rather than assume it.
    public let since: SupervisionInstant
    public let generatedAt: SupervisionInstant
    /// **One merged array, ascending by `ts` — not two.**
    ///
    /// `docs/cli-supervise.md` commits to `jq '.lines[] | select(.kind=="send")'`,
    /// and the two records' kind vocabularies are disjoint, so a single array
    /// reads correctly for a caller filtering on kind. `source` rides on every
    /// line anyway so provenance never rests on kind-set membership a later
    /// build could break by adding a colliding kind.
    public let lines: [SupervisionLedgerViewLine]
    public let skipped: SupervisionLedgerViewSkipped

    public init(project: String, since: SupervisionInstant,
                generatedAt: SupervisionInstant,
                lines: [SupervisionLedgerViewLine],
                skipped: SupervisionLedgerViewSkipped,
                schemaVersion: Int = SupervisionLedgerView.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.since = since
        self.generatedAt = generatedAt
        self.lines = lines
        self.skipped = skipped
    }
}

/// One line of the joined view: where it came from, the two envelope fields a
/// caller filters and orders on, the computed delivery status where one is
/// owed, and the original object untouched.
public struct SupervisionLedgerViewLine: Codable, Sendable, Equatable {
    /// Which record a line came from. Carried explicitly rather than inferred
    /// from `kind`, so a later build that adds a kind to either record cannot
    /// make a consumer's provenance test start lying.
    public enum Source: String, Codable, Sendable, CaseIterable {
        case actuation
        case supervision
    }

    public let source: Source
    /// The line's kind, lifted out of the original object so a caller can
    /// filter without reaching into `line`. `send`, `outcome`, … from the
    /// actuation record; `lifecycle`, `delivery`, … from the supervision
    /// ledger. A string, not an enum: both vocabularies grow, and a kind this
    /// build has never heard of must still be filterable.
    public let kind: String
    /// The line's timestamp, lifted out for the same reason — the merged array
    /// is ordered on it.
    public let ts: SupervisionInstant
    /// The computed delivery status for a verified send:
    /// `observed:landed-and-acting` and its siblings,
    /// `awaiting-observation`, or `unconfirmed`.
    ///
    /// Null for every line that is owed no observation — which is most of them.
    /// It is computed at query time and never stored: no row ever *says*
    /// `unconfirmed`, because writing a "gave up" row would make the record's
    /// claims depend on a sweep having run.
    public let delivery: String?
    /// The original line, verbatim — every key it carried, including the ones
    /// this build does not model.
    public let line: SupervisionJSONValue

    public init(source: Source, kind: String, ts: SupervisionInstant,
                delivery: String?, line: SupervisionJSONValue) {
        self.source = source
        self.kind = kind
        self.ts = ts
        self.delivery = delivery
        self.line = line
    }

    private enum CodingKeys: String, CodingKey {
        case source, kind, ts, delivery, line
    }

    /// Written by hand because synthesized `Codable` *omits* a nil optional.
    /// "This line is owed no delivery observation" is a fact worth stating, and
    /// an absent key would make it indistinguishable from a build that did not
    /// know how to compute one.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(kind, forKey: .kind)
        try container.encode(ts, forKey: .ts)
        try container.encode(delivery, forKey: .delivery)
        try container.encode(line, forKey: .line)
    }
}

/// How many lines in the window could not be read at all, per record.
///
/// This exists so damage is **visible as damage rather than as a quiet
/// absence**. Both records are append-only files a human may hand-edit and a
/// crash may truncate mid-write; a line that fails to parse is dropped from
/// `lines`, and without a count a reader would see a shorter list and conclude
/// nothing happened. A nonzero number here says "the record is damaged", which
/// is a different finding from "the fleet was quiet" and calls for a different
/// response.
///
/// A line whose *envelope* parses but whose body this build does not model is
/// not skipped — it rides in `lines` verbatim, which is the whole point of
/// passing lines through.
public struct SupervisionLedgerViewSkipped: Codable, Sendable, Equatable {
    public let actuationLines: Int
    public let supervisionLines: Int

    public init(actuationLines: Int, supervisionLines: Int) {
        self.actuationLines = actuationLines
        self.supervisionLines = supervisionLines
    }
}
