import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// `supervise.ledger` — the joined per-project view of both records.
///
/// Tier 2, on a real temp filesystem with every path injected. The fixture is
/// deliberately **two projects**: the failure this surface must not have is one
/// project's query showing another project's lines, and a single-project
/// fixture cannot see it.
@Suite("Supervision ledger query")
struct SupervisionLedgerQueryTests {

    // MARK: - Fixture

    private struct Project {
        let name: String
        let repo: Repo
        let worktree: Worktree
        let terminal: Terminal
    }

    private struct Fixture {
        let db: TBDDatabase
        let directory: URL
        let store: SupervisionStore
        let now: Date
        let alpha: Project
        let beta: Project

        var ledgerPath: String {
            directory.appendingPathComponent("ledger.jsonl").path
        }
        var actuationPath: String {
            directory.appendingPathComponent("actuations.jsonl").path
        }

        func query() -> SupervisionLedgerQuery {
            let stamp = now
            return SupervisionLedgerQuery(
                db: db,
                supervisionLedgerPath: ledgerPath,
                actuationRecord: ActuationRecordReader(activePath: actuationPath),
                now: { stamp })
        }

        func write(_ lines: [String], to path: String) throws {
            try (lines.joined(separator: "\n") + "\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
        }

        func view(_ project: Project, since: Date) async throws -> SupervisionLedgerView {
            let facts = try await store.projectFacts(project: project.name, brake: .released)
            return try await query().view(
                project: project.name,
                projectRepos: Set(facts.project.repos),
                since: SupervisionInstant(since))
        }
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_786_000_000)

    private func makeFixture() async throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SupervisionStore(
            files: SupervisionFileStore(
                fileURL: directory.appendingPathComponent("supervision.json")),
            ledger: SupervisionLedgerWriter(
                path: directory.appendingPathComponent("ledger.jsonl").path),
            fleet: DatabaseSupervisionFleetReader(db: db))
        return Fixture(
            db: db,
            directory: directory,
            store: store,
            now: Self.fixedNow,
            alpha: try await makeProject(db, name: "acme-alpha"),
            beta: try await makeProject(db, name: "acme-beta"))
    }

    private func makeProject(_ db: TBDDatabase, name: String) async throws -> Project {
        let repo = try await db.repos.create(
            path: "/private/tmp/\(name)", displayName: name, defaultBranch: "main")
        let worktree = try await db.worktrees.create(
            repoID: repo.id, name: "\(name)-wt", branch: "feature/x",
            path: "/private/tmp/\(name)/wt", tmuxServer: "tbd-\(name)")
        let terminal = try await db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
        return Project(name: name, repo: repo, worktree: worktree, terminal: terminal)
    }

    // MARK: - Line builders

    private static func actuationStamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func line(_ fields: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func actuation(
        id: String, at date: Date, kind: String = "send",
        target: [String: String]? = nil, extra: [String: Any] = [:]
    ) -> String {
        var fields: [String: Any] = [
            "id": id, "ts": actuationStamp(date), "kind": kind,
            "actor": ["kind": "daemon"],
        ]
        if let target { fields["target"] = target }
        for (key, value) in extra { fields[key] = value }
        return line(fields)
    }

    private static func supervision(
        id: String, at date: Date, kind: String = "lifecycle",
        project: Any = NSNull(), extra: [String: Any] = [:]
    ) -> String {
        var fields: [String: Any] = [
            "id": id, "ts": SupervisionInstant(date).wireValue, "kind": kind,
            "project": project, "mode": NSNull(),
        ]
        for (key, value) in extra { fields[key] = value }
        return line(fields)
    }

    private func ids(_ view: SupervisionLedgerView) -> [String] {
        view.lines.compactMap {
            guard case .object(let fields) = $0.line else { return nil }
            return fields["id"]?.stringValue
        }
    }

    // MARK: - Scoping

    @Test("Neither project's view carries the other's actuation rows")
    func viewsDoNotLeakAcrossProjects() async throws {
        let fixture = try await makeFixture()
        let since = fixture.now.addingTimeInterval(-600)
        try fixture.write([
            Self.actuation(
                id: "alpha-send", at: fixture.now.addingTimeInterval(-300),
                target: ["terminal": fixture.alpha.terminal.id.uuidString,
                         "worktree": fixture.alpha.worktree.id.uuidString]),
            Self.actuation(
                id: "beta-send", at: fixture.now.addingTimeInterval(-200),
                target: ["terminal": fixture.beta.terminal.id.uuidString,
                         "worktree": fixture.beta.worktree.id.uuidString]),
            Self.actuation(
                id: "alpha-repo-sweep", at: fixture.now.addingTimeInterval(-100),
                kind: "dispose", target: ["repo": fixture.alpha.repo.id.uuidString]),
        ], to: fixture.actuationPath)

        #expect(try await ids(fixture.view(fixture.alpha, since: since))
            == ["alpha-send", "alpha-repo-sweep"])
        #expect(try await ids(fixture.view(fixture.beta, since: since)) == ["beta-send"])
    }

    @Test("A row whose target no longer resolves is in no project's view")
    func unresolvableTargetIsExcludedEverywhere() async throws {
        let fixture = try await makeFixture()
        let since = fixture.now.addingTimeInterval(-600)
        try fixture.write([
            Self.actuation(
                id: "alpha-send", at: fixture.now.addingTimeInterval(-300),
                target: ["terminal": fixture.alpha.terminal.id.uuidString]),
            // A worktree and terminal deleted since the act — nothing left to
            // resolve, so it is dropped rather than guessed into a project.
            Self.actuation(
                id: "ghost", at: fixture.now.addingTimeInterval(-250),
                target: ["terminal": UUID().uuidString, "worktree": UUID().uuidString]),
            // A remote-provider act with no local coordinates at all.
            Self.actuation(
                id: "remote", at: fixture.now.addingTimeInterval(-240),
                target: ["provider": "acme-cloud", "session": "s-1"]),
            Self.actuation(
                id: "beta-send", at: fixture.now.addingTimeInterval(-200),
                target: ["terminal": fixture.beta.terminal.id.uuidString]),
        ], to: fixture.actuationPath)

        #expect(try await ids(fixture.view(fixture.alpha, since: since)) == ["alpha-send"])
        #expect(try await ids(fixture.view(fixture.beta, since: since)) == ["beta-send"])
    }

    @Test("A fleet-wide supervision line appears in every project's view")
    func fleetWideLinesAppearEverywhere() async throws {
        let fixture = try await makeFixture()
        let since = fixture.now.addingTimeInterval(-600)
        try fixture.write([
            // The brake carries no project by construction, and it is exactly
            // what explains a project's silence afterwards.
            Self.supervision(
                id: "brake", at: fixture.now.addingTimeInterval(-500),
                extra: ["event": "brakeEngaged"]),
            Self.supervision(
                id: "alpha-on", at: fixture.now.addingTimeInterval(-400),
                project: "acme-alpha", extra: ["event": "projectOn", "roster": []]),
        ], to: fixture.ledgerPath)

        #expect(try await ids(fixture.view(fixture.alpha, since: since)) == ["brake", "alpha-on"])
        #expect(try await ids(fixture.view(fixture.beta, since: since)) == ["brake"])
    }

    @Test("Only lines at or after `since` are emitted")
    func theWindowBoundsTheEmittedSet() async throws {
        let fixture = try await makeFixture()
        try fixture.write([
            Self.actuation(
                id: "before", at: fixture.now.addingTimeInterval(-900),
                target: ["terminal": fixture.alpha.terminal.id.uuidString]),
            Self.actuation(
                id: "after", at: fixture.now.addingTimeInterval(-100),
                target: ["terminal": fixture.alpha.terminal.id.uuidString]),
        ], to: fixture.actuationPath)

        let view = try await fixture.view(fixture.alpha, since: fixture.now.addingTimeInterval(-600))
        #expect(ids(view) == ["after"])
        #expect(view.since == SupervisionInstant(fixture.now.addingTimeInterval(-600)))
        #expect(view.generatedAt == SupervisionInstant(fixture.now))
        #expect(view.schemaVersion == SupervisionLedgerView.currentSchemaVersion)
    }

    // MARK: - Passing lines through

    @Test("A supervision line of an unmodelled kind rides through with every key intact")
    func unmodelledSupervisionLinePassesThroughVerbatim() async throws {
        let fixture = try await makeFixture()
        try fixture.write([
            Self.supervision(
                id: "delivery-1", at: fixture.now.addingTimeInterval(-100),
                kind: "delivery", project: "acme-alpha",
                extra: [
                    "textHash": "sha256:abc123",
                    "conductHash": "sha256:def456",
                    "supervisor": ["kind": "hostedDesk", "terminal": NSNull()],
                    "attempts": 1,
                    "fieldsThisBuildHasNeverHeardOf": ["one", "two"],
                ]),
        ], to: fixture.ledgerPath)

        let view = try await fixture.view(
            fixture.alpha, since: fixture.now.addingTimeInterval(-600))
        let entry = try #require(view.lines.first)
        #expect(view.lines.count == 1)
        #expect(entry.source == .supervision)
        #expect(entry.kind == "delivery")
        #expect(entry.delivery == nil)
        guard case .object(let fields) = entry.line else {
            Issue.record("the line was not carried as its own JSON object")
            return
        }
        #expect(fields["textHash"] == .string("sha256:abc123"))
        #expect(fields["conductHash"] == .string("sha256:def456"))
        #expect(fields["attempts"] == .integer(1))
        #expect(fields["supervisor"] == .object(["kind": .string("hostedDesk"), "terminal": .null]))
        #expect(fields["fieldsThisBuildHasNeverHeardOf"]
            == .array([.string("one"), .string("two")]))
        // An unmodelled body is not damage: it rides in `lines`, and the
        // skipped counts stay zero.
        #expect(view.skipped == SupervisionLedgerViewSkipped(
            actuationLines: 0, supervisionLines: 0))
    }

    @Test("A corrupt line is counted and the rest of the query still runs")
    func corruptLinesAreCountedNotSwallowed() async throws {
        let fixture = try await makeFixture()
        let since = fixture.now.addingTimeInterval(-600)
        try fixture.write([
            Self.supervision(
                id: "good-1", at: fixture.now.addingTimeInterval(-300),
                extra: ["event": "brakeEngaged"]),
            "{this is not json",
            Self.supervision(
                id: "good-2", at: fixture.now.addingTimeInterval(-200),
                extra: ["event": "brakeReleased"]),
        ], to: fixture.ledgerPath)
        try fixture.write([
            Self.actuation(
                id: "act-good", at: fixture.now.addingTimeInterval(-250),
                target: ["terminal": fixture.alpha.terminal.id.uuidString]),
            "]]] torn write",
        ], to: fixture.actuationPath)

        let view = try await fixture.view(fixture.alpha, since: since)
        #expect(ids(view) == ["good-1", "act-good", "good-2"])
        #expect(view.skipped == SupervisionLedgerViewSkipped(
            actuationLines: 1, supervisionLines: 1))
    }

    // MARK: - The delivery join

    @Test("Delivery is computed only for a request row that armed verification")
    func deliveryIsComputedForVerifiedRequestsOnly() async throws {
        let fixture = try await makeFixture()
        let since = fixture.now.addingTimeInterval(-600)
        let terminal = fixture.alpha.terminal.id.uuidString
        try fixture.write([
            Self.actuation(
                id: "plain", at: fixture.now.addingTimeInterval(-300),
                target: ["terminal": terminal]),
            Self.actuation(
                id: "armed-awaiting", at: fixture.now.addingTimeInterval(-10),
                target: ["terminal": terminal], extra: ["verify": true]),
            Self.actuation(
                id: "armed-stale", at: fixture.now.addingTimeInterval(-300),
                target: ["terminal": terminal], extra: ["verify": true]),
            Self.actuation(
                id: "armed-observed", at: fixture.now.addingTimeInterval(-280),
                target: ["terminal": terminal], extra: ["verify": true]),
            Self.actuation(
                id: "outcome-1", at: fixture.now.addingTimeInterval(-270), kind: "outcome",
                target: ["terminal": terminal],
                extra: ["confirms": "armed-observed", "result": "landed-and-acting"]),
        ], to: fixture.actuationPath)

        let view = try await fixture.view(fixture.alpha, since: since)
        var deliveries: [String: String?] = [:]
        for entry in view.lines {
            guard case .object(let fields) = entry.line,
                  let id = fields["id"]?.stringValue else { continue }
            deliveries[id] = entry.delivery
        }
        #expect(deliveries["plain"] == .some(nil))
        #expect(deliveries["armed-awaiting"] == .some("awaiting-observation"))
        #expect(deliveries["armed-stale"] == .some("unconfirmed"))
        #expect(deliveries["armed-observed"] == .some("observed:landed-and-acting"))
        #expect(deliveries["outcome-1"] == .some(nil))
    }

    @Test("The join reads past `since` so a send just before the window keeps its status")
    func theJoinReadsPastTheWindow() async throws {
        let fixture = try await makeFixture()
        let terminal = fixture.alpha.terminal.id.uuidString
        try fixture.write([
            // Dispatched before the window; observed inside it. Only the
            // outcome row is emitted, and it is the padded read that lets the
            // join see the request it confirms.
            Self.actuation(
                id: "armed", at: fixture.now.addingTimeInterval(-900),
                target: ["terminal": terminal], extra: ["verify": true]),
            Self.actuation(
                id: "outcome", at: fixture.now.addingTimeInterval(-100), kind: "outcome",
                target: ["terminal": terminal],
                extra: ["confirms": "armed", "result": "landed-and-acting"]),
        ], to: fixture.actuationPath)

        let view = try await fixture.view(
            fixture.alpha, since: fixture.now.addingTimeInterval(-600))
        #expect(ids(view) == ["outcome"])
    }

    // MARK: - Ordering

    @Test("Lines from both records merge into one array, ascending and stably ordered")
    func linesMergeInTimestampOrder() async throws {
        let fixture = try await makeFixture()
        let since = fixture.now.addingTimeInterval(-600)
        let tied = fixture.now.addingTimeInterval(-200)
        try fixture.write([
            Self.supervision(
                id: "sup-late", at: fixture.now.addingTimeInterval(-100),
                extra: ["event": "brakeReleased"]),
            Self.supervision(id: "sup-tied", at: tied, extra: ["event": "brakeEngaged"]),
        ], to: fixture.ledgerPath)
        try fixture.write([
            Self.actuation(
                id: "act-early", at: fixture.now.addingTimeInterval(-400),
                target: ["terminal": fixture.alpha.terminal.id.uuidString]),
            Self.actuation(
                id: "act-tied", at: tied,
                target: ["terminal": fixture.alpha.terminal.id.uuidString]),
        ], to: fixture.actuationPath)

        let view = try await fixture.view(fixture.alpha, since: since)
        // Ties break on `source` first — `actuation` before `supervision` —
        // so two runs over one record produce one order.
        #expect(ids(view) == ["act-early", "act-tied", "sup-tied", "sup-late"])
        #expect(view.lines.map(\.source)
            == [.actuation, .actuation, .supervision, .supervision])
        #expect(view.lines.map(\.ts) == view.lines.map(\.ts).sorted())
    }
}
