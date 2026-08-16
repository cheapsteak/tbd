import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// The two read-only supervision surfaces as a caller reaches them:
/// `supervise.readout` and `supervise.ledger`.
///
/// Tier 2. Both records and the operator's file live in a temp directory the
/// fixture injects, so nothing here touches `~/tbd`.
@Suite("Supervision read-only RPC")
struct SupervisionReadOnlyRPCTests {

    private struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        let directory: URL

        var actuationPath: String {
            directory.appendingPathComponent("actuations.jsonl").path
        }
        var ledgerPath: String {
            directory.appendingPathComponent("ledger.jsonl").path
        }
    }

    private func makeFixture(wireSupervision: Bool = true) throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-readonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: ActuationLog(
                path: directory.appendingPathComponent("actuations.jsonl").path))
        if wireSupervision {
            router.supervision = SupervisionStore(
                files: SupervisionFileStore(
                    fileURL: directory.appendingPathComponent("supervision.json")),
                ledger: SupervisionLedgerWriter(
                    path: directory.appendingPathComponent("ledger.jsonl").path),
                fleet: DatabaseSupervisionFleetReader(db: db))
        }
        return Fixture(router: router, db: db, directory: directory)
    }

    @discardableResult
    private func seed(_ fixture: Fixture, project name: String) async throws -> Terminal {
        let repo = try await fixture.db.repos.create(
            path: "/private/tmp/\(name)", displayName: name, defaultBranch: "main")
        let worktree = try await fixture.db.worktrees.create(
            repoID: repo.id, name: "\(name)-wt", branch: "feature/x",
            path: "/private/tmp/\(name)/wt", tmuxServer: "tbd-\(name)")
        return try await fixture.db.terminals.create(
            worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1", kind: .claude)
    }

    // MARK: - readout

    @Test("supervise.readout answers a project's whole current picture")
    func readoutAnswersThroughRPC() async throws {
        let fixture = try makeFixture()
        let terminal = try await seed(fixture, project: "acme-alpha")

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.superviseReadout,
            params: SuperviseReadoutParams(project: "acme-alpha")))
        #expect(response.success, "\(response.error ?? "")")

        let readout = try response.decodeResult(SupervisionReadout.self)
        #expect(readout.project == "acme-alpha")
        #expect(readout.agents.map(\.terminal) == [terminal.id])
        #expect(readout.supervision.brake == .engaged, "the shipped default, column unset")
        #expect(readout.supervisor.live == false)
    }

    @Test("supervise.readout refuses an unknown project by name")
    func readoutRefusesUnknownProject() async throws {
        let fixture = try makeFixture()
        try await seed(fixture, project: "acme-alpha")

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.superviseReadout,
            params: SuperviseReadoutParams(project: "acme-ghost")))
        #expect(response.success == false)
        #expect(response.error?.contains("There is no project \"acme-ghost\"") == true)
    }

    @Test("supervise.readout refuses when no supervision store is wired")
    func readoutRefusesWithoutAStore() async throws {
        let fixture = try makeFixture(wireSupervision: false)
        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.superviseReadout,
            params: SuperviseReadoutParams(project: "acme-alpha")))
        #expect(response.success == false)
        #expect(response.error?.contains("no supervision store") == true)
    }

    // MARK: - ledger

    @Test("supervise.ledger joins both records for the named project")
    func ledgerAnswersThroughRPC() async throws {
        let fixture = try makeFixture()
        let terminal = try await seed(fixture, project: "acme-alpha")
        let now = Date()

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let row: [String: Any] = [
            "id": "act-1", "ts": formatter.string(from: now.addingTimeInterval(-30)),
            "kind": "wake", "actor": ["kind": "daemon"],
            "target": ["terminal": terminal.id.uuidString],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        try (String(decoding: bytes, as: UTF8.self) + "\n")
            .write(toFile: fixture.actuationPath, atomically: true, encoding: .utf8)

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.superviseLedger,
            params: SuperviseLedgerParams(
                project: "acme-alpha",
                since: SupervisionInstant(now.addingTimeInterval(-600)))))
        #expect(response.success, "\(response.error ?? "")")

        let view = try response.decodeResult(SupervisionLedgerView.self)
        #expect(view.project == "acme-alpha")
        #expect(view.lines.map(\.kind) == ["wake"])
        #expect(view.lines.map(\.source) == [.actuation])
        #expect(view.skipped == SupervisionLedgerViewSkipped(
            actuationLines: 0, supervisionLines: 0))
    }

    @Test("supervise.ledger refuses an unknown project by name")
    func ledgerRefusesUnknownProject() async throws {
        let fixture = try makeFixture()
        try await seed(fixture, project: "acme-alpha")

        let response = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.superviseLedger,
            params: SuperviseLedgerParams(
                project: "acme-ghost", since: SupervisionInstant(Date()))))
        #expect(response.success == false)
        #expect(response.error?.contains("There is no project \"acme-ghost\"") == true)
    }

    // MARK: - What "read-only" does and does not mean

    /// Call both surfaces once, and answer for each that its RPC succeeded.
    private func callBothReadOnlySurfaces(_ fixture: Fixture) async throws {
        for method in [RPCMethod.superviseReadout, RPCMethod.superviseLedger] {
            let params: Data
            if method == RPCMethod.superviseReadout {
                params = try JSONEncoder().encode(
                    SuperviseReadoutParams(project: "acme-alpha"))
            } else {
                params = try JSONEncoder().encode(SuperviseLedgerParams(
                    project: "acme-alpha",
                    since: SupervisionInstant(Date().addingTimeInterval(-600))))
            }
            let response = await fixture.router.handle(RPCRequest(
                method: method, params: String(decoding: params, as: UTF8.self)))
            #expect(response.success, "\(method): \(response.error ?? "")")
        }
    }

    private func ledgerLineCount(_ fixture: Fixture) -> Int {
        guard let data = FileManager.default.contents(atPath: fixture.ledgerPath) else { return 0 }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).count
    }

    /// With nothing left over to reconcile — the ordinary case, and every case
    /// a sweep program hits on a healthy fleet — neither surface puts a byte in
    /// either record.
    @Test("Neither read-only surface writes to either record when there is nothing to reconcile")
    func readOnlySurfacesWriteNothing() async throws {
        let fixture = try makeFixture()
        try await seed(fixture, project: "acme-alpha")

        try await callBothReadOnlySurfaces(fixture)

        #expect(FileManager.default.fileExists(atPath: fixture.ledgerPath) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.actuationPath) == false)
    }

    /// The one append either surface can cause, pinned so the boundary is
    /// documented by a test rather than only by a comment.
    ///
    /// The surfaces resolve their project through `SupervisionStore`, which
    /// reads through the store's reconciliation — so when an operator ends a
    /// project's coverage by hand-editing the supervision file, the first
    /// readout to notice closes the span with a `projectOff` line. That records
    /// the **operator's** decision at the moment TBD observed it; the readout
    /// authored nothing and sent nothing. Skipping the reconciliation would buy
    /// an untouched file at the price of a readout reporting a mark it already
    /// knows is stale.
    @Test("A readout closes a span an operator ended by hand, and says so in the ledger")
    func aReadoutClosesAnOperatorsOrphanedSpan() async throws {
        let fixture = try makeFixture()
        try await seed(fixture, project: "acme-alpha")
        let store = try #require(fixture.router.supervision)
        _ = try await store.setProjectMark(project: "acme-alpha", on: true)
        #expect(ledgerLineCount(fixture) == 1, "the projectOn line the gesture wrote")

        // The operator clears the mark in the file, outside TBD.
        try SupervisionFileStore(
            fileURL: fixture.directory.appendingPathComponent("supervision.json"))
            .save(SupervisionFile())

        try await callBothReadOnlySurfaces(fixture)

        let lines = ledgerLineCount(fixture)
        #expect(lines == 2, "exactly one closing line — the second surface finds nothing left")
        guard let data = FileManager.default.contents(atPath: fixture.ledgerPath),
              let last = data.split(separator: 0x0A, omittingEmptySubsequences: true).last,
              case .projectOff = try JSONDecoder()
                .decode(SupervisionLedgerLine.self, from: Data(last)).payload else {
            Issue.record("the appended line must be the projectOff closing the orphaned span")
            return
        }
        #expect(FileManager.default.fileExists(atPath: fixture.actuationPath) == false,
                "the actuation record is untouched either way — no act happened")
    }
}
