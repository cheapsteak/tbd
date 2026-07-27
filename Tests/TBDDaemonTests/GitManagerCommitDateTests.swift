import Foundation
import Testing
@testable import TBDDaemonLib

/// Tier 2: uses a temporary repository and the real Git executable.
@Suite("GitManager commit date")
struct GitManagerCommitDateTests {
    @Test func returnsCommitterDateForRef() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-manager-commit-date-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        try runGit(["init"], at: repo)
        try runGit(["config", "commit.gpgSign", "false"], at: repo)
        try runGit(["config", "user.name", "Test"], at: repo)
        try runGit(["config", "user.email", "test@example.com"], at: repo)
        try runGit(
            ["commit", "--allow-empty", "-m", "initial"],
            at: repo,
            environment: [
                "GIT_AUTHOR_DATE": "2026-07-20T12:34:56Z",
                "GIT_COMMITTER_DATE": "2026-07-20T12:34:56Z",
            ]
        )

        let date = try await GitManager().commitDate(repoPath: repo.path, ref: "HEAD")
        #expect(date == ISO8601DateFormatter().date(from: "2026-07-20T12:34:56Z"))
    }

    private func runGit(
        _ arguments: [String],
        at directory: URL,
        environment: [String: String] = [:]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitManagerCommitDateTests", code: Int(process.terminationStatus))
        }
    }
}
