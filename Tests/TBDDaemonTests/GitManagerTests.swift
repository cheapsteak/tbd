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

    /// Write an executable stub that stands in for `git` in `pushBranchName`.
    private func makeGitStub(named name: String, script: String) throws -> String {
        let path = tempDir.appendingPathComponent(name).path
        try "#!/bin/sh\n\(script)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test func pushBranchNameTreatsAnUnparseableAnswerAsLookupFailure() async throws {
        // An exit-0 answer that is not a ref. Real git will not produce this on
        // demand, but the arm matters: `.lookupFailed` is what STOPS the PR heal
        // from deleting an attachment, so it must not be reachable only in
        // theory. Anything but a ref means we learned nothing.
        let stub = try makeGitStub(named: "git-garbage", script: "echo 'not-a-ref'")

        let resolution = await git.pushBranchName(
            worktreePath: repoDir.path, branch: "tbd/my-branch", executable: stub)

        #expect(resolution == .lookupFailed)
        cleanup()
    }

    @Test func pushBranchNameTreatsALaunchFailureAsLookupFailure() async throws {
        // The other producer: the subprocess never runs at all.
        let missing = tempDir.appendingPathComponent("no-such-git").path

        let resolution = await git.pushBranchName(
            worktreePath: repoDir.path, branch: "tbd/my-branch", executable: missing)

        #expect(resolution == .lookupFailed)
        cleanup()
    }

    @Test func pushBranchNameTreatsAGitRefusalAsNoPushDestination() async throws {
        // The complement, held apart from the two above: git ran and answered.
        let stub = try makeGitStub(
            named: "git-refuses",
            script: "echo \"fatal: cannot resolve 'simple' push to a single destination\" >&2; exit 128")

        let resolution = await git.pushBranchName(
            worktreePath: repoDir.path, branch: "tbd/my-branch", executable: stub)

        #expect(resolution == .noPushDestination)
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

    // MARK: - Subprocess environment

    /// Tier 2. Git's stderr is safety-critical here — `WorktreeLifecycle`'s
    /// failed-create cleanup decides whether it may delete a branch by matching
    /// English phrases in it — so the locale every git child runs under is
    /// pinned rather than inherited.
    ///
    /// Driven through the same `run()` wrapper production calls use (via the
    /// package-internal timeout seam, pointed at `/bin/sh` instead of git) so
    /// this asserts what actually reaches the child process, not what a helper
    /// returns. Asserting the inherited `HOME` in the same breath is the
    /// load-bearing half: pinning by *replacing* the environment instead of
    /// merging onto it would strip `HOME`, `PATH` and `SSH_AUTH_SOCK` from
    /// every git call the daemon makes — the tmux-launch-`PATH` regression, one
    /// subsystem over. `HOME` and not `PATH` because a POSIX shell invents a
    /// default `PATH` when it finds none, which would mask the replacement.
    @Test func gitSubprocessesInheritTheEnvironmentWithTheLocalePinned() async throws {
        defer { cleanup() }
        let inheritedHome = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let output = try await git.runForTimeoutTesting(
            executable: "/bin/sh",
            arguments: ["-c", #"printf '%s|%s|%s' "$LC_ALL" "$LANG" "$HOME""#],
            at: repoDir.path
        )
        #expect(output == "C|C|\(inheritedHome)",
                "git subprocess environment was not pinned-and-inherited: \(output)")
    }

    /// The composition itself, including the case the process environment
    /// cannot produce on demand: a hostile locale already set. Both arms —
    /// hostile values overridden, unrelated values untouched.
    @Test func gitEnvironmentOverridesAHostileLocaleAndKeepsEverythingElse() {
        let composed = GitManager.gitEnvironment(inheriting: [
            "LANG": "fr_FR.UTF-8",
            "LC_ALL": "fr_FR.UTF-8",
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "HOME": "/Users/test",
            "SSH_AUTH_SOCK": "/tmp/agent.sock",
        ])
        #expect(composed["LC_ALL"] == "C")
        #expect(composed["LANG"] == "C")
        #expect(composed["PATH"] == "/opt/homebrew/bin:/usr/bin")
        #expect(composed["HOME"] == "/Users/test")
        #expect(composed["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
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
