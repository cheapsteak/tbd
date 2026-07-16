import Testing
import TBDShared
@testable import TBDApp

/// Pure merge/dedup/filter logic for the branch picker's combined
/// branches + open-PRs list. View-free so it can be unit-tested directly.
@Suite("Branch picker merge/filter")
struct BranchPickerMergeTests {
    private func local(_ name: String) -> BranchInfo {
        BranchInfo(name: name, localName: name, isRemote: false)
    }
    private func remote(_ name: String) -> BranchInfo {
        BranchInfo(name: "origin/\(name)", localName: name, isRemote: true)
    }
    private func pr(_ number: Int, head: String, owner: String = "",
                    fork: Bool = false, draft: Bool = false,
                    title: String = "A title") -> OpenPRInfo {
        OpenPRInfo(number: number, title: title, headRefName: head, headOwner: owner,
                   isCrossRepository: fork, isDraft: draft)
    }

    @Test("same-repo PR decorates its matching branch row (no extra row)")
    func sameRepoDecorates() {
        let branches = [local("feature-x"), local("main")]
        let prs = [pr(454, head: "feature-x", title: "Weekly reset")]
        let items = mergePickerItems(branches: branches, prs: prs)
        #expect(items.count == 2)
        let decorated = items.first { $0.branch?.name == "feature-x" }
        #expect(decorated?.pr?.number == 454)
        #expect(items.first { $0.branch?.name == "main" }?.pr == nil)
    }

    @Test("fork PR appends a new row between local and remote branches")
    func forkPRAppendedBetween() {
        let branches = [local("main"), remote("dev")]
        let prs = [pr(454, head: "show-weekly-reset", owner: "zionts", fork: true)]
        let items = mergePickerItems(branches: branches, prs: prs)
        #expect(items.count == 3)
        // Order: local main, PR-only fork row, remote dev.
        #expect(items[0].branch?.name == "main")
        #expect(items[1].branch == nil)
        #expect(items[1].pr?.number == 454)
        #expect(items[2].branch?.name == "origin/dev")
    }

    @Test("non-fork PR with no matching branch still gets its own row (unfetched head)")
    func nonForkNoMatchGetsRow() {
        let branches = [local("main")]
        let prs = [pr(77, head: "not-fetched-yet", fork: false)]
        let items = mergePickerItems(branches: branches, prs: prs)
        #expect(items.count == 2)
        #expect(items.last?.branch == nil)
        #expect(items.last?.pr?.number == 77)
    }

    @Test("fork PR whose head name coincides with a local branch does NOT decorate it")
    func forkDoesNotDecorateCoincidentalLocal() {
        let branches = [local("main")]
        let prs = [pr(9, head: "main", fork: true, title: "fork from their main")]
        let items = mergePickerItems(branches: branches, prs: prs)
        #expect(items.count == 2)
        #expect(items.first { $0.branch?.name == "main" }?.pr == nil)
        #expect(items.last?.branch == nil)
        #expect(items.last?.pr?.number == 9)
    }

    @Test("PR-only rows go before remotes even with no local branches")
    func prOnlyBeforeRemotesNoLocals() {
        let branches = [remote("dev")]
        let prs = [pr(1, head: "fork-head", fork: true)]
        let items = mergePickerItems(branches: branches, prs: prs)
        #expect(items.count == 2)
        #expect(items[0].branch == nil)
        #expect(items[1].branch?.name == "origin/dev")
    }

    @Test("filter matches branch name, PR number, title word, and owner login")
    func filterMatches() {
        let branches = [local("feature-x")]
        let prs = [pr(454, head: "show-weekly-reset", owner: "zionts", fork: true,
                      title: "Show weekly reset")]
        let items = mergePickerItems(branches: branches, prs: prs)
        let forkRow = items.first { $0.pr?.number == 454 }!
        let branchRow = items.first { $0.branch?.name == "feature-x" }!

        #expect(matchesFilter(forkRow, query: "454"))
        #expect(matchesFilter(forkRow, query: "weekly"))
        #expect(matchesFilter(forkRow, query: "zionts"))
        #expect(matchesFilter(branchRow, query: "feature"))
        #expect(!matchesFilter(branchRow, query: "454"))
    }

    @Test("empty query returns all rows")
    func emptyQueryAll() {
        let branches = [local("main")]
        let prs = [pr(1, head: "fork", fork: true)]
        let items = mergePickerItems(branches: branches, prs: prs)
        #expect(items.allSatisfy { matchesFilter($0, query: "") })
        #expect(items.allSatisfy { matchesFilter($0, query: "   ") })
    }
}
