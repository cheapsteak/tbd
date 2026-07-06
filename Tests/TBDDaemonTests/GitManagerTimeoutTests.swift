import Foundation
import Testing
@testable import TBDDaemonLib

/// Exercises `GitManager`'s subprocess timeout/kill path directly, per the
/// review request: a real temp repo with a slow `post-checkout` hook makes a
/// git operation hang, and `GitManager(subprocessTimeout:)` must SIGTERM/SIGKILL
/// it and throw `GitTimeoutError` fast rather than block indefinitely.
struct GitManagerTimeoutTests {
    private static func shell(_ command: String, at dir: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", command]
            p.currentDirectoryURL = dir
            p.terminationHandler = { proc in
                proc.terminationStatus == 0
                    ? cont.resume()
                    : cont.resume(throwing: NSError(domain: "shell", code: Int(proc.terminationStatus)))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    @Test func worktreeAddTimesOutWhenAHookHangs() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repoDir = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try await Self.shell("git init", at: repoDir)
        try await Self.shell("git config user.email 'test@test.com'", at: repoDir)
        try await Self.shell("git config user.name 'Test'", at: repoDir)
        try await Self.shell("git commit --allow-empty -m init", at: repoDir)

        // A post-checkout hook that hangs — `git worktree add` runs it after the
        // checkout, so the git child blocks far longer than the timeout.
        let hooksDir = repoDir.appendingPathComponent(".git/hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let hook = hooksDir.appendingPathComponent("post-checkout")
        try "#!/bin/sh\nsleep 10\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let base = try await GitManager().detectDefaultBranch(repoPath: repoDir.path)
        let slowGit = GitManager(subprocessTimeout: .milliseconds(250))
        let wtPath = tempDir.appendingPathComponent("wt-timeout").path

        let start = Date()
        await #expect(throws: GitTimeoutError.self) {
            try await slowGit.worktreeAdd(
                repoPath: repoDir.path,
                worktreePath: wtPath,
                branch: "feature-timeout",
                baseBranch: base
            )
        }
        // Must fail fast — nowhere near the hook's 10s sleep.
        #expect(Date().timeIntervalSince(start) < 5.0,
                "GitManager must kill the hung git child and throw promptly")
    }
}
