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

    @Test("maps OPEN + UNSTABLE + FAILURE checks to .mergeable (non-required checks failing)")
    func mapsUnstableWithFailingChecksToMergeable() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "UNSTABLE",
            statusCheckRollupState: "FAILURE"
        )
        #expect(status == .mergeable)
    }

    @Test("maps OPEN + UNSTABLE + SUCCESS checks to .mergeable")
    func mapsUnstableWithSuccessChecksToMergeable() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "UNSTABLE",
            statusCheckRollupState: "SUCCESS"
        )
        #expect(status == .mergeable)
    }

    @Test("maps OPEN + UNSTABLE + PENDING checks to .pending (pending wins)")
    func mapsUnstableWithPendingChecksToPending() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "UNSTABLE",
            statusCheckRollupState: "PENDING"
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + UNSTABLE + nil checks to .mergeable")
    func mapsUnstableWithNilChecksToMergeable() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "UNSTABLE",
            statusCheckRollupState: nil
        )
        #expect(status == .mergeable)
    }

    @Test("maps OPEN + BLOCKED + FAILURE checks to .checksFailed (required-check failure stays red)")
    func mapsBlockedWithFailingChecksToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            statusCheckRollupState: "FAILURE"
        )
        #expect(status == .checksFailed)
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

    @Test("maps failing status checks to .checksFailed")
    func mapsFailingChecks() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN",
            statusCheckRollupState: "FAILURE"
        )
        #expect(status == .checksFailed)
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
