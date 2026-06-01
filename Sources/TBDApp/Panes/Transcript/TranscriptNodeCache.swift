import Foundation
import TBDShared
import os

/// Memoizes `transcriptRenderNodes(from:)` for a single `TranscriptItemsView`
/// instance so repeated `body` evaluations with unchanged `items` return the
/// SAME `[TranscriptRenderNode]` array instance.
///
/// Why (issue #129): `transcriptRenderNodes(from:)` walks every item, allocates
/// a fresh node array, and folds each node's multi-KB payload into a
/// `contentVersion` hash. Handing a *new* array identity to `ForEach` on every
/// `body` pass also forces SwiftUI/AttributeGraph to deep-copy the input (the
/// `TranscriptRenderNode` value-witness `initializeWithCopy` cost seen in hang
/// captures). Returning the same instance when `items` is unchanged lets
/// `ForEach` skip re-diffing and AttributeGraph skip the copy.
///
/// Cache key: value-equality of the `[TranscriptItem]` input. Both cheap and
/// correct:
///   - Cheap on the no-change path: `Array.==` checks `count` first, then
///     short-circuits on COW buffer identity. The live transcript only swaps in
///     a new array value when a poll detects a real change
///     (`LiveTranscriptPaneView.pollOnce`), so the common re-eval reuses the same
///     buffer → O(1).
///   - Correct: on a genuine content change the buffer differs and `==` does an
///     element compare, catching *every* mutation (result populating, text
///     growing, isError flipping, timestamps). A count/length-only signature
///     would silently drop a needed UI update, so we deliberately do NOT use a
///     partial signature.
///
/// Not thread-safe; only touched from `body` on the main actor.
@MainActor final class TranscriptNodeCache {
    private var cachedItems: [TranscriptItem]?
    private var cachedNodes: [TranscriptRenderNode] = []

    /// Number of times the node array was actually rebuilt (cache misses).
    /// Exposed for tests and as the before/after measurement signal for the
    /// issue #129 hover-rebuild fix.
    private(set) var rebuildCount = 0

    nonisolated private static let perfLog = Logger(subsystem: "com.tbd.app", category: "perf-transcript")

    func nodes(for items: [TranscriptItem]) -> [TranscriptRenderNode] {
        if let cachedItems, cachedItems == items {
            return cachedNodes
        }
        let nodes = transcriptRenderNodes(from: items)
        cachedItems = items
        cachedNodes = nodes
        rebuildCount &+= 1
        // Cache MISS only — silent at default log levels, never fires on the hot
        // (cache-hit) path. Counts rebuilds so a before/after mouse sweep is
        // measurable (issue #129). Activate with `log stream --level debug`.
        Self.perfLog.debug("nodes.rebuild seq=\(self.rebuildCount, privacy: .public) count=\(nodes.count, privacy: .public)")
        return nodes
    }
}
