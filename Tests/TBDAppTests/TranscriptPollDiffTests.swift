import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// Verifies the poll-loop change detection: the O(1) precheck may only ever
/// prove "changed" (count or last-item mismatch) — proving "unchanged"
/// requires the deep compare, because a late tool result merges into an
/// EARLIER `toolCall` item without touching the tail.
@Suite("TranscriptPollDiff")
struct TranscriptPollDiffTests {
    private func prompt(_ id: String, _ text: String) -> TranscriptItem {
        .userPrompt(id: id, text: text, timestamp: nil)
    }

    private func toolCall(_ id: String, result: ToolResult?) -> TranscriptItem {
        .toolCall(
            id: id, name: "Bash", inputJSON: "{}", inputTruncatedTo: nil,
            result: result, subagent: nil, timestamp: nil, usage: nil)
    }

    // MARK: cheapChangeCheck

    @Test("count mismatch is a definite change")
    func countMismatch() {
        let prev = [prompt("a", "one")]
        let new = [prompt("a", "one"), prompt("b", "two")]
        #expect(TranscriptPollDiff.cheapChangeCheck(prev: prev, new: new) == true)
        #expect(TranscriptPollDiff.changed(prev: prev, new: new))
    }

    @Test("same count with a differing last item is a definite change")
    func lastItemMismatch() {
        let prev = [prompt("a", "one"), prompt("b", "streaming…")]
        let new = [prompt("a", "one"), prompt("b", "streaming… more")]
        #expect(TranscriptPollDiff.cheapChangeCheck(prev: prev, new: new) == true)
        #expect(TranscriptPollDiff.changed(prev: prev, new: new))
    }

    @Test("matching count and last item is inconclusive, not equal")
    func inconclusivePrecheck() {
        let prev = [prompt("a", "one"), prompt("b", "two")]
        let new = [prompt("a", "CHANGED"), prompt("b", "two")]
        #expect(TranscriptPollDiff.cheapChangeCheck(prev: prev, new: new) == nil)
    }

    @Test("identical arrays are inconclusive at the precheck stage")
    func identicalInconclusive() {
        let items = [prompt("a", "one"), prompt("b", "two")]
        #expect(TranscriptPollDiff.cheapChangeCheck(prev: items, new: items) == nil)
    }

    // MARK: changed (deep fallback)

    @Test("mid-array mutation with an identical tail is detected as changed")
    func midArrayToolResultMerge() {
        // Simulates the parser merging a late tool result into an earlier
        // toolCall item: tail unchanged, middle mutated.
        let tail = prompt("c", "done")
        let prev = [prompt("a", "run it"), toolCall("b", result: nil), tail]
        let new = [
            prompt("a", "run it"),
            toolCall("b", result: ToolResult(text: "ok", truncatedTo: nil, isError: false)),
            tail,
        ]
        #expect(TranscriptPollDiff.cheapChangeCheck(prev: prev, new: new) == nil)
        #expect(TranscriptPollDiff.changed(prev: prev, new: new))
    }

    @Test("identical non-empty arrays are unchanged")
    func identicalUnchanged() {
        let items = [prompt("a", "one"), toolCall("b", result: nil)]
        #expect(!TranscriptPollDiff.changed(prev: items, new: items))
    }

    @Test("two empty arrays are unchanged")
    func bothEmpty() {
        #expect(!TranscriptPollDiff.changed(prev: [], new: []))
    }

    @Test("empty to non-empty is changed")
    func emptyToNonEmpty() {
        #expect(TranscriptPollDiff.changed(prev: [], new: [prompt("a", "hi")]))
    }
}
