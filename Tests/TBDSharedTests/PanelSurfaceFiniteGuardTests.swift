import Testing
import Foundation
@testable import TBDShared

@Suite("PanelSurfaceFiniteGuardTests")
struct PanelSurfaceFiniteGuardTests {
    private func surface(ratios: [Double]) -> WorkspaceTabSurface {
        let split = SplitNode(
            id: UUID(), direction: .horizontal,
            children: [.primary, .panel(PanelSlot(id: UUID(), content: .note(noteID: UUID())))],
            ratios: ratios)
        return WorkspaceTabSurface(
            id: UUID(), worktreeID: UUID(), primary: .terminal(terminalID: UUID()),
            layout: .split(split))
    }

    @Test func nanRatiosAreAViolation() {
        let violations = PanelSurfaceValidator.violations(in: surface(ratios: [.nan, .nan]))
        #expect(violations.contains { if case .ratioSumInvalid = $0 { return true }; return false })
    }

    @Test func infiniteRatioIsAViolation() {
        let violations = PanelSurfaceValidator.violations(in: surface(ratios: [.infinity, 0.5]))
        #expect(violations.contains { if case .ratioSumInvalid = $0 { return true }; return false })
    }

    @Test func finiteValidRatiosStayClean() {
        #expect(PanelSurfaceValidator.violations(in: surface(ratios: [0.5, 0.5])).isEmpty)
    }

    @Test func resizeRejectsNonFiniteRatios() throws {
        let base = surface(ratios: [0.5, 0.5])
        guard case .split(let split) = base.layout else { Issue.record("expected split"); return }
        let state = PanelSurfaceState(surface: base, histories: [:])
        #expect(throws: PanelOperationError.self) {
            _ = try PanelSurfaceReducer.apply(.resize(splitID: split.id, ratios: [.nan, 1.0]), to: state)
        }
    }
}
