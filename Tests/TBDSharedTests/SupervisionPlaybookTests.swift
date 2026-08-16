import Foundation
import Testing
@testable import TBDShared

/// Tier 1 — real filesystem under a per-test temp directory, no clocks, no
/// subprocesses, no daemon.
///
/// Every path comes from `TBDConstants.*(environment:)` through the resolver's
/// injected environment, so nothing here touches the developer's real `~/tbd`
/// and no `setenv` is needed — this target may not call one at all.
@Suite("Supervision playbook resolution")
struct SupervisionPlaybookTests {

    // MARK: - Fixture

    /// A fenced `TBD_HOME` plus a fake repo checkout, and the resolver over it.
    ///
    /// A class rather than a struct so `deinit` reclaims the temp tree when the
    /// test that made it ends. `scripts/test.sh` fences `~/tbd`, `~/.claude`,
    /// `~/.codex` and the tmux socket dir but not `$TMPDIR`, so a fixture that
    /// only ever creates directories leaks silently at one tree per test — the
    /// shape of every accumulation `Tests/CLAUDE.md` records. Tying the cleanup
    /// to the fixture's lifetime rather than to a `defer` at each call site is
    /// what keeps the next test from having to remember.
    private final class Fixture {
        let root: URL
        let home: URL
        let checkout: URL
        let repo: SupervisionRepo
        let resolver: SupervisionPlaybookResolver

        init(root: URL, home: URL, checkout: URL,
             repo: SupervisionRepo, resolver: SupervisionPlaybookResolver) {
            self.root = root
            self.home = home
            self.checkout = checkout
            self.repo = repo
            self.resolver = resolver
        }

        deinit {
            // A level deliberately chmod'ed 0o000 by a test is still removable:
            // unlinking depends on the parent directory's mode, not the file's.
            try? FileManager.default.removeItem(at: root)
        }

        /// `~/tbd/repos/<id>/supervision.md` — a singleton's operator level.
        var repoOperatorPath: String {
            TBDConstants.repoPlaybookPath(repoID: repo.id, environment: environment)
        }

        /// `<checkout>/.agents/supervision.md` — the repo level.
        var agentsPath: String {
            TBDConstants.repoAgentsPlaybookPath(checkout: checkout.path)
        }

        /// `~/tbd/supervision/projects/<name>/supervision.md` — a declared
        /// project's operator level.
        func projectOperatorPath(_ project: String) -> String {
            TBDConstants.supervisionPlaybookPath(project: project, environment: environment)!
        }

        var environment: [String: String] { ["TBD_HOME": home.path] }
    }

    private static func makeFixture(repoName: String = "acme-web") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-playbook-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("tbd", isDirectory: true)
        let checkout = root.appendingPathComponent("checkout", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let repo = SupervisionRepo(id: UUID(), name: repoName, path: checkout.path)
        return Fixture(
            root: root, home: home, checkout: checkout, repo: repo,
            resolver: SupervisionPlaybookResolver(environment: ["TBD_HOME": home.path]))
    }

    private static func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// The singleton project for the fixture's repo — no declaration anywhere.
    private static func singleton(_ fixture: Fixture) throws -> SupervisionProject {
        let projects = try SupervisionTopology.resolve(
            file: SupervisionFile(), repos: [fixture.repo])
        return try #require(projects.first)
    }

    // MARK: - The three tiers, in order

    @Test("A singleton resolves its per-repo operator copy, then .agents, then shipped")
    func singletonWalksItsThreeLevels() throws {
        let fixture = try Self.makeFixture()
        let project = try Self.singleton(fixture)
        let file = SupervisionFile()

        // Nothing written: the shipped default stands.
        let shipped = fixture.resolver.resolve(project: project, in: file, repos: [fixture.repo])
        #expect(shipped.tier == .shipped)
        #expect(shipped.path == nil)
        #expect(shipped.bytes == SupervisionPlaybookContent.bytes)

        // The repo's own file answers next.
        try Self.write("REPO LEVEL\n", to: fixture.agentsPath)
        let repoLevel = fixture.resolver.resolve(project: project, in: file, repos: [fixture.repo])
        #expect(repoLevel.tier == .repo)
        #expect(repoLevel.path == fixture.agentsPath)
        #expect(repoLevel.text == "REPO LEVEL\n")

        // The operator's copy beats it.
        try Self.write("OPERATOR LEVEL\n", to: fixture.repoOperatorPath)
        let operatorLevel = fixture.resolver.resolve(
            project: project, in: file, repos: [fixture.repo])
        #expect(operatorLevel.tier == .operator)
        #expect(operatorLevel.path == fixture.repoOperatorPath)
        #expect(operatorLevel.text == "OPERATOR LEVEL\n")
    }

    @Test("A declared project's operator copy lives beside its definition")
    func declaredProjectUsesItsProjectDirectory() throws {
        let fixture = try Self.makeFixture()
        let file = SupervisionFile(projects: [
            "acme-checkout": SupervisionProjectDeclaration(
                repos: [fixture.repo.id], policy: .repo(fixture.repo.id))
        ])
        let projects = try SupervisionTopology.resolve(file: file, repos: [fixture.repo])
        let project = try #require(projects.first { $0.name == "acme-checkout" })

        try Self.write("REPO LEVEL\n", to: fixture.agentsPath)
        let beforeCustomizing = fixture.resolver.resolve(
            project: project, in: file, repos: [fixture.repo])
        #expect(beforeCustomizing.tier == .repo)

        let operatorPath = fixture.projectOperatorPath("acme-checkout")
        try Self.write("DECLARED OPERATOR LEVEL\n", to: operatorPath)
        let resolved = fixture.resolver.resolve(project: project, in: file, repos: [fixture.repo])
        #expect(resolved.tier == .operator)
        #expect(resolved.path == operatorPath)
        // And the singleton location is *not* what a declared project reads —
        // writing there changes nothing.
        try Self.write("WRONG LEVEL\n", to: fixture.repoOperatorPath)
        let again = fixture.resolver.resolve(project: project, in: file, repos: [fixture.repo])
        #expect(again.path == operatorPath)
        #expect(again.text == "DECLARED OPERATOR LEVEL\n")
    }

    // MARK: - No merging

    @Test("The winning level is the whole conduct — no level below it appears in the result")
    func levelsAreNeverMerged() throws {
        let fixture = try Self.makeFixture()
        let project = try Self.singleton(fixture)
        try Self.write("repo-only-sentence\n", to: fixture.agentsPath)
        try Self.write("operator-only-sentence\n", to: fixture.repoOperatorPath)

        let resolved = fixture.resolver.resolve(
            project: project, in: SupervisionFile(), repos: [fixture.repo])

        #expect(resolved.tier == .operator)
        #expect(resolved.text == "operator-only-sentence\n")
        #expect(!resolved.text.contains("repo-only-sentence"),
                "the repo file's content must appear nowhere in a resolved operator playbook")
        // The shipped default is not appended either.
        #expect(!resolved.text.contains("Supervision playbook"))
        #expect(resolved.bytes.count == Data("operator-only-sentence\n".utf8).count)
    }

    // MARK: - Fall-through

    @Test("An empty file at a level falls through to the next one and is reported")
    func emptyLevelFallsThrough() throws {
        let fixture = try Self.makeFixture()
        let project = try Self.singleton(fixture)
        try Self.write("", to: fixture.repoOperatorPath)
        try Self.write("REPO LEVEL\n", to: fixture.agentsPath)

        let resolved = fixture.resolver.resolve(
            project: project, in: SupervisionFile(), repos: [fixture.repo])

        #expect(resolved.tier == .repo, "an empty operator copy is not conduct")
        #expect(resolved.text == "REPO LEVEL\n")
        #expect(resolved.skipped == [SupervisionPlaybookSkippedLevel(
            tier: .operator, path: fixture.repoOperatorPath, reason: .empty)])
    }

    @Test("An empty file at every level lands on the shipped default")
    func everyLevelEmptyLandsOnShipped() throws {
        let fixture = try Self.makeFixture()
        let project = try Self.singleton(fixture)
        try Self.write("", to: fixture.repoOperatorPath)
        try Self.write("", to: fixture.agentsPath)

        let resolved = fixture.resolver.resolve(
            project: project, in: SupervisionFile(), repos: [fixture.repo])

        #expect(resolved.tier == .shipped)
        #expect(resolved.bytes == SupervisionPlaybookContent.bytes)
        #expect(resolved.skipped.map(\.tier) == [.operator, .repo])
        #expect(resolved.skipped.allSatisfy { $0.reason == .empty })
    }

    @Test("An unreadable file at a level falls through and is reported as unreadable")
    func unreadableLevelFallsThrough() throws {
        let fixture = try Self.makeFixture()
        let project = try Self.singleton(fixture)
        try Self.write("OPERATOR LEVEL\n", to: fixture.repoOperatorPath)
        try Self.write("REPO LEVEL\n", to: fixture.agentsPath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: fixture.repoOperatorPath)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: fixture.repoOperatorPath)
        }

        let resolved = fixture.resolver.resolve(
            project: project, in: SupervisionFile(), repos: [fixture.repo])

        #expect(resolved.tier == .repo)
        #expect(resolved.skipped == [SupervisionPlaybookSkippedLevel(
            tier: .operator, path: fixture.repoOperatorPath, reason: .unreadable)])
    }

    // MARK: - The policy designation

    @Test("A policy of {\"operator\": true} skips the repo tier entirely")
    func operatorPolicySkipsTheRepoTier() throws {
        let fixture = try Self.makeFixture()
        let file = SupervisionFile(projects: [
            "acme-checkout": SupervisionProjectDeclaration(
                repos: [fixture.repo.id], policy: .operator)
        ])
        let projects = try SupervisionTopology.resolve(file: file, repos: [fixture.repo])
        let project = try #require(projects.first { $0.name == "acme-checkout" })

        // A repo file exists and says something loud. It is not this project's
        // policy source, so it is not consulted at all.
        try Self.write("REPO LEVEL\n", to: fixture.agentsPath)

        let site = fixture.resolver.site(for: project, in: file, repos: [fixture.repo])
        #expect(site.repoPath == nil, "an operator policy designates no repo file")

        let resolved = fixture.resolver.resolve(site)
        #expect(resolved.tier == .shipped)
        #expect(!resolved.text.contains("REPO LEVEL"))
        #expect(resolved.skipped.isEmpty, "a level that does not exist is not a finding")

        // The operator level still answers when it is written.
        let operatorPath = fixture.projectOperatorPath("acme-checkout")
        try Self.write("OPERATOR LEVEL\n", to: operatorPath)
        let withOperator = fixture.resolver.resolve(
            project: project, in: file, repos: [fixture.repo])
        #expect(withOperator.tier == .operator)
        #expect(withOperator.path == operatorPath)
    }

    @Test("A declared project reads the designated member's repo file, not another member's")
    func repoTierFollowsTheDesignatedMember() throws {
        let fixture = try Self.makeFixture()
        let otherCheckout = fixture.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherCheckout, withIntermediateDirectories: true)
        let other = SupervisionRepo(
            id: UUID(), name: "acme-api", path: otherCheckout.path)
        let file = SupervisionFile(projects: [
            "acme-checkout": SupervisionProjectDeclaration(
                repos: [fixture.repo.id, other.id], policy: .repo(other.id))
        ])
        let projects = try SupervisionTopology.resolve(
            file: file, repos: [fixture.repo, other])
        let project = try #require(projects.first { $0.name == "acme-checkout" })

        try Self.write("NOT THE POLICY SOURCE\n", to: fixture.agentsPath)
        let designated = TBDConstants.repoAgentsPlaybookPath(checkout: otherCheckout.path)
        try Self.write("THE POLICY SOURCE\n", to: designated)

        let resolved = fixture.resolver.resolve(
            project: project, in: file, repos: [fixture.repo, other])
        #expect(resolved.tier == .repo)
        #expect(resolved.path == designated)
        #expect(resolved.text == "THE POLICY SOURCE\n")
    }

    // MARK: - The hash

    @Test("The conduct hash is stable across resolutions and moves with one character")
    func hashIsStableAndSensitive() throws {
        let fixture = try Self.makeFixture()
        let project = try Self.singleton(fixture)
        try Self.write("conduct\n", to: fixture.repoOperatorPath)

        let first = fixture.resolver.resolve(
            project: project, in: SupervisionFile(), repos: [fixture.repo])
        let second = fixture.resolver.resolve(
            project: project, in: SupervisionFile(), repos: [fixture.repo])
        #expect(first.conductHash == second.conductHash)
        #expect(first.conductHash.count == 64)
        #expect(first.conductHash == first.conductHash.lowercased())
        #expect(first.conductHash.allSatisfy { $0.isHexDigit })

        try Self.write("conducT\n", to: fixture.repoOperatorPath)
        let changed = fixture.resolver.resolve(
            project: project, in: SupervisionFile(), repos: [fixture.repo])
        #expect(changed.conductHash != first.conductHash,
                "one character has to move the hash, or a playbook edit is invisible")
    }

    @Test("SHA-256 of the bytes, lowercase hex — the value a delivery records")
    func hashIsSHA256OfTheBytes() {
        // Pinned against the published SHA-256 of the empty input and of "abc",
        // so a change of algorithm or encoding is caught here rather than by a
        // consumer comparing hashes across builds.
        #expect(SupervisionPlaybook.hash(of: Data()) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SupervisionPlaybook.hash(of: Data("abc".utf8)) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - The shipped default

    @Test("The shipped default resolves for a project with neither file, deterministically")
    func shippedDefaultIsDeterministic() throws {
        let fixture = try Self.makeFixture()
        let project = try Self.singleton(fixture)

        let resolved = fixture.resolver.resolve(
            project: project, in: SupervisionFile(), repos: [fixture.repo])
        #expect(resolved.tier == .shipped)
        #expect(resolved.path == nil)
        #expect(resolved.conductHash ==
            SupervisionPlaybook.hash(of: SupervisionPlaybookContent.bytes))

        // A second resolver over a different home answers the same hash: the
        // shipped tier is the build's, not the installation's.
        let elsewhere = try Self.makeFixture()
        let other = try Self.singleton(elsewhere)
        let again = elsewhere.resolver.resolve(
            project: other, in: SupervisionFile(), repos: [elsewhere.repo])
        #expect(again.conductHash == resolved.conductHash)
    }

    @Test("The shipped default carries the universals and both baseline modes")
    func shippedDefaultCarriesItsRequiredContent() {
        let body = SupervisionPlaybookContent.body
        // Sections named for the two built-in modes, which is the convention a
        // desk reads — and the reason every project has both without authoring
        // anything.
        for mode in SupervisionModeEntry.builtInModes {
            #expect(body.contains("\n## \(mode)\n"), "missing a section for mode \"\(mode)\"")
        }
        #expect(body.hasSuffix("\n"), "a file a human edits ends in a newline")
        // The default is universals only: no commands to run, no bot names, no
        // organization-specific content. A fenced code block would be the shape
        // a command arrives in.
        #expect(!body.contains("```"))
        #expect(!body.contains("tbd "))
        #expect(!body.contains("$ "))
    }

    // MARK: - Sites

    @Test("An empty repo checkout leaves no repo tier rather than composing a bare path")
    func unknownCheckoutYieldsNoRepoPath() throws {
        let fixture = try Self.makeFixture()
        let pathless = SupervisionRepo(id: UUID(), name: "acme-api")
        let projects = try SupervisionTopology.resolve(
            file: SupervisionFile(), repos: [pathless])
        let project = try #require(projects.first)

        let site = fixture.resolver.site(
            for: project, in: SupervisionFile(), repos: [pathless])
        #expect(site.repoPath == nil)
        #expect(site.operatorPath == TBDConstants.repoPlaybookPath(
            repoID: pathless.id, environment: fixture.environment))
        #expect(fixture.resolver.resolve(site).tier == .shipped)
    }
}
