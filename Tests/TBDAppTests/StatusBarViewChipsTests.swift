import Foundation
import Testing
import TBDShared
@testable import TBDApp

// Tier 1: the pure chip model behind the status bar's PR cluster. Rendering is
// not exercised here — only the value transform the row is built from.
//
// Deliberately a `@Suite` struct rather than the free `@Test` functions the two
// sibling StatusBarView files use: `swift test --filter` matches the test ID,
// which carries the SUITE name, so free functions named `locationLabel_…` are
// invisible to `--filter StatusBarView`.
@Suite("StatusBarView PR chips")
struct StatusBarViewChipsTests {

    private func binding(_ number: Int, _ state: PRMergeableState) -> PRBinding {
        let url = "https://github.com/acme/acme-prod/pull/\(number)"
        return PRBinding(
            worktreeID: UUID(), owner: "acme", repo: "acme-prod",
            number: number, url: url,
            status: PRStatus(number: number, url: url, state: state),
            source: .hook
        )
    }

    @Test("the status bar exposes a chip per bound PR, capped at four")
    func chipsForSelection() {
        let bindings = (1...6).map { binding($0, .mergeable) }
        let model = StatusBarView.prChips(bindings)
        #expect(model.chips.count == 4)
        #expect(model.overflow == 2)
        #expect(model.chips[0].label == "#1")
    }

    @Test("no bindings means no chips at all")
    func noChips() {
        let model = StatusBarView.prChips([])
        #expect(model.chips.isEmpty)
        #expect(model.overflow == 0)
    }

    @Test("a chip carries the PR's url and state for the dot colour")
    func chipContent() {
        let model = StatusBarView.prChips([binding(412, .checksFailed)])
        #expect(model.chips[0].url?.absoluteString.hasSuffix("/pull/412") == true)
        #expect(model.chips[0].state == .checksFailed)
    }

    @Test("chips keep bind order, not severity order")
    func chipsKeepBindOrder() {
        let model = StatusBarView.prChips([
            binding(30, .mergeable), binding(10, .checksFailed), binding(20, .draft)
        ])
        #expect(model.chips.map(\.label) == ["#30", "#10", "#20"])
    }

    @Test("an explicit limit overrides the default cap")
    func explicitLimit() {
        let bindings = (1...6).map { binding($0, .mergeable) }
        let model = StatusBarView.prChips(bindings, limit: 2)
        #expect(model.chips.map(\.label) == ["#1", "#2"])
        #expect(model.overflow == 4)
    }

    @Test("a chip id is its binding's id, so the row is stable across refreshes")
    func chipIDMatchesBinding() {
        let one = binding(412, .mergeable)
        #expect(StatusBarView.prChips([one]).chips[0].id == one.id)
    }
}
