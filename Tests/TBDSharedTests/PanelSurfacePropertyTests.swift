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
    /// Small content pools, so exact matches, same-kind reuse and repeated
    /// transcripts all come up often.
    private static let terminals: [UUID] = (0..<3).map { _ in UUID() }
    private static let notes: [UUID] = (0..<3).map { _ in UUID() }

    private func content(
        of kind: PanelKind, rng: inout SeededRNG
    ) -> PanelContent {
        let index = Int.random(in: 0..<3, using: &rng)
        switch kind {
        case .file: return .file(FileReference(path: "/f\(index)"))
        case .web: return .web(URL(string: "https://example.com/\(index)")!)
        case .note: return .note(noteID: Self.notes[index])
        case .transcript: return .transcript(terminalID: Self.terminals[index])
        }
    }

    private func anyContent(rng: inout SeededRNG) -> PanelContent {
        let kinds: [PanelKind] = [.file, .web, .note, .transcript]
        let kind = kinds.randomElement(using: &rng)!
        return content(of: kind, rng: &rng)
    }

    /// A panel in the region most of the time, otherwise an unknown ID so the
    /// `panelNotFound` path is exercised too.
    private func targetPanel(in side: SideRegion, rng: inout SeededRNG) -> PanelID {
        if Int.random(in: 0..<8, using: &rng) == 0 { return UUID() }
        return side.panels.randomElement(using: &rng)?.id ?? UUID()
    }

    private func randomOperation(
        surface: WorkspaceTabSurface, rng: inout SeededRNG
    ) -> PanelOperation {
        let side = surface.side
        switch Int.random(in: 0..<10, using: &rng) {
        case 0, 1, 2:
            return .open(content: anyContent(rng: &rng),
                         newPanel: Int.random(in: 0..<4, using: &rng) == 0)
        case 3:
            let panelID = targetPanel(in: side, rng: &rng)
            // Half the time a destination of the panel's own kind, so
            // navigations land as well as get refused.
            let destination: PanelContent
            if let kind = side.panel(id: panelID)?.content?.kind, Bool.random(using: &rng) {
                destination = content(of: kind, rng: &rng)
            } else {
                destination = anyContent(rng: &rng)
            }
            return .navigate(panelID: panelID, destination: destination)
        case 4:
            let actions: [PanelHistoryAction] =
                [.back, .forward, .jump(index: Int.random(in: -1...11, using: &rng))]
            return .history(panelID: targetPanel(in: side, rng: &rng),
                            action: actions.randomElement(using: &rng)!)
        case 5:
            return .select(panelID: targetPanel(in: side, rng: &rng))
        case 6, 7:
            return .close(panelID: targetPanel(in: side, rng: &rng))
        case 8:
            return .setCollapsed(Bool.random(using: &rng))
        default:
            // Often invalid on purpose; the reducer must reject, never store.
            let widths: [Double] = [
                .nan, .infinity, -.infinity, 0, 0.05, 0.1, 0.5, 0.9, 0.95, 1.5,
                Double.random(in: 0...1, using: &rng),
            ]
            return .resize(width: widths.randomElement(using: &rng)!)
        }
    }

    @Test(arguments: UInt64(1)...UInt64(40))
    func randomOperationSequencesPreserveInvariants(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        var surface = WorkspaceTabSurface(
            id: UUID(), worktreeID: UUID(), primary: .terminal(terminalID: UUID()))

        for step in 0..<60 {
            let op = randomOperation(surface: surface, rng: &rng)
            let before = surface
            do {
                surface = try PanelSurfaceReducer.apply(op, to: surface) { UUID() }
            } catch is PanelOperationError {
                // Width is only ever stored after a range check, so `before`
                // never carries a NaN and `==` is meaningful here.
                #expect(surface == before,
                        "seed \(seed) step \(step): a throw must leave the surface untouched")
                switch op {
                case .open, .setCollapsed:
                    Issue.record("seed \(seed) step \(step): \(op) has no failure path but threw")
                default:
                    break
                }
                continue
            } catch {
                Issue.record("seed \(seed) step \(step): non-typed error \(error)")
                return
            }
            let violations = PanelSurfaceValidator.violations(in: surface)
            #expect(violations.isEmpty, "seed \(seed) step \(step) op \(op): \(violations)")
            #expect(surface.revision == before.revision + 1,
                    "seed \(seed) step \(step): one revision per apply")
            #expect(surface.primary == before.primary,
                    "seed \(seed) step \(step): no operation touches the primary")

            // `open` always ends with its content in front and visible.
            if case .open(let content, _) = op {
                let active = surface.side.activePanelID.flatMap { surface.side.panel(id: $0) }
                #expect(active?.content == content,
                        "seed \(seed) step \(step): open did not put its content in front")
                #expect(surface.side.isVisible,
                        "seed \(seed) step \(step): open left the region hidden")
            }
        }
    }
}
