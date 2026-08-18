import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("GitLab state mapping")
struct GitLabMappingTests {

    private func map(
        _ verdict: String, state: String = "opened", draft: Bool = false,
        pipeline: String? = nil, gated: Bool = true
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
