import Foundation
import Testing
@testable import TBDDaemonLib

struct GitManagerTests {
    let tempDir: URL
    let repoDir: URL
    let git: GitManager

    init() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repoDir = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)

        // Init a repo with an initial commit
        try await GitManagerTests.shell("git init", at: repoDir)
        try await GitManagerTests.shell("git config user.email 'test@test.com'", at: repoDir)
        try await GitManagerTests.shell("git config user.name 'Test'", at: repoDir)
        try await GitManagerTests.shell("git commit --allow-empty -m 'init'", at: repoDir)
        git = GitManager()
    }

    // MARK: - Tests

    @Test func detectDefaultBranch() async throws {
        let branch = try await git.detectDefaultBranch(repoPath: repoDir.path)
        // Fresh git init uses "main" or "master" depending on config
        #expect(["main", "master"].contains(branch))
    }

    @Test func isGitRepo() async throws {
        let isRepo = await git.isGitRepo(path: repoDir.path)
        #expect(isRepo)
        let isNotRepo = await git.isGitRepo(path: tempDir.path)
        #expect(!isNotRepo)
    }

    @Test func worktreeAddAndList() async throws {
        let wtPath = tempDir.appendingPathComponent("wt1").path
        let branch = try await git.detectDefaultBranch(repoPath: repoDir.path)
        try await git.worktreeAdd(repoPath: repoDir.path, worktreePath: wtPath, branch: "tbd/test", baseBranch: branch)

        let worktrees = try await git.worktreeList(repoPath: repoDir.path)
        #expect(worktrees.count >= 2) // main + new worktree

        // Verify the worktree directory exists
        #expect(FileManager.default.fileExists(atPath: wtPath))

        // Clean up worktree
        try await git.worktreeRemove(repoPath: repoDir.path, worktreePath: wtPath)
        cleanup()
    }

    @Test func worktreeRemove() async throws {
        let wtPath = tempDir.appendingPathComponent("wt1").path
        let branch = try await git.detectDefaultBranch(repoPath: repoDir.path)
        try await git.worktreeAdd(repoPath: repoDir.path, worktreePath: wtPath, branch: "tbd/remove-test", baseBranch: branch)
        try await git.worktreeRemove(repoPath: repoDir.path, worktreePath: wtPath)
        #expect(!FileManager.default.fileExists(atPath: wtPath))
        cleanup()
    }

    @Test func getRemoteURL() async throws {
        // No remote on a fresh repo
        let url = await git.getRemoteURL(repoPath: repoDir.path)
        #expect(url == nil)
        cleanup()
    }

    @Test func upstreamBranchNameReturnsConfiguredMergeBranch() async throws {
        try await GitManagerTests.shell("git checkout -b local-feature", at: repoDir)
        try await GitManagerTests.shell("git config branch.local-feature.remote origin", at: repoDir)
        try await GitManagerTests.shell("git config branch.local-feature.merge refs/heads/tbd/upstream-feature", at: repoDir)

        let upstream = await git.upstreamBranchName(worktreePath: repoDir.path, branch: "local-feature")

        #expect(upstream == "tbd/upstream-feature")
        cleanup()
    }

    // MARK: - @{push} resolution (base vs head discrimination)

    /// Wire `repoDir` to a fresh bare remote and push the default branch, so
    /// `@{push}` has something real to resolve against.
    private func addBareRemoteAndPushDefault() async throws -> String {
        let base = try await git.detectDefaultBranch(repoPath: repoDir.path)
        let remotePath = tempDir.appendingPathComponent("remote.git").path
        try await GitManagerTests.shell("git init --bare '\(remotePath)'", at: tempDir)
        try await GitManagerTests.shell("git remote add origin '\(remotePath)'", at: repoDir)
        try await GitManagerTests.shell("git push -u origin \(base)", at: repoDir)
        return base
    }

    @Test func pushBranchNameReportsNoDestinationForABranchTrackingItsBase() async throws {
        // The shape every worktree branch cut from the base branch has: it
        // TRACKS the base, and git refuses to derive a push destination from
        // that. This is the discriminator the PR matcher relies on — the
        // tracking config alone cannot tell a head ref from a base ref.
        let base = try await addBareRemoteAndPushDefault()
        try await GitManagerTests.shell("git checkout -b tbd/my-branch", at: repoDir)
        try await GitManagerTests.shell("git config branch.tbd/my-branch.remote origin", at: repoDir)
        try await GitManagerTests.shell("git config branch.tbd/my-branch.merge refs/heads/\(base)", at: repoDir)
        try await GitManagerTests.shell("git config push.default simple", at: repoDir)

        let resolution = await git.pushBranchName(worktreePath: repoDir.path, branch: "tbd/my-branch")

        #expect(resolution == .noPushDestination)
        cleanup()
    }

    @Test func pushBranchNameResolvesARenamePush() async throws {
        // The one case a second head-ref candidate exists for: the branch is
        // pushed under a different name, so its PR is only findable there.
        _ = try await addBareRemoteAndPushDefault()
        try await GitManagerTests.shell("git checkout -b local-x", at: repoDir)
        try await GitManagerTests.shell("git push origin local-x:renamed-on-remote", at: repoDir)
        try await GitManagerTests.shell("git config branch.local-x.remote origin", at: repoDir)
        try await GitManagerTests.shell("git config branch.local-x.merge refs/heads/renamed-on-remote", at: repoDir)
        try await GitManagerTests.shell("git config push.default upstream", at: repoDir)

        let resolution = await git.pushBranchName(worktreePath: repoDir.path, branch: "local-x")

        #expect(resolution == .resolved("renamed-on-remote"))
        cleanup()
    }

    @Test func pushBranchShortNameStripsTheRemoteAndKeepsSlashesInTheBranch() {
        #expect(GitManager.pushBranchShortName(fromFullRef: "refs/remotes/origin/tbd/my-branch\n")
                == "tbd/my-branch")
        #expect(GitManager.pushBranchShortName(fromFullRef: "refs/heads/local-only") == "local-only")
    }

    @Test func pushBranchShortNameRejectsAnUnexpectedShape() {
        // An unparseable ref must degrade to "no evidence" (the caller maps nil
        // to `.lookupFailed`) rather than invent a branch name.
        #expect(GitManager.pushBranchShortName(fromFullRef: "origin/whatever") == nil)
        #expect(GitManager.pushBranchShortName(fromFullRef: "refs/remotes/origin/") == nil)
        #expect(GitManager.pushBranchShortName(fromFullRef: "") == nil)
    }

    /// Regression test for a race in `GitManager.run()` where the readability handler
    /// did `availableData` and `accumulator.append` in two non-atomic steps,
    /// allowing `terminationHandler` to snapshot between them and drop the chunk.
    /// Manifested as fast commands like `git rev-parse HEAD` returning "" with exit 0.
    /// Without the fix, this test reliably catches the race within ~200 iterations.
    @Test func concurrentHeadSHADoesNotRace() async throws {
        let repoPath = repoDir.path
        let expected = try await git.headSHA(repoPath: repoPath)
        #expect(expected.count == 40)
        #expect(!expected.isEmpty)

        let iterations = 200
        let results = await withTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<iterations {
                group.addTask {
                    (try? await self.git.headSHA(repoPath: repoPath)) ?? ""
                }
            }
            var collected: [String] = []
            for await sha in group {
                collected.append(sha)
            }
            return collected
        }

        #expect(results.count == iterations)
        for sha in results {
            #expect(sha.count == 40, "Expected 40-char SHA, got \(sha.count) chars: '\(sha)'")
            #expect(sha == expected, "Expected '\(expected)', got '\(sha)'")
        }
        cleanup()
    }

    /// Sibling regression test for the same `GitManager.run()` pipe-drain race,
    /// exercised through `detectDefaultBranch`. An empty branch name flows into
    /// `git worktree add ... -b <branch> ''` and produces the
    /// `fatal: not a valid object name: ''` failure observed in `worktreeRemove`.
    @Test func concurrentDetectDefaultBranchDoesNotRace() async throws {
        let repoPath = repoDir.path
        let expected = try await git.detectDefaultBranch(repoPath: repoPath)
        #expect(!expected.isEmpty)
        #expect(["main", "master"].contains(expected))

        let iterations = 200
        let results = await withTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<iterations {
                group.addTask {
                    (try? await self.git.detectDefaultBranch(repoPath: repoPath)) ?? ""
                }
            }
            var collected: [String] = []
            for await branch in group {
                collected.append(branch)
            }
            return collected
        }

        #expect(results.count == iterations)
        for branch in results {
            #expect(!branch.isEmpty, "Expected non-empty branch name, got empty string")
            #expect(branch == expected, "Expected '\(expected)', got '\(branch)'")
        }
        cleanup()
    }

    // MARK: - Helpers

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static func shell(_ command: String, at dir: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = dir

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "shell",
                        code: Int(proc.terminationStatus)
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
