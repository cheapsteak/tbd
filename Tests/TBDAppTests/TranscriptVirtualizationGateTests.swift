import Foundation
import Testing
@testable import TBDApp

/// THROWAWAY SPIKE (issue #129). Tests the pure gate that decides whether
/// `TranscriptItemsView` renders the AppKit `VirtualizedTranscriptList` instead
/// of the production `LazyVStack { ForEach }`. Per CLAUDE.md "test each branch
/// of a gated conditional": assert the off-by-default branches AND the on
/// branch. The AppKit view itself is not exercised headlessly — only the gate
/// decision.
@Suite("Transcript virtualization gate")
struct TranscriptVirtualizationGateTests {
    @Test("off when TBD_VIRT_TRANSCRIPT is absent")
    func offWhenAbsent() {
        #expect(TranscriptItemsView.useVirtualizedTranscript([:]) == false)
    }

    @Test("off when TBD_VIRT_TRANSCRIPT is empty")
    func offWhenEmpty() {
        #expect(TranscriptItemsView.useVirtualizedTranscript(["TBD_VIRT_TRANSCRIPT": ""]) == false)
    }

    @Test("off when TBD_VIRT_TRANSCRIPT is a non-1 value")
    func offWhenNotOne() {
        #expect(TranscriptItemsView.useVirtualizedTranscript(["TBD_VIRT_TRANSCRIPT": "0"]) == false)
        #expect(TranscriptItemsView.useVirtualizedTranscript(["TBD_VIRT_TRANSCRIPT": "true"]) == false)
    }

    @Test("on when TBD_VIRT_TRANSCRIPT == 1")
    func onWhenOne() {
        #expect(TranscriptItemsView.useVirtualizedTranscript(["TBD_VIRT_TRANSCRIPT": "1"]) == true)
    }
}
