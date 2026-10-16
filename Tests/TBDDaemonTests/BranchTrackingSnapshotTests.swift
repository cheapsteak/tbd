import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib

/// `BranchTrackingSnapshot` stands in for two per-branch git calls, so its whole
/// contract is "answer what they answer". The parse tests pin the shapes git's
/// output can take; the live-git test holds the snapshot equal to the
/// per-branch calls over every branch shape the PR matcher tells apart, under
/// each `push.default` that changes `@{push}`, and from a linked worktree.
@Suite("Branch tracking snapshot")
struct BranchTrackingSnapshotTests {

    // MARK: - Parsing

    @Test("a merge key's branch name keeps its dots and slashes, and the last value wins")
    func parsesMergeConfig() {
        let config = [
            "branch.main.merge\nrefs/heads/main",
            "branch.feat.v2/x.merge\nrefs/heads/feat.v2/x",
            "branch.twice.merge\nrefs/heads/first",
            "branch.twice.merge\nrefs/heads/second",
            "branch.novalue.merge",
            "",
        ].joined(separator: "\0")
        let snapshot = BranchTrackingSnapshot.parse(mergeConfig: config, refListing: "")
        #expect(snapshot.upstreamBranchName(branch: "main") == "main")
        #expect(snapshot.upstreamBranchName(branch: "feat.v2/x") == "feat.v2/x")
        #expect(snapshot.upstreamBranchName(branch: "twice") == "second")
        #expect(snapshot.upstreamBranchName(branch: "novalue") == nil)
        #expect(snapshot.upstreamBranchName(branch: "absent") == nil)
    }

    @Test("a push destination resolves only when its ref is in the listing")
    func pushNeedsAnExistingRef() {
        let listing = [
            "refs/heads/pushed\0refs/remotes/origin/pushed",
            "refs/heads/unfetched\0refs/remotes/origin/unfetched",
            "refs/heads/nowhere\0",
            "refs/heads/odd\0refs/tags/v1",
            "refs/remotes/origin/pushed\0",
            "refs/tags/v1\0",
            "",
        ].joined(separator: "\n")
        let snapshot = BranchTrackingSnapshot.parse(mergeConfig: "", refListing: listing)
        #expect(snapshot.pushBranch(branch: "pushed") == .resolved("pushed"))
        // `rev-parse` refuses a destination that was never fetched.
        #expect(snapshot.pushBranch(branch: "unfetched") == .noPushDestination)
        #expect(snapshot.pushBranch(branch: "nowhere") == .noPushDestination)
        #expect(snapshot.pushBranch(branch: "missing") == .noPushDestination)
        // An existing ref that names no branch: git answered, but not with a
        // destination the matcher can use — the per-branch call's `.lookupFailed`.
        #expect(snapshot.pushBranch(branch: "odd") == .lookupFailed)
    }

    // MARK: - Against real git

    /// One repo holding every branch shape the PR matcher distinguishes, plus a
    /// linked worktree, the way TBD creates one.
    private static func makeFixture(in tempDir: URL) async throws -> (repo: URL, worktree: URL) {
        let repo = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let remote = tempDir.appendingPathComponent("remote.git").path
        try await shell("git init -b main && git commit --allow-empty -m init", at: repo)
        try await shell("git init --bare '\(remote)'", at: tempDir)
        try await shell("git remote add origin '\(remote)' && git push -u origin main", at: repo)
        // Pushed under its own name.
        try await shell("git checkout -b plain && git push -u origin plain", at: repo)
        // Tracks its base, as `git worktree add -b` off main leaves it.
        try await shell("git checkout -b tbd/base-tracking main && git branch --set-upstream-to=origin/main", at: repo)
        // Pushed under a different name.
        try await shell("git checkout -b local-x main && git push origin local-x:renamed-on-remote"
                        + " && git branch --set-upstream-to=origin/renamed-on-remote", at: repo)
        // Never pushed, no upstream.
        try await shell("git checkout -b never-pushed main", at: repo)
        // Tracking config naming a remote branch that was never fetched.
        try await shell("git checkout -b configured-only main"
                        + " && git config branch.configured-only.remote origin"
                        + " && git config branch.configured-only.merge refs/heads/configured-only", at: repo)
        // A name with dots and a slash.
        try await shell("git checkout -b feat.v2/dotted main && git push -u origin feat.v2/dotted", at: repo)
        try await shell("git checkout main", at: repo)
        let worktree = tempDir.appendingPathComponent("wt")
        try await shell("git worktree add '\(worktree.path)' -b tbd/in-worktree main", at: repo)
        // The fixture's own preconditions: without fetched remote-tracking refs
        // every `@{push}` would read "no destination" on both sides and the
        // comparison would prove nothing.
        try await shell("git rev-parse --verify refs/remotes/origin/plain", at: repo)
        try await shell("git rev-parse --verify refs/remotes/origin/renamed-on-remote", at: repo)
        return (repo, worktree)
    }

    private static let branches = [
        "main", "plain", "tbd/base-tracking", "local-x", "never-pushed",
        "configured-only", "feat.v2/dotted", "tbd/in-worktree", "no-such-branch",
    ]

    @Test("the snapshot answers exactly what the per-branch calls answer",
          .fastPassBounded,
          arguments: ["simple", "upstream", "current"])
    func snapshotMatchesPerBranchCalls(pushDefault: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fixture = try await Self.makeFixture(in: tempDir)
        try await shell("git config push.default \(pushDefault)", at: fixture.repo)
        let git = GitManager()

        let snapshot = try await git.branchTrackingSnapshot(repoPath: fixture.repo.path)
        // Read in the repo for every branch, and in the linked worktree too:
        // a local row used to read its facts in its own checkout, and the
        // snapshot reads them in the repo's.
        for directory in [fixture.repo.path, fixture.worktree.path] {
            for branch in Self.branches {
                let upstream = await git.upstreamBranchName(worktreePath: directory, branch: branch)
                let push = await git.pushBranchName(worktreePath: directory, branch: branch)
                #expect(snapshot.upstreamBranchName(branch: branch) == upstream,
                        "upstream of \(branch) read in \(directory)")
                #expect(snapshot.pushBranch(branch: branch) == push,
                        "@{push} of \(branch) read in \(directory)")
            }
        }
        // Not vacuous: the fixture produced both kinds of answer.
        #expect(snapshot.pushBranch(branch: "plain") == .resolved("plain"))
        #expect(snapshot.upstreamBranchName(branch: "local-x") == "renamed-on-remote")
        #expect(snapshot.pushBranch(branch: "configured-only") == .noPushDestination)
    }

    @Test("a repo with no tracking branches reads as an empty snapshot, not a failure",
          .fastPassBounded)
    func noTrackingConfigIsEmpty() async throws {
        let (tempDir, repoDir) = try await createTestRepo()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let snapshot = try await GitManager().branchTrackingSnapshot(repoPath: repoDir.path)
        #expect(snapshot.mergeRefs.isEmpty)
        #expect(snapshot.refNames.contains("refs/heads/main"))
        #expect(snapshot.pushBranch(branch: "main") == .noPushDestination)
    }

    @Test("a directory that is not a repository throws rather than answering for every branch",
          .fastPassBounded)
    func notARepositoryThrows() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: (any Error).self) {
            _ = try await GitManager().branchTrackingSnapshot(repoPath: dir.path)
        }
    }
}
