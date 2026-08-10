import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared

@Suite("PR binding presentation")
struct PRBindingPresentationTests {

    private func binding(_ n: Int, _ state: PRMergeableState) -> PRBinding {
        let url = "https://github.com/acme/acme-prod/pull/\(n)"
        return PRBinding(worktreeID: UUID(), owner: "acme", repo: "acme-prod",
                         number: n, url: url,
                         status: PRStatus(number: n, url: url, state: state),
                         source: .hook)
    }

    @Test("no bindings renders no control")
    func zero() {
        #expect(PRBindingPresentation.buttonLabel([]) == nil)
        #expect(PRBindingPresentation.iconBinding([]) == nil)
    }

    @Test("one binding shows its number, as today")
    func one() {
        #expect(PRBindingPresentation.buttonLabel([binding(412, .mergeable)]) == "#412")
    }

    @Test("several bindings show a count")
    func many() {
        let label = PRBindingPresentation.buttonLabel(
            [binding(412, .mergeable), binding(413, .checksFailed), binding(414, .draft)])
        #expect(label == "3 PRs")
    }

    @Test("the icon follows the worst state at any count")
    func iconFollowsWorst() {
        let bindings = [binding(412, .mergeable), binding(413, .checksFailed),
                        binding(414, .draft)]
        #expect(PRBindingPresentation.iconBinding(bindings)?.number == 413)
        #expect(PRBindingPresentation.iconBinding([binding(9, .draft)])?.number == 9)
    }

    @Test("status-bar chips cap and report overflow")
    func chipCap() {
        let bindings = (1...7).map { binding($0, .mergeable) }
        let result = PRBindingPresentation.statusBarChips(bindings, limit: 4)
        #expect(result.chips.count == 4)
        #expect(result.overflow == 3)
        #expect(result.chips.map(\.number) == [1, 2, 3, 4])   // bind order
    }

    @Test("no overflow when within the cap")
    func chipNoOverflow() {
        let result = PRBindingPresentation.statusBarChips(
            [binding(1, .mergeable), binding(2, .draft)], limit: 4)
        #expect(result.chips.count == 2)
        #expect(result.overflow == 0)
    }

    @Test("menu rows keep bind order, not severity order")
    func menuOrder() {
        let bindings = [binding(30, .mergeable), binding(10, .checksFailed),
                        binding(20, .draft)]
        #expect(PRBindingPresentation.menuRows(bindings).map(\.number) == [30, 10, 20])
    }

    @Test("a menu row carries number, reason and branch")
    func menuRowContent() {
        var b = binding(412, .checksFailed)
        b = PRBinding(id: b.id, worktreeID: b.worktreeID, host: b.host, owner: b.owner,
                      repo: b.repo, number: b.number, url: b.url,
                      headBranch: "fix-login-timeout", baseRef: "main",
                      status: b.status, source: b.source, detached: false, boundAt: b.boundAt)
        let row = PRBindingPresentation.menuRows([b])[0]
        #expect(row.number == 412)
        #expect(row.title.contains("#412"))
        #expect(row.title.contains("Checks failing"))
        #expect(row.title.contains("fix-login-timeout"))
    }
}
