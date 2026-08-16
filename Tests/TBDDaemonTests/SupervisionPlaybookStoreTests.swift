import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — real filesystem, no clocks, no subprocesses.
///
/// The store's own paths are injected (`SupervisionFileStore(fileURL:)`,
/// `SupervisionLedgerWriter(path:)`) and the playbook resolver is handed an
/// explicit environment, so this suite never touches `TBD_HOME` — the process
/// global only `TBDHomeSerialized` may mutate.
@Suite("Supervision playbook, through the store")
struct SupervisionPlaybookStoreTests {

    private struct StubFleet: SupervisionFleetReading {
        var repoList: [SupervisionRepo] = []

        func repos() async throws -> [SupervisionRepo] { repoList }
        func agents(inRepos repoIDs: Set<UUID>) async throws -> [SupervisionFleetAgent] { [] }
    }

    private struct Fixture {
        let root: URL
        let home: URL
        let checkout: URL
        let repo: SupervisionRepo
        let store: SupervisionStore

        var environment: [String: String] { ["TBD_HOME": home.path] }

        var repoOperatorPath: String {
            TBDConstants.repoPlaybookPath(repoID: repo.id, environment: environment)
        }
        var agentsPath: String {
            TBDConstants.repoAgentsPlaybookPath(checkout: checkout.path)
        }
        func projectOperatorPath(_ project: String) -> String {
            TBDConstants.supervisionPlaybookPath(project: project, environment: environment)!
        }
    }

    private static func makeFixture(
        seed: SupervisionFile? = nil, extraRepos: [SupervisionRepo] = []
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-playbook-store-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("tbd", isDirectory: true)
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)

        let repo = SupervisionRepo(id: UUID(), name: "acme-web", path: checkout.path)
        let files = SupervisionFileStore(
            fileURL: home.appendingPathComponent("supervision.json"))
        if let seed { try files.save(seed) }

        return Fixture(
            root: root, home: home, checkout: checkout, repo: repo,
            store: SupervisionStore(
                files: files,
                ledger: SupervisionLedgerWriter(path: home.appendingPathComponent("ledger.jsonl").path),
                fleet: StubFleet(repoList: [repo] + extraRepos),
                playbooks: SupervisionPlaybookResolver(environment: ["TBD_HOME": home.path]),
                now: TestDateSource().provider))
    }

    // MARK: - show

    @Test("A project with no file of its own resolves the shipped default")
    func showFallsBackToShipped() async throws {
        let fixture = try Self.makeFixture()
        let view = try await fixture.store.playbook(project: "acme-web")
        #expect(view.tier == .shipped)
        #expect(view.path == nil)
        #expect(view.hash == SupervisionPlaybook.hash(of: SupervisionPlaybookContent.bytes))
        #expect(view.content == SupervisionPlaybookContent.body)
    }

    @Test("An unknown project is refused rather than answered with the shipped default")
    func showRefusesUnknownProject() async throws {
        let fixture = try Self.makeFixture()
        await #expect(throws: SupervisionStoreError.unknownProject("nope")) {
            try await fixture.store.playbook(project: "nope")
        }
    }

    // MARK: - customize, write-once

    @Test("customize writes the operator level once and refuses the second call")
    func customizeWritesOnceAtTheOperatorLevel() async throws {
        let fixture = try Self.makeFixture()

        let first = try await fixture.store.customizePlaybook(
            project: "acme-web", level: .operator)
        #expect(first.path == fixture.repoOperatorPath)
        #expect(first.hash == SupervisionPlaybook.hash(of: SupervisionPlaybookContent.bytes))

        // The operator edits their copy. That edit is what a second call must
        // not be able to destroy.
        let edited = Data("MY OWN CONDUCT\n".utf8)
        try edited.write(to: URL(fileURLWithPath: first.path))

        await #expect(throws: SupervisionPlaybookError.alreadyCustomized(
            project: "acme-web", level: .operator, path: first.path)) {
            try await fixture.store.customizePlaybook(project: "acme-web", level: .operator)
        }
        #expect(FileManager.default.contents(atPath: first.path) == edited,
                "the refused second call must leave the first file's bytes untouched")

        // And the edited copy is what resolves.
        let view = try await fixture.store.playbook(project: "acme-web")
        #expect(view.tier == .operator)
        #expect(view.content == "MY OWN CONDUCT\n")
    }

    @Test("customize --repo writes the designated repo's .agents file, once")
    func customizeWritesTheRepoLevelOnce() async throws {
        let fixture = try Self.makeFixture()

        let first = try await fixture.store.customizePlaybook(project: "acme-web", level: .repo)
        #expect(first.path == fixture.agentsPath)
        #expect(FileManager.default.contents(atPath: first.path)
            == SupervisionPlaybookContent.bytes)

        let edited = Data("SHARED CONDUCT\n".utf8)
        try edited.write(to: URL(fileURLWithPath: first.path))
        await #expect(throws: SupervisionPlaybookError.alreadyCustomized(
            project: "acme-web", level: .repo, path: first.path)) {
            try await fixture.store.customizePlaybook(project: "acme-web", level: .repo)
        }
        #expect(FileManager.default.contents(atPath: first.path) == edited)
    }

    @Test("customize copies the shipped default even when a level above it already stands")
    func customizeCopiesTheShippedDefaultNotTheResolvedPlaybook() async throws {
        let fixture = try Self.makeFixture()
        _ = try await fixture.store.customizePlaybook(project: "acme-web", level: .operator)
        try Data("OPERATOR ONLY\n".utf8).write(
            to: URL(fileURLWithPath: fixture.repoOperatorPath))

        let repoLevel = try await fixture.store.customizePlaybook(
            project: "acme-web", level: .repo)
        #expect(FileManager.default.contents(atPath: repoLevel.path)
            == SupervisionPlaybookContent.bytes,
            "the gesture means \"give me the tool's default\", never \"duplicate the level above\"")
    }

    @Test("A declared project customizes beside its definition")
    func declaredProjectCustomizesItsProjectDirectory() async throws {
        let repoID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-playbook-store-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("tbd", isDirectory: true)
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let repo = SupervisionRepo(id: repoID, name: "acme-web", path: checkout.path)
        let files = SupervisionFileStore(
            fileURL: home.appendingPathComponent("supervision.json"))
        try files.save(SupervisionFile(projects: [
            "acme-checkout": SupervisionProjectDeclaration(repos: [repoID], policy: .repo(repoID))
        ]))
        let store = SupervisionStore(
            files: files,
            ledger: SupervisionLedgerWriter(path: home.appendingPathComponent("ledger.jsonl").path),
            fleet: StubFleet(repoList: [repo]),
            playbooks: SupervisionPlaybookResolver(environment: ["TBD_HOME": home.path]),
            now: TestDateSource().provider)

        let written = try await store.customizePlaybook(project: "acme-checkout", level: .operator)
        #expect(written.path == TBDConstants.supervisionPlaybookPath(
            project: "acme-checkout", environment: ["TBD_HOME": home.path]))
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    @Test("A project whose policy is the operator level has no repo level to customize")
    func operatorPolicyRefusesRepoCustomize() async throws {
        let repoID = UUID()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-playbook-store-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("tbd", isDirectory: true)
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let repo = SupervisionRepo(id: repoID, name: "acme-web", path: checkout.path)
        let files = SupervisionFileStore(
            fileURL: home.appendingPathComponent("supervision.json"))
        try files.save(SupervisionFile(projects: [
            "acme-checkout": SupervisionProjectDeclaration(repos: [repoID], policy: .operator)
        ]))
        let store = SupervisionStore(
            files: files,
            ledger: SupervisionLedgerWriter(path: home.appendingPathComponent("ledger.jsonl").path),
            fleet: StubFleet(repoList: [repo]),
            playbooks: SupervisionPlaybookResolver(environment: ["TBD_HOME": home.path]),
            now: TestDateSource().provider)

        await #expect(throws: SupervisionPlaybookError.noRepoLevel(project: "acme-checkout")) {
            try await store.customizePlaybook(project: "acme-checkout", level: .repo)
        }
        #expect(!FileManager.default.fileExists(
            atPath: TBDConstants.repoAgentsPlaybookPath(checkout: checkout.path)),
            "a refused customize writes nothing")
    }
}
