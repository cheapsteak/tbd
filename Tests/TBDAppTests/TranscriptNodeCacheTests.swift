import Foundation
import Testing
import TBDShared

@testable import TBDApp

/// Tests for `TranscriptNodeCache` — the issue #129 node-array memoization.
///
/// Two properties matter:
///   1. Stability: unchanged `items` → the SAME array instance back (no rebuild),
///      so `ForEach`/AttributeGraph skip re-diffing and re-copying.
///   2. Correctness (the dangerous failure mode): a content change MUST invalidate
///      the cache, or a needed SwiftUI re-render is silently dropped. We test that
///      a same-count, same-id payload mutation still busts the cache.
@Suite("TranscriptNodeCache")
@MainActor
struct TranscriptNodeCacheTests {

    private func toolItem(id: String, result: ToolResult? = nil) -> TranscriptItem {
        .toolCall(id: id, name: "Bash", inputJSON: "{}", inputTruncatedTo: nil,
                  result: result, subagent: nil, timestamp: nil)
    }

    private func userItem(id: String, text: String) -> TranscriptItem {
        .userPrompt(id: id, text: text, timestamp: nil)
    }

    /// Stable buffer base address of an array, for identity comparison.
    private func baseAddress(_ nodes: [TranscriptRenderNode]) -> UnsafeRawPointer? {
        nodes.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
    }

    // 1. Unchanged items → no rebuild, same instance.
    @Test func unchangedItems_returnsCachedInstance_noRebuild() {
        let cache = TranscriptNodeCache()
        let items = [userItem(id: "u1", text: "hi"), toolItem(id: "t1")]

        let r1 = cache.nodes(for: items)
        let r2 = cache.nodes(for: items)

        #expect(cache.rebuildCount == 1)
        #expect(baseAddress(r1) == baseAddress(r2))
    }

    // 2. A genuinely new (but equal-valued) array still hits the cache, because
    //    the key is value-equality, not buffer identity.
    @Test func equalValuedItems_stillCacheHit() {
        let cache = TranscriptNodeCache()
        let itemsA = [userItem(id: "u1", text: "hi"), toolItem(id: "t1")]
        let itemsB = [userItem(id: "u1", text: "hi"), toolItem(id: "t1")]

        _ = cache.nodes(for: itemsA)
        let r2 = cache.nodes(for: itemsB)

        #expect(cache.rebuildCount == 1)
        _ = r2
    }

    // 3. Count change → rebuild.
    @Test func countChange_rebuilds() {
        let cache = TranscriptNodeCache()
        _ = cache.nodes(for: [toolItem(id: "t1")])
        _ = cache.nodes(for: [toolItem(id: "t1"), toolItem(id: "t2")])
        #expect(cache.rebuildCount == 2)
    }

    // 4. CORRECTNESS: same count + same id, but a payload mutation (result
    //    nil → populated). Must invalidate, or the UI would silently miss the
    //    tool result appearing.
    @Test func sameCountSameId_payloadMutation_rebuilds() {
        let cache = TranscriptNodeCache()
        let before = [toolItem(id: "t1", result: nil)]
        let after = [toolItem(id: "t1",
                              result: ToolResult(text: "output", truncatedTo: nil, isError: false))]

        let r1 = cache.nodes(for: before)
        let r2 = cache.nodes(for: after)

        #expect(cache.rebuildCount == 2)
        #expect(r1 != r2)
    }

    // 5. CORRECTNESS: text edit under a stable id, same length, still busts cache.
    @Test func sameLengthTextEdit_rebuilds() {
        let cache = TranscriptNodeCache()
        _ = cache.nodes(for: [userItem(id: "u1", text: "cat")])
        _ = cache.nodes(for: [userItem(id: "u1", text: "dog")]) // same length, different content
        #expect(cache.rebuildCount == 2)
    }

    // 6. Toggling back and forth between two distinct item arrays rebuilds each
    //    time (single-slot cache) — documents the cache depth.
    @Test func alternatingItems_rebuildEachTime() {
        let cache = TranscriptNodeCache()
        let a = [toolItem(id: "t1")]
        let b = [toolItem(id: "t2")]
        _ = cache.nodes(for: a)
        _ = cache.nodes(for: b)
        _ = cache.nodes(for: a)
        #expect(cache.rebuildCount == 3)
    }

    // 7. CORRECTNESS: a subagent payload change under a stable toolCall id
    //    (recursive Equatable) must still bust the cache.
    @Test func subagentItemCountChange_rebuilds() {
        let cache = TranscriptNodeCache()
        let before = [TranscriptItem.toolCall(
            id: "t1", name: "Agent", inputJSON: "{}", inputTruncatedTo: nil,
            result: nil, subagent: Subagent(agentID: "a1", agentType: nil, items: []),
            timestamp: nil)]
        let after = [TranscriptItem.toolCall(
            id: "t1", name: "Agent", inputJSON: "{}", inputTruncatedTo: nil,
            result: nil,
            subagent: Subagent(agentID: "a1", agentType: nil,
                               items: [.userPrompt(id: "u1", text: "hi", timestamp: nil)]),
            timestamp: nil)]
        _ = cache.nodes(for: before)
        _ = cache.nodes(for: after)
        #expect(cache.rebuildCount == 2)
    }
}
