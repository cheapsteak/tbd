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

    @Test("maps required pending checks to .pending")
    func mapsPendingChecks() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "UNKNOWN",
            requiredChecksPending: true
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + CLEAN + required pending checks to .pending")
    func mapsPendingChecksOverClean() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN",
            requiredChecksPending: true
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + BLOCKED + required pending checks to .pending")
    func mapsPendingChecksOverBlocked() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            requiredChecksPending: true
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + BLOCKED + REVIEW_REQUIRED + passing required checks to .mergeable")
    func mapsReviewRequiredWithPassingChecksToMergeable() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            requiredChecksFailing: false,
            requiredChecksPending: false
        )
        #expect(status == .mergeable)
    }

    @Test("maps OPEN + BLOCKED + REVIEW_REQUIRED + required pending checks to .pending (pending wins)")
    func mapsReviewRequiredWithPendingChecksToPending() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            requiredChecksPending: true
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

    @Test("maps UNSTABLE + required pending checks to .pending (a required check still running)")
    func mapsUnstablePendingChecks() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "UNSTABLE",
            requiredChecksPending: true
        )
        #expect(status == .pending)
    }

    @Test("maps unknown future merge state to .blocked")
    func mapsUnknownFutureMergeState() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeStateStatus: "SOME_FUTURE_STATE")
        #expect(status == .blocked)
    }

    @Test("maps unknown future merge state with required pending checks to .pending")
    func mapsPendingUnknownFutureMergeState() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "SOME_FUTURE_STATE",
            requiredChecksPending: true
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
            requiredChecksFailing: false
        )
        #expect(status == .mergeable)
    }

    @Test("maps BLOCKED + failing (required) status check to .checksFailed")
    func mapsRequiredFailingCheckToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            requiredChecksFailing: true
        )
        #expect(status == .checksFailed)
    }

    @Test("draft wins over failing status checks")
    func mapsDraftOverFailingChecks() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN",
            isDraft: true,
            requiredChecksFailing: true
        )
        #expect(status == .draft)
    }

    @Test("failing wins over pending when both signals are set (BLOCKED)")
    func mapsFailingOverPendingBlocked() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            requiredChecksFailing: true,
            requiredChecksPending: true
        )
        #expect(status == .checksFailed)
    }

    @Test("failing wins over pending when both signals are set (CLEAN)")
    func mapsFailingOverPendingClean() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN",
            requiredChecksFailing: true,
            requiredChecksPending: true
        )
        #expect(status == .checksFailed)
    }

    @Test("maps UNSTABLE + failing required check to .checksFailed")
    func mapsUnstableRequiredFailingToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "UNSTABLE",
            requiredChecksFailing: true
        )
        #expect(status == .checksFailed)
    }

    @Test("maps DIRTY + failing required check to .checksFailed")
    func mapsDirtyRequiredFailingToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "DIRTY",
            requiredChecksFailing: true
        )
        #expect(status == .checksFailed)
    }

    @Test("maps BEHIND + failing required check to .checksFailed")
    func mapsBehindRequiredFailingToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BEHIND",
            requiredChecksFailing: true
        )
        #expect(status == .checksFailed)
    }

    @Test("maps unknown future merge state + failing required check to .checksFailed")
    func mapsUnknownFutureMergeStateRequiredFailingToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "SOME_FUTURE_STATE",
            requiredChecksFailing: true
        )
        #expect(status == .checksFailed)
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

    // MARK: - parsePRCheckDetail

    @Test("parsePRCheckDetail parses a mixed CheckRun + StatusContext blob")
    func parsePRCheckDetailMixed() throws {
        let json = """
        {
          "data": { "repository": { "pullRequest": { "commits": { "nodes": [
            { "commit": { "statusCheckRollup": { "state": "FAILURE", "contexts": {
              "pageInfo": { "hasNextPage": false },
              "nodes": [
                { "__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "FAILURE", "isRequired": true },
                { "__typename": "StatusContext", "context": "ci/legacy", "state": "PENDING" }
              ]
            } } } }
          ] } } } }
        }
        """.data(using: .utf8)!

        let detail = try PRStatusManager.parsePRCheckDetail(fromJSON: json)
        #expect(detail.rollupState == "FAILURE")
        #expect(detail.truncated == false)
        #expect(detail.contexts.count == 2)

        let build = detail.contexts[0]
        #expect(build.name == "build")
        #expect(build.status == "COMPLETED")
        #expect(build.conclusion == "FAILURE")
        #expect(build.state == nil)
        #expect(build.isRequired == true)

        let legacy = detail.contexts[1]
        #expect(legacy.name == "ci/legacy")
        #expect(legacy.status == nil)
        #expect(legacy.conclusion == nil)
        #expect(legacy.state == "PENDING")
        #expect(legacy.isRequired == nil)
    }

    @Test("parsePRCheckDetail collects across multiple commit nodes and skips nameless nodes")
    func parsePRCheckDetailMultipleCommitNodes() throws {
        let json = """
        {
          "data": { "repository": { "pullRequest": { "commits": { "nodes": [
            { "commit": { "statusCheckRollup": { "state": "SUCCESS", "contexts": {
              "pageInfo": { "hasNextPage": false },
              "nodes": [
                { "__typename": "CheckRun", "name": "a", "status": "COMPLETED", "conclusion": "SUCCESS" },
                { "__typename": "Other" }
              ]
            } } } },
            { "commit": { "statusCheckRollup": { "state": "SUCCESS", "contexts": {
              "pageInfo": { "hasNextPage": false },
              "nodes": [
                { "__typename": "StatusContext", "context": "b", "state": "SUCCESS" }
              ]
            } } } }
          ] } } } }
        }
        """.data(using: .utf8)!

        let detail = try PRStatusManager.parsePRCheckDetail(fromJSON: json)
        #expect(detail.contexts.count == 2)
        #expect(detail.contexts.map(\.name) == ["a", "b"])
    }

    @Test("parsePRCheckDetail throws on malformed outer shape")
    func parsePRCheckDetailThrowsOnBadJSON() {
        let json = """
        { "data": { "nope": true } }
        """.data(using: .utf8)!
        #expect(throws: PRStatusError.self) {
            _ = try PRStatusManager.parsePRCheckDetail(fromJSON: json)
        }
    }

    @Test("parsePRCheckDetail marks truncated when contexts have another page")
    func parsePRCheckDetailTruncated() throws {
        let json = """
        {
          "data": { "repository": { "pullRequest": { "commits": { "nodes": [
            { "commit": { "statusCheckRollup": { "state": "PENDING", "contexts": {
              "pageInfo": { "hasNextPage": true },
              "nodes": [
                { "__typename": "CheckRun", "name": "build", "status": "COMPLETED", "conclusion": "SUCCESS", "isRequired": true }
              ]
            } } } }
          ] } } } }
        }
        """.data(using: .utf8)!

        let detail = try PRStatusManager.parsePRCheckDetail(fromJSON: json)
        #expect(detail.truncated == true)
        #expect(detail.rollupState == "PENDING")
        #expect(detail.contexts.count == 1)
    }

    @Test("parsePRCheckDetail returns an empty detail for a null statusCheckRollup (no checks at all)")
    func parsePRCheckDetailNullRollup() throws {
        let json = """
        {
          "data": { "repository": { "pullRequest": { "commits": { "nodes": [
            { "commit": { "statusCheckRollup": null } }
          ] } } } }
        }
        """.data(using: .utf8)!

        let detail = try PRStatusManager.parsePRCheckDetail(fromJSON: json)
        #expect(detail.contexts.isEmpty)
        #expect(detail.rollupState == nil)
        #expect(detail.truncated == false)
    }

    // MARK: - checkSignals

    @Test("checkSignals reports failing for a required FAILURE CheckRun")
    func checkSignalsRequiredFailure() {
        let contexts = [
            PRStatusManager.CheckContext(name: "build", status: "COMPLETED", conclusion: "FAILURE", state: nil, isRequired: true)
        ]
        let signals = PRStatusManager.checkSignals(contexts: contexts, aggregateRollupState: "FAILURE")
        #expect(signals.failing == true)
        #expect(signals.pending == false)
    }

    @Test("checkSignals reports pending for a required IN_PROGRESS CheckRun with no conclusion")
    func checkSignalsRequiredPending() {
        let contexts = [
            PRStatusManager.CheckContext(name: "build", status: "IN_PROGRESS", conclusion: nil, state: nil, isRequired: true)
        ]
        let signals = PRStatusManager.checkSignals(contexts: contexts, aggregateRollupState: "PENDING")
        #expect(signals.failing == false)
        #expect(signals.pending == true)
    }

    @Test("checkSignals ignores non-required failing/running checks when a required check passes (core bug case)")
    func checkSignalsNonRequiredFailingRunningWithRequiredSuccess() {
        let contexts = [
            PRStatusManager.CheckContext(name: "lint", status: "COMPLETED", conclusion: "FAILURE", state: nil, isRequired: false),
            PRStatusManager.CheckContext(name: "flaky", status: "IN_PROGRESS", conclusion: nil, state: nil, isRequired: false),
            PRStatusManager.CheckContext(name: "build", status: "COMPLETED", conclusion: "SUCCESS", state: nil, isRequired: true)
        ]
        let signals = PRStatusManager.checkSignals(contexts: contexts, aggregateRollupState: "FAILURE")
        #expect(signals.failing == false)
        #expect(signals.pending == false)
    }

    @Test("checkSignals reports failing for a required ERROR StatusContext")
    func checkSignalsRequiredStatusContextError() {
        let contexts = [
            PRStatusManager.CheckContext(name: "ci/legacy", status: nil, conclusion: nil, state: "ERROR", isRequired: true)
        ]
        let signals = PRStatusManager.checkSignals(contexts: contexts, aggregateRollupState: "ERROR")
        #expect(signals.failing == true)
        #expect(signals.pending == false)
    }

    @Test("checkSignals with no required checks counts a failing check (unprotected repo fallback)")
    func checkSignalsUnprotectedRepoFailing() {
        let contexts = [
            PRStatusManager.CheckContext(name: "build", status: "COMPLETED", conclusion: "FAILURE", state: nil, isRequired: false),
            PRStatusManager.CheckContext(name: "lint", status: "COMPLETED", conclusion: "SUCCESS", state: nil, isRequired: false)
        ]
        let signals = PRStatusManager.checkSignals(contexts: contexts, aggregateRollupState: "FAILURE")
        #expect(signals.failing == true)
        #expect(signals.pending == false)
    }

    @Test("checkSignals with no required checks counts a running check as pending (unprotected repo fallback)")
    func checkSignalsUnprotectedRepoPending() {
        let contexts = [
            PRStatusManager.CheckContext(name: "build", status: "IN_PROGRESS", conclusion: nil, state: nil, isRequired: false)
        ]
        let signals = PRStatusManager.checkSignals(contexts: contexts, aggregateRollupState: "PENDING")
        #expect(signals.failing == false)
        #expect(signals.pending == true)
    }

    @Test("checkSignals with no required checks and all passing reports neither signal")
    func checkSignalsUnprotectedRepoAllPassing() {
        let contexts = [
            PRStatusManager.CheckContext(name: "build", status: "COMPLETED", conclusion: "SUCCESS", state: nil, isRequired: false),
            PRStatusManager.CheckContext(name: "ci/legacy", status: nil, conclusion: nil, state: "SUCCESS", isRequired: false)
        ]
        let signals = PRStatusManager.checkSignals(contexts: contexts, aggregateRollupState: nil)
        #expect(signals.failing == false)
        #expect(signals.pending == false)
    }

    @Test("checkSignals treats aggregate EXPECTED as pending even when listed required checks pass (post-push window)")
    func checkSignalsAggregateExpectedWithPassingRequired() {
        let contexts = [
            PRStatusManager.CheckContext(name: "build", status: "COMPLETED", conclusion: "SUCCESS", state: nil, isRequired: true)
        ]
        let signals = PRStatusManager.checkSignals(contexts: contexts, aggregateRollupState: "EXPECTED")
        #expect(signals.failing == false)
        #expect(signals.pending == true)
    }

    // MARK: - aggregateFallbackSignals

    @Test("aggregateFallbackSignals maps FAILURE to failing")
    func aggregateFallbackFailure() {
        let signals = PRStatusManager.aggregateFallbackSignals("FAILURE")
        #expect(signals.failing == true)
        #expect(signals.pending == false)
    }

    @Test("aggregateFallbackSignals maps PENDING to pending")
    func aggregateFallbackPending() {
        let signals = PRStatusManager.aggregateFallbackSignals("PENDING")
        #expect(signals.failing == false)
        #expect(signals.pending == true)
    }

    @Test("aggregateFallbackSignals maps SUCCESS and nil to no signals")
    func aggregateFallbackSuccessAndNil() {
        let success = PRStatusManager.aggregateFallbackSignals("SUCCESS")
        #expect(success.failing == false)
        #expect(success.pending == false)

        let none = PRStatusManager.aggregateFallbackSignals(nil)
        #expect(none.failing == false)
        #expect(none.pending == false)
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

    // MARK: - GraphQL query builder

    /// A malformed (unbalanced) GraphQL query is rejected by the server at parse time,
    /// which silently degrades to the keep-previous-status fallback. Guard the brace
    /// balance here so that can't regress.
    @Test("prCheckQuery produces brace-balanced GraphQL")
    func prCheckQueryIsBraceBalanced() {
        let query = PRStatusManager.prCheckQuery(owner: "o", name: "r", number: 21539)
        let opens = query.filter { $0 == "{" }.count
        let closes = query.filter { $0 == "}" }.count
        #expect(opens == closes, "unbalanced braces (\(opens) open vs \(closes) close) in: \(query)")
    }

    @Test("prCheckQuery embeds the PR number in both required positions")
    func prCheckQueryEmbedsNumber() {
        let query = PRStatusManager.prCheckQuery(owner: "o", name: "r", number: 21539)
        #expect(query.contains("pullRequest(number: 21539)"))
        #expect(query.contains("isRequired(pullRequestNumber: 21539)"))
    }

    // MARK: - Cache behavior

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
