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
