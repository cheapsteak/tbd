import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// The `supervise.*` surface as the CLI reaches it, plus the brake's ledger
/// lines.
///
/// The store is injected with temp paths, so nothing here writes into
/// `~/tbd/supervision` — and the router deliberately has no default store for
/// exactly that reason.
@Suite("Supervision RPC")
struct SupervisionRPCTests {

    private struct EmptyFleet: SupervisionFleetReading {
        func repos() async throws -> [SupervisionRepo] { [] }
        func agents(inRepos repoIDs: Set<UUID>) async throws -> [SupervisionFleetAgent] { [] }
    }

    private struct Fixture {
        let router: RPCRouter
        let db: TBDDatabase
        let ledgerPath: String
    }

    private func makeFixture(wireSupervision: Bool = true) throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-rpc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledgerPath = directory.appendingPathComponent("ledger.jsonl").path
        if wireSupervision {
            router.supervision = SupervisionStore(
                files: SupervisionFileStore(
                    fileURL: directory.appendingPathComponent("supervision.json")),
                ledger: SupervisionLedgerWriter(path: ledgerPath),
                fleet: EmptyFleet())
        }
        return Fixture(router: router, db: db, ledgerPath: ledgerPath)
    }

    private func setBrake(_ fixture: Fixture, enabled: Bool) async throws {
        let request = try RPCRequest(
            method: RPCMethod.configSetSupervisionEnabled,
            params: ConfigSetSupervisionEnabledParams(enabled: enabled))
        let response = await fixture.router.handle(request)
        #expect(response.success, "\(response.error ?? "")")
    }

    private func lines(at path: String) throws -> [SupervisionLedgerLine] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return try data.split(separator: 0x0A, omittingEmptySubsequences: true).map { raw in
            try JSONDecoder().decode(SupervisionLedgerLine.self, from: Data(raw))
        }
    }

    // MARK: - The brake

    @Test("Releasing and re-engaging the brake each write one fleet-wide line")
    func brakeGesturesAreRecorded() async throws {
        let fixture = try makeFixture()
        try await setBrake(fixture, enabled: true)
        try await setBrake(fixture, enabled: false)

        let decoded = try lines(at: fixture.ledgerPath)
        #expect(decoded.map(\.payload) == [.brakeReleased, .brakeEngaged])
        #expect(decoded.allSatisfy { $0.project == nil && $0.mode == nil })
    }

    @Test("Engaging a brake that already stands engaged writes the column but no line")
    func unchangedBrakeWritesNoLine() async throws {
        let fixture = try makeFixture()
        // The shipped default is engaged, and the column starts unset. Sending
        // `false` is a real gesture on the column — it lifts it out of NULL —
        // and no change at all to what the brake means.
        try await setBrake(fixture, enabled: false)

        #expect(try await fixture.db.config.get().supervisionEnabled == false)
        #expect(try lines(at: fixture.ledgerPath).isEmpty)
    }

    @Test("The brake write reports the resolved value it replaced")
    func brakeWriteReportsWhatItReplaced() async throws {
        let db = try TBDDatabase(inMemory: true)

        // The column starts unset, so the value being replaced is the shipped
        // default rather than a written one — the distinction that stops an
        // opening `off` from being recorded as a transition.
        let firstPrevious = try await db.config.setSupervisionEnabled(enabled: false)
        #expect(firstPrevious == Config.supervisionEnabledDefault)

        let secondPrevious = try await db.config.setSupervisionEnabled(enabled: true)
        #expect(secondPrevious == false, "now reading the written value, not the default")

        let thirdPrevious = try await db.config.setSupervisionEnabled(enabled: true)
        #expect(thirdPrevious == true, "a repeat reports no transition")
    }

    @Test("A released brake with no projects reports the loud case through RPC")
    func statusReportsTheLoudCase() async throws {
        let fixture = try makeFixture()
        try await setBrake(fixture, enabled: true)

        let response = await fixture.router.handle(
            RPCRequest(method: RPCMethod.superviseStatus))
        #expect(response.success, "\(response.error ?? "")")
        let status = try response.decodeResult(SupervisionStatus.self)
        #expect(status.brake == .released)
        #expect(status.effectivelySupervising == false)
        #expect(status.warnings.map(\.code) == [.noProjectsOn])
        #expect(status.projects.isEmpty)
    }

    @Test("The status readout follows the brake column")
    func statusFollowsTheBrakeColumn() async throws {
        let fixture = try makeFixture()

        let engaged = try await fixture.router.handle(
            RPCRequest(method: RPCMethod.superviseStatus))
            .decodeResult(SupervisionStatus.self)
        #expect(engaged.brake == .engaged, "shipped default, with the column unset")

        try await setBrake(fixture, enabled: true)
        let released = try await fixture.router.handle(
            RPCRequest(method: RPCMethod.superviseStatus))
            .decodeResult(SupervisionStatus.self)
        #expect(released.brake == .released)
    }

    // MARK: - Refusals

    @Test("A daemon with no supervision store refuses rather than crashing")
    func unwiredSupervisionRefuses() async throws {
        let fixture = try makeFixture(wireSupervision: false)
        let response = await fixture.router.handle(
            RPCRequest(method: RPCMethod.superviseStatus))
        #expect(response.success == false)
        #expect(response.error?.contains("no supervision store") == true)
    }

    @Test("The brake still moves when no supervision store is wired")
    func brakeWorksWithoutAStore() async throws {
        let fixture = try makeFixture(wireSupervision: false)
        try await setBrake(fixture, enabled: true)
        #expect(try await fixture.db.config.get().supervisionEnabled == true)
    }

    @Test("An unknown project is refused by name, and the topology still lists")
    func unknownProjectIsRefused() async throws {
        let fixture = try makeFixture()
        let request = try RPCRequest(
            method: RPCMethod.superviseSetProjectMark,
            params: SuperviseSetProjectMarkParams(project: "acme-platform", on: true))
        let response = await fixture.router.handle(request)
        #expect(response.success == false)
        #expect(response.error?.contains("acme-platform") == true)

        let listed = try await fixture.router.handle(
            RPCRequest(method: RPCMethod.superviseProjectList))
            .decodeResult(SuperviseProjectListResult.self)
        #expect(listed.projects.isEmpty)
    }
}
