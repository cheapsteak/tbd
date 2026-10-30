import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib

/// Tier 2: uses a temporary repository and the real Git executable.
@Suite("GitManager commit date")
struct GitManagerCommitDateTests {
    @Test func returnsCommitterDateForExplicitOlderRef() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-manager-commit-date-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        // `shell` waits off the cooperative pool and supplies the identity and
        // the global-config isolation, so the repo needs no config of its own.
        try await shell(
            "git init"
                + " && GIT_AUTHOR_DATE=2026-07-20T12:34:56Z GIT_COMMITTER_DATE=2026-07-20T12:34:56Z"
                + " git commit --allow-empty -m initial",
            at: repo
        )
        let olderSHA = try await GitManager().headSHA(repoPath: repo.path)
        try await shell(
            "git tag older"
                + " && GIT_AUTHOR_DATE=2026-07-21T01:02:03Z GIT_COMMITTER_DATE=2026-07-21T01:02:03Z"
                + " git commit --allow-empty -m newer",
            at: repo
        )

        let formatter = ISO8601DateFormatter()
        let headDate = try await GitManager().commitDate(repoPath: repo.path, ref: "HEAD")
        let shaDate = try await GitManager().commitDate(repoPath: repo.path, ref: olderSHA)
        let tagDate = try await GitManager().commitDate(repoPath: repo.path, ref: "older")

        #expect(headDate == formatter.date(from: "2026-07-21T01:02:03Z"))
        #expect(shaDate == formatter.date(from: "2026-07-20T12:34:56Z"))
        #expect(tagDate == formatter.date(from: "2026-07-20T12:34:56Z"))
    }
}
