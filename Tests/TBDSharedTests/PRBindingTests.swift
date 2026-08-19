import Foundation
import Testing
@testable import TBDShared

@Suite("PRBinding rules")
struct PRBindingTests {

    private func binding(_ number: Int, _ state: PRMergeableState,
                         detached: Bool = false) -> PRBinding {
        PRBinding(
            id: UUID(), worktreeID: UUID(), host: "github.com",
            owner: "acme", repo: "acme-prod", number: number,
            url: "https://github.com/acme/acme-prod/pull/\(number)",
            headBranch: "feature-\(number)", baseRef: "main",
            status: PRStatus(number: number,
                             url: "https://github.com/acme/acme-prod/pull/\(number)",
                             state: state),
            source: .hook, detached: detached, boundAt: Date()
        )
    }

    /// Per-binding text speaks the binding's own forge. Aggregate wording ("2
    /// pull requests") deliberately does not, because a worktree can span
    /// forges — that is asserted where the aggregates live, in TBDApp.
    @Test("per-binding label uses each forge's own reference syntax")
    func refLabelPerForge() {
        let gh = PRBinding(id: UUID(), worktreeID: UUID(), host: "github.com",
                           owner: "acme", repo: "acme-prod", number: 412,
                           url: "https://github.com/acme/acme-prod/pull/412",
                           source: .manual, boundAt: Date(timeIntervalSince1970: 0))
        let gl = PRBinding(id: UUID(), worktreeID: UUID(), host: "git.acme.example",
                           owner: "acme/platform", repo: "api-gateway", number: 412,
                           url: "https://git.acme.example/acme/platform/api-gateway/-/merge_requests/412",
                           source: .manual, boundAt: Date(timeIntervalSince1970: 0))
        #expect(gh.refLabel == "PR #412")
        #expect(gl.refLabel == "MR !412")
    }

    /// The marker travels with the URL, not with the host, so GitLab's own
    /// SaaS host reads the same way a self-managed one does.
    @Test("gitlab.com bindings read as merge requests too")
    func refLabelGitLabDotCom() {
        let gl = PRBinding(id: UUID(), worktreeID: UUID(), host: "gitlab.com",
                           owner: "acme", repo: "api-gateway", number: 7,
                           url: "https://gitlab.com/acme/api-gateway/-/merge_requests/7",
                           source: .manual, boundAt: Date(timeIntervalSince1970: 0))
        #expect(gl.refLabel == "MR !7")
    }

    /// The URL decides, not the host — because "not github.com" is not evidence
    /// of GitLab. GitHub Enterprise, Bitbucket, Gitea and Codeberg all serve
    /// pull requests from their own hosts, and a binding on one of them must
    /// not be relabelled a merge request.
    @Test("a pull request on a self-hosted host is still a PR")
    func refLabelSelfHostedPullRequest() {
        for host in ["github.acme.example", "bitbucket.acme.example",
                     "git.acme.example", "codeberg.org"] {
            let binding = PRBinding(id: UUID(), worktreeID: UUID(), host: host,
                                    owner: "acme", repo: "acme-prod", number: 412,
                                    url: "https://\(host)/acme/acme-prod/pull/412",
                                    source: .manual, boundAt: Date(timeIntervalSince1970: 0))
            #expect(binding.refLabel == "PR #412")
        }
    }

    /// The marker is matched case-insensitively so an odd-cased URL cannot flip
    /// a merge request into a pull request in the UI.
    @Test("forge derivation ignores URL case")
    func forgeDerivationIgnoresCase() {
        #expect(Forge.forURL(
            "https://GIT.ACME.EXAMPLE/acme/api/-/MERGE_REQUESTS/7") == .gitlab)
        #expect(Forge.forURL("https://GITHUB.COM/acme/acme-prod/PULL/7") == .github)
    }

    @Test("terminal states are merged and closed only")
    func terminalStates() {
        #expect(PRMergeableState.merged.isTerminal)
        #expect(PRMergeableState.closed.isTerminal)
        for state: PRMergeableState in [.pending, .blocked, .changesRequested,
                                        .draft, .checksFailed, .mergeable] {
            #expect(!state.isTerminal)
        }
    }

    @Test("worst-state picks the PR needing most attention")
    func worstState() {
        let picked = PRBinding.worst(of: [
            binding(1, .mergeable), binding(2, .checksFailed), binding(3, .draft)
        ])
        #expect(picked?.number == 2)
    }

    /// The design's order, worst first: checks failing, blocked, changes
    /// requested, pending, mergeable, draft. Asserted as adjacent pairs so a
    /// single inversion names itself, and once as a whole list.
    @Test("worst-state ranks checks-failing over blocked over changes-requested over pending over mergeable over draft")
    func worstStateOrdering() {
        #expect(PRBinding.worst(of: [binding(1, .draft), binding(2, .mergeable)])?.number == 2)
        #expect(PRBinding.worst(of: [binding(1, .mergeable), binding(2, .pending)])?.number == 2)
        #expect(PRBinding.worst(of: [binding(1, .pending), binding(2, .changesRequested)])?.number == 2)
        // Pinned explicitly: blocked outranks changes requested. The code once
        // had this pair inverted, and a test whose name disagreed with its body
        // let it through.
        #expect(PRBinding.worst(of: [binding(1, .changesRequested), binding(2, .blocked)])?.number == 2)
        #expect(PRBinding.worst(of: [binding(1, .blocked), binding(2, .checksFailed)])?.number == 2)

        let allSix: [PRBinding] = [binding(1, .draft), binding(2, .mergeable),
                                   binding(3, .pending), binding(4, .changesRequested),
                                   binding(5, .blocked), binding(6, .checksFailed)]
        #expect(PRBinding.worst(of: allSix)?.number == 6)
        #expect(PRBinding.worst(of: allSix.filter { $0.number != 6 })?.number == 5)
        #expect(PRBinding.worst(of: allSix.filter { $0.number < 5 })?.number == 4)
    }

    @Test("worst-state ignores detached bindings")
    func worstIgnoresDetached() {
        let picked = PRBinding.worst(of: [
            binding(1, .mergeable), binding(2, .checksFailed, detached: true)
        ])
        #expect(picked?.number == 1)
    }

    @Test("worst-state of an empty list is nil")
    func worstEmpty() {
        #expect(PRBinding.worst(of: []) == nil)
    }

    @Test("all-resolved requires every binding terminal and one merged")
    func allResolvedRule() {
        // one merged → fires
        #expect(PRBinding.allResolved([binding(1, .merged)]))
        // three, one merged → does not fire
        #expect(!PRBinding.allResolved([binding(1, .merged), binding(2, .mergeable),
                                        binding(3, .draft)]))
        // three, all terminal with one merged → fires
        #expect(PRBinding.allResolved([binding(1, .merged), binding(2, .closed),
                                       binding(3, .closed)]))
        // all closed, none merged → does not fire
        #expect(!PRBinding.allResolved([binding(1, .closed), binding(2, .closed)]))
        // empty → does not fire
        #expect(!PRBinding.allResolved([]))
    }

    @Test("all-resolved ignores detached bindings")
    func allResolvedIgnoresDetached() {
        #expect(PRBinding.allResolved([binding(1, .merged),
                                       binding(2, .mergeable, detached: true)]))
    }

    /// The ownership arm, the half that keeps the trigger strictly stronger than
    /// the single-PR rule: a merged PR only counts as this worktree's own when
    /// its head branch is one of the worktree's candidates, or its number is the
    /// worktree's provenance number.
    @Test("own work needs a merged binding on a candidate branch")
    func ownWorkByBranch() {
        #expect(PRBinding.mergedBindingIsOwnWork([binding(1, .merged)],
                                                 branchCandidates: ["feature-1"],
                                                 provenancePRNumber: nil))
        // The H1 scenario in miniature: the only merged PR is a subagent's, on a
        // branch this worktree never checked out.
        #expect(!PRBinding.mergedBindingIsOwnWork([binding(1, .merged)],
                                                  branchCandidates: ["work-2"],
                                                  provenancePRNumber: nil))
        // A candidate that is not the local branch — a tracked or push branch —
        // counts just the same; the caller passes the matcher's whole list.
        #expect(PRBinding.mergedBindingIsOwnWork([binding(1, .merged)],
                                                 branchCandidates: ["work-2", "feature-1"],
                                                 provenancePRNumber: nil))
        // Only a MERGED binding can establish ownership.
        #expect(!PRBinding.mergedBindingIsOwnWork([binding(1, .mergeable)],
                                                  branchCandidates: ["feature-1"],
                                                  provenancePRNumber: nil))
        // Own branch merged among several: the subagent's PRs do not obscure it.
        #expect(PRBinding.mergedBindingIsOwnWork(
            [binding(1, .merged), binding(2, .merged)],
            branchCandidates: ["feature-2"], provenancePRNumber: nil))
        // Branch names compare case-sensitively, as git refs do.
        #expect(!PRBinding.mergedBindingIsOwnWork([binding(1, .merged)],
                                                  branchCandidates: ["Feature-1"],
                                                  provenancePRNumber: nil))
    }

    /// A fork PR's head branch belongs to the fork and matches nothing local, so
    /// the stored number is the only handle that exists for it.
    @Test("own work accepts the worktree's provenance PR number")
    func ownWorkByProvenanceNumber() {
        #expect(PRBinding.mergedBindingIsOwnWork([binding(412, .merged)],
                                                 branchCandidates: ["work-2"],
                                                 provenancePRNumber: 412))
        #expect(!PRBinding.mergedBindingIsOwnWork([binding(412, .merged)],
                                                  branchCandidates: ["work-2"],
                                                  provenancePRNumber: 413))
        // The provenance PR is only own work when it actually merged.
        #expect(!PRBinding.mergedBindingIsOwnWork([binding(412, .closed)],
                                                  branchCandidates: ["work-2"],
                                                  provenancePRNumber: 412))
    }

    @Test("a merged binding with no observed head branch is not own work")
    func ownWorkNeedsAnObservedHeadBranch() {
        let merged = binding(1, .merged)
        let unobserved = PRBinding(
            id: merged.id, worktreeID: merged.worktreeID, host: merged.host,
            owner: merged.owner, repo: merged.repo, number: merged.number,
            url: merged.url, headBranch: nil, baseRef: merged.baseRef,
            status: merged.status, source: merged.source, detached: false,
            boundAt: merged.boundAt)
        #expect(!PRBinding.mergedBindingIsOwnWork([unobserved],
                                                  branchCandidates: ["feature-1", "work-2"],
                                                  provenancePRNumber: nil))
        // …but its number can still say it is ours.
        #expect(PRBinding.mergedBindingIsOwnWork([unobserved],
                                                 branchCandidates: [],
                                                 provenancePRNumber: 1))
    }

    @Test("own work ignores detached bindings")
    func ownWorkIgnoresDetached() {
        #expect(!PRBinding.mergedBindingIsOwnWork(
            [binding(1, .merged, detached: true)],
            branchCandidates: ["feature-1"], provenancePRNumber: 1))
    }

    @Test("a binding with no observed status is not resolved")
    func unknownStatusBlocksResolution() {
        var unknown = binding(2, .mergeable)
        unknown = PRBinding(
            id: unknown.id, worktreeID: unknown.worktreeID, host: unknown.host,
            owner: unknown.owner, repo: unknown.repo, number: unknown.number,
            url: unknown.url, headBranch: unknown.headBranch, baseRef: unknown.baseRef,
            status: nil, source: unknown.source, detached: false, boundAt: unknown.boundAt)
        #expect(!PRBinding.allResolved([binding(1, .merged), unknown]))
    }
}
