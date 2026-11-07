import Foundation

/// Lines a file-editing tool call adds and removes, measured from its
/// untruncated input.
public struct FileEditStats: Sendable, Equatable {
    public let added: Int
    public let removed: Int

    public init(added: Int, removed: Int) {
        self.added = added
        self.removed = removed
    }
}

/// A run of whole transcript lines that ends at a byte offset, read by
/// `TranscriptParser.parseWindow`. Offsets are absolute byte offsets into the
/// transcript file, so a window and the next older one meet exactly at
/// `startOffset`.
public struct TranscriptWindow: Sendable {
    /// One item, and the offset of the first byte of the line it came from.
    public struct Entry: Sendable {
        public let item: TranscriptItem
        public let lineOffset: UInt64

        public init(item: TranscriptItem, lineOffset: UInt64) {
            self.item = item
            self.lineOffset = lineOffset
        }
    }

    public let entries: [Entry]
    /// The first byte of the first kept line. The next older window ends here.
    public let startOffset: UInt64
    /// The window's exclusive end.
    public let endOffset: UInt64
    /// Whether the window reaches back to the start of the file.
    public var reachedStart: Bool { startOffset == 0 }
    /// Every tool result in the bytes read, including results on lines the
    /// window trimmed from its front.
    public let toolResultsByID: [String: ToolResult]
    /// `tool_use` id → line stats from the untruncated input, for every
    /// Edit, MultiEdit and Write call in the bytes read.
    public let fileEdits: [String: FileEditStats]
    /// `tool_use` id → the subagent's `agentId`, for every subagent call whose
    /// result is in the bytes read.
    public let subagentAgentIDs: [String: String]

    public init(
        entries: [Entry], startOffset: UInt64, endOffset: UInt64,
        toolResultsByID: [String: ToolResult],
        fileEdits: [String: FileEditStats],
        subagentAgentIDs: [String: String]
    ) {
        self.entries = entries
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.toolResultsByID = toolResultsByID
        self.fileEdits = fileEdits
        self.subagentAgentIDs = subagentAgentIDs
    }
}

extension TranscriptParser {
    /// The first read size of `parseWindow`, unless its `scanLimit` is
    /// smaller. Each retry doubles it.
    static let windowInitialChunkBytes: UInt64 = 64 * 1024

    /// The newest whole lines before `end`, built into items, holding at most
    /// `messageLimit` messages and about `itemLimit` items.
    ///
    /// `end` (`endingBefore`) is a byte offset. Below the file's size it must
    /// be a line start: the byte before it must be `"\n"`. Past the file's
    /// size it is stale: it names bytes the file no longer holds, such as a
    /// cursor taken before the file was rewritten or truncated. In either
    /// case this returns nil, as it does when the file cannot be read. Nil,
    /// or an offset equal to the file's size, means the end of the file's
    /// complete lines: just past its last `"\n"`, or 0 when it has none. A
    /// last line with no newline yet is one Claude Code is still writing, so
    /// the window leaves it out and `endOffset` stops before it. A live append
    /// cursor started at `endOffset` then reads that line whole once it is
    /// finished, the way `TranscriptFileWindow.read(path:from:)` withholds a
    /// partial line. A window's `startOffset` is always a line start, so it is
    /// the `end` of the next older window.
    ///
    /// The read goes backwards from `end`, `windowInitialChunkBytes` at first.
    /// A read that starts inside the file drops its bytes up to and including
    /// the first `"\n"`, since they may be the tail of a line that began
    /// earlier. Every whole line is decoded as JSON, and lines that fail to
    /// decode are skipped. A line's item ID comes from its `uuid`, or from
    /// `at-<lineOffset>` when it has none, so two windows that hold the same
    /// line give it the same ID. The read is accepted when any of these holds:
    /// - its items hold `messageLimit` messages (`.userPrompt`,
    ///   `.assistantText`, `.peerMessage`);
    /// - its items reach `itemLimit`;
    /// - it starts at the first byte of the file;
    /// - it spans `scanLimit` bytes and holds at least one whole line.
    ///
    /// Otherwise the read size doubles, stopping at `scanLimit` on the way and
    /// never going past `end`, and the read reaches further back. Each pass
    /// reads and decodes only the bytes before the lines it already holds, and
    /// builds the items of every held line again.
    ///
    /// `scanLimit` bounds the bytes one call reads back from `end` when the
    /// lines there hold few items, such as a few huge tool results between
    /// two messages. The window then holds fewer than `messageLimit` messages
    /// and `reachedStart` is false, and the next older window carries on from
    /// `startOffset`. A line longer than `scanLimit` is still read whole, so
    /// the window holds at least one line whenever there is one before `end`.
    /// Such a window can hold no items, when none of its lines builds one;
    /// its `startOffset` still moves back past them.
    ///
    /// Then the front is trimmed, by whole lines only:
    /// - Everything from the line that holds the `messageLimit`-th message
    ///   counted from the end is kept, back to and including that message.
    ///   When there are fewer messages, nothing is trimmed by this rule.
    /// - If more than `itemLimit` items remain, the oldest lines are dropped
    ///   until at most `itemLimit` remain. The newest line is always kept,
    ///   so a single line with more than `itemLimit` items is returned whole.
    /// - `startOffset` is the offset of the line of the first kept item.
    ///   Lines before it that build no item, such as the results of older
    ///   tool calls, belong to the next older window, where those calls are.
    ///   The one exception: when the read started at the first byte of the
    ///   file and no item was trimmed, `startOffset` is 0.
    ///
    /// `toolResultsByID`, `fileEdits` and `subagentAgentIDs` cover every line
    /// read, trimmed lines included. Sidechain (subagent) lines build items
    /// only when `includeSidechain` is true. Limits below 1 count as 1.
    public static func parseWindow(
        filePath: String, endingBefore requestedEnd: UInt64?, messageLimit: Int,
        itemLimit: Int, includeSidechain: Bool = false, scanLimit: Int = 8 * 1024 * 1024
    ) -> TranscriptWindow? {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        if let requestedEnd, requestedEnd > fileSize { return nil }

        let end: UInt64
        if let requestedEnd, requestedEnd < fileSize {
            if requestedEnd > 0 {
                guard let before = readBytes(handle, in: (requestedEnd - 1)..<requestedEnd),
                      before.first == UInt8(ascii: "\n") else { return nil }
            }
            end = requestedEnd
        } else {
            guard let linesEnd = completeLinesEnd(handle, fileSize: fileSize) else { return nil }
            end = linesEnd
        }
        let messageLimit = max(1, messageLimit)
        let itemLimit = max(1, itemLimit)
        let scanLimit = UInt64(max(1, scanLimit))

        // The whole lines decoded so far, from `keptStart` to `end`. Each pass
        // reads only the bytes before `keptStart`. `start < keptStart` on every
        // pass after the first, since `keptStart` is never before the previous
        // pass's start and the read size grows.
        var lines = WindowLines()
        var keptStart = end
        var chunk = min(windowInitialChunkBytes, scanLimit, end)
        while true {
            let start = end - chunk
            guard let bytes = readBytes(handle, in: start..<keptStart) else { return nil }

            let fresh: Data
            let freshStart: UInt64
            if start == 0 {
                fresh = bytes
                freshStart = 0
            } else if let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
                fresh = bytes[(newline + 1)...]
                freshStart = start + UInt64(newline + 1 - bytes.startIndex)
            } else {
                // No new whole line. Unreachable while the byte before
                // `keptStart` is "\n", which `end` and every line start
                // guarantee, but harmless: the held lines stay as they are.
                fresh = Data()
                freshStart = keptStart
            }
            lines.prepend(decodeWindowLines(fresh, firstLineOffset: freshStart))
            keptStart = freshStart

            let built = buildItemsWithLineIndices(
                rawLines: lines.rawLines, stableIDs: lines.stableIDs,
                toolResultsByID: lines.toolResultsByID, includeSidechain: includeSidechain)
            let messageCount = built.items.filter(isWindowMessage).count
            // `keptStart < end`: at least one whole line is held.
            let scannedEnough = chunk >= scanLimit && keptStart < end

            if messageCount >= messageLimit || built.items.count >= itemLimit || start == 0 || scannedEnough {
                return trimmedWindow(
                    lines: lines, items: built.items, lineIndices: built.lineIndices,
                    keptStart: keptStart, end: end, messageLimit: messageLimit, itemLimit: itemLimit)
            }
            chunk = nextWindowChunk(after: chunk, scanLimit: scanLimit, end: end)
        }
    }

    /// Line stats for every Edit, MultiEdit and Write `tool_use` block on an
    /// assistant line, keyed by `tool_use` id, from the raw input. The items
    /// `buildItems` makes carry input whose strings `truncateInputStrings`
    /// capped, so the stats must come from the line itself.
    ///
    /// - **Edit** – `new_string`'s lines diffed against `old_string`'s, with
    ///   `Array.difference(from:)`: `added` is the insertion count and
    ///   `removed` the removal count.
    /// - **MultiEdit** – the same for each entry of `edits`, summed.
    /// - **Write** – `added` is the line count of `content`, `removed` 0.
    ///
    /// Text splits into lines at `"\n"` (or `"\r\n"`), and a final newline
    /// ends the last line rather than starting an empty one.
    public static func fileEditStats(fromLine json: [String: Any]) -> [String: FileEditStats] {
        guard json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return [:] }

        var stats: [String: FileEditStats] = [:]
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String,
                  let input = block["input"] as? [String: Any] else { continue }
            switch block["name"] as? String {
            case "Edit":
                stats[id] = editStats(old: input["old_string"], new: input["new_string"])
            case "MultiEdit":
                let edits = (input["edits"] as? [[String: Any]]) ?? []
                let each = edits.map { editStats(old: $0["old_string"], new: $0["new_string"]) }
                stats[id] = FileEditStats(
                    added: each.reduce(0) { $0 + $1.added },
                    removed: each.reduce(0) { $0 + $1.removed })
            case "Write":
                let content = (input["content"] as? String) ?? ""
                stats[id] = FileEditStats(added: editLines(content).count, removed: 0)
            default:
                continue
            }
        }
        return stats
    }

    /// `tool_use` id → subagent `agentId`, from a user line that returns a
    /// subagent call's result.
    ///
    /// Claude Code records the subagent beside the result, not inside it: the
    /// line's `message.content` holds one `tool_result` block, and the line's
    /// top-level `toolUseResult.agentId` names the agent, whose transcript is
    /// `<sessionID>/subagents/agent-<agentId>.jsonl`. `toolUseResult`
    /// describes the line's one result, so a line with several `tool_result`
    /// blocks, or with an empty or non-string `agentId`, maps nothing.
    public static func subagentAgentIDs(fromLine json: [String: Any]) -> [String: String] {
        guard json["type"] as? String == "user",
              let toolUseResult = json["toolUseResult"] as? [String: Any],
              let agentID = toolUseResult["agentId"] as? String, !agentID.isEmpty,
              let message = json["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return [:] }
        let results = blocks.filter { $0["type"] as? String == "tool_result" }
        guard results.count == 1, let toolUseID = results[0]["tool_use_id"] as? String else { return [:] }
        return [toolUseID: agentID]
    }

    // MARK: - window helpers

    /// The stable ID of a window line with no `uuid`: `at-<offset>`, where
    /// `offset` is the line's first byte.
    static func windowLineID(offset: UInt64) -> String {
        "at-\(offset)"
    }

    /// The offset an `at-<offset>` line ID names, or nil for any other ID.
    /// Takes a line ID without an item's `#<block>` suffix.
    static func windowLineOffset(fromLineID lineID: String) -> UInt64? {
        let prefix = "at-"
        guard lineID.hasPrefix(prefix) else { return nil }
        let digits = lineID.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return UInt64(digits)
    }

    /// The decoded lines of one read, each with its absolute offset, and the
    /// per-line facts a window reports.
    private struct WindowLines {
        var rawLines: [[String: Any]] = []
        /// Parallel to `rawLines`.
        var offsets: [UInt64] = []
        /// Parallel to `rawLines`.
        var stableIDs: [String] = []
        var toolResultsByID: [String: ToolResult] = [:]
        var fileEdits: [String: FileEditStats] = [:]
        var subagentAgentIDs: [String: String] = [:]

        /// Puts `older`, the lines just before these, in front of them. Where
        /// both name the same id, the later line wins, as it does within one
        /// decode.
        mutating func prepend(_ older: WindowLines) {
            rawLines = older.rawLines + rawLines
            offsets = older.offsets + offsets
            stableIDs = older.stableIDs + stableIDs
            toolResultsByID.merge(older.toolResultsByID) { later, _ in later }
            fileEdits.merge(older.fileEdits) { later, _ in later }
            subagentAgentIDs.merge(older.subagentAgentIDs) { later, _ in later }
        }
    }

    /// Splits `bytes`, which start at a line start whose file offset is
    /// `firstLineOffset`, on `"\n"`, and decodes each line. `parseWindow`
    /// only hands it bytes that end in `"\n"`, since a window never ends
    /// inside a line.
    private static func decodeWindowLines(_ bytes: Data, firstLineOffset: UInt64) -> WindowLines {
        var lines = WindowLines()
        var lineStart = bytes.startIndex
        while lineStart < bytes.endIndex {
            let lineEnd = bytes[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? bytes.endIndex
            let offset = firstLineOffset + UInt64(lineStart - bytes.startIndex)
            let lineData = Data(bytes[lineStart..<lineEnd])
            lineStart = lineEnd + 1
            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            lines.rawLines.append(json)
            lines.offsets.append(offset)
            lines.stableIDs.append((json["uuid"] as? String) ?? windowLineID(offset: offset))

            for toolResult in toolResults(fromLine: json) {
                lines.toolResultsByID[toolResult.id] = toolResult.result
            }
            lines.fileEdits.merge(fileEditStats(fromLine: json)) { _, newer in newer }
            lines.subagentAgentIDs.merge(subagentAgentIDs(fromLine: json)) { _, newer in newer }
        }
        return lines
    }

    /// Applies `parseWindow`'s front-trim rules to an accepted read whose
    /// first whole line starts at `keptStart`, which is 0 exactly when the
    /// read started at the first byte of the file.
    private static func trimmedWindow(
        lines: WindowLines, items: [TranscriptItem], lineIndices: [Int],
        keptStart: UInt64, end: UInt64, messageLimit: Int, itemLimit: Int
    ) -> TranscriptWindow {
        var first = 0

        // Back to and including the `messageLimit`-th message from the end,
        // from the first item of its line.
        let messageIndices = items.indices.filter { isWindowMessage(items[$0]) }
        if messageIndices.count >= messageLimit {
            let cutLine = lineIndices[messageIndices[messageIndices.count - messageLimit]]
            first = lineIndices.firstIndex(of: cutLine) ?? 0
        }

        // Whole oldest lines off the front while over `itemLimit`, never the
        // newest line. `lineIndices` never decreases, so the inner loop stops
        // on the newest line at the latest.
        if let newestLine = lineIndices.last {
            while items.count - first > itemLimit, lineIndices[first] != newestLine {
                let line = lineIndices[first]
                while lineIndices[first] == line { first += 1 }
            }
        }

        let startOffset: UInt64
        if items.isEmpty || (first == 0 && keptStart == 0) {
            startOffset = keptStart
        } else {
            startOffset = lines.offsets[lineIndices[first]]
        }

        let entries = (first..<items.count).map {
            TranscriptWindow.Entry(item: items[$0], lineOffset: lines.offsets[lineIndices[$0]])
        }
        return TranscriptWindow(
            entries: entries, startOffset: startOffset, endOffset: end,
            toolResultsByID: lines.toolResultsByID,
            fileEdits: lines.fileEdits,
            subagentAgentIDs: lines.subagentAgentIDs)
    }

    /// `parseWindow`'s read size after `chunk`: twice it, but no more than
    /// `scanLimit` while below it, and never past `end`.
    private static func nextWindowChunk(after chunk: UInt64, scanLimit: UInt64, end: UInt64) -> UInt64 {
        let doubled = chunk * 2
        return min(chunk < scanLimit ? min(doubled, scanLimit) : doubled, end)
    }

    /// Whether `item` counts toward `parseWindow`'s `messageLimit`.
    private static func isWindowMessage(_ item: TranscriptItem) -> Bool {
        switch item {
        case .userPrompt, .assistantText, .peerMessage: return true
        default: return false
        }
    }

    /// The bytes in `range`, or nil when they cannot all be read, such as
    /// when the file shrank since its size was taken.
    private static func readBytes(_ handle: FileHandle, in range: Range<UInt64>) -> Data? {
        guard !range.isEmpty else { return Data() }
        let count = Int(range.upperBound - range.lowerBound)
        guard (try? handle.seek(toOffset: range.lowerBound)) != nil,
              let data = try? handle.read(upToCount: count),
              data.count == count else { return nil }
        return data
    }

    /// Where the file's complete lines end: just past the last `"\n"` before
    /// `fileSize`, or 0 when there is none. Nil when a read fails. A file
    /// that ends in `"\n"` costs a one-byte read; otherwise the scan goes back
    /// `windowInitialChunkBytes` at a time over the unfinished last line.
    private static func completeLinesEnd(_ handle: FileHandle, fileSize: UInt64) -> UInt64? {
        guard fileSize > 0 else { return 0 }
        guard let last = readBytes(handle, in: (fileSize - 1)..<fileSize) else { return nil }
        if last.first == UInt8(ascii: "\n") { return fileSize }

        var readEnd = fileSize - 1
        while readEnd > 0 {
            let readStart = readEnd - min(windowInitialChunkBytes, readEnd)
            guard let bytes = readBytes(handle, in: readStart..<readEnd) else { return nil }
            if let newline = bytes.lastIndex(of: UInt8(ascii: "\n")) {
                return readStart + UInt64(newline - bytes.startIndex) + 1
            }
            readEnd = readStart
        }
        return 0
    }

    private static func editStats(old: Any?, new: Any?) -> FileEditStats {
        let oldLines = editLines((old as? String) ?? "")
        let newLines = editLines((new as? String) ?? "")
        let difference = newLines.difference(from: oldLines)
        return FileEditStats(added: difference.insertions.count, removed: difference.removals.count)
    }

    private static func editLines(_ text: String) -> [Substring] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}
