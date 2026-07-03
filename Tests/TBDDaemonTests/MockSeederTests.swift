import Testing
import Foundation
import TBDShared
@testable import TBDDaemonLib

@Suite("MockSeeder")
struct MockSeederTests {
    private func scenario() -> MockScenario {
        MockScenario(repos: [
            .init(path: "/tmp/acme", displayName: "acme", worktrees: [
                .init(name: "main", branch: "main", status: .main),
                .init(name: "feat-x", branch: "tbd/feat-x",
                      prStatus: PRStatus(number: 12, url: "https://x/12", state: .mergeable),
                      terminals: [
                        .init(kind: .claude, activityState: .working,
                              transcriptFixture: "long-session.jsonl")
                      ]),
                .init(name: "child", branch: "tbd/child", hasConflicts: true,
                      parentName: "feat-x"),
            ])
        ])
    }

    @Test("seeds repos, worktrees, terminals with all authored fields")
    func seedsFullScenario() async throws {
        let db = try TBDDatabase(inMemory: true)
        // A directory that exists so transcript path resolution is deterministic.
        let dir = FileManager.default.temporaryDirectory
        try await MockSeeder().seed(scenario: scenario(), into: db, fixtureDirectory: dir)

        let repos = try await db.repos.list()
        #expect(repos.contains { $0.displayName == "acme" })
        let repo = try #require(repos.first { $0.displayName == "acme" })

        // excludeArchived defaults to false, so all 3 worktrees are returned
        let wts = try await db.worktrees.list(repoID: repo.id)
        #expect(wts.count == 3)
        let feat = try #require(wts.first { $0.name == "feat-x" })
        #expect(feat.prStatus?.number == 12)
        let child = try #require(wts.first { $0.name == "child" })
        #expect(child.hasConflicts == true)
        #expect(child.parentWorktreeID == feat.id)

        let terms = try await db.terminals.list(worktreeID: feat.id)
        #expect(terms.count == 1)
        #expect(terms[0].kind == .claude)
        #expect(terms[0].activityState == .working)
        let expected = dir.appendingPathComponent("transcripts")
            .appendingPathComponent("long-session.jsonl").path
        #expect(terms[0].transcriptPath == expected)
    }

    @Test("committed default fixture decodes and seeds without error")
    func defaultFixtureSeeds() async throws {
        // Resolve the fixture relative to this source file so the test is CWD-independent.
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // TBDDaemonTests/
            .deletingLastPathComponent()          // Tests/
            .appendingPathComponent("Fixtures/mock-state/scenario-default.json")
        let data = try Data(contentsOf: fixtureURL)
        let scenario = try JSONDecoder().decode(MockScenario.self, from: data)
        let db = try TBDDatabase(inMemory: true)
        try await MockSeeder().seed(
            scenario: scenario, into: db,
            fixtureDirectory: fixtureURL.deletingLastPathComponent())
        let repos = try await db.repos.list()
        #expect(repos.count == 2)
    }
}
