import AppKit
import Testing
@testable import TBDApp

@MainActor
@Suite("Transcript stream plan")
struct TranscriptStreamPlanTests {
    @Test("appending new nodes yields .append from the old count")
    func appendStep() {
        let prev = [TranscriptRenderNode.makeAssistantText(id: "a1", text: "one")]
        let next = [
            TranscriptRenderNode.makeAssistantText(id: "a1", text: "one"),
            TranscriptRenderNode.makeAssistantText(id: "a2", text: "two"),
        ]
        #expect(TranscriptStreamPlan.step(previous: prev, next: next) == .append(fromIndex: 1))
    }

    @Test("only the tail content changing yields .updateLast")
    func updateLastStep() {
        let prev = [
            TranscriptRenderNode.makeAssistantText(id: "a1", text: "frozen"),
            TranscriptRenderNode.makeAssistantText(id: "a2", text: "str"),
        ]
        let next = [
            TranscriptRenderNode.makeAssistantText(id: "a1", text: "frozen"),
            TranscriptRenderNode.makeAssistantText(id: "a2", text: "streamed more"),
        ]
        #expect(TranscriptStreamPlan.step(previous: prev, next: next) == .updateLast)
    }

    @Test("identical input yields .noop")
    func noopStep() {
        let same = [TranscriptRenderNode.makeAssistantText(id: "a1", text: "x")]
        #expect(TranscriptStreamPlan.step(previous: same, next: same) == .noop)
    }

    @Test("a mid-array id change yields .rebuild")
    func rebuildStep() {
        let prev = [
            TranscriptRenderNode.makeAssistantText(id: "a1", text: "x"),
            TranscriptRenderNode.makeAssistantText(id: "a2", text: "y"),
        ]
        let next = [
            TranscriptRenderNode.makeAssistantText(id: "aZ", text: "x"),
            TranscriptRenderNode.makeAssistantText(id: "a2", text: "y"),
        ]
        #expect(TranscriptStreamPlan.step(previous: prev, next: next) == .rebuild)
    }

    @Test("near-bottom threshold compares document tail to visible tail")
    func nearBottom() {
        #expect(TranscriptStreamPlan.isNearBottom(documentMaxY: 1000, visibleMaxY: 900, threshold: 120))
        #expect(!TranscriptStreamPlan.isNearBottom(documentMaxY: 1000, visibleMaxY: 700, threshold: 120))
    }

    @Test("non-tail version change in prefix yields .rebuild not .append")
    func nonTailVersionChangeRebuild() {
        // prefix has a non-tail node with changed contentVersion → must rebuild
        let prev = [
            TranscriptRenderNode.makeAssistantText(id: "a1", text: "original"),
            TranscriptRenderNode.makeAssistantText(id: "a2", text: "tail"),
        ]
        let next = [
            TranscriptRenderNode.makeAssistantText(id: "a1", text: "CHANGED"),  // non-tail version changed
            TranscriptRenderNode.makeAssistantText(id: "a2", text: "tail"),
            TranscriptRenderNode.makeAssistantText(id: "a3", text: "new"),
        ]
        #expect(TranscriptStreamPlan.step(previous: prev, next: next) == .rebuild)
    }
}
