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

    @Test("worktree with an unresolvable parentName throws with worktree context")
    func unresolvedParentFailsLoud() async throws {
        // `child` names a parent that is never seeded in this repo (typo /
        // forward-reference). A silent nil would create `child` as a root row;
        // the fail-loud contract requires an abort naming the child worktree.
        let scenario = MockScenario(repos: [
            .init(path: "/tmp/acme-parent", displayName: "acme", worktrees: [
                .init(name: "child", branch: "tbd/child", parentName: "nonexistent"),
            ]),
        ])
        let db = try TBDDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory

        do {
            try await MockSeeder().seed(scenario: scenario, into: db, fixtureDirectory: dir)
            Issue.record("expected seed to throw on unresolvable parentName")
        } catch let error as MockSeedError {
            #expect(error.item == "worktree 'child' in repo 'acme'")
            #expect(error.description.contains("nonexistent"))
        }
    }

    @Test("worktree with a valid backward parentName seeds without throwing")
    func resolvedParentSeedsSuccessfully() async throws {
        // `parent` is listed EARLIER, so `child`'s backward reference resolves
        // and the seed completes — the positive-path guard for the fix.
        let scenario = MockScenario(repos: [
            .init(path: "/tmp/acme-ok", displayName: "acme", worktrees: [
                .init(name: "parent", branch: "tbd/parent"),
                .init(name: "child", branch: "tbd/child", parentName: "parent"),
            ]),
        ])
        let db = try TBDDatabase(inMemory: true)
        let dir = FileManager.default.temporaryDirectory

        try await MockSeeder().seed(scenario: scenario, into: db, fixtureDirectory: dir)
    }
}
