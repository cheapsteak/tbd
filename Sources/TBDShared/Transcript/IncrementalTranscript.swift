import Foundation

/// Accumulates a Claude session transcript from JSONL lines delivered in
/// arbitrary chunks, producing exactly what `TranscriptParser.parse` would
/// produce over the concatenation of those chunks.
///
/// Two facts make this possible, and both are load-bearing:
///
/// 1. `TranscriptParser.buildItems` is a pure function of the lines handed to
///    it — every item is derivable from its own row. So lines that arrive
///    later can be built in isolation and appended.
/// 2. The single exception is `toolResultsByID`. A `tool_use` resolves its
///    result from a `user` line that arrives LATER, so an append-only
///    implementation leaves such tool cards permanently unresolved. Ingest
///    therefore patches already-built items when their result finally lands.
///
/// Raw line dictionaries are deliberately not retained. Holding every parsed
/// `[String: Any]` for a large session would cost more memory than this design
/// saves in transfer; only the built items, the result index, and the rows of
/// tool calls that might still be patched are kept.
public struct IncrementalTranscript: Sendable {

    /// What one `ingest` changed, so a caller can publish narrowly instead of
    /// diffing the whole array.
    public struct Change: Sendable, Equatable {
        public let appended: Range<Int>
        public let updated: [Int]
        public init(appended: Range<Int>, updated: [Int]) {
            self.appended = appended
            self.updated = updated
        }
        public var isEmpty: Bool { appended.isEmpty && updated.isEmpty }
    }

    public private(set) var items: [TranscriptItem] = []

    /// Every tool result seen so far, by `tool_use_id`.
    private var toolResultsByID: [String: ToolResult] = [:]
    /// Position in `items` of the tool call carrying each `tool_use_id`, so a
    /// late result can patch one item instead of rebuilding the array.
    private var toolCallIndexByID: [String: Int] = [:]
    /// Raw row and stable id of each built tool call, kept so it can be rebuilt
    /// in place once its result arrives. Only tool-call rows are retained —
    /// every other row is final the moment it is built.
    ///
    /// `[String: Any]` is not `Sendable`, so the retained rows are re-encoded
    /// to their original JSON text and re-parsed on the rare patch. That keeps
    /// this a `Sendable` value type without a lock or an `@unchecked`
    /// conformance, and costs one JSON round-trip per late tool result rather
    /// than per line.
    ///
    /// A row lives here only while its call is **unresolved**. A tool call's
    /// row is often the largest line in a transcript (the whole tool input), so
    /// keeping resolved ones would roughly double the memory the tool-call
    /// portion costs, for no reachable use: `buildItems` consumes the result
    /// exactly once, and a `tool_use_id` is answered exactly once. Rows are
    /// therefore never retained for a call whose result is already in
    /// `toolResultsByID`, and are dropped as soon as a late result patches the
    /// item in. What remains is bounded by the calls still in flight.
    private var toolCallRowByID: [String: RetainedRow] = [:]
    /// Lines ingested so far, for the `line-N` stable-id fallback. Must count
    /// the same lines the whole-file parser counts, or ids diverge.
    private var lineCursor = 0

    /// One tool-call row held for a possible later patch: the line's original
    /// JSON text plus the stable id `buildItems` was given for it.
    private struct RetainedRow: Sendable {
        let line: String
        let stableID: String
    }

    /// How many tool-call rows are still held for a possible later patch —
    /// i.e. how many calls are still unanswered. Internal and read-only, so
    /// `@testable` can assert the bound and nothing public can depend on it.
    var retainedToolCallRowCount: Int { toolCallRowByID.count }

    public init() {}

    @discardableResult
    public mutating func ingest(lines: [String]) -> Change {
        guard !lines.isEmpty else { return Change(appended: items.count..<items.count, updated: []) }

        var rawLines: [[String: Any]] = []
        var rawText: [String] = []
        var stableIDs: [String] = []
        var newlyResolved: [String] = []

        for line in lines where !line.isEmpty {
            defer { lineCursor += 1 }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            rawLines.append(json)
            rawText.append(line)
            stableIDs.append((json["uuid"] as? String) ?? "line-\(lineCursor)")

            if json["type"] as? String == "user",
               let message = json["message"] as? [String: Any],
               let array = message["content"] as? [[String: Any]] {
                for block in array where (block["type"] as? String) == "tool_result" {
                    guard let id = block["tool_use_id"] as? String else { continue }
                    toolResultsByID[id] = TranscriptParser.extractToolResult(from: block)
                    // A result for a call built in an EARLIER ingest must patch
                    // that item. One for a call in THIS batch is picked up by
                    // buildItems below and needs no patch.
                    if toolCallIndexByID[id] != nil { newlyResolved.append(id) }
                }
            }
        }

        let start = items.count
        let built = TranscriptParser.buildItems(
            rawLines: rawLines, stableIDs: stableIDs, toolResultsByID: toolResultsByID)
        items.append(contentsOf: built)

        // Index the tool calls this batch produced, retaining their rows so a
        // later result can rebuild them. One assistant row can carry several
        // tool_use blocks, so map every id the row declares.
        //
        // A call whose result is ALREADY in `toolResultsByID` needs no row: the
        // `buildItems` above resolved it, so the item is final and no patch
        // below can ever name it. That is the whole-file case, and the common
        // one for a pane opening onto an existing transcript.
        for rowIdx in rawLines.indices {
            for toolUseID in Self.toolUseIDs(in: rawLines[rowIdx])
            where toolResultsByID[toolUseID] == nil {
                toolCallRowByID[toolUseID] = RetainedRow(
                    line: rawText[rowIdx], stableID: stableIDs[rowIdx])
            }
        }
        for (offset, item) in built.enumerated() {
            guard case .toolCall(let toolUseID, _, _, _, _, _, _, _) = item else { continue }
            toolCallIndexByID[toolUseID] = start + offset
        }

        // Patch earlier items whose result has now arrived.
        var updated: [Int] = []
        for id in newlyResolved {
            guard let idx = toolCallIndexByID[id], let row = toolCallRowByID[id],
                  let data = row.line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let rebuilt = TranscriptParser.buildItems(
                rawLines: [json], stableIDs: [row.stableID], toolResultsByID: toolResultsByID)
            guard let replacement = rebuilt.first(where: { $0.id == items[idx].id }) else { continue }
            if items[idx] != replacement {
                items[idx] = replacement
                updated.append(idx)
            }
        }

        // Each id in `newlyResolved` has had its one result folded in. Nothing
        // can name it again, so stop carrying its JSON text. Done after the
        // loop rather than inside it because sibling ids on the SAME assistant
        // row hold separate entries pointing at that one line, and each still
        // needs its own rebuild.
        for id in newlyResolved { toolCallRowByID.removeValue(forKey: id) }

        return Change(appended: start..<items.count, updated: updated)
    }

    /// Every `tool_use` id an assistant row declares.
    private static func toolUseIDs(in json: [String: Any]) -> [String] {
        guard json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        return content
            .filter { ($0["type"] as? String) == "tool_use" }
            .compactMap { $0["id"] as? String }
    }
}
