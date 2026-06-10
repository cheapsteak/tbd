import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PRStatusManager Tests")
struct PRStatusManagerTests {

    // MARK: - State mapping

    @Test("maps OPEN + CLEAN to .mergeable")
    func mapsMergeableState() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "CLEAN")
        #expect(status == .mergeable)
    }

    @Test("maps OPEN + BLOCKED to .blocked")
    func mapsBlocked() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "BLOCKED")
        #expect(status == .blocked)
    }

    @Test("maps OPEN + DIRTY to .blocked")
    func mapsDirty() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "DIRTY")
        #expect(status == .blocked)
    }

    @Test("maps OPEN + BEHIND to .blocked")
    func mapsBehind() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "BEHIND")
        #expect(status == .blocked)
    }

    @Test("maps OPEN + UNKNOWN to .pending")
    func mapsPendingUnknown() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "UNKNOWN")
        #expect(status == .pending)
    }

    @Test("maps pending status checks to .pending")
    func mapsPendingChecks() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "UNKNOWN",
            statusCheckRollupState: "PENDING"
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + CLEAN + pending status checks to .pending")
    func mapsPendingChecksOverClean() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN",
            statusCheckRollupState: "PENDING"
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + BLOCKED + pending status checks to .pending")
    func mapsPendingChecksOverBlocked() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            statusCheckRollupState: "PENDING"
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + BLOCKED + REVIEW_REQUIRED + SUCCESS checks to .mergeable")
    func mapsReviewRequiredWithPassingChecksToMergeable() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            statusCheckRollupState: "SUCCESS"
        )
        #expect(status == .mergeable)
    }

    @Test("maps OPEN + BLOCKED + REVIEW_REQUIRED + nil checks to .mergeable")
    func mapsReviewRequiredWithNilChecksToMergeable() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            statusCheckRollupState: nil
        )
        #expect(status == .mergeable)
    }

    @Test("maps OPEN + BLOCKED + REVIEW_REQUIRED + pending checks to .pending (pending wins)")
    func mapsReviewRequiredWithPendingChecksToPending() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            statusCheckRollupState: "PENDING"
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + BLOCKED + empty reviewDecision to .blocked (review-required branch off)")
    func mapsBlockedWithEmptyReviewDecisionToBlocked() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            reviewDecision: ""
        )
        #expect(status == .blocked)
    }

    @Test("maps HAS_HOOKS to .mergeable")
    func mapsHasHooks() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "HAS_HOOKS")
        #expect(status == .mergeable)
    }

    @Test("maps UNSTABLE (non-required checks failing) to .mergeable")
    func mapsUnstable() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "UNSTABLE")
        #expect(status == .mergeable)
    }

    @Test("maps UNSTABLE + pending checks to .pending (non-required check still running)")
    func mapsUnstablePendingChecks() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "UNSTABLE",
            statusCheckRollupState: "PENDING"
        )
        #expect(status == .pending)
    }

    @Test("maps unknown future merge state to .blocked")
    func mapsUnknownFutureMergeState() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "SOME_FUTURE_STATE")
        #expect(status == .blocked)
    }

    @Test("maps unknown future merge state with pending checks to .pending")
    func mapsPendingUnknownFutureMergeState() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "SOME_FUTURE_STATE",
            statusCheckRollupState: "EXPECTED"
        )
        #expect(status == .pending)
    }

    @Test("maps MERGED to .merged")
    func mapsMerged() {
        let status = PRStatusManager.mapState(ghState: "MERGED", mergeStateStatus: "UNKNOWN")
        #expect(status == .merged)
    }

    @Test("maps CLOSED to .closed")
    func mapsClosed() {
        let status = PRStatusManager.mapState(ghState: "CLOSED", mergeStateStatus: "BLOCKED")
        #expect(status == .closed)
    }

    @Test("maps OPEN + CHANGES_REQUESTED to .changesRequested")
    func mapsChangesRequested() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "BLOCKED", reviewDecision: "CHANGES_REQUESTED")
        #expect(status == .changesRequested)
    }

    @Test("maps OPEN + CLEAN + CHANGES_REQUESTED to .changesRequested (review wins)")
    func mapsChangesRequestedOverClean() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "CLEAN", reviewDecision: "CHANGES_REQUESTED")
        #expect(status == .changesRequested)
    }

    @Test("maps draft PRs to .draft")
    func mapsDraft() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "CLEAN", isDraft: true)
        #expect(status == .draft)
    }

    @Test("maps CLEAN + failing (non-required) status check to .mergeable")
    func mapsNonRequiredFailingCheckStaysMergeable() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN",
            statusCheckRollupState: "FAILURE"
        )
        #expect(status == .mergeable)
    }

    @Test("maps BLOCKED + failing (required) status check to .checksFailed")
    func mapsRequiredFailingCheckToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            statusCheckRollupState: "FAILURE",
            requiredChecksFailing: true
        )
        #expect(status == .checksFailed)
    }

    @Test("maps BLOCKED + REVIEW_REQUIRED + failing (non-required) check to .mergeable")
    func mapsBlockedReviewRequiredNonRequiredFailingToMergeable() {
        // Bug case: PR blocked only by a missing review, with an unrelated
        // failing *non-required* check. The failing aggregate must NOT turn it red.
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            statusCheckRollupState: "FAILURE",
            requiredChecksFailing: false
        )
        #expect(status == .mergeable)
    }

    @Test("draft wins over failing status checks")
    func mapsDraftOverFailingChecks() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN",
            isDraft: true,
            statusCheckRollupState: "FAILURE"
        )
        #expect(status == .draft)
    }

    // MARK: - JSON parsing

    @Test("parseGraphQLResponse keeps all branch names")
    func parsesResponse() throws {
        let json = """
        {
          "data": {
            "viewer": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 42,
                    "url": "https://github.com/owner/repo/pull/42",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "isDraft": true,
                    "statusCheckRollup": { "state": "FAILURE" },
                    "reviewDecision": null,
                    "headRefName": "tbd/cool-feature",
                    "createdAt": "2026-03-24T10:00:00Z"
                  },
                  {
                    "number": 7,
                    "url": "https://github.com/owner/repo/pull/7",
                    "state": "MERGED",
                    "mergeStateStatus": "UNKNOWN",
                    "reviewDecision": null,
                    "headRefName": "tbd/old-feature",
                    "createdAt": "2026-03-20T10:00:00Z"
                  },
                  {
                    "number": 99,
                    "url": "https://github.com/owner/repo/pull/99",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": null,
                    "headRefName": "feature/not-tbd",
                    "createdAt": "2026-03-24T12:00:00Z"
                  }
                ]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let nodes = try PRStatusManager.parsePRNodes(from: json)
        #expect(nodes.count == 3)
        #expect(nodes[0].headRefName == "tbd/cool-feature")
        #expect(nodes[0].state == "OPEN")
        #expect(nodes[0].mergeStateStatus == "CLEAN")
        #expect(nodes[0].isDraft == true)
        #expect(nodes[0].statusCheckRollupState == "FAILURE")
        #expect(nodes[1].headRefName == "tbd/old-feature")
        #expect(nodes[2].headRefName == "feature/not-tbd")
    }

    @Test("parseGraphQLResponse ignores null nodes in partial results")
    func parsesResponseWithNullNodes() throws {
        let json = """
        {
          "data": {
            "viewer": {
              "pullRequests": {
                "nodes": [
                  null,
                  {
                    "number": 42,
                    "url": "https://github.com/owner/repo/pull/42",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": null,
                    "headRefName": "tbd/cool-feature",
                    "createdAt": "2026-03-24T10:00:00Z"
                  },
                  null,
                  {
                    "number": 7,
                    "url": "https://github.com/owner/repo/pull/7",
                    "state": "MERGED",
                    "mergeStateStatus": "UNKNOWN",
                    "reviewDecision": null,
                    "headRefName": "tbd/old-feature",
                    "createdAt": "2026-03-20T10:00:00Z"
                  },
                  {
                    "number": 99,
                    "url": "https://github.com/owner/repo/pull/99",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": null,
                    "headRefName": "feature/not-tbd",
                    "createdAt": "2026-03-24T12:00:00Z"
                  }
                ]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let nodes = try PRStatusManager.parsePRNodes(from: json)
        #expect(nodes.count == 3)
        #expect(nodes[0].headRefName == "tbd/cool-feature")
        #expect(nodes[1].headRefName == "tbd/old-feature")
        #expect(nodes[2].headRefName == "feature/not-tbd")
    }

    @Test("graphQLOutputData keeps non-empty stdout")
    func graphQLOutputDataUsesNonEmptyStdout() {
        let stdout = """
        {"data":{"viewer":{"pullRequests":{"nodes":[]}}}}
        """

        let data = PRStatusManager.graphQLOutputData(stdout: stdout)

        #expect(data == stdout.data(using: .utf8))
    }

    @Test("graphQLOutputData returns nil when stdout is empty")
    func graphQLOutputDataRejectsEmptyStdout() {
        let data = PRStatusManager.graphQLOutputData(stdout: " \n")

        #expect(data == nil)
    }

    @Test("branchCandidates keeps only the local branch when no upstream is configured")
    func branchCandidatesWithoutUpstream() {
        let candidates = PRStatusManager.branchCandidates(localBranch: "feature/local", upstreamBranch: nil)

        #expect(candidates == ["feature/local"])
    }

    @Test("branchCandidates includes a distinct upstream branch for PR matching")
    func branchCandidatesWithDistinctUpstream() {
        let candidates = PRStatusManager.branchCandidates(
            localBranch: "feature/local",
            upstreamBranch: "tbd/upstream-feature"
        )

        #expect(candidates == ["feature/local", "tbd/upstream-feature"])
    }

    // MARK: - Required-check parsing

    @Test("requiredChecksFailing is true when a required CheckRun is FAILURE")
    func requiredCheckRunFailureIsRequiredFailing() throws {
        let json = """
        {
          "data": { "repository": { "pullRequest": { "commits": { "nodes": [
            { "commit": { "statusCheckRollup": { "contexts": { "nodes": [
              { "__typename": "CheckRun", "conclusion": "FAILURE", "isRequired": true }
            ] } } } }
          ] } } } }
        }
        """.data(using: .utf8)!

        #expect(try PRStatusManager.requiredChecksFailing(fromContextsJSON: json) == true)
    }

    @Test("requiredChecksFailing is false when only a non-required check fails")
    func nonRequiredFailureWithRequiredSuccessIsNotRequiredFailing() throws {
        let json = """
        {
          "data": { "repository": { "pullRequest": { "commits": { "nodes": [
            { "commit": { "statusCheckRollup": { "contexts": { "nodes": [
              { "__typename": "CheckRun", "conclusion": "FAILURE", "isRequired": false },
              { "__typename": "CheckRun", "conclusion": "SUCCESS", "isRequired": true }
            ] } } } }
          ] } } } }
        }
        """.data(using: .utf8)!

        #expect(try PRStatusManager.requiredChecksFailing(fromContextsJSON: json) == false)
    }

    @Test("requiredChecksFailing is true when a required StatusContext is ERROR")
    func requiredStatusContextErrorIsRequiredFailing() throws {
        let json = """
        {
          "data": { "repository": { "pullRequest": { "commits": { "nodes": [
            { "commit": { "statusCheckRollup": { "contexts": { "nodes": [
              { "__typename": "StatusContext", "state": "ERROR", "isRequired": true }
            ] } } } }
          ] } } } }
        }
        """.data(using: .utf8)!

        #expect(try PRStatusManager.requiredChecksFailing(fromContextsJSON: json) == true)
    }

    // MARK: - parseOwnerRepo

    @Test("parseOwnerRepo extracts owner and name from a PR URL")
    func parseOwnerRepoFromURL() {
        let result = PRStatusManager.parseOwnerRepo(fromURL: "https://github.com/cheapsteak/tbd/pull/263")
        #expect(result?.owner == "cheapsteak")
        #expect(result?.name == "tbd")
    }

    @Test("parseOwnerRepo returns nil for a malformed URL")
    func parseOwnerRepoMalformed() {
        #expect(PRStatusManager.parseOwnerRepo(fromURL: "https://example.com/not-a-pr") == nil)
    }

    // MARK: - GraphQL query builders

    /// A malformed (unbalanced) GraphQL query is rejected by the server at parse time,
    /// which silently trips the conservative "assume failing" fallback and forces a red icon.
    /// Guard the brace balance here so that can't regress.
    @Test("isRequired query builders produce brace-balanced GraphQL")
    func checkQueriesAreBraceBalanced() {
        for query in [
            PRStatusManager.requiredChecksQuery(owner: "o", name: "r", number: 21539),
            PRStatusManager.prCheckDetailQuery(owner: "o", name: "r", number: 21539)
        ] {
            let opens = query.filter { $0 == "{" }.count
            let closes = query.filter { $0 == "}" }.count
            #expect(opens == closes, "unbalanced braces (\(opens) open vs \(closes) close) in: \(query)")
        }
    }

    @Test("isRequired query embeds the PR number in both required positions")
    func checkQueriesEmbedNumber() {
        let query = PRStatusManager.requiredChecksQuery(owner: "o", name: "r", number: 21539)
        #expect(query.contains("pullRequest(number: 21539)"))
        #expect(query.contains("isRequired(pullRequestNumber: 21539)"))
    }

    @Test("allStatuses reflects cache after manual seed")
    func cacheRoundTrip() async {
        let manager = PRStatusManager()
        let id = UUID()
        let status = PRStatus(number: 1, url: "https://github.com/o/r/pull/1", state: .mergeable)
        await manager.seedForTesting(worktreeID: id, status: status)
        let all = await manager.allStatuses()
        #expect(all[id] == status)
    }

    @Test("invalidate removes entry from cache")
    func invalidate() async {
        let manager = PRStatusManager()
        let id = UUID()
        let status = PRStatus(number: 2, url: "https://github.com/o/r/pull/2", state: .pending)
        await manager.seedForTesting(worktreeID: id, status: status)
        await manager.invalidate(worktreeID: id)
        let all = await manager.allStatuses()
        #expect(all[id] == nil)
    }
}
