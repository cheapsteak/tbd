import AppKit

/// Chat-bubble classification for a message block, used by the renderer to
/// draw the right background chrome behind a node's text range (#129):
///
/// - `.user` → right-aligned, narrower filled blue bubble (matches
///   `ChatBubbleView`'s `Color.accentColor.opacity(0.15)`).
/// - `.assistant` → full-width bordered rounded card (1px border, light fill).
/// - `.other` → no bubble (tool cards, subagent summaries draw their own chrome).
enum BubbleRole: Equatable {
    case user
    case assistant
    case other

    /// Interior horizontal padding between a chat bubble's text and its drawn
    /// edge (matches `ChatBubbleView`'s ~11pt chrome inset). Shared so the
    /// right-aligned user paragraph's `tailIndent` (in `TranscriptDocumentBuilder`)
    /// and the bubble rect's `hInset` (in `BubbleBackgroundView`) stay in lock-step:
    /// the tail indent pulls the wrapped text's right edge inward by this amount so
    /// it never runs to the container margin, and the same value grows the drawn
    /// bubble back out so the text sits inside with symmetric padding. (#129)
    static let horizontalPadding: CGFloat = 11

    /// Vertical clearance reserved BETWEEN the role header ("You" / "Claude") and
    /// the top of the drawn bubble/card, so the header sits above the card with a
    /// gap (as in `ChatBubbleView`'s `VStack(spacing: 3)` + the card's own 8pt top
    /// inset) instead of being painted over the top border. Applied as the body's
    /// first-paragraph `paragraphSpacingBefore` in `TranscriptDocumentBuilder`; it
    /// must exceed `BubbleBackgroundView.vInset` (8) so the card's top edge — the
    /// body top minus that inset — still lands below the header. (#129)
    static let headerBodyGap: CGFloat = 14

    /// Stable string carried in the `.transcriptBubbleRole` attribute. `.other`
    /// is never stamped (those nodes draw no bubble), so it has no value.
    var attributeValue: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .other: return "other"
        }
    }

    init?(attributeValue: String) {
        switch attributeValue {
        case "user": self = .user
        case "assistant": self = .assistant
        default: return nil
        }
    }
}

extension NSAttributedString.Key {
    /// Stamped by `TranscriptDocumentBuilder` onto a chat-bubble's BODY range
    /// (header excluded). Its value is the `BubbleRole` raw string ("user" /
    /// "assistant"); `ReadOnlySTTextView` scans the rendered text storage for
    /// these runs to draw bubble chrome behind the text. Carrying the role in
    /// the attributed string (rather than a side map) means any code path that
    /// renders the same storage — including the headless visual-compare harness —
    /// draws identical bubbles. (#129)
    static let transcriptBubbleRole = NSAttributedString.Key("transcriptBubbleRole")
}

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

    /// The accumulated attributed string — the SINGLE SOURCE OF TRUTH the
    /// `STTextView` actually renders. After `bind(to:)` adopts STTextView's own
    /// `NSTextContentStorage.textStorage`, every mutation here (`append`/
    /// `updateLast`/`rebuild`) lands directly in the bytes the layout manager
    /// lays out, so streaming edits are visible. (Before `bind`, it is a
    /// standalone `NSTextStorage()` — e.g. in document-layer unit tests.)
    ///
    /// `NSTextStorage` is an `NSMutableAttributedString` subclass, so
    /// `append`/`replaceCharacters`/`deleteCharacters`/`length`/`string`/
    /// `enumerateAttribute` all behave identically. Consumers may hold a
    /// reference; mutation is safe because all callers are @MainActor.
    private(set) var storage = NSTextStorage()

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

    /// Adopt an externally-owned `NSTextStorage` (STTextView's own
    /// `NSTextContentStorage.textStorage`) as this document's backing store, so
    /// the document mutates the EXACT object STTextView renders. Without this,
    /// `attributedText =` would copy bytes into a different internal storage and
    /// our streaming `append`/`updateLast` would be invisible (#129, C1).
    ///
    /// Resets all bookkeeping; the caller must follow with `rebuild` to populate
    /// the adopted storage from the current nodes. We do NOT replace STTextView's
    /// `textStorage` object — we reuse the one already wired to its layout manager.
    func bind(to external: NSTextStorage) {
        storage = external
        ranges.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        length = 0
    }

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
