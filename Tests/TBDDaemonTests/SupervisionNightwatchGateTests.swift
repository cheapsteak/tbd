import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The coexistence gate between the two supervision paths.
///
/// Nightwatch stays live until the redesign's cutover, so the two are
/// **mutually exclusive rather than sequential**: both drive the same fleet
/// through the same terminals on different theories of who decides what.
/// Each direction refuses the *on* gesture and names the condition — and
/// **neither direction can refuse an `off`**, which is the property that keeps
/// an operator from wedging themselves with the fleet running and no gesture
/// that stops it.
///
/// Tier 2 — in-memory database, tmux in `dryRun`, real filesystem for the
/// supervision files, no clocks.
@Suite("Supervision / Nightwatch coexistence")
struct SupervisionNightwatchGateTests {

    private struct StubFleet: SupervisionFleetReading {
        var repoList: [SupervisionRepo] = []
        func repos() async throws -> [SupervisionRepo] { repoList }
        func agents(inRepos repoIDs: Set<UUID>) async throws -> [SupervisionFleetAgent] { [] }
    }

    private struct Fixture {
        let db: TBDDatabase
        let router: RPCRouter
        let directory: URL
    }

    private static func makeFixture(repos names: [String] = ["acme-web"]) throws -> Fixture {
        let db = try TBDDatabase(inMemory: true)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-supervision-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog())
        router.supervision = SupervisionStore(
            files: SupervisionFileStore(
                fileURL: directory.appendingPathComponent("supervision.json")),
            ledger: SupervisionLedgerWriter(
                path: directory.appendingPathComponent("ledger.jsonl").path),
            fleet: StubFleet(repoList: names.map { SupervisionRepo(id: UUID(), name: $0) }))
        // Deliberately no `supervisionDesks`: the gate is about the mark, and
        // wiring a desk manager here would spawn sessions this suite never
        // looks at.
        return Fixture(db: db, router: router, directory: directory)
    }

    private static func setMark(
        _ fixture: Fixture, _ project: String, on: Bool
    ) async throws -> RPCResponse {
        await fixture.router.handle(try RPCRequest(
            method: RPCMethod.superviseSetProjectMark,
            params: SuperviseSetProjectMarkParams(project: project, on: on)))
    }

    private static func setNightwatch(
        _ fixture: Fixture, _ mode: NightwatchMode
    ) async throws -> RPCResponse {
        await fixture.router.handle(try RPCRequest(
            method: RPCMethod.nightwatchSetMode,
            params: NightwatchSetModeParams(mode: mode)))
    }

    // MARK: - supervise on, while Nightwatch runs

    @Test("`supervise on <project>` is refused while Nightwatch is running")
    func superviseOnRefusedWhileNightwatchRuns() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try await fixture.db.config.setNightwatchMode(.nightwatch)
        let response = try await Self.setMark(fixture, "acme-web", on: true)
        #expect(!response.success)
        let error = try #require(response.error)
        // Names the condition and the way out, rather than failing opaquely.
        #expect(error.contains("Nightwatch is running"))
        #expect(error.contains("tbd nightwatch mode off"))

        // And the mark really did not move: a refusal that half-applied would
        // be worse than either outcome.
        let store = try #require(fixture.router.supervision)
        #expect(try await store.markedProjects().isEmpty)
    }

    @Test("`supervise on <project>` is allowed once Nightwatch is off")
    func superviseOnAllowedWhenNightwatchOff() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try await fixture.db.config.setNightwatchMode(.off)
        let response = try await Self.setMark(fixture, "acme-web", on: true)
        #expect(response.success)
        let store = try #require(fixture.router.supervision)
        #expect(try await store.markedProjects() == ["acme-web"])
    }

    @Test("`supervise off <project>` is never refused, whatever Nightwatch is doing")
    func superviseOffIsNeverRefused() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(try await Self.setMark(fixture, "acme-web", on: true).success)
        // Nightwatch comes up out of band — a hand-edited config, an older
        // build, a race. The operator must still be able to stand down.
        try await fixture.db.config.setNightwatchMode(.daywatch)
        let response = try await Self.setMark(fixture, "acme-web", on: false)
        #expect(response.success)
        let store = try #require(fixture.router.supervision)
        #expect(try await store.markedProjects().isEmpty)
    }

    // MARK: - Nightwatch on, while a project is supervised

    @Test("`nightwatch.setMode` is refused while a project is supervised")
    func nightwatchRefusedWhileProjectSupervised() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(try await Self.setMark(fixture, "acme-web", on: true).success)
        let response = try await Self.setNightwatch(fixture, .nightwatch)
        #expect(!response.success)
        let error = try #require(response.error)
        #expect(error.contains("acme-web"))
        #expect(error.contains("tbd supervise off"))

        // Gated ahead of the DB write, so a refused mode never persists.
        #expect(try await fixture.db.config.get().nightwatchMode == .off)
    }

    @Test("`nightwatch.setMode` is allowed once no project is supervised")
    func nightwatchAllowedWithNoProjectsOn() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(try await Self.setMark(fixture, "acme-web", on: true).success)
        #expect(try await Self.setMark(fixture, "acme-web", on: false).success)
        #expect(try await Self.setNightwatch(fixture, .daywatch).success)
        #expect(try await fixture.db.config.get().nightwatchMode == .daywatch)
    }

    @Test("`nightwatch.setMode off` is never refused, even with projects supervised")
    func nightwatchOffIsNeverRefused() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try await fixture.db.config.setNightwatchMode(.nightwatch)
        // A supervised project alongside a running Nightwatch: reachable
        // through an older build or a hand edit, and exactly the state where a
        // symmetric refusal would leave the operator with no way out.
        let store = try #require(fixture.router.supervision)
        _ = try await store.setProjectMark(project: "acme-web", on: true)

        #expect(try await Self.setNightwatch(fixture, .off).success)
        #expect(try await fixture.db.config.get().nightwatchMode == .off)
    }

    @Test("A daemon with no supervision store does not block Nightwatch")
    func noSupervisionStoreDoesNotBlock() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // Mock mode and unit tests run without a store. Nothing is supervised
        // there by construction, so the gate has nothing to protect.
        fixture.router.supervision = nil
        #expect(try await Self.setNightwatch(fixture, .nightwatch).success)
    }

    // MARK: - A stood-down project is still observable

    @Test("A stood-down project still appears in the readout and the account")
    func stoodDownProjectStaysVisible() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        #expect(try await Self.setMark(fixture, "acme-web", on: true).success)
        #expect(try await Self.setMark(fixture, "acme-web", on: false).success)

        // The account: `supervise status` lists it, off, with its mode.
        let store = try #require(fixture.router.supervision)
        let status = try await store.status(brake: .released)
        let project = try #require(status.projects.first { $0.name == "acme-web" })
        #expect(!project.on)
        #expect(project.mode == "attended")

        // The readout: refused only for a project that does not exist, never
        // for one that is merely off — observability is never withheld.
        let readout = await fixture.router.handle(try RPCRequest(
            method: RPCMethod.superviseReadout,
            params: SuperviseReadoutParams(project: "acme-web")))
        #expect(readout.success)
    }
}
