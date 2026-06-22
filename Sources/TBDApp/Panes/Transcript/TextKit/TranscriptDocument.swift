import AppKit

/// Stateful document layer for the TextKit 2 transcript renderer.
///
/// Holds a single `NSMutableAttributedString` built from `TranscriptRenderNode` fragments
/// and a `node.id → NSRange` map so the layout engine can address individual nodes.
/// Exposes three mutation points for the streaming lifecycle:
///
/// - `rebuild(_:)` — full replace (initial load or /clear). Mutates `storage` in place so
///   consumers (NSTextContentStorage) holding a reference to the same object stay valid.
/// - `append(_:)` — O(1) append for each newly arrived node during streaming.
/// - `updateLast(_:)` — O(tail) in-place replace of the streaming tail node when its
///   content grows (text delta, tool result, error flag). Earlier nodes are immutable
///   once a newer node exists, so only the last range ever needs patching. (#129)
@MainActor
final class TranscriptDocument {

    // MARK: - Public state

    /// The accumulated attributed string. Consumers (NSTextContentStorage) hold a
    /// reference to this object; mutation is safe because all callers are @MainActor.
    /// The object identity is stable for the document's lifetime — `rebuild` mutates
    /// in place rather than replacing the instance.
    private(set) var storage = NSMutableAttributedString()

    /// Mirrors `storage.length` without requiring a property read on every hot-path call.
    private(set) var length = 0

    /// The card-rendering context passed through to `TranscriptDocumentBuilder`.
    let context: TranscriptCardContext

    // MARK: - Private state

    /// Maps `node.id → NSRange` within `storage`. Ranges for earlier (frozen) nodes
    /// never change after a newer node is appended.
    private var ranges: [String: NSRange] = [:]

    /// Node IDs in document order, parallel to the segments in `storage`.
    private var order: [String] = []

    // MARK: - Init

    init(context: TranscriptCardContext) {
        self.context = context
    }

    // MARK: - Public API

    /// The node IDs present in the document, in document order.
    var nodeIDs: [String] { order }

    /// Returns the `NSRange` of `id`'s fragment inside `storage`, or `nil` if absent.
    func range(forNodeID id: String) -> NSRange? { ranges[id] }

    /// Replaces the entire document with fragments built from `nodes`.
    /// Mutates `storage` **in place** (preserving object identity) so any consumer
    /// holding a reference to `storage` does not go stale.
    func rebuild(_ nodes: [TranscriptRenderNode]) {
        storage.deleteCharacters(in: NSRange(location: 0, length: storage.length))
        length = 0
        ranges.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        for node in nodes { appendNew(node) }
    }

    /// Appends a new node fragment to the end of the document.
    ///
    /// - If `node.id` is not yet tracked → appends normally.
    /// - If `node.id` is the current tail → in-place tail replace (same as `updateLast`).
    /// - If `node.id` is tracked but is NOT the tail → no-op (prevents orphaned bytes).
    func append(_ node: TranscriptRenderNode) {
        guard let oldRange = ranges[node.id] else {
            appendNew(node)
            return
        }
        // Already tracked.
        if order.last == node.id {
            replaceTail(node, oldRange: oldRange)
        }
        // else: tracked non-tail — no-op to avoid orphaning bytes.
    }

    /// Re-renders only the tail node in place. Used for streaming deltas where the
    /// last node's content grows (more text, tool result arriving, etc.).
    ///
    /// - If `node.id` equals the current tail → in-place replace (normal path).
    /// - If `node.id` is not yet tracked → delegates to `appendNew` (brand-new node).
    /// - If `node.id` is tracked but is NOT the tail → no-op (prevents orphaned bytes).
    func updateLast(_ node: TranscriptRenderNode) {
        guard let oldRange = ranges[node.id] else {
            // Untracked id — fall back to append for brand-new nodes.
            appendNew(node)
            return
        }
        if order.last == node.id {
            replaceTail(node, oldRange: oldRange)
        }
        // else: tracked non-tail — no-op.
    }

    // MARK: - Private helpers

    /// Appends a new node that is not yet tracked. Caller must ensure `ranges[node.id] == nil`.
    private func appendNew(_ node: TranscriptRenderNode) {
        let fragment = TranscriptDocumentBuilder.fragment(for: node, context: context)
        let start = length
        storage.append(fragment)
        length = storage.length
        ranges[node.id] = NSRange(location: start, length: length - start)
        order.append(node.id)
    }

    /// Replaces the tail node's bytes in place. Caller must ensure `node.id == order.last`.
    private func replaceTail(_ node: TranscriptRenderNode, oldRange: NSRange) {
        let fragment = TranscriptDocumentBuilder.fragment(for: node, context: context)
        storage.replaceCharacters(in: oldRange, with: fragment)
        length = storage.length
        ranges[node.id] = NSRange(location: oldRange.location, length: fragment.length)
    }
}
