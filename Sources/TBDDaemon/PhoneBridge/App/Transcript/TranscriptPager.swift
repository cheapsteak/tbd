import CryptoKit
import Foundation
import TBDShared

/// One transcript page, and what the feed keeps from building it.
struct PageBuild: Sendable {
    let page: TranscriptPage
    /// The first byte of the page's first source line. The next older page
    /// ends here, and the page's cursor names it.
    let startOffset: UInt64
    /// The window's exclusive end: just past the last whole line it read. A
    /// live append cursor starts here, so it reads every line after the page,
    /// a line Claude Code was still writing included, once it is whole.
    let endOffset: UInt64
    /// Item ID → the offset of the line it came from, for every item on the
    /// page, so a detail lookup can start there.
    let lineOffsets: [String: UInt64]
    /// The page's tool rows still `running`, by item ID: tool, file-edit and
    /// subagent rows whose result is neither in the window nor in
    /// `ShapingContext.joinedResults`. The feed updates them when a result
    /// arrives.
    let unresolvedCalls: [String: PhoneItem]
    /// Every tool result in the bytes the window read, for joins into older
    /// pages.
    let results: [String: ToolResult]
}

/// Builds transcript pages (spec section 7, "Pages"): the first page from the
/// end of the file, and older pages before a cursor, each fitted to its byte
/// budget.
///
/// Every path comes from the feed, which takes it from the terminal's
/// transcript locator or the remote transcript cache. A path never comes from
/// the phone. The phone sends only cursors, and a cursor is checked against the
/// file before any page is read from it.
enum TranscriptPager {
    /// The most bytes of one line a cursor's anchor covers. A longer line is
    /// anchored by its first `anchorLineBytes` bytes, so making or checking a
    /// cursor never reads a whole multi-megabyte line.
    static let anchorLineBytes = 65_536
    /// Hex characters in a cursor's anchor.
    static let anchorHexLength = 16
    /// The longest cursor accepted. A real one is under 60 bytes.
    static let cursorMaxBytes = 128

    static let staleCursorMessage = "That part of the transcript has changed. Reopen the transcript to load it again."

    // MARK: - Pages

    /// The newest page: back to and including the 4th-last message, with at
    /// most `firstPageItemLimit` items, fitted to `firstPageBytes`. Nil when
    /// the file cannot be read.
    static func firstPage(filePath: String, generation: Int, ctx: ShapingContext) -> PageBuild? {
        guard let window = TranscriptParser.parseWindow(
            filePath: filePath, endingBefore: nil,
            messageLimit: PhoneAppConstants.firstPageMessages,
            itemLimit: PhoneAppConstants.firstPageItemLimit) else { return nil }
        return build(window, filePath: filePath, generation: generation, ctx: ctx, budget: PhoneFrameBudget.firstPageBytes)
    }

    /// The page before `cursor`: the next `olderPageMessages` messages back,
    /// with at most `olderPageItemLimit` items, fitted to `olderPageBytes`.
    /// A tool call whose result is not in the window takes its status from
    /// `ctx.joinedResults`, the results the feed kept from newer pages and
    /// live updates.
    ///
    /// Throws `stale_cursor` when the cursor does not resolve
    /// (`resolveCursor`) or names no line start the file still holds.
    static func olderPage(filePath: String, cursor: String, generation: Int, ctx: ShapingContext) throws -> PageBuild {
        guard let offset = resolveCursor(cursor, generation: generation, filePath: filePath),
              let window = TranscriptParser.parseWindow(
                filePath: filePath, endingBefore: offset,
                messageLimit: PhoneAppConstants.olderPageMessages,
                itemLimit: PhoneAppConstants.olderPageItemLimit) else {
            throw PhoneAppError(code: .staleCursor, message: staleCursorMessage)
        }
        return build(window, filePath: filePath, generation: generation, ctx: ctx, budget: PhoneFrameBudget.olderPageBytes)
    }

    // MARK: - Cursors

    /// `"<generation>:<offset>:<anchor>"`, where `anchor` is the first 16 hex
    /// characters of the SHA-256 of the line at `offset`: its bytes before
    /// the `"\n"`, or its first `anchorLineBytes` bytes when it is longer.
    /// Nil when the file cannot be read, when `offset` is not before its end,
    /// or when the file ends inside the line's first `anchorLineBytes` bytes
    /// with no `"\n"`: a last line Claude Code is still writing.
    static func makeCursor(generation: Int, offset: UInt64, filePath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), offset < fileSize,
              let head = readBytes(handle, at: offset, count: headCount(at: offset, fileSize: fileSize)),
              let anchor = lineAnchor(head) else { return nil }
        return "\(generation):\(offset):\(anchor)"
    }

    /// The line start `cursor` names in the file as it is now, or nil.
    ///
    /// Nil when the cursor is malformed (not three `:`-separated parts, an
    /// offset that is not a decimal `UInt64`, an anchor that is not 16
    /// lowercase hex characters), when its generation is not `generation`,
    /// or when its offset is at or past the end of the file. Otherwise it is
    /// the cursor's offset when the line starting there has the cursor's
    /// anchor. Failing that, the lines after it are scanned in order, over at
    /// most `anchorScanLimit` bytes from the offset, and the first one with
    /// the anchor is the answer: after a remote prepend, the line the cursor
    /// named sits further on by exactly the bytes prepended. No line, nil.
    /// It reads at most `anchorScanLimit` plus `anchorLineBytes` bytes.
    static func resolveCursor(_ cursor: String, generation: Int, filePath: String) -> UInt64? {
        guard let parsed = ParsedCursor(cursor), parsed.generation == String(generation),
              let handle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), parsed.offset < fileSize else { return nil }

        if isLineStart(handle, parsed.offset),
           let head = readBytes(handle, at: parsed.offset, count: headCount(at: parsed.offset, fileSize: fileSize)),
           lineAnchor(head) == parsed.anchor {
            return parsed.offset
        }

        // The region covers every line that starts within the scan limit,
        // with each one's head.
        let scanLimit = PhoneAppConstants.anchorScanLimit
        let regionCount = Int(min(UInt64(scanLimit + anchorLineBytes), fileSize - parsed.offset))
        guard let region = readBytes(handle, at: parsed.offset, count: regionCount),
              let firstNewline = region.firstIndex(of: newline) else { return nil }
        let base = region.startIndex
        var lineStart = firstNewline + 1
        while lineStart < region.endIndex, lineStart - base < scanLimit {
            let headEnd = min(region.endIndex, lineStart + anchorLineBytes)
            if lineAnchor(region[lineStart..<headEnd]) == parsed.anchor {
                return parsed.offset + UInt64(lineStart - base)
            }
            guard let lineEnd = region[lineStart...].firstIndex(of: newline) else { return nil }
            lineStart = lineEnd + 1
        }
        return nil
    }

    // MARK: - Subagent counts

    /// The transcript of subagent `agentID` beside the session transcript at
    /// `transcriptPath`: `<directory>/<sessionID>/subagents/agent-<agentID>.jsonl`.
    /// Nil when `agentID` is not 1 to 128 ASCII letters, digits, `-` or `_`,
    /// so it cannot name another path.
    static func subagentFilePath(transcriptPath: String, agentID: String) -> String? {
        guard !agentID.isEmpty, agentID.utf8.count <= 128, agentID.utf8.allSatisfy(isAgentIDByte) else { return nil }
        let transcript = URL(fileURLWithPath: transcriptPath)
        let sessionID = transcript.deletingPathExtension().lastPathComponent
        guard !sessionID.isEmpty else { return nil }
        return transcript.deletingLastPathComponent()
            .appendingPathComponent(sessionID)
            .appendingPathComponent("subagents")
            .appendingPathComponent("agent-\(agentID).jsonl")
            .path
    }

    /// How many items of subagent `agentID`'s transcript the phone would show
    /// with `showDetails`, for `ShapingContext.subagentItemCount`. Nil when
    /// the file is missing, unreadable, or larger than `subagentCountLimit`
    /// bytes, so one count never reads more than that.
    static func subagentItemCount(transcriptPath: String, agentID: String, showDetails: Bool) -> Int? {
        guard let path = subagentFilePath(transcriptPath: transcriptPath, agentID: agentID),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        let size = try? handle.seekToEnd()
        try? handle.close()
        guard let size, size <= UInt64(PhoneAppConstants.subagentCountLimit),
              let window = TranscriptParser.parseWindow(
                filePath: path, endingBefore: nil, messageLimit: .max, itemLimit: .max,
                includeSidechain: true, scanLimit: PhoneAppConstants.subagentCountLimit) else { return nil }
        return window.entries.filter { TranscriptShaper.isShown($0.item, showDetails: showDetails) }.count
    }

    // MARK: - Building a page

    /// One shaped item, with the line it came from and its encoded size.
    private struct Row {
        let source: TranscriptItem
        let item: PhoneItem
        let lineOffset: UInt64
        let size: Int
    }

    /// `window` shaped and fitted to `budget` bytes of encoded page JSON.
    ///
    /// 1. Each item is shaped with `ctx` plus the window's file-edit stats and
    ///    subagent IDs, encoded once, and its size noted.
    /// 2. A page's size is the empty page's encoded size, plus the item
    ///    sizes, plus one comma between each pair of items. The empty page is
    ///    measured with the longest cursor this generation can have and the
    ///    largest `omittedItems` possible, so the real page is never larger.
    /// 3. While the page is over budget and more than one source line
    ///    remains, the oldest line's items go. The next older page holds them.
    /// 4. If one line remains and is still over budget, its oldest items go,
    ///    and `omittedItems` counts them.
    /// 5. `cursor` names the first kept line, or the window's start when no
    ///    line went, and is nil when that offset is 0, which is also when
    ///    `reachedStart` is true. It is nil too, with `reachedStart` false,
    ///    when the file changed under the read so that no cursor can be made;
    ///    the feed resets on that change.
    ///
    /// A subagent row is measured with the largest count it can carry, and
    /// `ctx.subagentItemCount` runs only for the subagent rows the page keeps,
    /// once fitting is done, so a page reads no subagent file for a row it
    /// drops.
    private static func build(
        _ window: TranscriptWindow, filePath: String, generation: Int, ctx: ShapingContext, budget: Int
    ) -> PageBuild {
        let shaping = ShapingContext(
            showDetails: ctx.showDetails,
            fileEdits: ctx.fileEdits.merging(window.fileEdits) { _, fromWindow in fromWindow },
            subagentAgentIDs: ctx.subagentAgentIDs.merging(window.subagentAgentIDs) { _, fromWindow in fromWindow },
            joinedResults: ctx.joinedResults,
            subagentItemCount: ctx.subagentItemCount)
        let measuring = ShapingContext(
            showDetails: shaping.showDetails,
            fileEdits: shaping.fileEdits,
            subagentAgentIDs: shaping.subagentAgentIDs,
            joinedResults: shaping.joinedResults,
            subagentItemCount: { _ in PhoneAppConstants.subagentCountLimit })
        let encoder = PhoneAppCoding.makeEncoder()

        // Rows grouped by source line, oldest first.
        var lines: [[Row]] = []
        for entry in window.entries {
            guard let item = TranscriptShaper.shape(entry.item, measuring) else { continue }
            // A row that cannot be encoded is larger than any budget, so
            // fitting drops it.
            let size = (try? encoder.encode(item))?.count ?? budget + 1
            let row = Row(source: entry.item, item: item, lineOffset: entry.lineOffset, size: size)
            if let last = lines.last?.last, last.lineOffset == entry.lineOffset {
                lines[lines.count - 1].append(row)
            } else {
                lines.append([row])
            }
        }

        var count = lines.reduce(0) { $0 + $1.count }
        let longestCursor = "\(generation):\(UInt64.max):\(String(repeating: "f", count: anchorHexLength))"
        let emptyPage = TranscriptPage(items: [], cursor: longestCursor, reachedStart: false, omittedItems: count)
        let emptySize = (try? encoder.encode(emptyPage))?.count ?? budget
        var itemBytes = lines.reduce(0) { total, line in total + line.reduce(0) { $0 + $1.size } }
        func pageSize() -> Int { emptySize + itemBytes + max(0, count - 1) }

        var firstLine = 0
        while pageSize() > budget, lines.count - firstLine > 1 {
            itemBytes -= lines[firstLine].reduce(0) { $0 + $1.size }
            count -= lines[firstLine].count
            firstLine += 1
        }
        var kept = lines[firstLine...].flatMap { $0 }
        var omitted = 0
        while pageSize() > budget, omitted < kept.count {
            itemBytes -= kept[omitted].size
            count -= 1
            omitted += 1
        }
        kept.removeFirst(omitted)

        let items = kept.map { row -> PhoneItem in
            guard row.item.kind == .subagent, row.item.itemCount != nil else { return row.item }
            return TranscriptShaper.shape(row.source, shaping) ?? row.item
        }
        let startOffset = firstLine > 0 ? lines[firstLine][0].lineOffset : window.startOffset
        let cursor = startOffset == 0 ? nil : makeCursor(generation: generation, offset: startOffset, filePath: filePath)

        var lineOffsets: [String: UInt64] = [:]
        var unresolvedCalls: [String: PhoneItem] = [:]
        for (row, item) in zip(kept, items) {
            lineOffsets[item.id] = row.lineOffset
            if item.toolStatus == TranscriptShaper.runningStatus {
                unresolvedCalls[item.id] = item
            }
        }
        return PageBuild(
            page: TranscriptPage(items: items, cursor: cursor, reachedStart: startOffset == 0, omittedItems: omitted),
            startOffset: startOffset,
            endOffset: window.endOffset,
            lineOffsets: lineOffsets,
            unresolvedCalls: unresolvedCalls,
            results: window.toolResultsByID)
    }

    // MARK: - Reading

    private static let newline = UInt8(ascii: "\n")

    /// A cursor, split and checked for shape alone.
    private struct ParsedCursor {
        let generation: String
        let offset: UInt64
        let anchor: String

        init?(_ cursor: String) {
            guard cursor.utf8.count <= TranscriptPager.cursorMaxBytes else { return nil }
            let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let digits = parts[1]
            guard !digits.isEmpty,
                  digits.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
                  let offset = UInt64(digits) else { return nil }
            let anchor = parts[2]
            guard anchor.utf8.count == TranscriptPager.anchorHexLength,
                  anchor.utf8.allSatisfy(TranscriptPager.isLowercaseHexByte) else { return nil }
            self.generation = String(parts[0])
            self.offset = offset
            self.anchor = String(anchor)
        }
    }

    /// The anchor of the line `head` begins with. `head` holds the line's
    /// first bytes: `anchorLineBytes` of them, or fewer only where the file
    /// ends. Nil for a last line with no `"\n"` yet, which Claude Code is
    /// still writing.
    private static func lineAnchor(_ head: Data) -> String? {
        let line: Data
        if let end = head.firstIndex(of: newline) {
            line = head[head.startIndex..<end]
        } else if head.count >= anchorLineBytes {
            line = head.prefix(anchorLineBytes)
        } else {
            return nil
        }
        return SHA256.hash(data: line).prefix(anchorHexLength / 2).map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes a line's head takes at `offset`: `anchorLineBytes`, or what
    /// is left of the file.
    private static func headCount(at offset: UInt64, fileSize: UInt64) -> Int {
        Int(min(UInt64(anchorLineBytes), fileSize - offset))
    }

    /// Whether `offset` starts a line: it is 0, or the byte before it is
    /// `"\n"`.
    private static func isLineStart(_ handle: FileHandle, _ offset: UInt64) -> Bool {
        guard offset > 0 else { return true }
        return readBytes(handle, at: offset - 1, count: 1)?.first == newline
    }

    /// Exactly `count` bytes from `offset`, or nil when they cannot all be
    /// read.
    private static func readBytes(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count),
              data.count == count else { return nil }
        return data
    }

    private static func isLowercaseHexByte(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
    }

    private static func isAgentIDByte(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
    }
}
