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

    @Test("parsePRNodes decodes mergeQueueEntry.position and tolerates a null entry")
    func parsesMergeQueuePosition() throws {
        let json = """
        {
          "data": {
            "viewer": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 12,
                    "url": "https://github.com/acme/acme-prod/pull/12",
                    "state": "OPEN",
                    "mergeStateStatus": "UNKNOWN",
                    "reviewDecision": null,
                    "headRefName": "acme/queued-feature",
                    "createdAt": "2026-03-24T10:00:00Z",
                    "mergeQueueEntry": { "position": 3 }
                  },
                  {
                    "number": 34,
                    "url": "https://github.com/acme/acme-prod/pull/34",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": null,
                    "headRefName": "acme/not-queued",
                    "createdAt": "2026-03-24T11:00:00Z",
                    "mergeQueueEntry": null
                  },
                  {
                    "number": 56,
                    "url": "https://github.com/acme/acme-prod/pull/56",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": null,
                    "headRefName": "acme/no-entry-key",
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
        #expect(nodes[0].mergeQueuePosition == 3)      // front-of-queue is 1-indexed; this PR is 3rd
        #expect(nodes[1].mergeQueuePosition == nil)    // explicit null entry
        #expect(nodes[2].mergeQueuePosition == nil)    // absent key entirely
    }

    // MARK: - parsePRByBranch (rewritten refresh() decoder)

    @Test("parsePRByBranch decodes the same field set, including mergeQueuePosition")
    func parsePRByBranchDecodesFields() throws {
        let json = """
        {
          "data": {
            "repository": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 77,
                    "url": "https://github.com/acme/acme-prod/pull/77",
                    "state": "OPEN",
                    "mergeStateStatus": "UNKNOWN",
                    "reviewDecision": "APPROVED",
                    "isDraft": false,
                    "mergeQueueEntry": { "position": 1 }
                  }
                ]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let result = try #require(try PRStatusManager.parsePRByBranch(from: json))
        #expect(result.number == 77)
        #expect(result.url == "https://github.com/acme/acme-prod/pull/77")
        #expect(result.state == "OPEN")
        #expect(result.mergeStateStatus == "UNKNOWN")
        #expect(result.reviewDecision == "APPROVED")
        #expect(result.isDraft == false)
        #expect(result.mergeQueuePosition == 1)
    }

    @Test("parsePRByBranch yields nil position for a null mergeQueueEntry")
    func parsePRByBranchNullQueueEntry() throws {
        let json = """
        {
          "data": {
            "repository": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 88,
                    "url": "https://github.com/acme/acme-prod/pull/88",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": null,
                    "isDraft": false,
                    "mergeQueueEntry": null
                  }
                ]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let result = try #require(try PRStatusManager.parsePRByBranch(from: json))
        #expect(result.mergeQueuePosition == nil)
        #expect(result.reviewDecision == nil)
    }

    @Test("parsePRByBranch picks the highest-priority PR (OPEN over CLOSED) for a reused branch")
    func parsePRByBranchPicksBestNode() throws {
        // Query orders newest-first; a branch reused across a closed then
        // reopened PR must resolve to the OPEN one regardless of node order.
        let json = """
        {
          "data": {
            "repository": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 91,
                    "url": "https://github.com/acme/acme-prod/pull/91",
                    "state": "CLOSED",
                    "mergeStateStatus": "UNKNOWN",
                    "reviewDecision": null,
                    "isDraft": false,
                    "mergeQueueEntry": null
                  },
                  {
                    "number": 90,
                    "url": "https://github.com/acme/acme-prod/pull/90",
                    "state": "OPEN",
                    "mergeStateStatus": "UNKNOWN",
                    "reviewDecision": null,
                    "isDraft": false,
                    "mergeQueueEntry": { "position": 2 }
                  }
                ]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let result = try #require(try PRStatusManager.parsePRByBranch(from: json))
        #expect(result.number == 90)
        #expect(result.state == "OPEN")
        #expect(result.mergeQueuePosition == 2)
    }

    @Test("parsePRByBranch returns nil when the branch has no PR")
    func parsePRByBranchEmpty() throws {
        let json = """
        { "data": { "repository": { "pullRequests": { "nodes": [] } } } }
        """.data(using: .utf8)!
        #expect(try PRStatusManager.parsePRByBranch(from: json) == nil)
    }

    @Test("parsePRByBranch throws on a malformed outer shape")
    func parsePRByBranchThrows() {
        let json = "{ \"data\": { \"repository\": null } }".data(using: .utf8)!
        #expect(throws: PRStatusError.self) {
            _ = try PRStatusManager.parsePRByBranch(from: json)
        }
    }

    // MARK: - prByBranchArgs (branch passed as a GraphQL variable, never interpolated)

    @Test("prByBranchArgs passes owner/name/branch as fields, not interpolated into the query")
    func prByBranchArgsUsesVariables() {
        let args = PRStatusManager.prByBranchArgs(owner: "acme", name: "acme-prod", branch: "feature/x")

        // The query itself must reference GraphQL variables, never the literal values.
        let queryArg = args.first { $0.hasPrefix("query=") }
        #expect(queryArg?.contains("$branch") == true)
        #expect(queryArg?.contains("$owner") == true)
        #expect(queryArg?.contains("acme-prod") == false)
        #expect(queryArg?.contains("feature/x") == false)

        // Values are bound as raw-string (`-f`) fields so String! typing survives.
        #expect(args.contains("owner=acme"))
        #expect(args.contains("name=acme-prod"))
        #expect(args.contains("branch=feature/x"))
        #expect(!args.contains("-F"))   // -F would coerce a numeric/bool-looking branch
    }

    @Test("prByBranchArgs handles a branch containing a double-quote without corrupting the query")
    func prByBranchArgsHandlesQuoteInBranch() {
        // A git ref may legally contain `"`. Interpolating it into the query text
        // (the old `headRefName: "\(branch)"`) produced malformed GraphQL; as a
        // variable field the quote is inert and round-trips verbatim.
        let branch = "foo\"bar"
        let args = PRStatusManager.prByBranchArgs(owner: "acme", name: "acme-prod", branch: branch)

        let queryArg = args.first { $0.hasPrefix("query=") }
        #expect(queryArg?.contains(branch) == false)   // the quote never reaches the query text
        #expect(queryArg?.contains("$branch") == true)

        // The branch survives intact as its own field value (execve arg), quote and all.
        #expect(args.contains("branch=\(branch)"))
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

    @Test("checkSignals ignores all checks when none are required (stacked PR / unprotected base)")
    func checkSignalsZeroRequiredIgnoresAllChecks() {
        let contexts = [
            PRStatusManager.CheckContext(name: "scoring", status: "COMPLETED", conclusion: "CANCELLED", state: nil, isRequired: false),
            PRStatusManager.CheckContext(name: "build", status: "IN_PROGRESS", conclusion: nil, state: nil, isRequired: false)
        ]
        let signals = PRStatusManager.checkSignals(contexts: contexts, aggregateRollupState: "FAILURE")
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

    // MARK: - Reason computation

    @Test("computeReason returns 'Merged' for merged state")
    func reasonForMerged() {
        let reason = PRStatusManager.computeReason(
            ghState: "MERGED",
            mergeStateStatus: "UNKNOWN",
            reviewDecision: "",
            isDraft: false
        )
        #expect(reason == "Merged")
    }

    @Test("computeReason returns 'Closed' for closed state")
    func reasonForClosed() {
        let reason = PRStatusManager.computeReason(
            ghState: "CLOSED",
            mergeStateStatus: "UNKNOWN",
            reviewDecision: "",
            isDraft: false
        )
        #expect(reason == "Closed")
    }

    @Test("computeReason returns 'Draft' for draft PRs")
    func reasonForDraft() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN",
            reviewDecision: "",
            isDraft: true
        )
        #expect(reason == "Draft")
    }

    @Test("computeReason returns 'Ready to merge' for mergeable state")
    func reasonForMergeable() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN",
            reviewDecision: "",
            isDraft: false
        )
        #expect(reason == "Ready to merge")
    }

    @Test("computeReason returns 'Merge conflicts' for DIRTY merge state")
    func reasonForConflicts() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeStateStatus: "DIRTY",
            reviewDecision: "",
            isDraft: false
        )
        #expect(reason == "Merge conflicts")
    }

    @Test("computeReason returns 'Behind base branch' for BEHIND merge state")
    func reasonForBehind() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeStateStatus: "BEHIND",
            reviewDecision: "",
            isDraft: false
        )
        #expect(reason == "Behind base branch")
    }

    @Test("computeReason returns 'Checks failing' for failed status checks")
    func reasonForFailingChecks() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN",
            reviewDecision: "",
            isDraft: false,
            requiredChecksFailing: true
        )
        #expect(reason == "Checks failing")
    }

    @Test("computeReason returns 'Checks pending' for pending status checks")
    func reasonForPendingChecks() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN",
            reviewDecision: "",
            isDraft: false,
            requiredChecksPending: true
        )
        #expect(reason == "Checks pending")
    }

    @Test("computeReason returns 'Checks failing' for a failing required check under UNSTABLE")
    func reasonForRequiredFailingUnderUnstable() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeStateStatus: "UNSTABLE",
            requiredChecksFailing: true
        )
        #expect(reason == "Checks failing")
    }

    @Test("computeReason returns 'Checks pending' for a pending required check under BLOCKED")
    func reasonForRequiredPendingUnderBlocked() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            requiredChecksPending: true
        )
        #expect(reason == "Checks pending")
    }

    @Test("computeReason returns 'Changes requested' for CHANGES_REQUESTED review decision")
    func reasonForChangesRequested() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            reviewDecision: "CHANGES_REQUESTED",
            isDraft: false
        )
        #expect(reason == "Changes requested")
    }

    @Test("computeReason returns 'Ready to merge' for REVIEW_REQUIRED with no other blocker (green state)")
    func reasonForReviewRequired() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED",
            isDraft: false
        )
        // REVIEW_REQUIRED with passing checks is actually mergeable (green), never shows a red/yellow warning
        #expect(reason == "Ready to merge")
    }

    // MARK: - Unified state+reason pairs (critical consistency tests)

    @Test("BLOCKED + REVIEW_REQUIRED + passing checks → (.mergeable, 'Ready to merge')")
    func stateAndReasonBlockedReviewRequiredMergeable() {
        let (state, reason) = PRStatusManager.mapStateAndReason(
            ghState: "OPEN",
            mergeStateStatus: "BLOCKED",
            reviewDecision: "REVIEW_REQUIRED"
        )
        #expect(state == .mergeable)
        #expect(reason == "Ready to merge")
    }

    @Test("UNSTABLE + no required signals → (.mergeable, 'Ready to merge')")
    func stateAndReasonUnstableNilChecksMergeable() {
        let (state, reason) = PRStatusManager.mapStateAndReason(
            ghState: "OPEN",
            mergeStateStatus: "UNSTABLE"
        )
        #expect(state == .mergeable)
        #expect(reason == "Ready to merge")
    }

    @Test("CLEAN + no pending checks → (.mergeable, 'Ready to merge')")
    func stateAndReasonCleanMergeable() {
        let (state, reason) = PRStatusManager.mapStateAndReason(
            ghState: "OPEN",
            mergeStateStatus: "CLEAN"
        )
        #expect(state == .mergeable)
        #expect(reason == "Ready to merge")
    }

    @Test("DIRTY → (.blocked, 'Merge conflicts')")
    func stateAndReasonDirtyConflicts() {
        let (state, reason) = PRStatusManager.mapStateAndReason(
            ghState: "OPEN",
            mergeStateStatus: "DIRTY"
        )
        #expect(state == .blocked)
        #expect(reason == "Merge conflicts")
    }

    @Test("BEHIND → (.blocked, 'Behind base branch')")
    func stateAndReasonBehind() {
        let (state, reason) = PRStatusManager.mapStateAndReason(
            ghState: "OPEN",
            mergeStateStatus: "BEHIND"
        )
        #expect(state == .blocked)
        #expect(reason == "Behind base branch")
    }

    // MARK: - Hydration & persistence

    /// Thread-safe fire counter for `@Sendable` callbacks.
    private actor FireCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    @Test("hydrate populates allStatuses without firing callbacks")
    func hydratePopulatesAllStatuses() async {
        let manager = PRStatusManager()
        let id = UUID()
        let status = PRStatus(number: 7, url: "https://example.com/pr/7", state: .mergeable, reason: "Ready to merge")
        await manager.hydrate([id: status])
        let all = await manager.allStatuses()
        #expect(all[id] == status)
    }

    @Test("hydrating merged then applying same merged does NOT fire onMergedTransition")
    func hydratedMergedDoesNotRefireTransition() async {
        let manager = PRStatusManager()
        let id = UUID()
        let counter = FireCounter()
        await manager.setOnMergedTransition { _, _ in await counter.bump() }

        let merged = PRStatus(number: 11, url: "https://example.com/pr/11", state: .merged, reason: "Merged")
        await manager.hydrate([id: merged])
        await manager.seedForTesting(worktreeID: id, status: merged)

        #expect(await counter.count == 0)
    }

    @Test("hydrating non-merged then applying merged DOES fire onMergedTransition once")
    func hydratedNonMergedFiresTransitionOnMerge() async {
        let manager = PRStatusManager()
        let id = UUID()
        let counter = FireCounter()
        await manager.setOnMergedTransition { _, _ in await counter.bump() }

        let open = PRStatus(number: 12, url: "https://example.com/pr/12", state: .mergeable, reason: "Ready to merge")
        let merged = PRStatus(number: 12, url: "https://example.com/pr/12", state: .merged, reason: "Merged")
        await manager.hydrate([id: open])
        await manager.seedForTesting(worktreeID: id, status: merged)

        #expect(await counter.count == 1)
    }

    @Test("apply fires onStatusPersist on change, not on identical status")
    func persistFiresOnChangeOnly() async {
        let manager = PRStatusManager()
        let id = UUID()
        let counter = FireCounter()
        await manager.setOnStatusPersist { _, _ in await counter.bump() }

        let statusA = PRStatus(number: 20, url: "https://example.com/pr/20", state: .mergeable, reason: "Ready to merge")
        let statusB = PRStatus(number: 20, url: "https://example.com/pr/20", state: .blocked, reason: "Blocked")

        await manager.seedForTesting(worktreeID: id, status: statusA)
        #expect(await counter.count == 1)

        // Identical status — no persist.
        await manager.seedForTesting(worktreeID: id, status: statusA)
        #expect(await counter.count == 1)

        // Different status — persist again.
        await manager.seedForTesting(worktreeID: id, status: statusB)
        #expect(await counter.count == 2)
    }

    @Test("apply does NOT fire onStatusPersist for a .merged status even though it changed")
    func persistSkipsMergedState() async {
        let manager = PRStatusManager()
        let id = UUID()
        let counter = FireCounter()
        await manager.setOnStatusPersist { _, _ in await counter.bump() }

        // Applying a .merged status is a genuine change (cache was empty), but
        // merged is the auto-archive trigger and must NOT be persisted —
        // persisting + hydrating it would defeat #295's archive-while-down
        // recovery (see PRStatusManager.apply doc comment).
        let merged = PRStatus(number: 30, url: "https://example.com/pr/30", state: .merged, reason: "Merged")
        await manager.seedForTesting(worktreeID: id, status: merged)
        #expect(await counter.count == 0)

        // The cache still updated, even though nothing was persisted.
        let all = await manager.allStatuses()
        #expect(all[id] == merged)
    }

    // MARK: - parseOpenPRNodes (repo.listOpenPRs)

    @Test("parseOpenPRNodes parses a fork PR and a draft PR")
    func parseOpenPRNodesHappyPath() {
        let json = """
        {
          "data": {
            "repository": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 454,
                    "title": "Weekly reset job",
                    "headRefName": "show-weekly-reset",
                    "isDraft": false,
                    "isCrossRepository": true,
                    "headRepositoryOwner": { "login": "zionts" }
                  },
                  {
                    "number": 12,
                    "title": "WIP: refactor",
                    "headRefName": "tbd/refactor",
                    "isDraft": true,
                    "isCrossRepository": false,
                    "headRepositoryOwner": { "login": "acme" }
                  }
                ]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let prs = PRStatusManager.parseOpenPRNodes(from: json)
        #expect(prs.count == 2)
        #expect(prs[0].number == 454)
        #expect(prs[0].title == "Weekly reset job")
        #expect(prs[0].headRefName == "show-weekly-reset")
        #expect(prs[0].headOwner == "zionts")
        #expect(prs[0].isCrossRepository == true)
        #expect(prs[0].isDraft == false)
        #expect(prs[1].number == 12)
        #expect(prs[1].isDraft == true)
        #expect(prs[1].isCrossRepository == false)
    }

    @Test("parseOpenPRNodes returns empty for empty nodes")
    func parseOpenPRNodesEmptyNodes() {
        let json = """
        {
          "data": {
            "repository": {
              "pullRequests": {
                "nodes": []
              }
            }
          }
        }
        """.data(using: .utf8)!

        let prs = PRStatusManager.parseOpenPRNodes(from: json)
        #expect(prs.isEmpty)
    }

    @Test("parseOpenPRNodes returns empty for malformed JSON")
    func parseOpenPRNodesMalformed() {
        let json = "{ not valid json".data(using: .utf8)!
        let prs = PRStatusManager.parseOpenPRNodes(from: json)
        #expect(prs.isEmpty)
    }

    @Test("parseOpenPRNodes returns empty when the outer shape is missing repository")
    func parseOpenPRNodesMissingRepository() {
        let json = """
        { "data": { "somethingElse": true } }
        """.data(using: .utf8)!
        let prs = PRStatusManager.parseOpenPRNodes(from: json)
        #expect(prs.isEmpty)
    }

    @Test("parseOpenPRNodes defaults headOwner to empty string when headRepositoryOwner is absent")
    func parseOpenPRNodesMissingHeadRepositoryOwner() {
        let json = """
        {
          "data": {
            "repository": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 7,
                    "title": "Same-repo PR",
                    "headRefName": "tbd/same-repo",
                    "isDraft": false,
                    "isCrossRepository": false
                  }
                ]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let prs = PRStatusManager.parseOpenPRNodes(from: json)
        #expect(prs.count == 1)
        #expect(prs[0].headOwner == "")
    }

    // MARK: - Number-first path (fetchAll partition + by-number resolution)

    @Test("partitionByPRNumber splits stored-number worktrees from the rest (both branches of the conditional)")
    func partitionByPRNumberSplits() {
        let a = UUID(); let b = UUID(); let c = UUID()
        let items: [(id: UUID, prNumber: Int?)] = [
            (a, 454),   // numbered → by-number path
            (b, nil),   // unnumbered → legacy branch-name path
            (c, 12)     // numbered → by-number path
        ]
        let (numbered, unnumbered) = PRStatusManager.partitionByPRNumber(items) { $0.prNumber }
        #expect(numbered.map { $0.id } == [a, c])
        #expect(unnumbered.map { $0.id } == [b])
    }

    @Test("parseNumberedPRNodes resolves a numbered (fork) worktree from the by-number response")
    func parseNumberedPRNodesResolvesForkPR() {
        // The fork PR's head branch never appears in the viewer-authored batch;
        // the stored number resolves it directly under its alias.
        let wt = UUID()
        let json = """
        {
          "data": {
            "repository": {
              "pr0": {
                "number": 454,
                "url": "https://github.com/acme/acme/pull/454",
                "state": "OPEN",
                "mergeStateStatus": "CLEAN",
                "reviewDecision": "APPROVED",
                "headRefName": "show-weekly-reset",
                "createdAt": "2026-07-10T00:00:00Z",
                "isDraft": false,
                "statusCheckRollup": { "state": "SUCCESS" },
                "mergeQueueEntry": { "position": 3 }
              }
            }
          }
        }
        """.data(using: .utf8)!

        let matches = PRStatusManager.parseNumberedPRNodes(from: json, aliases: [(alias: "pr0", worktreeID: wt)])
        #expect(matches.count == 1)
        #expect(matches.first?.worktreeID == wt)
        #expect(matches.first?.node.number == 454)
        #expect(matches.first?.node.headRefName == "show-weekly-reset")
        #expect(matches.first?.node.mergeQueuePosition == 3)
    }

    @Test("parseNumberedPRNodes skips a null pullRequest (deleted/inaccessible PR) without crashing")
    func parseNumberedPRNodesSkipsNullPullRequest() {
        let wt = UUID()
        let json = """
        { "data": { "repository": { "pr0": null } } }
        """.data(using: .utf8)!
        let matches = PRStatusManager.parseNumberedPRNodes(from: json, aliases: [(alias: "pr0", worktreeID: wt)])
        #expect(matches.isEmpty)
    }

    @Test("parseNumberedPRNodes returns empty for a malformed outer shape")
    func parseNumberedPRNodesMalformed() {
        let matches = PRStatusManager.parseNumberedPRNodes(
            from: "{ not json".data(using: .utf8)!,
            aliases: [(alias: "pr0", worktreeID: UUID())])
        #expect(matches.isEmpty)
    }

    @Test("unnumbered worktree still resolves via the legacy viewer-authored branch match (regression)")
    func unnumberedResolvesViaLegacyBranchMatch() throws {
        // The viewer batch carries a node for the worktree's branch; a worktree
        // with no stored number must still match it exactly as before.
        let json = """
        {
          "data": {
            "viewer": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 7,
                    "url": "https://github.com/acme/acme/pull/7",
                    "state": "OPEN",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": "APPROVED",
                    "headRefName": "feature-x",
                    "createdAt": "2026-07-01T00:00:00Z",
                    "isDraft": false,
                    "statusCheckRollup": { "state": "SUCCESS" }
                  }
                ]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let nodes = try PRStatusManager.parsePRNodes(from: json)
        let byBranch = PRStatusManager.bestNodeByBranch(nodes)
        let candidates = PRStatusManager.branchCandidates(localBranch: "feature-x", upstreamBranch: nil)
        let node = candidates.compactMap { byBranch[$0] }.first
        #expect(node?.number == 7)
    }

    // MARK: - Partial-results tolerance (regression guard, PR #208)

    @Test("parseOpenPRNodes yields nodes from a body carrying BOTH an errors array and valid data.repository")
    func parseOpenPRNodesToleratesPartialErrors() {
        // `gh api graphql` exits non-zero and includes `errors` when one node
        // fails, yet still returns usable `data`. The parse must read the data
        // regardless — the caller no longer bails on the non-zero exit.
        let json = """
        {
          "errors": [
            { "type": "NOT_FOUND", "message": "Could not resolve to a PullRequest." }
          ],
          "data": {
            "repository": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 454,
                    "title": "Weekly reset job",
                    "headRefName": "show-weekly-reset",
                    "isDraft": false,
                    "isCrossRepository": true,
                    "headRepositoryOwner": { "login": "zionts" }
                  }
                ]
              }
            }
          }
        }
        """.data(using: .utf8)!

        let prs = PRStatusManager.parseOpenPRNodes(from: json)
        #expect(prs.count == 1)
        #expect(prs[0].number == 454)
    }

    @Test("parseNumberedPRNodes yields matches from a body carrying BOTH an errors array and valid data.repository")
    func parseNumberedPRNodesToleratesPartialErrors() {
        // One aliased PR errored (stale/deleted fork PR) → non-zero exit + errors,
        // but the sibling aliases still carry usable nodes.
        let wt = UUID()
        let json = """
        {
          "errors": [
            { "path": ["repository", "pr1"], "message": "Could not resolve to a PullRequest." }
          ],
          "data": {
            "repository": {
              "pr0": {
                "number": 454,
                "url": "https://github.com/acme/acme/pull/454",
                "state": "OPEN",
                "mergeStateStatus": "CLEAN",
                "reviewDecision": "APPROVED",
                "headRefName": "show-weekly-reset",
                "createdAt": "2026-07-10T00:00:00Z",
                "isDraft": false,
                "statusCheckRollup": { "state": "SUCCESS" },
                "mergeQueueEntry": { "position": 3 }
              },
              "pr1": null
            }
          }
        }
        """.data(using: .utf8)!

        let matches = PRStatusManager.parseNumberedPRNodes(
            from: json,
            aliases: [(alias: "pr0", worktreeID: wt), (alias: "pr1", worktreeID: UUID())])
        #expect(matches.count == 1)
        #expect(matches.first?.worktreeID == wt)
        #expect(matches.first?.node.number == 454)
    }

    @Test("numberedPRQuery is brace-balanced and aliases each PR number")
    func numberedPRQueryBraceBalancedAndAliased() {
        let query = PRStatusManager.numberedPRQuery(aliases: [(alias: "pr0", number: 454), (alias: "pr1", number: 12)])
        let opens = query.filter { $0 == "{" }.count
        let closes = query.filter { $0 == "}" }.count
        #expect(opens == closes, "unbalanced braces (\(opens) open vs \(closes) close) in: \(query)")
        #expect(query.contains("pr0: pullRequest(number: 454)"))
        #expect(query.contains("pr1: pullRequest(number: 12)"))
        #expect(query.contains("repository(owner: $owner, name: $name)"))
    }
}
