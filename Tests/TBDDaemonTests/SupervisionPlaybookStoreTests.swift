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

    /// A class rather than a struct so `deinit` reclaims the temp tree when the
    /// test that made it ends — `scripts/test.sh` fences `~/tbd`, `~/.claude`,
    /// `~/.codex` and the tmux socket dir, but not `$TMPDIR`, so a fixture that
    /// only ever creates directories leaks one tree per test unnoticed.
    private final class Fixture {
        let root: URL
        let home: URL
        let checkout: URL
        let repo: SupervisionRepo
        let store: SupervisionStore

        init(root: URL, home: URL, checkout: URL,
             repo: SupervisionRepo, store: SupervisionStore) {
            self.root = root
            self.home = home
            self.checkout = checkout
            self.repo = repo
            self.store = store
        }

        deinit { try? FileManager.default.removeItem(at: root) }

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

    /// `seed` receives the fixture repo's id, which is what a declaration has to
    /// name — so a test that needs a declared project gets one without
    /// rebuilding the whole tree by hand, and inherits the fixture's cleanup.
    private static func makeFixture(
        seed: ((UUID) -> SupervisionFile)? = nil, extraRepos: [SupervisionRepo] = []
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
        if let seed { try files.save(seed(repo.id)) }

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
        let fixture = try Self.makeFixture(seed: { repoID in
            SupervisionFile(projects: [
                "acme-checkout": SupervisionProjectDeclaration(
                    repos: [repoID], policy: .repo(repoID))
            ])
        })

        let written = try await fixture.store.customizePlaybook(
            project: "acme-checkout", level: .operator)
        #expect(written.path == fixture.projectOperatorPath("acme-checkout"))
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    @Test("A project whose policy is the operator level has no repo level to customize")
    func operatorPolicyRefusesRepoCustomize() async throws {
        let fixture = try Self.makeFixture(seed: { repoID in
            SupervisionFile(projects: [
                "acme-checkout": SupervisionProjectDeclaration(repos: [repoID], policy: .operator)
            ])
        })

        await #expect(throws: SupervisionPlaybookError.noRepoLevel(project: "acme-checkout")) {
            try await fixture.store.customizePlaybook(project: "acme-checkout", level: .repo)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.agentsPath),
                "a refused customize writes nothing")
    }

    @Test("customize --repo-level refuses a checkout that is no longer on disk")
    func repoCustomizeRefusesAVanishedCheckout() async throws {
        let fixture = try Self.makeFixture()
        // The repo row survives; its checkout does not. That drift is ordinary
        // — it is why `WorktreeLifecycle+Reconcile` exists.
        try FileManager.default.removeItem(at: fixture.checkout)

        await #expect(throws: SupervisionPlaybookError.missingRepoCheckout(
            project: "acme-web", checkout: fixture.checkout.path)) {
            try await fixture.store.customizePlaybook(project: "acme-web", level: .repo)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.checkout.path),
                "the refusal must not conjure the checkout tree back into existence")

        // And the gesture is still available once the checkout is restored —
        // the refusal is a state, not a permanent verdict.
        try FileManager.default.createDirectory(
            at: fixture.checkout, withIntermediateDirectories: true)
        let written = try await fixture.store.customizePlaybook(
            project: "acme-web", level: .repo)
        #expect(written.path == fixture.agentsPath)
    }
}
