import Foundation
import Testing
@testable import TBDShared

@Suite("PanelSurfaceValidator")
struct PanelSurfaceValidatorTests {
    private func surface(layout: PanelLayoutNode) -> WorkspaceTabSurface {
        WorkspaceTabSurface(id: UUID(), worktreeID: UUID(),
                            primary: .terminal(terminalID: UUID()),
                            layout: layout, revision: 0)
    }
    private func slot(_ path: String, id: PanelID = UUID()) -> PanelLayoutNode {
        .panel(PanelSlot(id: id, content: .file(FileReference(path: path))))
    }

    @Test func validSurfaceHasNoViolations() {
        let s = surface(layout: .split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [.primary, slot("/a")], ratios: [0.6, 0.4])))
        #expect(PanelSurfaceValidator.violations(in: s).isEmpty)
    }

    @Test func missingAndDuplicatePrimaryAreViolations() {
        #expect(PanelSurfaceValidator.violations(in: surface(layout: slot("/a")))
            .contains(.primaryCount(0)))
        let two = surface(layout: .split(SplitNode(
            id: UUID(), direction: .vertical,
            children: [.primary, .primary], ratios: [0.5, 0.5])))
        #expect(PanelSurfaceValidator.violations(in: two).contains(.primaryCount(2)))
    }

    @Test func duplicatePanelIDsAreCaught() {
        let dup = UUID()
        let s = surface(layout: .split(SplitNode(
            id: UUID(), direction: .horizontal,
            children: [.primary, slot("/a", id: dup), slot("/b", id: dup)],
            ratios: [0.4, 0.3, 0.3])))
        #expect(PanelSurfaceValidator.violations(in: s).contains(.duplicatePanelID(dup)))
    }

    @Test func duplicateSplitIDsAreCaught() {
        let dup = UUID()
        let inner = PanelLayoutNode.split(SplitNode(
            id: dup, direction: .vertical, children: [slot("/a"), slot("/b")],
            ratios: [0.5, 0.5]))
        let s = surface(layout: .split(SplitNode(
            id: dup, direction: .horizontal,
            children: [.primary, inner], ratios: [0.5, 0.5])))
        #expect(PanelSurfaceValidator.violations(in: s).contains(.duplicateSplitID(dup)))
    }

    @Test func degenerateAndBadRatioSplitsAreCaught() {
        let empty = UUID(), single = UUID(), mismatch = UUID(), tiny = UUID(), badSum = UUID()
        #expect(PanelSurfaceValidator.violations(in: surface(layout: .split(SplitNode(
            id: empty, direction: .horizontal, children: [], ratios: []))))
            .contains(.degenerateSplit(empty)))
        #expect(PanelSurfaceValidator.violations(in: surface(layout: .split(SplitNode(
            id: single, direction: .horizontal, children: [.primary], ratios: [1.0]))))
            .contains(.degenerateSplit(single)))
        #expect(PanelSurfaceValidator.violations(in: surface(layout: .split(SplitNode(
            id: mismatch, direction: .horizontal, children: [.primary, slot("/a")],
            ratios: [1.0]))))
            .contains(.ratioCountMismatch(mismatch)))
        #expect(PanelSurfaceValidator.violations(in: surface(layout: .split(SplitNode(
            id: tiny, direction: .horizontal, children: [.primary, slot("/a")],
            ratios: [0.95, 0.05]))))
            .contains(.ratioBelowMinimum(tiny)))
        #expect(PanelSurfaceValidator.violations(in: surface(layout: .split(SplitNode(
            id: badSum, direction: .horizontal, children: [.primary, slot("/a")],
            ratios: [0.3, 0.3]))))
            .contains(.ratioSumInvalid(badSum)))
    }

    @Test func nestedSplitViolationsAreCaught() {
        let outer = UUID(), inner = UUID()
        let s = surface(layout: .split(SplitNode(
            id: outer, direction: .horizontal,
            children: [.primary, .split(SplitNode(
                id: inner, direction: .vertical,
                children: [slot("/a"), slot("/b")], ratios: [0.95, 0.05]))],
            ratios: [0.5, 0.5])))
        let violations = PanelSurfaceValidator.violations(in: s)
        #expect(violations == [.ratioBelowMinimum(inner)])
    }
}
