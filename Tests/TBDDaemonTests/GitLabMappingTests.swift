import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("GitLab state mapping")
struct GitLabMappingTests {

    private func map(
        _ verdict: String, state: String = "opened", draft: Bool = false,
        pipeline: String? = nil, gated: Bool? = true
    ) -> (state: PRMergeableState, reason: String) {
        PRStatusManager.mapStateAndReason(
            forge: .gitlab, ghState: state, mergeVerdictRaw: verdict,
            isDraft: draft, pipelineGated: gated, pipelineStatus: pipeline)
    }

    @Test("NOT_APPROVED reads as ready, mirroring GitHub BLOCKED + REVIEW_REQUIRED")
    func notApproved() {
        // The single most common state in the field (#673). Mapping it to
        // .blocked would paint most of a healthy fleet as needing attention.
        #expect(map("NOT_APPROVED", pipeline: "SUCCESS").state == .mergeable)
    }

    @Test("DISCUSSIONS_NOT_RESOLVED reads as changes requested")
    func discussions() {
        let r = map("DISCUSSIONS_NOT_RESOLVED", pipeline: "SUCCESS")
        #expect(r.state == .changesRequested)
        #expect(r.reason == "Unresolved discussions")
    }

    @Test("REQUESTED_CHANGES reads as changes requested")
    func requestedChanges() {
        #expect(map("REQUESTED_CHANGES", pipeline: "SUCCESS").state == .changesRequested)
    }

    @Test("an explicit change request outranks a failing gated pipeline")
    func requestedChangesBeatsFailingPipeline() {
        // The GitHub arm puts CHANGES_REQUESTED ahead of its required-check
        // signals, so a reviewer's explicit rejection is what the author is
        // told about even when CI is also red. This arm must agree, otherwise
        // the rejection is masked and never surfaces anywhere in the UI.
        // Note the deliberate severity inversion: .changesRequested (4) ranks
        // below .checksFailed (6), and is still the state we want here.
        let r = map("REQUESTED_CHANGES", pipeline: "FAILED")
        #expect(r.state == .changesRequested)
        #expect(r.reason == "Changes requested")
    }

    @Test("an unresolved discussion does not outrank a failing gated pipeline")
    func discussionsDoNotBeatFailingPipeline() {
        // The deliberate other half of the rule above, pinned so that a future
        // edit made in the name of consistency cannot quietly promote
        // DISCUSSIONS_NOT_RESOLVED alongside REQUESTED_CHANGES. An open thread
        // is not an explicit rejection, and a failing pipeline is the more
        // actionable thing to show the author.
        let r = map("DISCUSSIONS_NOT_RESOLVED", pipeline: "FAILED")
        #expect(r.state == .checksFailed)
        #expect(r.reason == "Pipeline failed")
    }

    @Test("a merge conflict does not outrank a failing gated pipeline")
    func conflictDoesNotBeatFailingPipeline() {
        // The ordering is deliberate, not an oversight: the CI signal is
        // computed ahead of the merge-status switch, so CONFLICT reports the
        // pipeline rather than the conflict. Both are true and both block, and
        // the pipeline is the signal GitLab's own detailedMergeStatus is least
        // able to report — it ranks CI below almost everything, which is why
        // the CI signal is computed separately at all. Pinned so a future
        // reader does not "fix" the precedence into the switch.
        let r = map("CONFLICT", pipeline: "FAILED")
        #expect(r.state == .checksFailed)
        #expect(r.reason == "Pipeline failed")
    }

    @Test("a draft outranks both an explicit change request and a failing pipeline")
    func draftBeatsRequestedChanges() {
        // Draft sits above the change-request slot, so hoisting
        // REQUESTED_CHANGES over the CI signal must not disturb it.
        #expect(map("REQUESTED_CHANGES", draft: true, pipeline: "FAILED").state == .draft)
    }

    @Test("MERGEABLE reads as ready")
    func mergeable() {
        #expect(map("MERGEABLE", pipeline: "SUCCESS").state == .mergeable)
    }

    @Test("CONFLICT, NEED_REBASE and BLOCKED_STATUS each block with their own reason")
    func blockers() {
        #expect(map("CONFLICT", pipeline: "SUCCESS") == (.blocked, "Merge conflicts"))
        #expect(map("NEED_REBASE", pipeline: "SUCCESS") == (.blocked, "Behind base branch"))
        #expect(map("BLOCKED_STATUS", pipeline: "SUCCESS")
                == (.blocked, "Blocked by another merge request"))
    }

    @Test("UNCHECKED is distinguishable from the transient checking states")
    func uncheckedIsNotTransient() {
        // 21 of 71 observed merge requests sat here, some for months (#673), so
        // the reason must not imply it is about to resolve.
        let unchecked = map("UNCHECKED", pipeline: "SUCCESS")
        #expect(unchecked.state == .pending)
        #expect(unchecked.reason == "Mergeability not checked")
        #expect(map("CHECKING", pipeline: "SUCCESS").reason == "Checks pending")
        #expect(unchecked.reason != map("CHECKING", pipeline: "SUCCESS").reason)
    }

    @Test("an unrecognised value is pending, never blocked")
    func unknownIsPending() {
        // DetailedMergeStatus grows between releases; unknown-means-blocked
        // would make future GitLab versions silently paint MRs red.
        #expect(map("SOME_FUTURE_STATUS", pipeline: "SUCCESS").state == .pending)
    }

    @Test("a failing pipeline on a gating project is red")
    func failingGated() {
        // detailedMergeStatus masks CI behind higher-precedence blockers: 33
        // failing pipelines produced zero CI_MUST_PASS (#673), so the CI signal
        // must be computed independently of the merge status.
        #expect(map("NOT_APPROVED", pipeline: "FAILED").state == .checksFailed)
    }

    @Test("UNCHECKED with a failing pipeline on a gating project is red, not pending")
    func uncheckedWithFailingPipeline() {
        // Observed live against gitlab.com on a gated project: the shipped query
        // returns detailedMergeStatus UNCHECKED alongside headPipeline FAILED.
        // UNCHECKED is the second most common verdict in the field, so if the CI
        // signal were read off the merge status this pairing would render a
        // broken merge request as merely "not checked yet".
        let r = map("UNCHECKED", pipeline: "FAILED")
        #expect(r.state == .checksFailed)
        #expect(r.reason == "Pipeline failed")
    }

    @Test("a failing pipeline on a non-gating project is not red")
    func failingNotGated() {
        // The same situation as GitHub's UNSTABLE, which TBD does not colour.
        #expect(map("NOT_APPROVED", pipeline: "FAILED", gated: false).state != .checksFailed)
    }

    @Test("a failing pipeline stays red when nobody could read whether merges are gated")
    func failingWithUnknownGating() {
        // nil is "the project did not tell us", which only `false` may
        // silence. The witness for why: the line below is what the same merge
        // request maps to when unknown is collapsed to false — .mergeable,
        // "Ready to merge", printed against a failed pipeline. Over-colouring
        // an ungated project costs a glance; this costs a bad merge.
        let unknown = map("NOT_APPROVED", pipeline: "FAILED", gated: nil)
        #expect(unknown.state == .checksFailed)
        #expect(unknown.reason == "Pipeline failed")
        #expect(map("NOT_APPROVED", pipeline: "FAILED", gated: false) == (.mergeable, "Ready to merge"))
    }

    @Test("unknown gating reads as gated for the pending statuses too, not only for failures")
    func pendingWithUnknownGating() {
        // One rule rather than two: the whole CI branch is entered on anything
        // but an explicit false.
        #expect(map("NOT_APPROVED", pipeline: "RUNNING", gated: nil)
                == (.pending, "Pipeline running"))
        #expect(map("NOT_APPROVED", pipeline: "RUNNING", gated: false).state == .mergeable)
    }

    @Test("unknown gating does not colour a merge request with no pipeline at all")
    func noPipelineWithUnknownGating() {
        // The CI branch needs a status to read; an unknown gating answer is not
        // itself evidence of anything to show.
        #expect(map("MERGEABLE", pipeline: nil, gated: nil).state == .mergeable)
        #expect(map("CONFLICT", pipeline: nil, gated: nil) == (.blocked, "Merge conflicts"))
    }

    @Test("a draft with a failing pipeline stays draft")
    func draftBeatsFailingPipeline() {
        // 15 of 17 observed drafts had failing pipelines; work in progress must
        // not turn the fleet red.
        #expect(map("DRAFT_STATUS", draft: true, pipeline: "FAILED").state == .draft)
    }

    @Test("MANUAL is pending with its own reason")
    func manualPipeline() {
        let r = map("NOT_APPROVED", pipeline: "MANUAL")
        #expect(r.state == .pending)
        #expect(r.reason == "Pipeline awaiting manual action")
    }

    @Test("a null pipeline leaves the merge status to decide")
    func nullPipeline() {
        #expect(map("MERGEABLE", pipeline: nil).state == .mergeable)
    }

    @Test("merged and closed come from state, not the verdict")
    func terminalStates() {
        #expect(map("NOT_OPEN", state: "merged").state == .merged)
        #expect(map("NOT_OPEN", state: "closed").state == .closed)
    }

    @Test("the GitHub arm is unaffected by the new parameters")
    func githubArmUnchanged() {
        let r = PRStatusManager.mapStateAndReason(
            forge: .github, ghState: "OPEN", mergeVerdictRaw: "CLEAN")
        #expect(r == (.mergeable, "Ready to merge"))
    }
}
