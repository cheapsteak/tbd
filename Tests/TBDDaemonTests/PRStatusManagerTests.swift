import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PRStatusManager Tests")
struct PRStatusManagerTests {

    // MARK: - State mapping

    @Test("maps OPEN + CLEAN to .mergeable")
    func mapsMergeableState() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeVerdictRaw: "CLEAN")
        #expect(status == .mergeable)
    }

    @Test("maps OPEN + BLOCKED to .blocked")
    func mapsBlocked() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeVerdictRaw: "BLOCKED")
        #expect(status == .blocked)
    }

    @Test("maps OPEN + DIRTY to .blocked")
    func mapsDirty() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeVerdictRaw: "DIRTY")
        #expect(status == .blocked)
    }

    @Test("maps OPEN + BEHIND to .blocked")
    func mapsBehind() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeVerdictRaw: "BEHIND")
        #expect(status == .blocked)
    }

    @Test("maps OPEN + UNKNOWN to .pending")
    func mapsPendingUnknown() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeVerdictRaw: "UNKNOWN")
        #expect(status == .pending)
    }

    @Test("maps required pending checks to .pending")
    func mapsPendingChecks() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "UNKNOWN",
            requiredChecksPending: true
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + CLEAN + required pending checks to .pending")
    func mapsPendingChecksOverClean() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "CLEAN",
            requiredChecksPending: true
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + BLOCKED + required pending checks to .pending")
    func mapsPendingChecksOverBlocked() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "BLOCKED",
            requiredChecksPending: true
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + BLOCKED + REVIEW_REQUIRED + passing required checks to .mergeable")
    func mapsReviewRequiredWithPassingChecksToMergeable() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "BLOCKED",
            reviewVerdictRaw: "REVIEW_REQUIRED",
            requiredChecksFailing: false,
            requiredChecksPending: false
        )
        #expect(status == .mergeable)
    }

    @Test("maps OPEN + BLOCKED + REVIEW_REQUIRED + required pending checks to .pending (pending wins)")
    func mapsReviewRequiredWithPendingChecksToPending() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "BLOCKED",
            reviewVerdictRaw: "REVIEW_REQUIRED",
            requiredChecksPending: true
        )
        #expect(status == .pending)
    }

    @Test("maps OPEN + BLOCKED + empty reviewDecision to .blocked (review-required branch off)")
    func mapsBlockedWithEmptyReviewDecisionToBlocked() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "BLOCKED",
            reviewVerdictRaw: ""
        )
        #expect(status == .blocked)
    }

    @Test("maps HAS_HOOKS to .mergeable")
    func mapsHasHooks() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeVerdictRaw: "HAS_HOOKS")
        #expect(status == .mergeable)
    }

    @Test("maps UNSTABLE (non-required checks failing) to .mergeable")
    func mapsUnstable() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeVerdictRaw: "UNSTABLE")
        #expect(status == .mergeable)
    }

    @Test("maps UNSTABLE + required pending checks to .pending (a required check still running)")
    func mapsUnstablePendingChecks() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "UNSTABLE",
            requiredChecksPending: true
        )
        #expect(status == .pending)
    }

    @Test("maps unknown future merge state to .blocked")
    func mapsUnknownFutureMergeState() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeVerdictRaw: "SOME_FUTURE_STATE")
        #expect(status == .blocked)
    }

    @Test("maps unknown future merge state with required pending checks to .pending")
    func mapsPendingUnknownFutureMergeState() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "SOME_FUTURE_STATE",
            requiredChecksPending: true
        )
        #expect(status == .pending)
    }

    @Test("maps MERGED to .merged")
    func mapsMerged() {
        let status = PRStatusManager.mapState(ghState: "MERGED", mergeVerdictRaw: "UNKNOWN")
        #expect(status == .merged)
    }

    @Test("maps CLOSED to .closed")
    func mapsClosed() {
        let status = PRStatusManager.mapState(ghState: "CLOSED", mergeVerdictRaw: "BLOCKED")
        #expect(status == .closed)
    }

    @Test("maps OPEN + CHANGES_REQUESTED to .changesRequested")
    func mapsChangesRequested() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeVerdictRaw: "BLOCKED", reviewVerdictRaw: "CHANGES_REQUESTED")
        #expect(status == .changesRequested)
    }

    @Test("maps OPEN + CLEAN + CHANGES_REQUESTED to .changesRequested (review wins)")
    func mapsChangesRequestedOverClean() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeVerdictRaw: "CLEAN", reviewVerdictRaw: "CHANGES_REQUESTED")
        #expect(status == .changesRequested)
    }

    @Test("maps draft PRs to .draft")
    func mapsDraft() {
        let status = PRStatusManager.mapState(ghState: "OPEN", mergeVerdictRaw: "CLEAN", isDraft: true)
        #expect(status == .draft)
    }

    @Test("maps CLEAN + failing (non-required) status check to .mergeable")
    func mapsNonRequiredFailingCheckStaysMergeable() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "CLEAN",
            requiredChecksFailing: false
        )
        #expect(status == .mergeable)
    }

    @Test("maps BLOCKED + failing (required) status check to .checksFailed")
    func mapsRequiredFailingCheckToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "BLOCKED",
            requiredChecksFailing: true
        )
        #expect(status == .checksFailed)
    }

    @Test("draft wins over failing status checks")
    func mapsDraftOverFailingChecks() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "CLEAN",
            isDraft: true,
            requiredChecksFailing: true
        )
        #expect(status == .draft)
    }

    @Test("failing wins over pending when both signals are set (BLOCKED)")
    func mapsFailingOverPendingBlocked() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "BLOCKED",
            requiredChecksFailing: true,
            requiredChecksPending: true
        )
        #expect(status == .checksFailed)
    }

    @Test("failing wins over pending when both signals are set (CLEAN)")
    func mapsFailingOverPendingClean() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "CLEAN",
            requiredChecksFailing: true,
            requiredChecksPending: true
        )
        #expect(status == .checksFailed)
    }

    @Test("maps UNSTABLE + failing required check to .checksFailed")
    func mapsUnstableRequiredFailingToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "UNSTABLE",
            requiredChecksFailing: true
        )
        #expect(status == .checksFailed)
    }

    @Test("maps DIRTY + failing required check to .checksFailed")
    func mapsDirtyRequiredFailingToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "DIRTY",
            requiredChecksFailing: true
        )
        #expect(status == .checksFailed)
    }

    @Test("maps BEHIND + failing required check to .checksFailed")
    func mapsBehindRequiredFailingToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "BEHIND",
            requiredChecksFailing: true
        )
        #expect(status == .checksFailed)
    }

    @Test("maps unknown future merge state + failing required check to .checksFailed")
    func mapsUnknownFutureMergeStateRequiredFailingToChecksFailed() {
        let status = PRStatusManager.mapState(
            ghState: "OPEN",
            mergeVerdictRaw: "SOME_FUTURE_STATE",
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
        #expect(nodes[0].mergeVerdictRaw == "CLEAN")
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

    @Test("branchCandidates keeps only the local branch when the tracked branch is the base")
    func branchCandidatesForBaseTrackingBranch() {
        // The shape every worktree branch cut from the default branch has. Under
        // git's default push config `@{push}` reports nothing here, so the local
        // branch is all that remains.
        let candidates = PRStatusManager.branchCandidates(
            localBranch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main",
            pushBranch: .noPushDestination)

        #expect(candidates == ["tbd/my-branch"])
    }

    @Test("branchCandidates adds the tracked branch for a rename-push under the default push config")
    func branchCandidatesRenamePushWithoutPushResolution() {
        // Measured on real git: with `push.default = simple`, a rename-push
        // resolves NO push destination — same answer as a base-tracking branch.
        // The tracked branch is therefore the only thing that can find this PR,
        // and it is safe to offer because it is not the default branch.
        let candidates = PRStatusManager.branchCandidates(
            localBranch: "local-x", upstreamBranch: "renamed-on-remote", defaultBranch: "main",
            pushBranch: .noPushDestination)

        #expect(candidates == ["local-x", "renamed-on-remote"])
    }

    @Test("branchCandidates adds a resolved push branch even when the stored default branch is wrong")
    func branchCandidatesResolvedPushBranchStandsAlone() {
        // `@{push}` is git's own answer about where the commits land, so it does
        // not depend on the stored default branch being right. Here the stored
        // default is stale ("main" when the repo really tracks "develop"), which
        // suppresses the tracked-branch candidate — the push branch still lands.
        let candidates = PRStatusManager.branchCandidates(
            localBranch: "local-x", upstreamBranch: "main", defaultBranch: "main",
            pushBranch: .resolved("renamed-on-remote"))

        #expect(candidates == ["local-x", "renamed-on-remote"])
    }

    @Test("branchCandidates does not duplicate a push branch that repeats another candidate")
    func branchCandidatesDeduplicates() {
        let sameAsLocal = PRStatusManager.branchCandidates(
            localBranch: "tbd/my-branch", upstreamBranch: nil, defaultBranch: "main",
            pushBranch: .resolved("tbd/my-branch"))
        #expect(sameAsLocal == ["tbd/my-branch"])

        let sameAsTracked = PRStatusManager.branchCandidates(
            localBranch: "local-x", upstreamBranch: "renamed-on-remote", defaultBranch: "main",
            pushBranch: .resolved("renamed-on-remote"))
        #expect(sameAsTracked == ["local-x", "renamed-on-remote"])
    }

    @Test("branchCandidates drops a push branch that names the default branch")
    func branchCandidatesDropsDefaultBranchPushTarget() {
        // Under `push.default = upstream`, `@{push}` IS the upstream, so a
        // base-tracking branch resolves straight to the default branch. Without
        // this exclusion the base would be a head-ref candidate again for
        // everyone on that config — the whole bug, reopened.
        let candidates = PRStatusManager.branchCandidates(
            localBranch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main",
            pushBranch: .resolved("main"))

        #expect(candidates == ["tbd/my-branch"])
    }

    @Test("branchCandidates drops the tracked branch when the default branch is unknown")
    func branchCandidatesWithoutDefaultBranch() {
        // Without knowing the base, a tracked-branch candidate risks the original
        // mis-attachment; dropping it only costs a rename-push match.
        let candidates = PRStatusManager.branchCandidates(
            localBranch: "local-x", upstreamBranch: "renamed-on-remote", defaultBranch: nil,
            pushBranch: .noPushDestination)

        #expect(candidates == ["local-x"])
    }

    @Test("branchCandidates keeps only the local branch when nothing else is known")
    func branchCandidatesWithNoTrackingAtAll() {
        let candidates = PRStatusManager.branchCandidates(
            localBranch: "tbd/my-branch", upstreamBranch: nil, defaultBranch: "main",
            pushBranch: .lookupFailed)

        #expect(candidates == ["tbd/my-branch"])
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

    @Test("parseOwnerRepo splits a nested GitLab URL at the /-/ separator")
    func parseOwnerRepoGitLab() {
        let parsed = PRStatusManager.parseOwnerRepo(
            fromURL: "https://git.acme.example/acme/platform/backend/api-gateway/-/merge_requests/412")
        #expect(parsed?.owner == "acme/platform/backend")
        #expect(parsed?.name == "api-gateway")
    }

    @Test("parseOwnerRepo still handles GitHub URLs")
    func parseOwnerRepoGitHub() {
        let parsed = PRStatusManager.parseOwnerRepo(
            fromURL: "https://github.com/acme/acme-prod/pull/412")
        #expect(parsed?.owner == "acme")
        #expect(parsed?.name == "acme-prod")
    }

    @Test("parseOwnerRepo rejects a GitLab URL with no project segment")
    func parseOwnerRepoGitLabTooShort() {
        #expect(PRStatusManager.parseOwnerRepo(
            fromURL: "https://git.acme.example/acme/-/merge_requests/1") == nil)
    }

    // MARK: - Remote identity

    @Test("parseRemoteIdentity reads host, owner and name from an https remote")
    func parseRemoteIdentityHTTPS() {
        let parsed = PRStatusManager.parseRemoteIdentity("https://github.com/acme/acme-prod.git")
        #expect(parsed?.host == "github.com")
        #expect(parsed?.owner == "acme")
        #expect(parsed?.name == "acme-prod")
    }

    @Test("parseRemoteIdentity reads an scp-style remote")
    func parseRemoteIdentitySCP() {
        let parsed = PRStatusManager.parseRemoteIdentity("git@git.acme.example:acme/platform/api-gateway.git")
        #expect(parsed?.host == "git.acme.example")
        // Everything before the last segment is the namespace, however deep.
        #expect(parsed?.owner == "acme/platform")
        #expect(parsed?.name == "api-gateway")
    }

    @Test("parseRemoteIdentity keeps a deeply nested GitLab namespace whole")
    func parseRemoteIdentityNested() {
        let parsed = PRStatusManager.parseRemoteIdentity(
            "https://git.acme.example/acme/platform/backend/api-gateway.git")
        #expect(parsed?.owner == "acme/platform/backend")
        #expect(parsed?.name == "api-gateway")
    }

    @Test("parseRemoteIdentity drops an ssh port from the host")
    func parseRemoteIdentitySSHPort() {
        let parsed = PRStatusManager.parseRemoteIdentity("ssh://git@git.acme.example:2222/acme/api.git")
        #expect(parsed?.host == "git.acme.example")
        #expect(parsed?.owner == "acme")
        #expect(parsed?.name == "api")
    }

    @Test("parseRemoteIdentity returns nil rather than guessing a host")
    func parseRemoteIdentityRejectsIncomplete() {
        // Nothing here names a host, and a caller that cannot name the host
        // must defer — never default to github.com.
        #expect(PRStatusManager.parseRemoteIdentity("acme/acme-prod") == nil)
        #expect(PRStatusManager.parseRemoteIdentity("") == nil)
        #expect(PRStatusManager.parseRemoteIdentity("   ") == nil)
        #expect(PRStatusManager.parseRemoteIdentity("https://github.com/acme") == nil)
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

    /// Invalidation has to reach the row, not just the map.
    ///
    /// `hydrate`/`hydrateObservations` read those rows back at the next daemon
    /// start, so an in-memory-only drop resurrects exactly what invalidation
    /// removed — an `.observed` outcome describing a value that no longer
    /// exists, which is the thing the code's own comment promises not to leave
    /// behind. The nil is the clear, in both persisters.
    @Test("invalidate clears the persisted row too, not only the in-memory maps")
    func invalidatePersistsTheClear() async {
        let manager = PRStatusManager()
        let id = UUID()
        let persistedStatuses = PersistedClearRecorder()
        let persistedObservations = PersistedClearRecorder()
        await manager.setOnStatusPersist { worktreeID, status in
            await persistedStatuses.record(worktreeID, isClear: status == nil)
        }
        await manager.setOnObservationPersist { worktreeID, observation in
            await persistedObservations.record(worktreeID, isClear: observation == nil)
        }
        await manager.seedForTesting(
            worktreeID: id,
            status: PRStatus(number: 3, url: "https://github.com/o/r/pull/3", state: .mergeable))
        await manager.hydrateObservations([id: PRObservation(outcome: .observed, observedAt: Date())])

        await manager.invalidate(worktreeID: id)

        #expect(await manager.observation(for: id) == nil)
        #expect(await persistedObservations.clears == [id],
                "the dropped observation was never written through to the row")
        #expect(await persistedStatuses.clears.contains(id),
                "the dropped status was never written through to the row")
    }

    // MARK: - Reason computation

    @Test("computeReason returns 'Merged' for merged state")
    func reasonForMerged() {
        let reason = PRStatusManager.computeReason(
            ghState: "MERGED",
            mergeVerdictRaw: "UNKNOWN",
            reviewVerdictRaw: "",
            isDraft: false
        )
        #expect(reason == "Merged")
    }

    @Test("computeReason returns 'Closed' for closed state")
    func reasonForClosed() {
        let reason = PRStatusManager.computeReason(
            ghState: "CLOSED",
            mergeVerdictRaw: "UNKNOWN",
            reviewVerdictRaw: "",
            isDraft: false
        )
        #expect(reason == "Closed")
    }

    @Test("computeReason returns 'Draft' for draft PRs")
    func reasonForDraft() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeVerdictRaw: "CLEAN",
            reviewVerdictRaw: "",
            isDraft: true
        )
        #expect(reason == "Draft")
    }

    @Test("computeReason returns 'Ready to merge' for mergeable state")
    func reasonForMergeable() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeVerdictRaw: "CLEAN",
            reviewVerdictRaw: "",
            isDraft: false
        )
        #expect(reason == "Ready to merge")
    }

    @Test("computeReason returns 'Merge conflicts' for DIRTY merge state")
    func reasonForConflicts() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeVerdictRaw: "DIRTY",
            reviewVerdictRaw: "",
            isDraft: false
        )
        #expect(reason == "Merge conflicts")
    }

    @Test("computeReason returns 'Behind base branch' for BEHIND merge state")
    func reasonForBehind() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeVerdictRaw: "BEHIND",
            reviewVerdictRaw: "",
            isDraft: false
        )
        #expect(reason == "Behind base branch")
    }

    @Test("computeReason returns 'Checks failing' for failed status checks")
    func reasonForFailingChecks() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeVerdictRaw: "CLEAN",
            reviewVerdictRaw: "",
            isDraft: false,
            requiredChecksFailing: true
        )
        #expect(reason == "Checks failing")
    }

    @Test("computeReason returns 'Checks pending' for pending status checks")
    func reasonForPendingChecks() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeVerdictRaw: "CLEAN",
            reviewVerdictRaw: "",
            isDraft: false,
            requiredChecksPending: true
        )
        #expect(reason == "Checks pending")
    }

    @Test("computeReason returns 'Checks failing' for a failing required check under UNSTABLE")
    func reasonForRequiredFailingUnderUnstable() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeVerdictRaw: "UNSTABLE",
            requiredChecksFailing: true
        )
        #expect(reason == "Checks failing")
    }

    @Test("computeReason returns 'Checks pending' for a pending required check under BLOCKED")
    func reasonForRequiredPendingUnderBlocked() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeVerdictRaw: "BLOCKED",
            reviewVerdictRaw: "REVIEW_REQUIRED",
            requiredChecksPending: true
        )
        #expect(reason == "Checks pending")
    }

    @Test("computeReason returns 'Changes requested' for CHANGES_REQUESTED review decision")
    func reasonForChangesRequested() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeVerdictRaw: "BLOCKED",
            reviewVerdictRaw: "CHANGES_REQUESTED",
            isDraft: false
        )
        #expect(reason == "Changes requested")
    }

    @Test("computeReason returns 'Ready to merge' for REVIEW_REQUIRED with no other blocker (green state)")
    func reasonForReviewRequired() {
        let reason = PRStatusManager.computeReason(
            ghState: "OPEN",
            mergeVerdictRaw: "BLOCKED",
            reviewVerdictRaw: "REVIEW_REQUIRED",
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
            mergeVerdictRaw: "BLOCKED",
            reviewVerdictRaw: "REVIEW_REQUIRED"
        )
        #expect(state == .mergeable)
        #expect(reason == "Ready to merge")
    }

    @Test("UNSTABLE + no required signals → (.mergeable, 'Ready to merge')")
    func stateAndReasonUnstableNilChecksMergeable() {
        let (state, reason) = PRStatusManager.mapStateAndReason(
            ghState: "OPEN",
            mergeVerdictRaw: "UNSTABLE"
        )
        #expect(state == .mergeable)
        #expect(reason == "Ready to merge")
    }

    @Test("CLEAN + no pending checks → (.mergeable, 'Ready to merge')")
    func stateAndReasonCleanMergeable() {
        let (state, reason) = PRStatusManager.mapStateAndReason(
            ghState: "OPEN",
            mergeVerdictRaw: "CLEAN"
        )
        #expect(state == .mergeable)
        #expect(reason == "Ready to merge")
    }

    @Test("DIRTY → (.blocked, 'Merge conflicts')")
    func stateAndReasonDirtyConflicts() {
        let (state, reason) = PRStatusManager.mapStateAndReason(
            ghState: "OPEN",
            mergeVerdictRaw: "DIRTY"
        )
        #expect(state == .blocked)
        #expect(reason == "Merge conflicts")
    }

    @Test("BEHIND → (.blocked, 'Behind base branch')")
    func stateAndReasonBehind() {
        let (state, reason) = PRStatusManager.mapStateAndReason(
            ghState: "OPEN",
            mergeVerdictRaw: "BEHIND"
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

    @Test("unnumbered worktree still resolves via the viewer-authored branch match when the repo matches (regression)")
    func unnumberedResolvesViaLegacyBranchMatch() throws {
        // The viewer batch carries a node for the worktree's branch; a worktree
        // with no stored number must still match it when its own repo agrees
        // with the node's URL repo.
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
        let wt = UUID()
        let matches = PRStatusManager.matchUnnumbered(
            [(id: wt, branch: "feature-x", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme", prNumber: nil)],
            nodes: nodes,
            resolveRepo: { _ in ("acme", "acme") })
        #expect(matches.count == 1)
        #expect(matches.first?.worktreeID == wt)
        #expect(matches.first?.node.number == 7)
    }

    // MARK: - Repo-scoped viewer-batch branch matching (cross-repo collision regression)

    /// Convenience PRNode factory for the matching tests.
    private func prNode(number: Int, url: String, branch: String, state: String = "OPEN",
                        createdAt: String = "2026-07-01T00:00:00Z") -> PRStatusManager.PRNode {
        PRStatusManager.PRNode(number: number, url: url, state: state, mergeVerdictRaw: "CLEAN",
                               reviewVerdictRaw: "", headRefName: branch, createdAt: createdAt,
                               isDraft: false, statusCheckRollupState: nil, mergeQueuePosition: nil)
    }

    @Test("matchUnnumbered gives each worktree its own repo's PR when two repos share a branch name")
    func matchUnnumberedScopesSameBranchAcrossRepos() {
        // The reported bug: identical branch name in mdg-private/monorepo and
        // mdg-private/studio-ui; the studio-ui PR must not win both worktrees.
        let branch = "Jephuff/BILL-149-remove-billingplan-userroles"
        let monorepoWT = UUID(); let studioWT = UUID()
        let nodes = [
            prNode(number: 13113, url: "https://github.com/mdg-private/studio-ui/pull/13113", branch: branch),
            prNode(number: 555, url: "https://github.com/mdg-private/monorepo/pull/555", branch: branch)
        ]
        let repos: [String: (owner: String, name: String)] = [
            "/wt/monorepo": ("mdg-private", "monorepo"),
            "/wt/studio-ui": ("mdg-private", "studio-ui")
        ]
        let matches = PRStatusManager.matchUnnumbered(
            [(id: monorepoWT, branch: branch, upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/monorepo", prNumber: nil),
             (id: studioWT, branch: branch, upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/studio-ui", prNumber: nil)],
            nodes: nodes,
            resolveRepo: { repos[$0] })
        #expect(matches.count == 2)
        let byID = Dictionary(uniqueKeysWithValues: matches.map { ($0.worktreeID, $0.node.number) })
        #expect(byID[monorepoWT] == 555)
        #expect(byID[studioWT] == 13113)
    }

    @Test("matchUnnumbered yields no match when the branch's only PR lives in another repo")
    func matchUnnumberedNoMatchAcrossRepos() {
        let nodes = [
            prNode(number: 13113, url: "https://github.com/mdg-private/studio-ui/pull/13113",
                   branch: "shared-branch")
        ]
        let matches = PRStatusManager.matchUnnumbered(
            [(id: UUID(), branch: "shared-branch", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/monorepo", prNumber: nil)],
            nodes: nodes,
            resolveRepo: { _ in ("mdg-private", "monorepo") })
        #expect(matches.isEmpty)
    }

    @Test("matchUnnumbered yields no match when the worktree's repo can't be resolved")
    func matchUnnumberedNoMatchWhenRepoUnresolved() {
        // Degrade like the numbered path: an unscoped match could apply another
        // repo's PR, so an unresolvable repo means no match at all.
        let nodes = [
            prNode(number: 7, url: "https://github.com/acme/acme/pull/7", branch: "feature-x")
        ]
        let matches = PRStatusManager.matchUnnumbered(
            [(id: UUID(), branch: "feature-x", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme", prNumber: nil)],
            nodes: nodes,
            resolveRepo: { _ in nil })
        #expect(matches.isEmpty)
    }

    @Test("matchUnnumbered compares owner/name case-insensitively")
    func matchUnnumberedCaseInsensitiveRepoCompare() {
        let nodes = [
            prNode(number: 8, url: "https://github.com/Acme/Widgets/pull/8", branch: "feature-y")
        ]
        let matches = PRStatusManager.matchUnnumbered(
            [(id: UUID(), branch: "feature-y", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/widgets", prNumber: nil)],
            nodes: nodes,
            resolveRepo: { _ in ("acme", "widgets") })
        #expect(matches.first?.node.number == 8)
    }

    @Test("matchUnnumbered still honors the rename-push candidate when the repo matches")
    func matchUnnumberedRenamePushCandidate() {
        // Local branch has no PR under its own name; the branch it is pushed to
        // does, in the same repo. `.noPushDestination` is what git's DEFAULT
        // push config reports for this branch, so the tracked-branch candidate
        // is the only thing that can find the PR (regression guard for PR #212).
        let nodes = [
            prNode(number: 9, url: "https://github.com/acme/acme/pull/9", branch: "renamed-on-remote")
        ]
        let matches = PRStatusManager.matchUnnumbered(
            [(id: UUID(), branch: "local-x", upstreamBranch: "renamed-on-remote", defaultBranch: "main",
              pushBranch: .noPushDestination, worktreePath: "/wt/acme", prNumber: nil)],
            nodes: nodes,
            resolveRepo: { _ in ("acme", "acme") })
        #expect(matches.first?.node.number == 9)
    }

    @Test("matchUnnumbered does not attach a PR whose head is the repo's base branch")
    func matchUnnumberedIgnoresBaseBranchPR() {
        // A worktree branch cut from the base branch tracks `refs/heads/main`, so
        // the base branch used to be offered as a head candidate — handing every
        // worktree without its own PR yet the PR someone once opened FROM main.
        let nodes = [
            prNode(number: 88, url: "https://github.com/acme/acme-prod/pull/88", branch: "main",
                   state: "CLOSED")
        ]
        let matches = PRStatusManager.matchUnnumbered(
            [(id: UUID(), branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme-prod", prNumber: nil)],
            nodes: nodes,
            resolveRepo: { _ in ("acme", "acme-prod") })
        #expect(matches.isEmpty)
    }

    @Test("matchUnnumbered still attaches the worktree's own PR when a base-branch PR also exists")
    func matchUnnumberedPrefersOwnBranchOverBaseBranchPR() {
        let nodes = [
            prNode(number: 88, url: "https://github.com/acme/acme-prod/pull/88", branch: "main",
                   state: "CLOSED"),
            prNode(number: 89, url: "https://github.com/acme/acme-prod/pull/89", branch: "tbd/my-branch")
        ]
        let matches = PRStatusManager.matchUnnumbered(
            [(id: UUID(), branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme-prod", prNumber: nil)],
            nodes: nodes,
            resolveRepo: { _ in ("acme", "acme-prod") })
        #expect(matches.first?.node.number == 89)
    }

    // MARK: - Head-ref heal (base-branch mis-attachment)

    @Test("headRefMismatchedMatches flags an unnumbered worktree whose PR head is the base branch")
    func headRefHealFlagsBaseBranchHead() {
        let wt = UUID()
        let node = prNode(number: 88, url: "https://github.com/acme/acme-prod/pull/88",
                          branch: "main", state: "CLOSED")
        let out = PRStatusManager.headRefMismatchedMatches(
            [(wt, node)],
            unnumbered: [(id: wt, branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme-prod", prNumber: nil)])
        #expect(out.count == 1)
        #expect(out.first?.worktreeID == wt)
        #expect(out.first?.headRefName == "main")
        #expect(out.first?.candidates == ["tbd/my-branch"])
    }

    @Test("headRefMismatchedMatches keeps a match on the worktree's own branch")
    func headRefHealKeepsOwnBranchMatch() {
        let wt = UUID()
        let node = prNode(number: 89, url: "https://github.com/acme/acme-prod/pull/89",
                          branch: "tbd/my-branch")
        let out = PRStatusManager.headRefMismatchedMatches(
            [(wt, node)],
            unnumbered: [(id: wt, branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme-prod", prNumber: nil)])
        #expect(out.isEmpty)
    }

    @Test("headRefMismatchedMatches keeps a rename-push match under git's default push config")
    func headRefHealKeepsRenamePushMatch() {
        // With `push.default = simple` a rename-push reports NO push
        // destination, so the tracked branch is the only thing that makes its PR
        // findable — and it is offered as a candidate here because it is not the
        // default branch, which is what stops the heal ("head is not a
        // candidate" fails first). The condition that the tracked branch be the
        // DEFAULT branch is what covers this shape when the default branch is
        // unknown and no candidate can be offered: see
        // headRefHealKeepsMatchWhenDefaultBranchUnknown.
        let wt = UUID()
        let node = prNode(number: 9, url: "https://github.com/acme/acme-prod/pull/9",
                          branch: "renamed-on-remote")
        let out = PRStatusManager.headRefMismatchedMatches(
            [(wt, node)],
            unnumbered: [(id: wt, branch: "local-x", upstreamBranch: "renamed-on-remote", defaultBranch: "main",
                          pushBranch: .noPushDestination,
                          worktreePath: "/wt/acme-prod", prNumber: nil)])
        #expect(out.isEmpty)
    }

    @Test("headRefMismatchedMatches clears nothing when the repo's default branch is unknown")
    func headRefHealKeepsMatchWhenDefaultBranchUnknown() {
        // Without the default branch there is no way to tell a tracked BASE from
        // a rename-push target, so nothing is demonstrably wrong.
        let wt = UUID()
        let node = prNode(number: 88, url: "https://github.com/acme/acme-prod/pull/88",
                          branch: "main", state: "CLOSED")
        let out = PRStatusManager.headRefMismatchedMatches(
            [(wt, node)],
            unnumbered: [(id: wt, branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: nil,
                          pushBranch: .noPushDestination,
                          worktreePath: "/wt/acme-prod", prNumber: nil)])
        #expect(out.isEmpty)
    }

    @Test("headRefMismatchedMatches clears nothing when the push lookup failed")
    func headRefHealSkipsWorktreeWithFailedPushLookup() {
        // The destructive sequence this guards: a rename-push worktree whose
        // `@{push}` lookup transiently fails has its candidate list collapsed to
        // the local branch — but `cachedNumberFallback` still resolves its PR BY
        // NUMBER, a path that never consults candidates. Judging that match
        // against the collapsed list would turn a failure-to-attach into a
        // deletion of state the user cannot recreate.
        let wt = UUID()
        let node = prNode(number: 9, url: "https://github.com/acme/acme-prod/pull/9",
                          branch: "renamed-on-remote")
        let out = PRStatusManager.headRefMismatchedMatches(
            [(wt, node)],
            unnumbered: [(id: wt, branch: "local-x", upstreamBranch: "renamed-on-remote", defaultBranch: "main",
                          pushBranch: .lookupFailed,
                          worktreePath: "/wt/acme-prod", prNumber: nil)])
        #expect(out.isEmpty)
    }

    @Test("headRefMismatchedMatches keeps a head ref that is neither a candidate nor the tracked branch")
    func headRefHealKeepsUnexplainedHeadRef() {
        // Unexplained is not the same as demonstrably wrong: without positive
        // evidence that the PR's head is a branch this worktree merely tracks,
        // the entry stays.
        let wt = UUID()
        let node = prNode(number: 55, url: "https://github.com/acme/acme-prod/pull/55",
                          branch: "someone-elses-branch")
        let out = PRStatusManager.headRefMismatchedMatches(
            [(wt, node)],
            unnumbered: [(id: wt, branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main",
                          pushBranch: .noPushDestination,
                          worktreePath: "/wt/acme-prod", prNumber: nil)])
        #expect(out.isEmpty)
    }

    @Test("headRefMismatchedMatches keeps an entry whose tracked branch is unknown")
    func headRefHealKeepsWorktreeWithoutTrackedBranch() {
        let wt = UUID()
        let node = prNode(number: 88, url: "https://github.com/acme/acme-prod/pull/88",
                          branch: "main", state: "CLOSED")
        let out = PRStatusManager.headRefMismatchedMatches(
            [(wt, node)],
            unnumbered: [(id: wt, branch: "tbd/my-branch", upstreamBranch: nil, defaultBranch: "main",
                          pushBranch: .noPushDestination,
                          worktreePath: "/wt/acme-prod", prNumber: nil)])
        #expect(out.isEmpty)
    }

    @Test("headRefMismatchedMatches never flags a numbered worktree (fork PR heads legitimately differ)")
    func headRefHealSkipsNumberedWorktree() {
        // A worktree created from a PR row carries that PR's number; a fork PR's
        // head ref lives in another repo's namespace and rarely equals the local
        // branch. Only IDs present in `unnumbered` are judged.
        let numberedWT = UUID()
        let node = prNode(number: 77, url: "https://github.com/acme/acme-prod/pull/77",
                          branch: "contributor-fork-branch")
        let out = PRStatusManager.headRefMismatchedMatches(
            [(numberedWT, node)],
            unnumbered: [(id: UUID(), branch: "tbd/other", upstreamBranch: nil, defaultBranch: "main",
                          pushBranch: .noPushDestination,
                          worktreePath: "/wt/acme-prod", prNumber: nil)])
        #expect(out.isEmpty)
    }

    @Test("headRefMismatchedMatches flags a MERGED mis-attached node, so it is dropped before any merged transition")
    func headRefHealFlagsMergedMisattachedNode() {
        // fetchAll removes flagged matches from the apply loop, which is what
        // keeps a mis-attached MERGED PR from firing auto-archive on a worktree
        // that has nothing to do with it.
        let wt = UUID()
        let node = prNode(number: 88, url: "https://github.com/acme/acme-prod/pull/88",
                          branch: "main", state: "MERGED")
        let out = PRStatusManager.headRefMismatchedMatches(
            [(wt, node)],
            unnumbered: [(id: wt, branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main",
                          pushBranch: .noPushDestination,
                          worktreePath: "/wt/acme-prod", prNumber: nil)])
        #expect(out.count == 1)
    }

    @Test("headRefVerificationTargets picks up an unmatched cached entry, carrying its PR number")
    func headRefVerificationTargetsIncludesUnmatchedCached() {
        // The stuck case: a mis-attached CLOSED PR is terminal, so
        // cachedNumberFallback never re-queries it and no fresh node ever exists
        // to judge. One by-number resolution per daemon run supplies the head ref.
        let wt = UUID()
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: wt, branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme-prod", prNumber: nil)]
        let out = PRStatusManager.headRefVerificationTargets(
            unnumbered: unnumbered, matchedIDs: [], batchSucceeded: true, verifiedIDs: [],
            cachedStatus: { _ in PRStatus(number: 88, url: "https://github.com/acme/acme-prod/pull/88",
                                          state: .closed) })
        #expect(out.count == 1)
        #expect(out.first?.id == wt)
        #expect(out.first?.prNumber == 88)
    }

    @Test("headRefVerificationTargets skips a worktree this pass already matched")
    func headRefVerificationTargetsSkipsMatched() {
        let wt = UUID()
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: wt, branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme-prod", prNumber: nil)]
        let out = PRStatusManager.headRefVerificationTargets(
            unnumbered: unnumbered, matchedIDs: [wt], batchSucceeded: true, verifiedIDs: [],
            cachedStatus: { _ in PRStatus(number: 88, url: "https://github.com/acme/acme-prod/pull/88",
                                          state: .closed) })
        #expect(out.isEmpty)
    }

    @Test("headRefVerificationTargets skips a worktree already attempted in this daemon run")
    func headRefVerificationTargetsSkipsVerified() {
        // Bounds the extra round trip: without it every terminal cached entry
        // would be re-queried on every poll forever.
        let wt = UUID()
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: wt, branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme-prod", prNumber: nil)]
        let out = PRStatusManager.headRefVerificationTargets(
            unnumbered: unnumbered, matchedIDs: [], batchSucceeded: true, verifiedIDs: [wt],
            cachedStatus: { _ in PRStatus(number: 88, url: "https://github.com/acme/acme-prod/pull/88",
                                          state: .closed) })
        #expect(out.isEmpty)
    }

    @Test("headRefVerificationTargets skips a worktree whose push lookup failed")
    func headRefVerificationTargetsSkipsFailedPushLookup() {
        // Its answer could not be acted on (the heal refuses to clear in this
        // state), so the round trip would buy nothing.
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: UUID(), branch: "local-x", upstreamBranch: "renamed-on-remote", defaultBranch: "main", pushBranch: .lookupFailed,
              worktreePath: "/wt/acme-prod", prNumber: nil)]
        let out = PRStatusManager.headRefVerificationTargets(
            unnumbered: unnumbered, matchedIDs: [], batchSucceeded: true, verifiedIDs: [],
            cachedStatus: { _ in PRStatus(number: 9, url: "https://github.com/acme/acme-prod/pull/9",
                                          state: .closed) })
        #expect(out.isEmpty)
    }

    @Test("headRefVerificationTargets skips a worktree with no known default branch")
    func headRefVerificationTargetsSkipsUnknownDefaultBranch() {
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: UUID(), branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: nil,
              pushBranch: .noPushDestination, worktreePath: "/wt/acme-prod", prNumber: nil)]
        let out = PRStatusManager.headRefVerificationTargets(
            unnumbered: unnumbered, matchedIDs: [], batchSucceeded: true, verifiedIDs: [],
            cachedStatus: { _ in PRStatus(number: 88, url: "https://github.com/acme/acme-prod/pull/88",
                                          state: .closed) })
        #expect(out.isEmpty)
    }

    @Test("headRefVerificationTargets skips a worktree with no known tracked branch")
    func headRefVerificationTargetsSkipsUnknownTrackedBranch() {
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: UUID(), branch: "tbd/my-branch", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme-prod", prNumber: nil)]
        let out = PRStatusManager.headRefVerificationTargets(
            unnumbered: unnumbered, matchedIDs: [], batchSucceeded: true, verifiedIDs: [],
            cachedStatus: { _ in PRStatus(number: 88, url: "https://github.com/acme/acme-prod/pull/88",
                                          state: .closed) })
        #expect(out.isEmpty)
    }

    @Test("headRefVerificationTargets skips a worktree with no cached status")
    func headRefVerificationTargetsSkipsUncached() {
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: UUID(), branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme-prod", prNumber: nil)]
        let out = PRStatusManager.headRefVerificationTargets(
            unnumbered: unnumbered, matchedIDs: [], batchSucceeded: true, verifiedIDs: [],
            cachedStatus: { _ in nil })
        #expect(out.isEmpty)
    }

    @Test("headRefVerificationTargets yields nothing when the viewer batch failed")
    func headRefVerificationTargetsSkippedOnBatchFailure() {
        // Absence of evidence is not proof of mis-attachment: on a fetch/parse
        // failure every worktree is "unmatched" and the word means nothing.
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: UUID(), branch: "tbd/my-branch", upstreamBranch: "main", defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme-prod", prNumber: nil)]
        let out = PRStatusManager.headRefVerificationTargets(
            unnumbered: unnumbered, matchedIDs: [], batchSucceeded: false, verifiedIDs: [],
            cachedStatus: { _ in PRStatus(number: 88, url: "https://github.com/acme/acme-prod/pull/88",
                                          state: .closed) })
        #expect(out.isEmpty)
    }

    @Test("bestNodeByRepoBranch keeps the tie-break within one repo: OPEN beats MERGED, newest wins within a state")
    func bestNodeByRepoBranchTieBreakWithinRepo() {
        let key = PRStatusManager.repoBranchKey(owner: "acme", name: "acme", branch: "reused")
        // OPEN beats MERGED regardless of age.
        let openVsMerged = PRStatusManager.bestNodeByRepoBranch([
            prNode(number: 1, url: "https://github.com/acme/acme/pull/1", branch: "reused",
                   state: "MERGED", createdAt: "2026-07-02T00:00:00Z"),
            prNode(number: 2, url: "https://github.com/acme/acme/pull/2", branch: "reused",
                   state: "OPEN", createdAt: "2026-07-01T00:00:00Z")
        ])
        #expect(openVsMerged[key]?.number == 2)
        // Within the same state, newest createdAt wins.
        let newestWins = PRStatusManager.bestNodeByRepoBranch([
            prNode(number: 3, url: "https://github.com/acme/acme/pull/3", branch: "reused",
                   state: "CLOSED", createdAt: "2026-07-01T00:00:00Z"),
            prNode(number: 4, url: "https://github.com/acme/acme/pull/4", branch: "reused",
                   state: "CLOSED", createdAt: "2026-07-03T00:00:00Z")
        ])
        #expect(newestWins[key]?.number == 4)
    }

    @Test("bestNodeByRepoBranch drops a node whose URL doesn't parse to owner/name")
    func bestNodeByRepoBranchDropsUnparseableURL() {
        let byKey = PRStatusManager.bestNodeByRepoBranch([
            prNode(number: 5, url: "not a url", branch: "feature-z")
        ])
        #expect(byKey.isEmpty)
    }

    // MARK: - Poisoned-cache invalidation (cross-repo heal)

    @Test("poisonedCacheEntries flags a cached status whose PR URL belongs to a different repo")
    func poisonedCacheEntriesFlagsRepoMismatch() {
        let wt = UUID()
        let cached = PRStatus(number: 13113, url: "https://github.com/mdg-private/studio-ui/pull/13113",
                              state: .mergeable)
        let out = PRStatusManager.poisonedCacheEntries(
            unnumbered: [(id: wt, branch: "shared-branch", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/monorepo", prNumber: nil)],
            resolveRepo: { _ in ("mdg-private", "monorepo") },
            cachedStatus: { _ in cached })
        #expect(out.count == 1)
        #expect(out.first?.worktreeID == wt)
        #expect(out.first?.cachedRepo == "mdg-private/studio-ui")
        #expect(out.first?.worktreeRepo == "mdg-private/monorepo")
    }

    @Test("poisonedCacheEntries keeps a cached status from the worktree's own repo")
    func poisonedCacheEntriesKeepsSameRepo() {
        let cached = PRStatus(number: 555, url: "https://github.com/mdg-private/monorepo/pull/555",
                              state: .mergeable)
        let out = PRStatusManager.poisonedCacheEntries(
            unnumbered: [(id: UUID(), branch: "shared-branch", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/monorepo", prNumber: nil)],
            resolveRepo: { _ in ("mdg-private", "monorepo") },
            cachedStatus: { _ in cached })
        #expect(out.isEmpty)
    }

    @Test("poisonedCacheEntries treats owner/name casing differences as the same repo")
    func poisonedCacheEntriesCaseInsensitive() {
        let cached = PRStatus(number: 1, url: "https://github.com/MDG-Private/Monorepo/pull/1",
                              state: .pending)
        let out = PRStatusManager.poisonedCacheEntries(
            unnumbered: [(id: UUID(), branch: "b", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/monorepo", prNumber: nil)],
            resolveRepo: { _ in ("mdg-private", "monorepo") },
            cachedStatus: { _ in cached })
        #expect(out.isEmpty)
    }

    @Test("poisonedCacheEntries keeps an entry whose cached URL doesn't parse")
    func poisonedCacheEntriesKeepsUnparseableURL() {
        let cached = PRStatus(number: 1, url: "not a pr url", state: .pending)
        let out = PRStatusManager.poisonedCacheEntries(
            unnumbered: [(id: UUID(), branch: "b", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/monorepo", prNumber: nil)],
            resolveRepo: { _ in ("mdg-private", "monorepo") },
            cachedStatus: { _ in cached })
        #expect(out.isEmpty)
    }

    @Test("poisonedCacheEntries keeps an entry whose worktree repo can't be resolved")
    func poisonedCacheEntriesKeepsUnresolvedRepo() {
        // Absence of evidence is not proof of poisoning: never invalidate when
        // either side fails to resolve.
        let cached = PRStatus(number: 13113, url: "https://github.com/mdg-private/studio-ui/pull/13113",
                              state: .mergeable)
        let out = PRStatusManager.poisonedCacheEntries(
            unnumbered: [(id: UUID(), branch: "b", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/monorepo", prNumber: nil)],
            resolveRepo: { _ in nil },
            cachedStatus: { _ in cached })
        #expect(out.isEmpty)
    }

    @Test("poisonedCacheEntries skips a worktree with no cached status")
    func poisonedCacheEntriesSkipsNoCache() {
        let out = PRStatusManager.poisonedCacheEntries(
            unnumbered: [(id: UUID(), branch: "b", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/monorepo", prNumber: nil)],
            resolveRepo: { _ in ("mdg-private", "monorepo") },
            cachedStatus: { _ in nil })
        #expect(out.isEmpty)
    }

    @Test("cachedNumberFallback excludes a worktree the batch matched, even with a cached number")
    func cachedNumberFallbackExcludesBatchMatched() {
        // A branch re-pointed to a NEW PR must not get pinned to the stale cached number.
        let wt = UUID()
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: wt, branch: "feature-x", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/tmp/repo", prNumber: nil)]
        let out = PRStatusManager.cachedNumberFallback(
            unnumbered: unnumbered, matchedIDs: [wt], batchSucceeded: true,
            cachedStatus: { _ in PRStatus(number: 42, url: "https://example.com/pr/42", state: .pending) })
        #expect(out.isEmpty)
    }

    @Test("cachedNumberFallback includes an unmatched worktree, carrying its cached PR number")
    func cachedNumberFallbackIncludesUnmatchedWithCachedNumber() {
        // The stale PR fell out of the 100-PR viewer batch; the cached number is
        // the only remaining handle to observe the merged transition.
        let wt = UUID()
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: wt, branch: "old-branch", upstreamBranch: "origin/old-branch", defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/tmp/repo", prNumber: nil)]
        let out = PRStatusManager.cachedNumberFallback(
            unnumbered: unnumbered, matchedIDs: [], batchSucceeded: true,
            cachedStatus: { _ in PRStatus(number: 457, url: "https://example.com/pr/457", state: .mergeable) })
        #expect(out.count == 1)
        #expect(out.first?.id == wt)
        #expect(out.first?.prNumber == 457)
        #expect(out.first?.branch == "old-branch")
    }

    @Test("cachedNumberFallback excludes an unmatched worktree with no cached entry")
    func cachedNumberFallbackExcludesNoCachedEntry() {
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: UUID(), branch: "feature-y", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/tmp/repo", prNumber: nil)]
        let out = PRStatusManager.cachedNumberFallback(
            unnumbered: unnumbered, matchedIDs: [], batchSucceeded: true, cachedStatus: { _ in nil })
        #expect(out.isEmpty)
    }

    @Test("cachedNumberFallback yields nothing when the viewer batch failed, even with unmatched cached numbers")
    func cachedNumberFallbackSkippedOnBatchFailure() {
        // On a fetch/parse failure "unmatched" means nothing — falling back could
        // resolve a stale MERGED number and auto-archive off an unrelated PR.
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: UUID(), branch: "old-branch", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/tmp/repo", prNumber: nil)]
        let out = PRStatusManager.cachedNumberFallback(
            unnumbered: unnumbered, matchedIDs: [], batchSucceeded: false,
            cachedStatus: { _ in PRStatus(number: 457, url: "https://example.com/pr/457", state: .mergeable) })
        #expect(out.isEmpty)
    }

    @Test("cachedNumberFallback excludes worktrees whose cached state is terminal (.merged / .closed)")
    func cachedNumberFallbackExcludesTerminalCachedStates() {
        // .merged has no further transition to observe; .closed is excluded to
        // avoid a permanent per-poll re-query — a reopened PR is recovered by
        // the on-select refresh() path (or a restored batch match), not the fallback.
        let mergedWT = UUID(); let closedWT = UUID()
        let unnumbered: [PRStatusManager.PollWorktree] =
            [(id: mergedWT, branch: "merged-branch", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/tmp/repo", prNumber: nil),
             (id: closedWT, branch: "closed-branch", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/tmp/repo", prNumber: nil)]
        let statuses: [UUID: PRStatus] = [
            mergedWT: PRStatus(number: 11, url: "https://example.com/pr/11", state: .merged),
            closedWT: PRStatus(number: 12, url: "https://example.com/pr/12", state: .closed)
        ]
        let out = PRStatusManager.cachedNumberFallback(
            unnumbered: unnumbered, matchedIDs: [], batchSucceeded: true,
            cachedStatus: { statuses[$0] })
        #expect(out.isEmpty)
    }

    @Test("groupNumberedByRepo groups multi-repo entries by their own repo, in first-appearance order")
    func groupNumberedByRepoGroupsMultiRepo() {
        // One repo's owner/name must never be applied to another worktree's PR
        // number — the wrong repo could hold an unrelated (even MERGED) PR.
        let a = UUID(); let b = UUID(); let c = UUID()
        let numbered: [PRStatusManager.PollWorktree] = [
            (id: a, branch: "b1", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/tbd-1", prNumber: 457),
            (id: b, branch: "b2", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/acme-prod-1", prNumber: 9),
            (id: c, branch: "b3", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/tbd-2", prNumber: 460)
        ]
        let repos = ["/wt/tbd-1": ("acme", "tbd"), "/wt/tbd-2": ("acme", "tbd"),
                     "/wt/acme-prod-1": ("acme", "acme-prod")]
        let groups = PRStatusManager.groupNumberedByRepo(numbered) { repos[$0] }
        #expect(groups.count == 2)
        #expect(groups.first?.owner == "acme")
        #expect(groups.first?.name == "tbd")
        #expect(groups.first?.cwd == "/wt/tbd-1")
        #expect(groups.first?.entries.map { $0.worktreeID } == [a, c])
        #expect(groups.first?.entries.map { $0.number } == [457, 460])
        #expect(groups.last?.name == "acme-prod")
        #expect(groups.last?.entries.map { $0.worktreeID } == [b])
    }

    @Test("groupNumberedByRepo drops entries whose repo can't be resolved")
    func groupNumberedByRepoDropsUnresolved() {
        let a = UUID()
        let numbered: [PRStatusManager.PollWorktree] = [
            (id: a, branch: "b1", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/known", prNumber: 1),
            (id: UUID(), branch: "b2", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/unknown", prNumber: 2)
        ]
        let groups = PRStatusManager.groupNumberedByRepo(numbered) {
            $0 == "/wt/known" ? ("acme", "tbd") : nil
        }
        #expect(groups.count == 1)
        #expect(groups.first?.entries.map { $0.worktreeID } == [a])
    }

    @Test("groupNumberedByRepo passes a single-repo set through as one group")
    func groupNumberedByRepoSingleRepoPassthrough() {
        let a = UUID(); let b = UUID()
        let numbered: [PRStatusManager.PollWorktree] = [
            (id: a, branch: "b1", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/one", prNumber: 10),
            (id: b, branch: "b2", upstreamBranch: nil, defaultBranch: "main", pushBranch: .noPushDestination,
              worktreePath: "/wt/two", prNumber: 11)
        ]
        let groups = PRStatusManager.groupNumberedByRepo(numbered) { _ in ("acme", "tbd") }
        #expect(groups.count == 1)
        #expect(groups.first?.cwd == "/wt/one")
        #expect(groups.first?.entries.map { $0.number } == [10, 11])
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

// MARK: - fetchAll end-to-end (injected gh)

/// A stand-in for the `gh` CLI. Answers the three query shapes `fetchAll`
/// issues — `repo view` (owner/name), the viewer batch, and the aliased
/// by-number lookup — and counts them, so tests can assert not just the
/// resulting cache but how many round trips it took to get there.
private actor FakeGH {
    private let viewerNodes: [String]
    private let prsByNumber: [Int: String]
    private let viewerSucceeds: Bool
    private let byNumberSucceeds: Bool
    private(set) var viewerQueries = 0
    private(set) var numberedQueries = 0

    init(viewerNodes: [String] = [],
         prsByNumber: [Int: String] = [:],
         viewerSucceeds: Bool = true,
         byNumberSucceeds: Bool = true) {
        self.viewerNodes = viewerNodes
        self.prsByNumber = prsByNumber
        self.viewerSucceeds = viewerSucceeds
        self.byNumberSucceeds = byNumberSucceeds
    }

    func run(args: [String], repoPath: String) -> GHCommandResult? {
        if args.first == "repo" { return GHCommandResult(stdout: #"{"nameWithOwner":"acme/acme-prod","url":"https://github.com/acme/acme-prod"}"#) }
        guard let query = args.first(where: { $0.hasPrefix("query=") }) else { return nil }
        if query.contains("viewer {") {
            viewerQueries += 1
            guard viewerSucceeds else { return nil }
            return GHCommandResult(
                stdout: #"{"data":{"viewer":{"pullRequests":{"nodes":[\#(viewerNodes.joined(separator: ","))]}}}}"#)
        }
        if query.contains("pullRequest(number:") {
            numberedQueries += 1
            guard byNumberSucceeds else { return nil }
            let fields = Self.aliasedNumbers(inQuery: query).map { alias, number in
                "\"\(alias)\": \(prsByNumber[number] ?? "null")"
            }
            return GHCommandResult(stdout: #"{"data":{"repository":{\#(fields.joined(separator: ","))}}}"#)
        }
        return nil
    }

    /// Parse `pr0: pullRequest(number: 88) { … }` lines back into (alias, number).
    private static func aliasedNumbers(inQuery query: String) -> [(alias: String, number: Int)] {
        query.split(separator: "\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":"),
                  let open = line.range(of: "pullRequest(number: "),
                  let close = line[open.upperBound...].firstIndex(of: ")"),
                  let number = Int(line[open.upperBound..<close]) else { return nil }
            return (String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces), number)
        }
    }
}

/// Holds the manager so an injected `gh` runner can call back into it —
/// simulating a user-initiated refresh that lands while a batch is in flight.
private actor ManagerHolder {
    private var manager: PRStatusManager?

    func set(_ manager: PRStatusManager) { self.manager = manager }

    func refreshDuringBatch(worktreeID: UUID, number: Int) async {
        _ = await manager?.refresh(worktreeID: worktreeID, branch: "tbd/my-branch",
                                   upstreamBranch: "main", defaultBranch: "main",
                                   pushBranch: .noPushDestination,
                                   repoPath: "/wt/acme-prod", prNumber: number)
    }
}

/// Records what the actor asked the daemon to persist, and every merged
/// transition it fired.
private actor CallbackRecorder {
    private(set) var persisted: [(id: UUID, status: PRStatus?)] = []
    private(set) var mergedTransitions: [(id: UUID, number: Int)] = []

    func recordPersist(_ id: UUID, _ status: PRStatus?) { persisted.append((id, status)) }
    func recordMerged(_ id: UUID, _ number: Int) { mergedTransitions.append((id, number)) }
    var clearedIDs: [UUID] { persisted.filter { $0.status == nil }.map(\.id) }
}

@Suite("PRStatusManager fetchAll head-ref heal")
struct PRStatusManagerFetchAllTests {

    private static func nodeJSON(number: Int, head: String, state: String = "OPEN") -> String {
        """
        {"number": \(number), "url": "https://github.com/acme/acme-prod/pull/\(number)",
         "state": "\(state)", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
         "headRefName": "\(head)", "createdAt": "2026-07-01T00:00:00Z", "isDraft": false,
         "statusCheckRollup": {"state": "SUCCESS"}}
        """
    }

    private static func worktree(
        _ id: UUID,
        branch: String = "tbd/my-branch",
        upstream: String? = "main",
        defaultBranch: String? = "main",
        push: GitManager.PushBranchResolution = .noPushDestination
    ) -> PRStatusManager.PollWorktree {
        (id: id, branch: branch, upstreamBranch: upstream, defaultBranch: defaultBranch,
         pushBranch: push, worktreePath: "/wt/acme-prod", prNumber: nil)
    }

    private static func attach(_ recorder: CallbackRecorder, to manager: PRStatusManager) async {
        await manager.setOnStatusPersist { id, status in await recorder.recordPersist(id, status) }
        await manager.setOnMergedTransition { id, number in await recorder.recordMerged(id, number) }
    }

    @Test("a mis-attached MERGED PR reached by number is cleared without firing a merged transition")
    func clearsMisattachedMergedPRWithoutTransition() async {
        // The by-number fallback route: the batch matches nothing, so the cached
        // number is re-resolved — and that route never consults candidates, so
        // the heal is the only thing standing between a base branch's MERGED PR
        // and auto-archive on an unrelated worktree.
        let wt = UUID()
        let gh = FakeGH(prsByNumber: [88: Self.nodeJSON(number: 88, head: "main", state: "MERGED")])
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        await manager.seedForTesting(
            worktreeID: wt,
            status: PRStatus(number: 88, url: "https://github.com/acme/acme-prod/pull/88", state: .pending))
        let recorder = CallbackRecorder()
        await Self.attach(recorder, to: manager)

        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        #expect(await manager.allStatuses()[wt] == nil)
        #expect(await recorder.clearedIDs == [wt])
        #expect(await recorder.mergedTransitions.isEmpty)
    }

    @Test("a match on the worktree's own branch is applied normally")
    func appliesLegitimateMatch() async {
        // The heal's OFF branch: nothing is flagged, nothing is verified, and the
        // status lands in the cache as usual.
        let wt = UUID()
        let gh = FakeGH(viewerNodes: [Self.nodeJSON(number: 89, head: "tbd/my-branch")])
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        let recorder = CallbackRecorder()
        await Self.attach(recorder, to: manager)

        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        #expect(await manager.allStatuses()[wt]?.number == 89)
        #expect(await recorder.clearedIDs.isEmpty)
        #expect(await gh.numberedQueries == 0)
    }

    @Test("a rename-push attachment survives under git's default push config")
    func keepsRenamePushAttachmentUnderDefaultPushConfig() async {
        // The regression this rule exists for, driven end to end: with
        // `push.default = simple` a rename-push resolves no push destination, so
        // the by-number fallback re-attaches PR #9 while the candidate list holds
        // only "local-x" — and the tracked branch equals the PR's head. Only the
        // "tracked branch is the DEFAULT branch" condition keeps this alive.
        let wt = UUID()
        let gh = FakeGH(prsByNumber: [9: Self.nodeJSON(number: 9, head: "renamed-on-remote")])
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        await manager.seedForTesting(
            worktreeID: wt,
            status: PRStatus(number: 9, url: "https://github.com/acme/acme-prod/pull/9", state: .pending))
        let recorder = CallbackRecorder()
        await Self.attach(recorder, to: manager)

        await manager.fetchAll(worktrees: [
            Self.worktree(wt, branch: "local-x", upstream: "renamed-on-remote", push: .noPushDestination)
        ])

        #expect(await manager.allStatuses()[wt]?.number == 9)
        #expect(await recorder.clearedIDs.isEmpty)
    }

    @Test("an attachment survives a failed push lookup")
    func keepsAttachmentWhenPushLookupFailed() async {
        // Covers the restraint the `.lookupFailed` arm buys: the by-number
        // fallback re-attaches PR #9 without consulting candidates, and the heal
        // declines to judge a list it could not derive. (Not a guard against the
        // pre-fix behavior — before the heal existed nothing cleared at all.)
        let wt = UUID()
        let gh = FakeGH(prsByNumber: [9: Self.nodeJSON(number: 9, head: "renamed-on-remote")])
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        await manager.seedForTesting(
            worktreeID: wt,
            status: PRStatus(number: 9, url: "https://github.com/acme/acme-prod/pull/9", state: .pending))
        let recorder = CallbackRecorder()
        await Self.attach(recorder, to: manager)

        await manager.fetchAll(worktrees: [
            Self.worktree(wt, branch: "local-x", upstream: "renamed-on-remote", push: .lookupFailed)
        ])

        #expect(await manager.allStatuses()[wt]?.number == 9)
        #expect(await recorder.clearedIDs.isEmpty)
    }

    @Test("a terminal cached mis-attachment is cleared by the one-time verification")
    func clearsTerminalCachedMisattachment() async {
        // `.closed` is never re-queried by cachedNumberFallback, so this entry has
        // no freshly-resolved node to judge — pass 2 fetches one on purpose.
        let wt = UUID()
        let gh = FakeGH(prsByNumber: [88: Self.nodeJSON(number: 88, head: "main", state: "CLOSED")])
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        await manager.seedForTesting(
            worktreeID: wt,
            status: PRStatus(number: 88, url: "https://github.com/acme/acme-prod/pull/88", state: .closed))
        let recorder = CallbackRecorder()
        await Self.attach(recorder, to: manager)

        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        #expect(await manager.allStatuses()[wt] == nil)
        #expect(await recorder.clearedIDs == [wt])
        #expect(await gh.numberedQueries == 1)
    }

    @Test("an unresolvable cached number is verified at most once per daemon run")
    func verifiesUnresolvableNumberOnlyOnce() async {
        // Attempted, not resolved: a PR that can never resolve must not re-query
        // on every poll for the life of the daemon.
        let wt = UUID()
        let gh = FakeGH(byNumberSucceeds: false)
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        let cached = PRStatus(number: 88, url: "https://github.com/acme/acme-prod/pull/88", state: .closed)
        await manager.seedForTesting(worktreeID: wt, status: cached)
        let recorder = CallbackRecorder()
        await Self.attach(recorder, to: manager)

        await manager.fetchAll(worktrees: [Self.worktree(wt)])
        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        #expect(await gh.numberedQueries == 1)
        #expect(await manager.allStatuses()[wt] == cached)   // no evidence, so nothing cleared
        #expect(await recorder.clearedIDs.isEmpty)
    }

    @Test("a cleared mis-attachment is not re-attached by the next poll (no oscillation)")
    func healDoesNotOscillate() async {
        // Drives the real path twice, including the fallback → by-number route
        // that produced the match in the first place.
        let wt = UUID()
        let gh = FakeGH(viewerNodes: [Self.nodeJSON(number: 88, head: "main", state: "CLOSED")],
                        prsByNumber: [88: Self.nodeJSON(number: 88, head: "main", state: "CLOSED")])
        let manager = PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) })
        await manager.seedForTesting(
            worktreeID: wt,
            status: PRStatus(number: 88, url: "https://github.com/acme/acme-prod/pull/88", state: .pending))
        let recorder = CallbackRecorder()
        await Self.attach(recorder, to: manager)

        await manager.fetchAll(worktrees: [Self.worktree(wt)])
        #expect(await manager.allStatuses()[wt] == nil)

        await manager.fetchAll(worktrees: [Self.worktree(wt)])
        #expect(await manager.allStatuses()[wt] == nil)
        #expect(await recorder.clearedIDs == [wt])   // cleared once, not once per poll
    }

    @Test("a user refresh that lands mid-batch is not cleared by the heal")
    func skipsHealForFresherDirectUpdate() async {
        // Covers the `lastDirectUpdate` guard on the heal: a refresh the user
        // made while the batch was in flight is fresher than the batch, so the
        // poll that follows must not delete it. (Not a guard against the pre-fix
        // behavior — before the heal existed nothing cleared at all.)
        let wt = UUID()
        let gh = FakeGH(prsByNumber: [88: Self.nodeJSON(number: 88, head: "main", state: "CLOSED")])
        let holder = ManagerHolder()
        let manager = PRStatusManager(ghRunner: { args, path in
            // The user hits Refresh while the viewer batch is still in flight.
            if args.contains(where: { $0.contains("viewer {") }) {
                await holder.refreshDuringBatch(worktreeID: wt, number: 88)
            }
            return await gh.run(args: args, repoPath: path)
        })
        await holder.set(manager)
        await manager.seedForTesting(
            worktreeID: wt,
            status: PRStatus(number: 88, url: "https://github.com/acme/acme-prod/pull/88", state: .pending))
        let recorder = CallbackRecorder()
        await Self.attach(recorder, to: manager)

        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        #expect(await manager.allStatuses()[wt]?.number == 88)
        #expect(await recorder.clearedIDs.isEmpty)
    }
}

/// Records which worktrees a persist callback was asked to CLEAR (nil value),
/// so a test can prove an in-memory drop was written through.
private actor PersistedClearRecorder {
    private(set) var clears: [UUID] = []
    func record(_ id: UUID, isClear: Bool) { if isClear { clears.append(id) } }
}

// MARK: - Actor reentrancy around `invalidate`

/// A `now` seam that never returns the same instant twice, so "later than the
/// batch started" is a fact about ordering rather than about clock resolution.
private final class MonotonicNow: @unchecked Sendable {
    private let lock = NSLock()
    private var tick = 0
    private let base = Date(timeIntervalSince1970: 1_780_000_000)
    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        tick += 1
        return base.addingTimeInterval(Double(tick))
    }
}

/// What each persist callback saw when it ran. Lock-guarded rather than an
/// actor: it is written from inside a callback that is already suspending the
/// actor under test, and an extra hop there buys nothing.
private final class StampProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String: Bool] = [:]
    func record(_ label: String, _ landed: Bool) {
        lock.lock(); seen[label] = landed; lock.unlock()
    }
    subscript(label: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }; return seen[label]
    }
}

@Suite("PRStatusManager invalidate reentrancy")
struct PRStatusManagerInvalidateReentrancyTests {

    /// `invalidate` stamps `lastDirectUpdate` **before** it suspends, and that
    /// ordering is the whole invalidation.
    ///
    /// On an actor every `await` is a reentrancy point. `invalidate`'s two
    /// persist callbacks are awaits, so a `fetchAll` parked in its `gh` call
    /// resumes *inside* them, asks `directRefreshLanded`, and — if the answer is
    /// still no — applies its match and puts back the very entry this call had
    /// just removed. That is the thing the line's own comment says it prevents.
    ///
    /// So the invariant is exactly: **by the time the first persist callback
    /// runs, the stamp is already in place.** This asserts it from inside the
    /// callbacks themselves, which *are* the suspension points, and through the
    /// same predicate `fetchAll` consults.
    ///
    /// Tier 1, and deliberately single-task. An earlier cut staged a real
    /// two-task interleaving with latches; it proved the same property far less
    /// reliably (it stalled in the parallel pass, reporting a latch state its
    /// own choreography said was impossible) and a test whose result "says
    /// nothing" is worse than no test. The reentrancy is real; the *guarantee*
    /// is an ordering within one call, and that is directly observable.
    @Test func theStampLandsBeforeTheFirstSuspensionSoAnInFlightBatchCannotResurrectTheEntry() async {
        let wt = UUID()
        let clock = MonotonicNow()
        // Stands in for an in-flight batch's `batchStartedAt`, taken before
        // `invalidate` runs so any stamp it writes is strictly newer.
        let batchStartedAt = clock.next()
        let manager = PRStatusManager(ghRunner: { _, _ in nil }, now: { clock.next() })
        let probe = StampProbe()

        // Seed BEFORE registering the callbacks: `seedForTesting` routes through
        // `apply`, which persists, and that call is not the one under test.
        await manager.seedForTesting(
            worktreeID: wt,
            status: PRStatus(number: 77, url: "https://github.com/acme/acme-prod/pull/77",
                             state: .pending))
        await manager.hydrateObservations(
            [wt: PRObservation(outcome: .observed, observedAt: Date())])

        await manager.setOnStatusPersist { [weak manager] _, _ in
            guard let manager else { return }
            probe.record("status", await manager.directRefreshLandedForTesting(
                wt, after: batchStartedAt))
        }
        await manager.setOnObservationPersist { [weak manager] _, _ in
            guard let manager else { return }
            probe.record("observation", await manager.directRefreshLandedForTesting(
                wt, after: batchStartedAt))
        }

        await manager.invalidate(worktreeID: wt)

        #expect(probe["status"] == true,
                "the status persist callback is invalidate's FIRST suspension point; it ran before the stamp, so an in-flight fetchAll resuming there would resurrect the entry")
        #expect(probe["observation"] == true,
                "the observation persist callback ran before the stamp")
        // …and the invalidation itself still does what it always did.
        #expect(await manager.allStatuses()[wt] == nil)
        #expect(await manager.observation(for: wt) == nil)
    }
}
