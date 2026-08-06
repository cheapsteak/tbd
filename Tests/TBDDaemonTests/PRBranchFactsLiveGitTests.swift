import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

/// End-to-end wiring of the PR matcher's branch facts against REAL git.
///
/// The unit tests feed `PushBranchResolution` values in by hand, which is
/// exactly how a wrong belief about git's behavior survives a green suite: an
/// earlier revision keyed the base-vs-head decision on `@{push}` alone, and that
/// held only under `push.default = upstream`. Under git's default (`simple`),
/// `@{push}` refuses for a rename-push and a base-tracking branch alike. So this
/// suite reads the facts from a real repository, under BOTH push configs, and
/// asserts what the matcher and the heal then do with them.
@Suite("PR branch facts against real git")
struct PRBranchFactsLiveGitTests {

    private struct Fixture {
        let repoDir: URL
        let defaultBranch: String
    }

    /// A repo with a bare origin and three branches covering the cases that
    /// matter: one tracking its base, one pushed under a different name, and one
    /// pushed under its own name.
    ///
    /// Every command that MUTATES the repo runs through `TestSupport.shell`,
    /// which THROWS on a non-zero exit and fences out the developer's global git
    /// config. Both matter more than usual here: a silently-failing fixture
    /// leaves a repo with no commits and no remote-tracking refs, where every
    /// `@{push}` degrades to "no destination" and both arms of this test pass
    /// while proving nothing — precisely the failure mode the suite exists to
    /// catch. The one exception is `detectDefaultBranch`, called in-process on
    /// the same `GitManager` the production code uses: it only reads, and the
    /// repo-local config the fixture just wrote wins over anything ambient.
    private static func makeFixture(in tempDir: URL) async throws -> Fixture {
        let repoDir = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let remotePath = tempDir.appendingPathComponent("remote.git").path

        try await shell("git init", at: repoDir)
        try await shell("git commit --allow-empty -m 'init'", at: repoDir)
        let base = try await GitManager().detectDefaultBranch(repoPath: repoDir.path)
        try await shell("git init --bare '\(remotePath)'", at: tempDir)
        try await shell("git remote add origin '\(remotePath)'", at: repoDir)
        try await shell("git push -u origin \(base)", at: repoDir)

        // Rename-push: pushed to a differently-named remote branch.
        try await shell("git checkout -b local-x", at: repoDir)
        try await shell("git push origin local-x:renamed-on-remote", at: repoDir)
        try await shell("git config branch.local-x.remote origin", at: repoDir)
        try await shell("git config branch.local-x.merge refs/heads/renamed-on-remote", at: repoDir)

        // Base-tracking: what `git worktree add -b` off the base branch produces.
        try await shell("git checkout -b tbd/my-branch \(base)", at: repoDir)
        try await shell("git config branch.tbd/my-branch.remote origin", at: repoDir)
        try await shell("git config branch.tbd/my-branch.merge refs/heads/\(base)", at: repoDir)

        // Plain: pushed under its own name.
        try await shell("git checkout -b plain", at: repoDir)
        try await shell("git push -u origin plain", at: repoDir)

        // The fixture's own preconditions: a real commit and real
        // remote-tracking refs. Without them every `@{push}` answer below is
        // vacuous, so assert them rather than trusting the setup.
        try await shell("git rev-parse --verify HEAD", at: repoDir)
        try await shell("git rev-parse --verify refs/remotes/origin/renamed-on-remote", at: repoDir)

        return Fixture(repoDir: repoDir, defaultBranch: base)
    }

    /// Read the real facts for one branch and assemble the poll entry the PR
    /// matcher would see.
    private static func pollEntry(
        _ fixture: Fixture, branch: String, git: GitManager
    ) async -> PRStatusManager.PollWorktree {
        (id: UUID(),
         branch: branch,
         upstreamBranch: await git.upstreamBranchName(worktreePath: fixture.repoDir.path, branch: branch),
         defaultBranch: fixture.defaultBranch,
         pushBranch: await git.pushBranchName(worktreePath: fixture.repoDir.path, branch: branch),
         worktreePath: fixture.repoDir.path,
         prNumber: nil)
    }

    private static func node(number: Int, head: String, state: String = "OPEN") -> PRStatusManager.PRNode {
        PRStatusManager.PRNode(
            number: number, url: "https://github.com/acme/acme-prod/pull/\(number)", state: state,
            mergeStateStatus: "CLEAN", reviewDecision: "", headRefName: head,
            createdAt: "2026-07-01T00:00:00Z", isDraft: false,
            statusCheckRollupState: nil, mergeQueuePosition: nil)
    }

    /// The explicit time limit — unusual in the fast parallel pass, where suites
    /// normally take `.clockDriven`'s budget or none — is here for two reasons:
    ///
    /// 1. **There is a real hang to bound.** This suite arms no `TestClock`, so
    ///    `.clockDriven` would be the wrong trait; the hazard is a wedged git
    ///    subprocess, and `TestSupport.shell` waits on its child without a
    ///    deadline. Without a limit that wedge is an indefinite stall with no
    ///    failing test to name it.
    /// 2. **A minute is not tight here.** The parallel pass's guards are sized
    ///    at 90 s / 240 s to absorb `TestClock` arming latency across a ~5000-
    ///    test population; this suite never arms one and so never pays that
    ///    cost. Measured runtime is ~0.4 s for both arms — roughly 130x of
    ///    headroom, wider in proportion than `.clockDriven` leaves the suites it
    ///    covers.
    @Test("candidates and heal behave identically under both push.default values",
          .timeLimit(.minutes(1)),
          arguments: ["simple", "upstream"])
    func branchFactsDriveMatchingAndHealing(pushDefault: String) async throws {
        // Registered BEFORE setup so a throwing fixture doesn't leak the dir.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fixture = try await Self.makeFixture(in: tempDir)
        try await shell("git config push.default \(pushDefault)", at: fixture.repoDir)
        let git = GitManager()
        let base = fixture.defaultBranch

        // A worktree branch cut from the base: the base must never be a head-ref
        // candidate, and a PR whose head IS the base must heal.
        let baseTracking = await Self.pollEntry(fixture, branch: "tbd/my-branch", git: git)
        #expect(PRStatusManager.candidatesFor(baseTracking) == ["tbd/my-branch"])
        let basePR = Self.node(number: 88, head: base, state: "CLOSED")
        #expect(PRStatusManager.headRefMismatchedMatches(
            [(baseTracking.id, basePR)], unnumbered: [baseTracking]).count == 1)

        // Rename-push: its PR must be findable under the remote name, and the
        // attachment must survive the heal.
        let renamePush = await Self.pollEntry(fixture, branch: "local-x", git: git)
        #expect(PRStatusManager.candidatesFor(renamePush).contains("renamed-on-remote"))
        let renamedPR = Self.node(number: 9, head: "renamed-on-remote")
        #expect(PRStatusManager.matchUnnumbered([renamePush], nodes: [renamedPR],
                                                resolveRepo: { _ in ("acme", "acme-prod") }).count == 1)
        #expect(PRStatusManager.headRefMismatchedMatches(
            [(renamePush.id, renamedPR)], unnumbered: [renamePush]).isEmpty)

        // A plainly-pushed branch is unaffected: its own name is the candidate,
        // and its PR is neither dropped nor healed.
        let plain = await Self.pollEntry(fixture, branch: "plain", git: git)
        #expect(PRStatusManager.candidatesFor(plain) == ["plain"])
        let plainPR = Self.node(number: 10, head: "plain")
        #expect(PRStatusManager.matchUnnumbered([plain], nodes: [plainPR],
                                                resolveRepo: { _ in ("acme", "acme-prod") }).count == 1)
        #expect(PRStatusManager.headRefMismatchedMatches(
            [(plain.id, plainPR)], unnumbered: [plain]).isEmpty)
    }
}
