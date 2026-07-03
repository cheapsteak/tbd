import Testing
import Foundation
import TBDShared
@testable import TBDDaemonLib

/// Covers the fail-loud contract: `MockSeeder.seed` must throw (never
/// silently render a half-seeded scenario) and must attach per-item context
/// naming the fixture entry that failed.
@Suite("MockSeederFailLoud")
struct MockSeederFailLoudTests {
    @Test("second repo colliding on UNIQUE path throws a context-tagged MockSeedError")
    func repoCollisionFailsLoud() async throws {
        // Two repos share the same `path`. Repo `path` is UNIQUE, so the second
        // create trips the constraint and must abort with the second repo's identity.
        let scenario = MockScenario(repos: [
            .init(path: "/tmp/dup-repo", displayName: "acme", worktrees: [
                .init(name: "main", branch: "main", status: .main),
            ]),
            .init(path: "/tmp/dup-repo", displayName: "acme-prod", worktrees: [
                .init(name: "main", branch: "main", status: .main),
            ]),
        ])
        // Fresh DB; a single seed pass. Repo 1 ('acme') commits, repo 2
        // ('acme-prod') collides on the shared path and aborts the seed.
        let db = try TBDDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory

        do {
            try await MockSeeder().seed(scenario: scenario, into: db, fixtureDirectory: dir)
            Issue.record("expected seed to throw on duplicate repo path")
        } catch let error as MockSeedError {
            #expect(error.item == "repo 'acme-prod'")
            #expect(error.description.contains("Mock seeding failed for repo 'acme-prod'"))
        }
    }

    @Test("worktree colliding on UNIQUE path within a repo throws with worktree context")
    func worktreeCollisionFailsLoud() async throws {
        // Two worktrees resolve to the same on-disk path (same pathSuffix), so
        // the second create trips the worktree UNIQUE path constraint. The
        // wrapped error must name the worktree, not the repo.
        let scenario = MockScenario(repos: [
            .init(path: "/tmp/acme-wt", displayName: "acme", worktrees: [
                .init(name: "first", branch: "tbd/first", pathSuffix: "shared"),
                .init(name: "second", branch: "tbd/second", pathSuffix: "shared"),
            ]),
        ])
        let db = try TBDDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory

        do {
            try await MockSeeder().seed(scenario: scenario, into: db, fixtureDirectory: dir)
            Issue.record("expected seed to throw on duplicate worktree path")
        } catch let error as MockSeedError {
            #expect(error.item == "worktree 'second' in repo 'acme'")
        }
    }
}
