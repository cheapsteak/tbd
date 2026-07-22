import Foundation
import Testing
@testable import TBDShared

/// Deterministic RNG so failures reproduce from the logged seed (SplitMix64).
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// NOTE: `swift test --filter` matches the TYPE name (PanelSurfacePropertyTests),
// not this display string — a filter on the display string matches zero tests
// and exits green. Suite string kept identical to the type name on purpose.
@Suite("PanelSurfacePropertyTests")
struct PanelSurfacePropertyTests {
    private func file(_ n: Int) -> PanelContent { .file(FileReference(path: "/f\(n)")) }

    private func randomOperation(
        state: PanelSurfaceState, rng: inout SeededRNG, counter: inout Int
    ) -> PanelOperation {
        let panels = state.surface.layout.allPanelIDs
        let splits = state.surface.layout.allSplitIDs
        counter += 1
        switch Int.random(in: 0..<8, using: &rng) {
        case 0:
            return .open(content: file(counter), placement: .automatic)
        case 1:
            let anchors: [PanelAnchor] = [.primary] + panels.map { .panel($0) }
            let edges: [PanelEdge] = [.left, .right, .above, .below]
            return .open(content: file(counter),
                         placement: .beside(target: anchors.randomElement(using: &rng)!,
                                            edge: edges.randomElement(using: &rng)!,
                                            // Deliberately dips below minShare (0.1) so the
                                            // suite probes the reject path in `wrapped()`.
                                            share: Double.random(in: 0.02...0.5, using: &rng)))
        case 2:
            return .close(panelID: panels.randomElement(using: &rng) ?? UUID())
        case 3:
            let edges: [PanelEdge] = [.left, .right, .above, .below]
            return .move(panelID: panels.randomElement(using: &rng) ?? UUID(),
                         placement: .beside(target: .primary,
                                            edge: edges.randomElement(using: &rng)!,
                                            share: nil))
        case 4:
            guard let splitID = splits.randomElement(using: &rng) else {
                return .open(content: file(counter), placement: .automatic)
            }
            // Random count 1...4 — often invalid on purpose; reducer must
            // reject, never corrupt.
            let count = Int.random(in: 1...4, using: &rng)
            let raw = (0..<count).map { _ in Double.random(in: 0.05...1.0, using: &rng) }
            return .resize(splitID: splitID, ratios: raw)
        case 5:
            return .navigate(panelID: panels.randomElement(using: &rng) ?? UUID(),
                             destination: file(counter))
        case 6:
            let actions: [PanelHistoryAction] =
                [.back, .forward, .jump(index: Int.random(in: -1...12, using: &rng))]
            return .history(panelID: panels.randomElement(using: &rng) ?? UUID(),
                            action: actions.randomElement(using: &rng)!)
        default:
            return .selectTab(tabID: UUID())
        }
    }

    @Test(arguments: UInt64(1)...UInt64(40))
    func randomOperationSequencesPreserveInvariants(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        var counter = 0
        var state = PanelSurfaceState(
            surface: WorkspaceTabSurface(
                id: UUID(), worktreeID: UUID(),
                primary: .terminal(terminalID: UUID()),
                layout: .primary, revision: 0),
            histories: [:])

        for step in 0..<60 {
            let op = randomOperation(state: state, rng: &rng, counter: &counter)
            let before = state
            do {
                state = try PanelSurfaceReducer.apply(op, to: state) { UUID() }
            } catch is PanelOperationError {
                #expect(state == before,
                        "seed \(seed) step \(step): a throw must leave state untouched")
                continue
            } catch {
                Issue.record("seed \(seed) step \(step): non-typed error \(error)")
                return
            }
            let violations = PanelSurfaceValidator.violations(in: state)
            #expect(violations.isEmpty,
                    "seed \(seed) step \(step) op \(op): \(violations)")
            #expect(state.surface.layout.primaryCount == 1,
                    "seed \(seed) step \(step): exactly one primary")
            #expect(state.surface.revision == before.surface.revision + 1)
        }
        // §5.5 "never a terminal panel" holds by type: PanelContent has no
        // terminal case, so no assertion is possible — or needed.
    }
}
