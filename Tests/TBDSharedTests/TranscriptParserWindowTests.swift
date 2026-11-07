import Foundation
import Testing

@testable import TBDShared

/// `TranscriptParser.parseWindow`, the line stats and subagent IDs it
/// collects, and `lookupDetail(startingAt:)`. Tier 1 apart from the fixture
/// files, which each test writes to a temp directory of its own.
@Suite("TranscriptParser.parseWindow")
struct TranscriptParserWindowTests {
    // MARK: - windows

    @Test func theFirstWindowGoesBackToTheFourthLastMessage() throws {
        let fixture = try WindowFixture(WindowLine.conversation(messages: 10))
        defer { fixture.remove() }

        let w = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 4, itemLimit: 256))
        let messageCount = w.entries.filter(\.item.isMessage).count
        let m7 = try #require(fixture.offset(ofUUID: "m7"))

        #expect(messageCount == 4)
        #expect(w.entries.first?.item.id == "m7")
        #expect(w.entries.last?.item.id == "toolu_10")
        #expect(w.startOffset == m7)
        #expect(w.endOffset == fixture.size)
        #expect(!w.reachedStart)
    }

    @Test func anOlderWindowEndsBeforeTheCursor() throws {
        let fixture = try WindowFixture(WindowLine.conversation(messages: 30))
        defer { fixture.remove() }

        let first = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 4, itemLimit: 256))
        let older = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: first.startOffset, messageLimit: 20, itemLimit: 1024))
        let olderMessageIDs = older.entries.filter(\.item.isMessage).map(\.item.id)
        let expectedIDs = (7...26).map { "m\($0)" }
        let lastOffset = try #require(older.entries.last?.lineOffset)
        let m7 = try #require(fixture.offset(ofUUID: "m7"))

        #expect(olderMessageIDs == expectedIDs)
        #expect(older.endOffset == first.startOffset)
        #expect(lastOffset < first.startOffset)
        #expect(older.startOffset == m7)

        // The call just before the cursor keeps its result, whose line also
        // sits before the cursor.
        let lastItem = try #require(older.entries.last?.item)
        guard case .toolCall(let id, _, _, _, let result, _, _, _) = lastItem else {
            Issue.record("expected the older window to end on a tool call, got \(lastItem)")
            return
        }
        #expect(id == "toolu_26")
        #expect(result?.text == "output 26")
    }

    @Test func aCursorInsideALineIsRejected() throws {
        let fixture = try WindowFixture(WindowLine.conversation(messages: 10))
        defer { fixture.remove() }

        let first = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 4, itemLimit: 256))
        let insideALine = TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: first.startOffset + 1, messageLimit: 4, itemLimit: 256)
        let rejected = insideALine == nil
        let atALineStart = TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: first.startOffset, messageLimit: 4, itemLimit: 256)
        let accepted = atALineStart != nil

        #expect(rejected, "a cursor one byte into a line must be refused")
        #expect(accepted, "the line start before it must be accepted")
    }

    @Test func aCursorPastTheFileEndIsStale() throws {
        // A cursor taken before the file was rewritten or truncated can name
        // bytes the file no longer holds. It must not read as "the end".
        let fixture = try WindowFixture(WindowLine.conversation(messages: 3))
        defer { fixture.remove() }

        let pastTheEnd = TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: fixture.size + 1, messageLimit: 4, itemLimit: 256)
        let stale = pastTheEnd == nil
        let atTheEnd = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: fixture.size, messageLimit: 4, itemLimit: 256))

        #expect(stale, "a cursor one byte past the file's end must be refused")
        #expect(atTheEnd.endOffset == fixture.size, "a cursor at the file's end is still the end")
    }

    @Test func theWindowStopsAtTheItemLimit() throws {
        var objects = [WindowLine.prompt("m1", "placeholder prompt")]
        for n in 1...600 {
            objects.append(WindowLine.toolUse("a\(n)", id: "toolu_\(n)", name: "Bash", input: ["command": "echo \(n)"]))
            objects.append(WindowLine.toolResult("r\(n)", toolUseID: "toolu_\(n)", text: "output \(n)"))
        }
        let fixture = try WindowFixture(objects)
        defer { fixture.remove() }

        let w = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 4, itemLimit: 256))
        let a345 = try #require(fixture.offset(ofUUID: "a345"))

        #expect(w.entries.count <= 256)
        #expect(w.entries.count == 256)
        #expect(w.entries.last?.item.id == "toolu_600", "the newest line is always kept")
        #expect(w.entries.first?.item.id == "toolu_345")
        // The window starts at the first kept call, so the result of the
        // last call it dropped stays with the older window that holds it.
        #expect(w.startOffset == a345)
    }

    @Test func aWindowGrowsPastAHugeLine() throws {
        let huge = String(repeating: "x", count: 3_000_000)
        let fixture = try WindowFixture([
            WindowLine.prompt("m1", "placeholder prompt 1"),
            WindowLine.prompt("m2", "placeholder prompt 2"),
            WindowLine.assistantText("big", huge),
            WindowLine.prompt("m3", "placeholder prompt 3"),
        ])
        defer { fixture.remove() }

        let w = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 2, itemLimit: 256))
        let ids = w.entries.map(\.item.id)
        let bigItem = try #require(w.entries.first?.item)
        guard case .assistantText(_, let text, _, _) = bigItem else {
            Issue.record("expected the huge assistant line first, got \(bigItem)")
            return
        }

        #expect(ids == ["big#0", "m3"])
        #expect(text.count == 3_000_000)
    }

    @Test func aTrailingPartialLineIsLeftForTheLiveCursor() throws {
        // The last line, `m4`, has no newline yet: Claude Code is still
        // writing it.
        var objects = WindowLine.conversation(messages: 3)
        objects.append(WindowLine.prompt("m4", "placeholder prompt 4"))
        let fixture = try WindowFixture(objects, trailingNewline: false)
        defer { fixture.remove() }
        let partialLine = try #require(fixture.offset(ofUUID: "m4"))

        let w = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 10, itemLimit: 256))
        let atTheFileSize = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: fixture.size, messageLimit: 10, itemLimit: 256))
        let ids = w.entries.map(\.item.id)

        #expect(ids == ["m1", "toolu_1", "m2", "toolu_2", "m3", "toolu_3"])
        #expect(w.toolResultsByID["toolu_3"]?.text == "output 3")
        #expect(w.endOffset == partialLine, "the window ends just after the last newline")
        #expect(atTheFileSize.endOffset == partialLine, "an end at the file's size is capped the same way")
        #expect(w.reachedStart)
    }

    @Test func aSparseTailStopsAtTheScanLimit() throws {
        // Two messages with five ~1 MiB tool results between them: about
        // 5 MB, more than the 4 MiB limit and less than the default 8 MiB.
        let scanLimit = 4 * 1024 * 1024
        let bigResult = String(repeating: "z", count: 1 << 20)
        var objects = [WindowLine.prompt("m1", "placeholder prompt 1")]
        for n in 1...5 {
            objects.append(WindowLine.toolUse("a\(n)", id: "toolu_\(n)", name: "Bash", input: ["command": "echo \(n)"]))
            objects.append(WindowLine.toolResult("r\(n)", toolUseID: "toolu_\(n)", text: bigResult))
        }
        objects.append(WindowLine.prompt("m2", "placeholder prompt 2"))
        let fixture = try WindowFixture(objects)
        defer { fixture.remove() }

        let w = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 4, itemLimit: 256, scanLimit: scanLimit))
        let unbounded = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 4, itemLimit: 256))
        let ids = w.entries.map(\.item.id)

        #expect(w.endOffset == fixture.size)
        #expect(w.endOffset - w.startOffset <= UInt64(scanLimit), "the read stops at the limit")
        #expect(w.endOffset - w.startOffset > UInt64(scanLimit / 2), "the read grows to the limit")
        #expect(!w.reachedStart)
        #expect(ids.last == "m2", "the newest line is kept")
        #expect(!ids.contains("m1"))
        #expect(unbounded.reachedStart, "the default limit reads this file back to its start")
    }

    @Test func aLineLongerThanTheScanLimitIsReadWhole() throws {
        let huge = String(repeating: "x", count: 2_000_000)
        let fixture = try WindowFixture([
            WindowLine.prompt("m1", "placeholder prompt 1"),
            WindowLine.assistantText("filler", String(repeating: "f", count: 3_000_000)),
            WindowLine.prompt("m2", "placeholder prompt 2"),
            WindowLine.assistantText("big", huge),
        ])
        defer { fixture.remove() }
        let big = try #require(fixture.offset(ofUUID: "big"))

        let w = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 4, itemLimit: 256, scanLimit: 64 * 1024))
        let ids = w.entries.map(\.item.id)
        let bigItem = try #require(w.entries.last?.item)
        guard case .assistantText(_, let text, _, _) = bigItem else {
            Issue.record("expected the huge assistant line last, got \(bigItem)")
            return
        }

        #expect(ids.last == "big#0")
        #expect(text.count == 2_000_000)
        #expect(w.startOffset <= big)
        #expect(!w.reachedStart)
        #expect(!ids.contains("m1"))
    }

    @Test func lineIDsAreStableAcrossWindows() throws {
        // Large enough that neither window's read starts at byte 0, so an
        // offset counted from the read's start would differ between them.
        let padding = String(repeating: "x", count: 4000)
        var objects = (1...40).map { WindowLine.prompt("m\($0)", "placeholder prompt \($0) \(padding)") }
        objects[36] = WindowLine.prompt(nil, "placeholder prompt 37 \(padding)")
        let fixture = try WindowFixture(objects)
        defer { fixture.remove() }
        let expectedID = "at-\(fixture.offsets[36])"

        let newest = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 4, itemLimit: 256))
        let older = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: fixture.offsets[38], messageLimit: 3, itemLimit: 256))
        let newestIDs = newest.entries.map(\.item.id)
        let olderIDs = older.entries.map(\.item.id)

        #expect(newestIDs == [expectedID, "m38", "m39", "m40"])
        #expect(olderIDs == ["m36", expectedID, "m38"])
        #expect(TranscriptParser.isPositionalFallbackID(expectedID))
        #expect(older.entries.dropFirst().first?.lineOffset == fixture.offsets[36])
    }

    @Test func sidechainLinesAreIncludedOnlyWhenAsked() throws {
        var sidechain = WindowLine.assistantText("side", "placeholder subagent text")
        sidechain["isSidechain"] = true
        let fixture = try WindowFixture([
            WindowLine.prompt("m1", "placeholder prompt 1"),
            sidechain,
            WindowLine.prompt("m2", "placeholder prompt 2"),
        ])
        defer { fixture.remove() }

        let without = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 10, itemLimit: 256))
        let with = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 10, itemLimit: 256, includeSidechain: true))
        let withoutIDs = without.entries.map(\.item.id)
        let withIDs = with.entries.map(\.item.id)

        #expect(withoutIDs == ["m1", "m2"])
        #expect(withIDs == ["m1", "side#0", "m2"])
    }

    // MARK: - edit stats

    @Test func editStatsComeFromTheUntruncatedInput() throws {
        let newString = (1...5000).map { "new line \($0)" }.joined(separator: "\n")
        let edit = WindowLine.toolUse("a1", id: "toolu_edit", name: "Edit", input: [
            "file_path": "/acme/widget.swift", "old_string": "old line", "new_string": newString,
        ])
        let fixture = try WindowFixture([WindowLine.prompt("m1", "placeholder prompt"), edit])
        defer { fixture.remove() }

        let w = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 4, itemLimit: 256))
        let stats = try #require(w.fileEdits["toolu_edit"])
        let callItem = try #require(w.entries.last?.item)
        guard case .toolCall(_, _, _, let inputTruncatedTo, _, _, _, _) = callItem else {
            Issue.record("expected the Edit call last, got \(callItem)")
            return
        }

        #expect(inputTruncatedTo != nil, "the item's input is truncated, so it cannot be the source")
        #expect(stats.added == 5000)
        #expect(stats.removed == 1)
    }

    @Test func multiEditSumsItsEdits() throws {
        let edits: [[String: Any]] = [
            ["old_string": "alpha\nbeta", "new_string": "alpha\ngamma\ndelta"],
            ["old_string": "epsilon\n", "new_string": ""],
        ]
        let line = try WindowLine.decoded(WindowLine.toolUse("a1", id: "toolu_multi", name: "MultiEdit", input: [
            "file_path": "/acme/widget.swift", "edits": edits,
        ]))

        let stats = TranscriptParser.fileEditStats(fromLine: line)

        // beta → gamma, delta: 2 added, 1 removed; epsilon removed: 1 removed.
        #expect(stats == ["toolu_multi": FileEditStats(added: 2, removed: 2)])
    }

    @Test func writeCountsOnlyAddedLines() throws {
        let line = try WindowLine.decoded(WindowLine.toolUse("a1", id: "toolu_write", name: "Write", input: [
            "file_path": "/acme/widget.swift", "content": "one\ntwo\nthree\n",
        ]))

        let stats = TranscriptParser.fileEditStats(fromLine: line)

        #expect(stats == ["toolu_write": FileEditStats(added: 3, removed: 0)])
    }

    // MARK: - subagent IDs

    @Test func subagentResultsMapToTheirAgentID() throws {
        var agentResult = WindowLine.toolResult("r1", toolUseID: "toolu_agent", text: "placeholder summary")
        let toolUseResult: [String: Any] = ["agentId": "a0123456789abcdef", "status": "completed"]
        agentResult["toolUseResult"] = toolUseResult
        var emptyAgent = WindowLine.toolResult("r2", toolUseID: "toolu_empty", text: "placeholder summary")
        let emptyResult: [String: Any] = ["agentId": ""]
        emptyAgent["toolUseResult"] = emptyResult
        let fixture = try WindowFixture([
            WindowLine.prompt("m1", "placeholder prompt"),
            WindowLine.toolUse("a1", id: "toolu_agent", name: "Agent", input: ["description": "placeholder"]),
            agentResult,
            WindowLine.toolUse("a2", id: "toolu_empty", name: "Agent", input: ["description": "placeholder"]),
            emptyAgent,
        ])
        defer { fixture.remove() }

        let w = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 4, itemLimit: 256))

        #expect(w.subagentAgentIDs == ["toolu_agent": "a0123456789abcdef"])
    }

    // MARK: - detail lookup

    @Test func lookupFromAnOffsetFindsTheSameDetail() throws {
        // A result bigger than one read chunk, so both scans carry a line
        // across chunk boundaries before they reach `toolu_3`.
        let bigResult = String(repeating: "y", count: 2 * TranscriptParser.detailChunkBytes + 17)
        var objects = WindowLine.conversation(messages: 5)
        objects[5] = WindowLine.toolResult("r2", toolUseID: "toolu_2", text: bigResult)
        let fixture = try WindowFixture(objects)
        defer { fixture.remove() }
        let p = fixture.path

        let w = try #require(TranscriptParser.parseWindow(
            filePath: p, endingBefore: nil, messageLimit: 5, itemLimit: 256))
        let call = w.entries.first(where: { entry in entry.item.id == "toolu_3" })
        let off = try #require(call?.lineOffset)
        let a3 = try #require(fixture.offset(ofUUID: "a3"))
        let m4 = try #require(fixture.offset(ofUUID: "m4"))
        let fromOffset = TranscriptParser.lookupDetail(filePath: p, itemID: "toolu_3#input", startingAt: off).text
        let pastTheCall = TranscriptParser.lookupDetail(filePath: p, itemID: "toolu_3#input", startingAt: m4).text
        let bigLookup = TranscriptParser.lookupDetail(filePath: p, itemID: "toolu_2").text
        let bigResultIsWhole = bigLookup == bigResult

        #expect(off == a3)
        #expect(fromOffset != nil)
        #expect(TranscriptParser.lookupDetail(filePath: p, itemID: "toolu_3#input", startingAt: off).text
                == TranscriptParser.lookupDetail(filePath: p, itemID: "toolu_3#input").text)
        #expect(bigResultIsWhole, "the whole-file scan returns a result that spans read chunks")
        #expect(pastTheCall == nil, "a scan that starts after the call cannot find it")
    }

    @Test func aPositionalIDResolvesItsLineInFull() throws {
        // Two long lines with no `uuid`: a reply, whose item ID carries a
        // block suffix, and a prompt, whose item ID is the bare line ID.
        let longReply = String(repeating: "w", count: 20_000)
        let longPrompt = String(repeating: "p", count: 20_000)
        var reply = WindowLine.assistantText("unused", longReply)
        reply.removeValue(forKey: "uuid")
        let fixture = try WindowFixture([
            WindowLine.prompt("m1", "placeholder prompt 1"),
            reply,
            WindowLine.prompt(nil, longPrompt),
            WindowLine.prompt("m2", "placeholder prompt 2"),
        ])
        defer { fixture.remove() }

        let w = try #require(TranscriptParser.parseWindow(
            filePath: fixture.path, endingBefore: nil, messageLimit: 10, itemLimit: 256))
        let replyEntry = try #require(w.entries.first(where: { entry in entry.lineOffset == fixture.offsets[1] }))
        let promptEntry = try #require(w.entries.first(where: { entry in entry.lineOffset == fixture.offsets[2] }))

        #expect(replyEntry.item.id == "at-\(fixture.offsets[1])#0")
        #expect(promptEntry.item.id == "at-\(fixture.offsets[2])")
        for (entry, text) in [(replyEntry, longReply), (promptEntry, longPrompt)] {
            let id = entry.item.id
            let whole = TranscriptParser.lookupDetail(filePath: fixture.path, itemID: id).text
            let fromItsLine = TranscriptParser.lookupDetail(
                filePath: fixture.path, itemID: id, startingAt: entry.lineOffset).text
            let fromTheEnd = TranscriptParser.lookupDetail(
                filePath: fixture.path, itemID: id, startingAt: fixture.size).text
            let wholeIsFull = whole == text
            let fromItsLineIsFull = fromItsLine == text
            let fromTheEndIsFull = fromTheEnd == text

            #expect(wholeIsFull, "the whole-file lookup resolves \(id) to its full text")
            #expect(fromItsLineIsFull, "the lookup from the line's offset resolves \(id) to its full text")
            #expect(fromTheEndIsFull, "a positional ID resolves whatever offset the lookup starts at")
        }
    }

    /// A positional lookup reads less at a time than the forward scan, so a
    /// line more than twice that size is carried across reads before its
    /// newline. It still resolves whole.
    @Test func aPositionalIDResolvesALineLongerThanOneReadInFull() throws {
        let longReply = String(repeating: "v", count: 2 * TranscriptParser.positionalDetailChunkBytes + 17)
        var reply = WindowLine.assistantText("unused", longReply)
        reply.removeValue(forKey: "uuid")
        let fixture = try WindowFixture([
            WindowLine.prompt("m1", "placeholder prompt 1"),
            reply,
            WindowLine.prompt("m2", "placeholder prompt 2"),
        ])
        defer { fixture.remove() }
        let id = "at-\(fixture.offsets[1])#0"

        let resolved = TranscriptParser.lookupDetail(filePath: fixture.path, itemID: id).text
        let isWhole = resolved == longReply
        let readsLess = TranscriptParser.positionalDetailChunkBytes < TranscriptParser.detailChunkBytes

        #expect(readsLess, "a positional lookup reads a smaller first chunk than the forward scan")
        #expect(isWhole, "a line longer than one positional read resolves to its full text")
    }

    @Test func aPositionalIDNamingALineWithAUUIDResolvesNothing() throws {
        let fixture = try WindowFixture([
            WindowLine.prompt("m1", "placeholder prompt 1"),
            WindowLine.assistantText("a1", "placeholder reply"),
            WindowLine.prompt(nil, "placeholder prompt 2"),
        ])
        defer { fixture.remove() }

        let onAPrompt = TranscriptParser.lookupDetail(filePath: fixture.path, itemID: "at-\(fixture.offsets[0])")
        let onAReply = TranscriptParser.lookupDetail(
            filePath: fixture.path, itemID: "at-\(fixture.offsets[1])#0", startingAt: fixture.offsets[1])
        let onTheUUIDLessLine = TranscriptParser.lookupDetail(
            filePath: fixture.path, itemID: "at-\(fixture.offsets[2])")

        #expect(onAPrompt.text == nil, "a stale ID never resolves a line that has a uuid")
        #expect(onAPrompt.attachment == nil)
        #expect(onAReply.text == nil, "a stale ID never resolves a line that has a uuid")
        #expect(onTheUUIDLessLine.text == "placeholder prompt 2", "the same file resolves its uuid-less line")
    }

    @Test func aPositionalIDOnAnEmptyLineResolvesNothing() throws {
        // A line, an empty line, then a line with no `uuid`. An ID naming the
        // empty line must not resolve the line after it.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-window-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try JSONSerialization.data(withJSONObject: WindowLine.prompt("m1", "placeholder prompt 1"))
        let second = try JSONSerialization.data(withJSONObject: WindowLine.prompt(nil, "placeholder prompt 2"))
        var bytes = first
        bytes.append(contentsOf: [UInt8(ascii: "\n"), UInt8(ascii: "\n")])
        bytes.append(second)
        bytes.append(UInt8(ascii: "\n"))
        let path = directory.appendingPathComponent("session.jsonl").path
        try bytes.write(to: URL(fileURLWithPath: path))
        let emptyLine = UInt64(first.count + 1)

        let onTheEmptyLine = TranscriptParser.lookupDetail(filePath: path, itemID: "at-\(emptyLine)").text
        let onTheNextLine = TranscriptParser.lookupDetail(filePath: path, itemID: "at-\(emptyLine + 1)").text

        #expect(onTheEmptyLine == nil, "an ID naming an empty line resolves nothing")
        #expect(onTheNextLine == "placeholder prompt 2")
    }
}

// MARK: - fixtures

private extension TranscriptItem {
    /// What `parseWindow` counts toward `messageLimit`.
    var isMessage: Bool {
        switch self {
        case .userPrompt, .assistantText, .peerMessage: return true
        default: return false
        }
    }
}

/// JSONL lines in the shape Claude Code writes and `TranscriptParser` reads.
private enum WindowLine {
    static let timestamp = "2026-05-05T10:00:00.000Z"

    static func prompt(_ uuid: String?, _ text: String) -> [String: Any] {
        let message: [String: Any] = ["role": "user", "content": text]
        var line: [String: Any] = ["type": "user", "timestamp": timestamp, "message": message]
        if let uuid { line["uuid"] = uuid }
        return line
    }

    static func assistantText(_ uuid: String, _ text: String) -> [String: Any] {
        let block: [String: Any] = ["type": "text", "text": text]
        return assistant(uuid, blocks: [block])
    }

    static func toolUse(_ uuid: String, id: String, name: String, input: [String: Any]) -> [String: Any] {
        let block: [String: Any] = ["type": "tool_use", "id": id, "name": name, "input": input]
        return assistant(uuid, blocks: [block])
    }

    static func toolResult(_ uuid: String, toolUseID: String, text: String) -> [String: Any] {
        let block: [String: Any] = ["type": "tool_result", "tool_use_id": toolUseID, "content": text]
        let message: [String: Any] = ["role": "user", "content": [block]]
        return ["type": "user", "uuid": uuid, "timestamp": timestamp, "message": message]
    }

    /// Prompts `m1`…`m<messages>`, each followed by a tool row: a Bash call
    /// `toolu_<n>` on line `a<n>` and its result `output <n>` on line `r<n>`.
    static func conversation(messages: Int) -> [[String: Any]] {
        var lines: [[String: Any]] = []
        for n in 1...messages {
            lines.append(prompt("m\(n)", "placeholder prompt \(n)"))
            lines.append(toolUse("a\(n)", id: "toolu_\(n)", name: "Bash", input: ["command": "echo \(n)"]))
            lines.append(toolResult("r\(n)", toolUseID: "toolu_\(n)", text: "output \(n)"))
        }
        return lines
    }

    /// `object` as the parser sees it once the line is read back from disk.
    static func decoded(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONSerialization.jsonObject(with: data)
        return try #require(decoded as? [String: Any])
    }

    private static func assistant(_ uuid: String, blocks: [[String: Any]]) -> [String: Any] {
        let message: [String: Any] = ["role": "assistant", "content": blocks]
        return ["type": "assistant", "uuid": uuid, "timestamp": timestamp, "message": message]
    }
}

/// A transcript file in a temp directory of its own, with each line's offset.
private struct WindowFixture {
    let directory: URL
    let path: String
    /// Each line's `uuid`, nil for a line without one.
    let uuids: [String?]
    /// The offset of each line's first byte.
    let offsets: [UInt64]
    let size: UInt64

    init(_ objects: [[String: Any]], trailingNewline: Bool = true) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-window-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = Data()
        var offsets: [UInt64] = []
        for (index, object) in objects.enumerated() {
            offsets.append(UInt64(bytes.count))
            let encoded = try JSONSerialization.data(withJSONObject: object)
            bytes.append(encoded)
            if trailingNewline || index < objects.count - 1 { bytes.append(UInt8(ascii: "\n")) }
        }
        let path = directory.appendingPathComponent("session.jsonl").path
        try bytes.write(to: URL(fileURLWithPath: path))

        self.directory = directory
        self.path = path
        self.uuids = objects.map { $0["uuid"] as? String }
        self.offsets = offsets
        self.size = UInt64(bytes.count)
    }

    func offset(ofUUID uuid: String) -> UInt64? {
        uuids.firstIndex(of: uuid).map { offsets[$0] }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
