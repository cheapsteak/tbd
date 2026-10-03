import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("GitHubRateLimitTelemetry")
struct GitHubRateLimitTelemetryTests {
    @Test func everyGitHubQueryBuilderSelectsRateLimit() {
        let texts = [
            PRStatusManager.prCheckQuery(owner: "acme", name: "acme-prod", number: 1),
            PRStatusManager.prByBranchQuery(),
            PRStatusManager.numberedPRQuery(aliases: [(alias: "pr0", number: 1)]),
            PRStatusManager.branchPRsQuery(aliasCount: 2),
            PRStatusManager.openPRsQuery(),
        ]
        for text in texts {
            #expect(text.contains("rateLimit { cost remaining resetAt }"), "missing in: \(text.prefix(80))")
            let opens = text.filter { $0 == "{" }.count
            let closes = text.filter { $0 == "}" }.count
            #expect(opens == closes, "unbalanced braces in: \(text)")
        }
    }

    @Test func parsesAReading() {
        let json = #"{"data":{"rateLimit":{"cost":6,"remaining":4321,"resetAt":"2026-10-01T18:00:00Z"},"repository":{}}}"#
        let signal = GitHubRateLimitSignal.parse(GHCommandResult(stdout: json))
        #expect(signal == .reading(cost: 6, remaining: 4321,
                                   resetAt: ISO8601DateFormatter().date(from: "2026-10-01T18:00:00Z")!))
    }

    @Test func recognisesARateLimitError() {
        let body = #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#
        #expect(GitHubRateLimitSignal.parse(GHCommandResult(stdout: body, exitStatus: 1)) == .limited)
        #expect(GitHubRateLimitSignal.parse(GHCommandResult(stdout: "", stderr: "gh: API rate limit exceeded for user", exitStatus: 1)) == .limited)
    }

    @Test func otherFailuresAreNotRateLimitSignals() {
        #expect(GitHubRateLimitSignal.parse(GHCommandResult(stdout: "not json", exitStatus: 1)) == nil)
        #expect(GitHubRateLimitSignal.parse(GHCommandResult(stdout: #"{"nameWithOwner":"acme/acme-prod"}"#)) == nil)
    }

    /// stdout is read structurally: a PR whose title names the error is data,
    /// not a rate-limit error, and the reading beside it still counts.
    @Test func aTitleMentioningTheErrorIsNotARateLimit() {
        let json = #"{"data":{"rateLimit":{"cost":1,"remaining":4000,"resetAt":"2026-10-01T18:00:00Z"},"repository":{"pullRequests":{"nodes":[{"title":"Handle RATE_LIMITED: API rate limit exceeded"}]}}}}"#
        let signal = GitHubRateLimitSignal.parse(GHCommandResult(stdout: json))
        #expect(signal == .reading(cost: 1, remaining: 4000,
                                   resetAt: ISO8601DateFormatter().date(from: "2026-10-01T18:00:00Z")!))
    }

    @Test func managerRecordsTheLatestReadingAndCallsBack() async {
        let json = #"{"data":{"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-10-01T18:00:00Z"},"repository":{"pr0":null}}}"#
        let manager = PRStatusManager(ghRunner: { _, _ in GHCommandResult(stdout: json) })
        let box = SignalBox()
        await manager.setOnRateLimitSignal { await box.add($0) }
        // The stub answers EVERY gh call with the rateLimit JSON, so any path that
        // reaches runGHResult records a signal. fetchOpenPRs always runs gh: its
        // `gh repo view` goes through runGHResult before anything else.
        _ = await manager.fetchOpenPRs(repoPath: "/wt/acme-prod")
        #expect(await box.items.contains { if case .reading(_, 4999, _) = $0 { true } else { false } })
        if case .reading(_, let remaining, _)? = await manager.latestRateLimitReading() {
            #expect(remaining == 4999)
        } else { Issue.record("no reading") }
    }
}

private actor SignalBox {
    var items: [GitHubRateLimitSignal] = []
    func add(_ s: GitHubRateLimitSignal) { items.append(s) }
}
