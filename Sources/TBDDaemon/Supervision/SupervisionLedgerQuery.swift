import Foundation
import os
import TBDShared

private let ledgerQueryLogger = Logger(
    subsystem: "com.tbd.daemon", category: "supervision.ledgerQuery")

/// Builds `supervise.ledger` — the joined per-project view of TBD's own record
/// since an instant
/// (`docs/specs/2026-08-01-fleet-supervision-sweep-program-design.md` §3).
///
/// This query itself opens both records for reading only: it makes no decision,
/// writes nothing, appends nothing, and starts nothing.
///
/// Its RPC handler resolves the project through `SupervisionStore` first, and
/// that resolution reads through the store's reconciliation, which may append a
/// `projectOff` line closing a coverage span an operator ended by hand-editing
/// the supervision file. The line records the **operator's** decision at the
/// moment TBD first noticed it — not one this query made.
///
/// **Lines pass through verbatim.** Each is decoded as a `SupervisionJSONValue`
/// object rather than into a modelled struct, the few envelope keys this build
/// filters and orders on are read out of that value, and the whole original
/// object rides under `line`. A slice-5 `delivery` line, an actuation kind a
/// later build adds, and any field either record grows all survive this query
/// unchanged — which is the entire point of a surface whose job is showing a
/// program *everything* that touched the fleet.
struct SupervisionLedgerQuery: Sendable {
    /// How far before `since` the actuation record is read for the delivery
    /// join.
    ///
    /// `DeliveryRecord.statuses` computes an act's status from the act plus
    /// every outcome row that followed it, walked in record order. Reading only
    /// from `since` would hand it a truncated walk, so a send dispatched just
    /// before the window whose outcome lands inside it could come back with the
    /// wrong standing. So rows are read with this padding and the *emitted* set
    /// is filtered by `since` afterwards — the join sees more than the caller
    /// does, which is what makes the statuses it reports correct.
    static let deliveryJoinLookback: TimeInterval = 60 * 60

    let db: TBDDatabase
    /// The supervision ledger, injected — never derived from `$HOME`.
    let supervisionLedgerPath: String
    let actuationRecord: ActuationRecordReader
    let now: @Sendable () -> Date

    init(
        db: TBDDatabase,
        supervisionLedgerPath: String,
        actuationRecord: ActuationRecordReader,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.db = db
        self.supervisionLedgerPath = supervisionLedgerPath
        self.actuationRecord = actuationRecord
        self.now = now
    }

    // MARK: - The query

    /// - Parameters:
    ///   - project: the project's name, matched against a supervision line's
    ///     own `project` field.
    ///   - projectRepos: the project's member repos, as `SupervisionStore`
    ///     resolved them. An actuation row is in this view exactly when its
    ///     target resolves to one of these — which is the same test as
    ///     "resolve the row's repo to a project and compare", because topology
    ///     puts a repo in at most one project, and it takes the answer from the
    ///     one resolver rather than re-implementing it here.
    func view(
        project: String, projectRepos: Set<UUID>, since: SupervisionInstant
    ) async throws -> SupervisionLedgerView {
        let generatedAt = now()
        var collected: [Collected] = []
        var skippedSupervision = 0
        var skippedActuation = 0

        collectSupervisionLines(
            project: project, since: since,
            into: &collected, skipped: &skippedSupervision)
        try await collectActuationRows(
            projectRepos: projectRepos, since: since, now: generatedAt,
            into: &collected, skipped: &skippedActuation)

        // Stable and total, so two runs over one record produce one order:
        // timestamp, then source, then the line's own id. Ties are real — the
        // instant is millisecond-resolution and both writers stamp from the
        // same clock — and an order that depended on which file was walked
        // first would make a consumer's diff of two queries noise.
        collected.sort {
            if $0.line.ts != $1.line.ts { return $0.line.ts < $1.line.ts }
            if $0.line.source != $1.line.source {
                return $0.line.source.rawValue < $1.line.source.rawValue
            }
            return $0.id < $1.id
        }

        if skippedSupervision > 0 || skippedActuation > 0 {
            ledgerQueryLogger.warning(
                """
                supervise.ledger: skipped \(skippedActuation, privacy: .public) actuation and \
                \(skippedSupervision, privacy: .public) supervision line(s) that would not parse \
                — the counts ride on the result so damage reads as damage.
                """)
        }

        return SupervisionLedgerView(
            project: project,
            since: since,
            generatedAt: SupervisionInstant(generatedAt),
            lines: collected.map(\.line),
            skipped: SupervisionLedgerViewSkipped(
                actuationLines: skippedActuation, supervisionLines: skippedSupervision))
    }

    /// A line on its way into the view, with the id the sort's last tiebreak
    /// needs. The id is not a field of `SupervisionLedgerViewLine` — it already
    /// rides inside `line` — so it is carried beside it rather than added to
    /// the wire type for the sort's benefit.
    private struct Collected {
        let line: SupervisionLedgerViewLine
        let id: String
    }

    // MARK: - The supervision ledger

    private func collectSupervisionLines(
        project: String, since: SupervisionInstant,
        into collected: inout [Collected], skipped: inout Int
    ) {
        guard let data = FileManager.default.contents(atPath: supervisionLedgerPath) else { return }
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = Self.object(from: Data(raw)),
                  let ts = Self.instant(in: object, key: "ts"),
                  let kind = object["kind"]?.stringValue else {
                skipped += 1
                continue
            }
            guard Self.belongsToProject(object, project: project) else { continue }
            guard ts >= since else { continue }
            collected.append(Collected(
                line: SupervisionLedgerViewLine(
                    source: .supervision, kind: kind, ts: ts, delivery: nil,
                    line: .object(object)),
                id: object["id"]?.stringValue ?? ""))
        }
    }

    /// Whether a supervision line belongs in this project's view.
    ///
    /// **A line naming no project is fleet-wide, and fleet-wide lines belong in
    /// every project's view.** That is the one inclusion rule here that is not
    /// "equals the project name", and it is load-bearing: the brake's lifecycle
    /// lines carry no project by construction (`SupervisionLedgerLine.brakeEngaged`
    /// takes none), and a brake engaged at 02:00 is exactly what explains a
    /// project's silence for the rest of the night. A view that hid it would
    /// leave a program reading a quiet fleet as a broken one.
    ///
    /// An absent `project` key is read the same way as an explicit null: JSON
    /// gives the two the same meaning, and the writer emits the key explicitly
    /// so only a hand-edit produces the absent form.
    private static func belongsToProject(
        _ object: [String: SupervisionJSONValue], project: String
    ) -> Bool {
        switch object["project"] {
        case .none, .some(.null): return true
        case .some(.string(let name)): return name == project
        default: return false
        }
    }

    // MARK: - The actuation record

    private func collectActuationRows(
        projectRepos: Set<UUID>, since: SupervisionInstant, now instant: Date,
        into collected: inout [Collected], skipped: inout Int
    ) async throws {
        let joinFrom = since.date.addingTimeInterval(-Self.deliveryJoinLookback)
        let decoder = JSONDecoder()

        // One walk, two readings of every line: the modelled row feeds the
        // delivery join, and the raw object is what the view carries. A row the
        // model cannot decode — a kind a later build added — still gets scoped
        // and emitted from its raw object; only its delivery status is absent,
        // which beats dropping a line the record really holds.
        var rows: [ActuationRow] = []
        var envelopes: [(object: [String: SupervisionJSONValue], ts: SupervisionInstant, kind: String)] = []
        for path in actuationRecord.segmentPaths(since: joinFrom) {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let bytes = Data(raw)
                if let row = try? decoder.decode(ActuationRow.self, from: bytes) {
                    rows.append(row)
                }
                guard let object = Self.object(from: bytes),
                      let ts = Self.instant(in: object, key: "ts"),
                      let kind = object["kind"]?.stringValue else {
                    skipped += 1
                    continue
                }
                envelopes.append((object, ts, kind))
            }
        }

        var deliveries: [String: String] = [:]
        for assessment in DeliveryRecord.statuses(in: rows, now: instant) {
            deliveries[assessment.request.id] = Self.deliveryDescription(assessment.status)
        }

        let resolver = TargetProjectResolver(db: db)
        for envelope in envelopes {
            guard envelope.ts >= since else { continue }
            guard let repoID = await resolver.repo(of: envelope.object["target"]),
                  projectRepos.contains(repoID) else { continue }
            let id = envelope.object["id"]?.stringValue ?? ""
            // Only a request row that armed verification is owed an
            // observation, so only one carries a status. An outcome row is the
            // observation, and a send that never asked for one has no honest
            // status to report — null, not a manufactured verdict.
            let armed = envelope.kind != ActuationKind.outcome.rawValue
                && envelope.object["verify"] == .bool(true)
            collected.append(Collected(
                line: SupervisionLedgerViewLine(
                    source: .actuation, kind: envelope.kind, ts: envelope.ts,
                    delivery: armed ? deliveries[id] : nil,
                    line: .object(envelope.object)),
                id: id))
        }
    }

    private static func deliveryDescription(_ status: DeliveryStatus) -> String {
        switch status {
        case .observed(let result): return "observed:\(result.rawValue)"
        case .awaitingObservation: return "awaiting-observation"
        case .unconfirmed: return "unconfirmed"
        }
    }

    // MARK: - Reading envelopes out of a passed-through line

    private static func object(from data: Data) -> [String: SupervisionJSONValue]? {
        guard let value = try? JSONDecoder().decode(SupervisionJSONValue.self, from: data),
              case .object(let fields) = value else { return nil }
        return fields
    }

    /// One envelope timestamp, in either form the two records write.
    ///
    /// The supervision ledger stamps ISO-8601 UTC with fractional seconds; the
    /// actuation record's own documented example rows are fractionless.
    /// `DeliveryRecord.parseTimestamp` already reads both, and is reused rather
    /// than paired with a second parser that could disagree with it about a row
    /// the delivery join is reading at the same moment.
    private static func instant(
        in object: [String: SupervisionJSONValue], key: String
    ) -> SupervisionInstant? {
        guard let raw = object[key]?.stringValue,
              let date = DeliveryRecord.parseTimestamp(raw) else { return nil }
        return SupervisionInstant(date)
    }
}

// MARK: - Scoping a row to a project

/// Resolves an actuation row's target to the repo whose project owns it,
/// memoizing the two table lookups.
///
/// **Memoized, because a record window holds many rows against few sessions.**
/// One database round trip per row would make a ledger query's cost a function
/// of how busy the fleet was rather than of how many sessions it has.
///
/// **A target that resolves to nothing is excluded by the caller, never passed
/// through on a guess.** A deleted worktree, a remote-provider act carrying no
/// local coordinates, a hand-edited row: none of them can be attributed, and
/// the failure that matters on this surface is one project's query showing
/// another project's lines.
private final class TargetProjectResolver {
    private let db: TBDDatabase
    private var worktreeOfTerminal: [UUID: UUID?] = [:]
    private var repoOfWorktree: [UUID: UUID?] = [:]

    init(db: TBDDatabase) {
        self.db = db
    }

    /// The repo a target resolves to, or nil when it resolves to nothing.
    ///
    /// Terminal first, then worktree, then repo — narrowest coordinate wins,
    /// because it is the one the caller actually named. A terminal that no
    /// longer resolves falls through to the row's worktree rather than
    /// abandoning the row: the coordinates are recorded together and the
    /// coarser one is still true about where the act landed.
    func repo(of target: SupervisionJSONValue?) async -> UUID? {
        guard case .some(.object(let fields)) = target else { return nil }
        if let raw = fields["terminal"]?.stringValue, let terminalID = UUID(uuidString: raw),
           let worktreeID = await worktree(ofTerminal: terminalID),
           let repoID = await repo(ofWorktree: worktreeID) {
            return repoID
        }
        if let raw = fields["worktree"]?.stringValue, let worktreeID = UUID(uuidString: raw),
           let repoID = await repo(ofWorktree: worktreeID) {
            return repoID
        }
        if let raw = fields["repo"]?.stringValue, let repoID = UUID(uuidString: raw) {
            return repoID
        }
        return nil
    }

    private func worktree(ofTerminal terminalID: UUID) async -> UUID? {
        if let cached = worktreeOfTerminal[terminalID] { return cached }
        let resolved = (try? await db.terminals.get(id: terminalID))??.worktreeID
        worktreeOfTerminal[terminalID] = resolved
        return resolved
    }

    private func repo(ofWorktree worktreeID: UUID) async -> UUID? {
        if let cached = repoOfWorktree[worktreeID] { return cached }
        let resolved = (try? await db.worktrees.get(id: worktreeID))??.repoID
        repoOfWorktree[worktreeID] = resolved
        return resolved
    }
}
