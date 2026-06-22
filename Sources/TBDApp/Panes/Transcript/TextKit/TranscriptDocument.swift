import AppKit

/// Stateful document layer for the TextKit 2 transcript renderer.
///
/// Holds a single `NSMutableAttributedString` built from `TranscriptRenderNode` fragments
/// and a `node.id → NSRange` map so the layout engine can address individual nodes.
/// Exposes three mutation points for the streaming lifecycle:
///
/// - `rebuild(_:)` — full replace (initial load or /clear).
/// - `append(_:)` — O(1) append for each newly arrived node during streaming.
/// - `updateLast(_:)` — O(tail) in-place replace of the streaming tail node when its
///   content grows (text delta, tool result, error flag). Earlier nodes are immutable
///   once a newer node exists, so only the last range ever needs patching. (#129)
@MainActor
final class TranscriptDocument {

    // MARK: - Public state

    /// The accumulated attributed string. Consumers (NSTextContentStorage) hold a
    /// reference to this object; mutation is safe because all callers are @MainActor.
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
    /// Resets `storage`, `ranges`, `order`, and `length`.
    func rebuild(_ nodes: [TranscriptRenderNode]) {
        storage = NSMutableAttributedString()
        length = 0
        ranges.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        for node in nodes { append(node) }
    }

    /// Appends a new node fragment to the end of the document.
    ///
    /// If `node.id` is already tracked (e.g. called twice for the same id),
    /// the range map is updated in place and no duplicate id is added to `order`.
    func append(_ node: TranscriptRenderNode) {
        let fragment = TranscriptDocumentBuilder.fragment(for: node, context: context)
        let start = length
        storage.append(fragment)
        length = storage.length
        let nodeRange = NSRange(location: start, length: length - start)
        if ranges[node.id] == nil {
            order.append(node.id)
        }
        ranges[node.id] = nodeRange
    }

    /// Re-renders only the tail node in place. Used for streaming deltas where the
    /// last node's content grows (more text, tool result arriving, etc.).
    ///
    /// Requires `node.id == order.last`. If the id is not the tail (or the document
    /// is empty), falls back to `append(_:)` rather than crashing.
    func updateLast(_ node: TranscriptRenderNode) {
        guard let lastID = order.last, lastID == node.id, let oldRange = ranges[node.id] else {
            append(node)
            return
        }
        let fragment = TranscriptDocumentBuilder.fragment(for: node, context: context)
        storage.replaceCharacters(in: oldRange, with: fragment)
        length = storage.length
        ranges[node.id] = NSRange(location: oldRange.location, length: fragment.length)
    }
}
