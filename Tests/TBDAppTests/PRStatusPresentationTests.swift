import Testing
@testable import TBDApp
@testable import TBDShared

@Suite("PR status presentation")
struct PRStatusPresentationTests {
    @Test("conflict-only worktrees do not get a PR icon")
    func conflictOnlyWorktreeHasNoPRPresentation() {
        let presentation = PRStatusPresentation.make(for: nil)

        #expect(presentation == nil)
    }

    @Test("merged PRs use purple merge icon")
    func mergedPresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 1, url: "https://example.com/1", state: .merged))

        #expect(presentation?.iconName == "git-merge")
        #expect(presentation?.colorSemantic == .merged)
    }

    @Test("mergeable PRs use green pull request icon")
    func mergeablePresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 2, url: "https://example.com/2", state: .mergeable))

        #expect(presentation?.iconName == "git-pull-request")
        #expect(presentation?.colorSemantic == .mergeable)
    }

    @Test("draft PRs use grey pull request icon")
    func draftPresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 3, url: "https://example.com/3", state: .draft))

        #expect(presentation?.iconName == "git-pull-request")
        #expect(presentation?.colorSemantic == .draft)
    }

    @Test("PRs with failing checks use red pull request icon")
    func checksFailedPresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 4, url: "https://example.com/4", state: .checksFailed))

        #expect(presentation?.iconName == "git-pull-request")
        #expect(presentation?.colorSemantic == .checksFailed)
    }

    @Test("changes-requested PRs stay neutral so red means CI errors")
    func changesRequestedPresentation() {
        let presentation = PRStatusPresentation.make(for: PRStatus(number: 5, url: "https://example.com/5", state: .changesRequested))

        #expect(presentation?.iconName == "git-pull-request")
        #expect(presentation?.colorSemantic == .neutral)
    }
}
