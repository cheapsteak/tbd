import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// `transcript.detail`: the chunker, the feed's detail cache, and the request
/// through the service. The chunker tests are tier 1. The rest are tier 2:
/// each writes its transcripts into a scratch directory of its own and reads
/// them back, over the harness's in-memory database and fake session actions.
/// No test starts a feed's live part, so nothing watches a file or waits on a
/// clock.
@Suite("Phone transcript detail", .fastPassBounded)
struct TranscriptDetailTests {
    // MARK: - The chunker

    @Test func aSmallResultIsOneChunk() {
        let text = "PASS src/auth/redirect.test.ts"
        let chunks = TranscriptDetailChunker.chunk(text)

        #expect(chunks.ranges.count == 1)
        #expect(chunks.chunkText(0) == text)
        #expect(chunks.totalBytes == text.utf8.count)
        #expect(!chunks.tooLarge)

        let empty = TranscriptDetailChunker.chunk("")
        #expect(empty.ranges.count == 1, "an empty text is one empty chunk")
        #expect(empty.chunkText(0) == "")
        #expect(empty.totalBytes == 0)
    }

    /// 300 KB of text the encoder escapes in every way: the ranges cover it
    /// in order with no gap, each chunk is within the budget and stops only
    /// where the next scalar would pass it, and the chunks rejoin exactly.
    @Test func chunksRejoinToTheOriginal() {
        let pieces = [
            "plain words ", "\"quoted\" ", "back\\slash ", "tab\tnew\nline ", "\u{1}\u{1f} ", "é ", "漢字 ",
            "😀 ", "a/b ",
        ]
        var text = ""
        var n = 0
        while text.utf8.count < 300_000 {
            text += pieces[n % pieces.count]
            n += 1
        }
        let chunks = TranscriptDetailChunker.chunk(text)
        let scalars = text.unicodeScalars
        let budget = PhoneFrameBudget.detailChunkBytes

        var gaps = 0
        var overBudget = 0
        var cutEarly = 0
        var rejoined: [Unicode.Scalar] = []
        for index in chunks.ranges.indices {
            let range = chunks.ranges[index]
            if index > 0, chunks.ranges[index - 1].upperBound != range.lowerBound {
                gaps += 1
            }
            let length = PhoneFrameBudget.escapedLength(scalars[range])
            if length > budget {
                overBudget += 1
            }
            if index < chunks.ranges.count - 1,
               length + PhoneFrameBudget.escapedLength(scalars[range.upperBound]) <= budget {
                cutEarly += 1
            }
            rejoined.append(contentsOf: chunks.chunkText(index).unicodeScalars)
        }
        let original = Array(scalars)

        #expect(chunks.ranges.count > 1)
        #expect(chunks.ranges.first?.lowerBound == scalars.startIndex)
        #expect(chunks.ranges.last?.upperBound == scalars.endIndex)
        #expect(gaps == 0)
        #expect(overBudget == 0)
        #expect(cutEarly == 0, "a chunk stops only before the scalar that would pass the budget")
        #expect(rejoined == original)
        #expect(chunks.totalBytes == text.utf8.count)
        #expect(!chunks.tooLarge)
    }

    /// One ASCII byte, then 4-byte scalars: the budget falls inside an emoji
    /// at every cut, and the cut goes before it.
    @Test func noChunkSplitsAScalar() {
        let text = "a" + String(repeating: "😀", count: 40_000)
        let chunks = TranscriptDetailChunker.chunk(text)

        var lengths: [Int] = []
        var onlyEmoji: [Bool] = []
        var rejoined: [Unicode.Scalar] = []
        for index in chunks.ranges.indices {
            let chunk = chunks.chunkText(index)
            lengths.append(chunk.utf8.count)
            onlyEmoji.append(chunk.unicodeScalars.allSatisfy { $0 == "😀" })
            rejoined.append(contentsOf: chunk.unicodeScalars)
        }
        let original = Array(text.unicodeScalars)

        // 1 + 4 × 14,999 = 59,997: one more emoji would make 60,001. Then
        // 15,000 emoji exactly, then the 10,001 left.
        #expect(lengths == [59_997, 60_000, 40_004])
        #expect(onlyEmoji == [false, true, true])
        #expect(rejoined == original)
    }

    /// Every chunk of the texts the encoder escapes most, in a reply with the
    /// longest item ID and request ID the service accepts, both in characters
    /// that escape to six bytes, the longest part name, and the most digits
    /// any count can have, fits one frame.
    @Test func worstCaseDetailChunksFitOneFrame() throws {
        let itemID = String(repeating: "\u{1}", count: PhoneAppConstants.detailItemIDMaxBytes)
        let requestID = String(repeating: "\u{1}", count: PhoneAppConstants.requestIDMaxBytes)
        let longestName = TranscriptDetailPart.allCases.map(\.rawValue.count).max() ?? 0
        let longestPart = TranscriptDetailPart.allCases.first { $0.rawValue.count == longestName }
        let part = try #require(longestPart)
        let texts = [
            String(repeating: "\"", count: 204_800),
            String(repeating: "\u{1}", count: 204_800),
            String(repeating: "😀", count: 51_200),
            String(repeating: "a/b", count: 68_267),
        ]

        var replies = 0
        var oversize: [Int] = []
        for text in texts {
            let chunks = TranscriptDetailChunker.chunk(text)
            for index in chunks.ranges.indices {
                let result = TranscriptDetailResult(
                    itemID: itemID, part: part, chunk: Int.max, chunkCount: Int.max, totalBytes: Int.max,
                    tooLarge: false, text: chunks.chunkText(index), items: nil)
                let size = PhoneAppCoding.framedSize(try PhoneAppCoding.reply(requestID: requestID, result: result))
                if size > 65_519 {
                    oversize.append(size)
                }
                replies += 1
            }
        }

        #expect(oversize.isEmpty, "replies over one frame: \(oversize)")
        #expect(replies > 2 * texts.count, "each text must take several chunks")
    }

    /// Runs of the largest row the shaper can make each fit one frame in a
    /// worst-case reply, no row is split or lost, and a row too large for any
    /// run is left out.
    @Test func worstCaseSubagentChunksFitOneFrame() throws {
        let control = "\u{1}"
        let largest = PhoneItem(
            id: String(repeating: control, count: PhoneAppConstants.detailItemIDMaxBytes),
            kind: .systemNote, at: Int64.max,
            text: String(repeating: control, count: PhoneAppConstants.messagePreviewBytes / 6),
            truncated: true,
            toolName: String(repeating: control, count: TranscriptShaper.toolNameLimit / 6),
            target: String(repeating: control, count: TranscriptShaper.targetLimit / 6),
            toolStatus: TranscriptShaper.runningStatus, added: Int.max, removed: Int.max,
            agentType: String(repeating: control, count: TranscriptShaper.targetLimit / 6),
            itemCount: Int.max,
            sender: String(repeating: control, count: TranscriptShaper.senderLimit / 6))
        let requestID = String(repeating: control, count: PhoneAppConstants.requestIDMaxBytes)
        let encoder = PhoneAppCoding.makeEncoder()

        let runs = TranscriptDetailChunker.itemChunks(Array(repeating: largest, count: 40))
        var kept = 0
        var overBudget: [Int] = []
        var oversize: [Int] = []
        for run in runs {
            kept += run.count
            let arrayBytes = try encoder.encode(run).count
            if arrayBytes > PhoneFrameBudget.detailChunkBytes {
                overBudget.append(arrayBytes)
            }
            let result = TranscriptDetailResult(
                itemID: largest.id, part: .subagent, chunk: Int.max, chunkCount: Int.max, totalBytes: Int.max,
                tooLarge: false, text: nil, items: run)
            let size = PhoneAppCoding.framedSize(try PhoneAppCoding.reply(requestID: requestID, result: result))
            if size > 65_519 {
                oversize.append(size)
            }
        }
        #expect(runs.count > 1)
        #expect(kept == 40)
        #expect(overBudget.isEmpty, "runs over the chunk budget: \(overBudget)")
        #expect(oversize.isEmpty, "replies over one frame: \(oversize)")

        let small = Self.item("s1")
        let huge = Self.item(String(repeating: "x", count: 70_000))
        let after = Self.item("s2")
        let withHuge = TranscriptDetailChunker.itemChunks([small, huge, after])
        let keptIDs = withHuge.flatMap { $0.map(\.id) }
        #expect(keptIDs == ["s1", "s2"])
        #expect(TranscriptDetailChunker.itemChunks([]) == [[]], "no items is one empty run")
    }

    // MARK: - The feed's cache

    /// The feed keeps the last few details, for the generation they were read
    /// in, drops the one used longest ago past its limit, and drops them all
    /// when it closes.
    @Test func theFeedKeepsTheLastFewDetailsForItsGenerationUntilItCloses() async throws {
        let fixture = try DetailFixture(DetailLine.conversation(messages: 1))
        defer { fixture.remove() }
        let path = fixture.path
        let terminalID = UUID()
        let feed = TranscriptFeed(
            session: .local(terminalID: terminalID), showDetails: false,
            source: .local(terminalID: terminalID, resolvePath: { path }),
            emit: { _ in }, clock: EventDrivenTestClock())
        _ = try await feed.open()

        let place = try #require(await feed.detailContext(itemID: "toolu_1"))
        #expect(place.filePath == path)
        #expect(place.lineOffset == fixture.offset(ofUUID: "a1"))
        #expect(place.agentID == nil)
        #expect(place.generation == 0)

        #expect(TranscriptFeed.detailCacheLimit == 4)
        await feed.cacheDetail("first", itemID: "m1", part: .text, generation: 0)
        await feed.cacheDetail("second", itemID: "toolu_1", part: .result, generation: 0)
        let first = await feed.cachedDetail(itemID: "m1", part: .text, as: String.self)
        let second = await feed.cachedDetail(itemID: "toolu_1", part: .result, as: String.self)
        let otherPart = await feed.cachedDetail(itemID: "toolu_1", part: .input, as: String.self)
        let otherType = await feed.cachedDetail(itemID: "toolu_1", part: .result, as: Int.self)
        #expect(first == "first", "the feed keeps more than one detail")
        #expect(second == "second")
        #expect(otherPart == nil)
        #expect(otherType == nil)

        // `m1` was used just now, so filling the cache past its limit drops
        // `toolu_1`, the one used longest ago, and keeps `m1`. `otherType`
        // read `toolu_1` last, so read `m1` again to make it the newest.
        _ = await feed.cachedDetail(itemID: "m1", part: .text, as: String.self)
        for index in 2...4 {
            await feed.cacheDetail("fill \(index)", itemID: "m\(index)", part: .text, generation: 0)
        }
        let dropped = await feed.cachedDetail(itemID: "toolu_1", part: .result, as: String.self)
        let kept = await feed.cachedDetail(itemID: "m1", part: .text, as: String.self)
        #expect(dropped == nil, "the detail used longest ago goes first")
        #expect(kept == "first")
        await feed.cacheDetail("second", itemID: "toolu_1", part: .result, generation: 0)

        await feed.cacheDetail("stale", itemID: "m9", part: .text, generation: 1)
        let stale = await feed.cachedDetail(itemID: "m9", part: .text, as: String.self)
        let stillKept = await feed.cachedDetail(itemID: "toolu_1", part: .result, as: String.self)
        #expect(stale == nil, "a detail read in another generation is not kept")
        #expect(stillKept == "second")

        await feed.close()
        let afterClose = await feed.cachedDetail(itemID: "toolu_1", part: .result, as: String.self)
        await feed.cacheDetail("late", itemID: "m1", part: .text, generation: 0)
        let late = await feed.cachedDetail(itemID: "m1", part: .text, as: String.self)
        #expect(afterClose == nil)
        #expect(late == nil)
    }

    // MARK: - Through the service

    @Test func overOneMegabyteServesOnlyTheFirstPart() async throws {
        let limit = PhoneAppConstants.detailLimitBytes
        let firstChunk = String(repeating: "x", count: PhoneFrameBudget.detailChunkBytes)
        let atTheLimit = TranscriptDetailChunker.chunk(String(repeating: "x", count: limit))
        let over = String(repeating: "x", count: limit + 1)
        let chunks = TranscriptDetailChunker.chunk(over)

        #expect(!atTheLimit.tooLarge)
        #expect(atTheLimit.ranges.count == 18)
        #expect(chunks.tooLarge)
        #expect(chunks.ranges.count == 1)
        #expect(chunks.totalBytes == limit + 1)
        #expect(chunks.chunkText(0) == firstChunk)
        #expect(chunks.text.utf8.count == PhoneFrameBudget.detailChunkBytes, "only the first chunk is kept")

        let h = try await PhoneServiceHarness.make()
        let fixture = try DetailFixture([
            DetailLine.prompt("m1", "placeholder prompt 1"),
            DetailLine.bash("a1", id: "toolu_1", command: "cat build.log"),
            DetailLine.toolResult("r1", toolUseID: "toolu_1", text: over),
        ])
        defer { fixture.remove() }
        let s = try await Self.openTranscript(h, path: fixture.path)

        let reply = try await Self.detail(h, s, itemID: "toolu_1", part: .result, chunk: 0)
        let next = try await Self.detail(h, s, itemID: "toolu_1", part: .result, chunk: 1)

        #expect(reply.error == nil)
        #expect(reply.result?.tooLarge == true)
        #expect(reply.result?.chunkCount == 1)
        #expect(reply.result?.totalBytes == limit + 1)
        #expect(reply.result?.text == firstChunk)
        #expect(reply.size <= 65_519)
        #expect(next.error?.code == .badRequest)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// An item on an older page is looked up from the line the feed kept for
    /// it. A decoy result for the same call sits at the top of the file, where
    /// a lookup from the start would find it first.
    @Test func aDetailForAPagedItemUsesItsOffset() async throws {
        let h = try await PhoneServiceHarness.make()
        let fixture = try DetailFixture(
            [DetailLine.toolResult("decoy", toolUseID: "toolu_2", text: "decoy output")]
                + DetailLine.conversation(messages: 10))
        defer { fixture.remove() }
        let s = try await Self.openTranscript(h, path: fixture.path)
        let cursor = try #require(s.opened.page?.cursor)
        let older = try await Self.page(h, s, cursor: cursor)
        let olderIDs = older.items.map(\.id)
        #expect(olderIDs.contains("toolu_2"))

        let result = try await Self.detail(h, s, itemID: "toolu_2", part: .result, chunk: 0)
        let input = try await Self.detail(h, s, itemID: "toolu_2", part: .input, chunk: 0)
        let message = try await Self.detail(h, s, itemID: "m2", part: .text, chunk: 0)
        let fromTheTop = TranscriptParser.lookupDetail(filePath: fixture.path, itemID: "toolu_2").text

        #expect(fromTheTop == "decoy output", "a lookup from the top finds the decoy")
        #expect(result.result?.text == "output 2")
        #expect(result.result?.chunkCount == 1)
        #expect(result.result?.tooLarge == false)
        #expect(input.result?.text == #"{"command":"echo 2"}"#)
        #expect(message.result?.text == "placeholder prompt 2")
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// The lines above a call go away after its offset was kept, so the
    /// offset lies past the call and its result. The lookup misses there and
    /// finds the result from the top.
    @Test func aMissFromTheItemsOffsetLooksAgainFromTheTop() async throws {
        let h = try await PhoneServiceHarness.make()
        let rest = [
            DetailLine.prompt("m1", "placeholder prompt 1"),
            DetailLine.bash("a1", id: "toolu_1", command: "echo 1"),
            DetailLine.toolResult("r1", toolUseID: "toolu_1", text: "output 1"),
        ]
        let fixture = try DetailFixture([DetailLine.prompt("p0", String(repeating: "x", count: 4_096))] + rest)
        defer { fixture.remove() }
        let s = try await Self.openTranscript(h, path: fixture.path)
        let feed = try #require(await h.service.transcriptFeed(for: h.peer.deviceID))
        let kept = try #require(await feed.detailContext(itemID: "toolu_1")?.lineOffset)

        try fixture.rewrite(rest)
        let size = try fixture.size()
        let reply = try await Self.detail(h, s, itemID: "toolu_1", part: .result, chunk: 0)

        #expect(kept >= size, "the kept offset must lie past every line")
        #expect(reply.result?.text == "output 1")
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// With the file larger than the scan limit, a lookup reads forward from
    /// the item's offset, or else the file's last `scanLimit` bytes, and finds
    /// nothing before that window once the offset is gone.
    @Test func aLookupReadsOnlyFromTheOffsetAndTheFilesTail() throws {
        let fixture = try DetailFixture(DetailLine.conversation(messages: 10))
        defer { fixture.remove() }
        let path = fixture.path
        let size = try fixture.size()
        let m10 = try #require(fixture.offset(ofUUID: "m10"))
        let a2 = try #require(fixture.offset(ofUUID: "a2"))
        let m3 = try #require(fixture.offset(ofUUID: "m3"))
        // The tail window holds `m10`, `a10` and `r10`, and a scan from `a2`
        // reads `a2` and `r2` whole before it stops.
        let scanLimit = size - m10

        let recent = TranscriptDetailReader.text(
            itemID: "toolu_10", part: .result, filePath: path, lineOffset: nil, scanLimit: scanLimit)
        let early = TranscriptDetailReader.text(
            itemID: "toolu_2", part: .result, filePath: path, lineOffset: nil, scanLimit: scanLimit)
        let earlyFromItsOffset = TranscriptDetailReader.text(
            itemID: "toolu_2", part: .result, filePath: path, lineOffset: a2, scanLimit: scanLimit)
        let earlyInput = TranscriptDetailReader.text(
            itemID: "toolu_2", part: .input, filePath: path, lineOffset: a2, scanLimit: scanLimit)
        let recentPastAWrongOffset = TranscriptDetailReader.text(
            itemID: "toolu_10", part: .result, filePath: path, lineOffset: a2, scanLimit: scanLimit)

        #expect(m3 - a2 <= scanLimit, "the scan from a2 must reach past r2")
        #expect(recent == "output 10")
        #expect(early == nil, "an item before the tail window, with no offset, is not found")
        #expect(earlyFromItsOffset == "output 2")
        #expect(earlyInput == #"{"command":"echo 2"}"#)
        #expect(recentPastAWrongOffset == "output 10", "a miss from the offset looks in the tail")
    }

    /// A result larger than one chunk arrives in chunks that rejoin to it and
    /// each fit one frame. Every chunk after the first comes from the feed's
    /// cache: the file is gone by then.
    @Test func aLargeResultArrivesInChunksAndLaterChunksReadNoFile() async throws {
        let h = try await PhoneServiceHarness.make()
        let output = (0..<6_000).map { "line \($0): PASS src/acme/widget\($0).test.ts" }.joined(separator: "\n")
        let fixture = try DetailFixture([
            DetailLine.prompt("m1", "placeholder prompt 1"),
            DetailLine.bash("a1", id: "toolu_1", command: "npm test"),
            DetailLine.toolResult("r1", toolUseID: "toolu_1", text: output),
        ])
        defer { fixture.remove() }
        let s = try await Self.openTranscript(h, path: fixture.path)

        let first = try await Self.detail(h, s, itemID: "toolu_1", part: .result, chunk: 0)
        let count = try #require(first.result?.chunkCount)
        try FileManager.default.removeItem(atPath: fixture.path)
        var texts = [try #require(first.result?.text)]
        var sizes = [first.size]
        for chunk in 1..<max(count, 1) {
            let reply = try await Self.detail(h, s, itemID: "toolu_1", part: .result, chunk: chunk)
            texts.append(reply.result?.text ?? "")
            sizes.append(reply.size)
        }
        let rejoined = Array(texts.joined().unicodeScalars)
        let original = Array(output.unicodeScalars)
        let oversize = sizes.filter { $0 > 65_519 }
        let input = try await Self.detail(h, s, itemID: "toolu_1", part: .input, chunk: 0)
        let past = try await Self.detail(h, s, itemID: "toolu_1", part: .result, chunk: count)

        #expect(count > 1)
        #expect(first.result?.totalBytes == output.utf8.count)
        #expect(rejoined == original)
        #expect(oversize.isEmpty, "replies over one frame: \(oversize)")
        #expect(input.error?.code == .notFound, "another part is read again, and the file is gone")
        #expect(past.error?.code == .badRequest)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// Bounded inputs, a session that is not the open one, and a detail the
    /// transcript does not hold.
    @Test func badDetailRequestsAreRefused() async throws {
        let h = try await PhoneServiceHarness.make()
        let fixture = try DetailFixture(DetailLine.conversation(messages: 2))
        defer { fixture.remove() }
        let s = try await Self.openTranscript(h, path: fixture.path)
        let longest = String(repeating: "x", count: PhoneAppConstants.detailItemIDMaxBytes)

        let served = try await Self.detail(h, s, itemID: "toolu_1", part: .result, chunk: 0)
        let atTheCap = try await Self.detail(h, s, itemID: longest, part: .result, chunk: 0)
        let overTheCap = try await Self.detail(h, s, itemID: longest + "x", part: .result, chunk: 0)
        let empty = try await Self.detail(h, s, itemID: "", part: .text, chunk: 0)
        let negative = try await Self.detail(h, s, itemID: "toolu_1", part: .result, chunk: -1)
        let past = try await Self.detail(h, s, itemID: "toolu_1", part: .result, chunk: 1)
        let otherSession = try await Self.detail(
            h, s, session: .local(terminalID: UUID()), itemID: "toolu_1", part: .result, chunk: 0)
        let missing = try await Self.detail(h, s, itemID: "toolu_missing", part: .result, chunk: 0)
        let noSubagent = try await Self.detail(h, s, itemID: "toolu_1", part: .subagent, chunk: 0)

        #expect(served.result?.text == "output 1")
        #expect(atTheCap.error?.code == .notFound, "an ID at the cap is looked up")
        #expect(overTheCap.error?.code == .badRequest)
        #expect(empty.error?.code == .badRequest)
        #expect(negative.error?.code == .badRequest)
        #expect(past.error?.code == .badRequest)
        #expect(otherSession.error?.code == .notOpen)
        #expect(missing.error?.code == .notFound)
        #expect(noSubagent.error?.code == .notFound)

        let closed = try await Self.ask(h, .transcriptClose, PhoneEmpty(), on: s.outbox)
        #expect(try JSONDecoder().decode(PhoneTestReply.self, from: closed).error == nil)
        let afterClose = try await Self.detail(h, s, itemID: "toolu_1", part: .result, chunk: 0)
        #expect(afterClose.error?.code == .notOpen)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// A subagent row's items arrive in runs of whole items, each fitting one
    /// frame, in the order the subagent's transcript holds them. Every run
    /// after the first comes from the feed's cache: the file is gone by then.
    @Test func subagentItemsArriveInChunks() async throws {
        let h = try await PhoneServiceHarness.make()
        let fixture = try DetailFixture([
            DetailLine.prompt("m1", "Survey the tests"),
            DetailLine.agent("a1", id: "toolu_agent", description: "Survey the tests"),
            DetailLine.toolResult("r1", toolUseID: "toolu_agent", text: "Found 40 suites.", agentID: "a-chunks"),
        ])
        defer { fixture.remove() }
        var lines: [[String: Any]] = []
        var expectedIDs: [String] = []
        for n in 0..<40 {
            lines.append(DetailLine.prompt("s\(n)", String(repeating: "survey \(n) ", count: 300), sidechain: true))
            expectedIDs.append("s\(n)")
        }
        let subagent = try fixture.writeSubagent("a-chunks", lines)
        let s = try await Self.openTranscript(h, path: fixture.path)

        let first = try await Self.detail(h, s, itemID: "toolu_agent", part: .subagent, chunk: 0)
        let count = try #require(first.result?.chunkCount)
        try FileManager.default.removeItem(atPath: subagent.path)
        var runs = [first.result?.items ?? []]
        var sizes = [first.size]
        for chunk in 1..<max(count, 1) {
            let reply = try await Self.detail(h, s, itemID: "toolu_agent", part: .subagent, chunk: chunk)
            runs.append(reply.result?.items ?? [])
            sizes.append(reply.size)
        }
        let ids = runs.flatMap { $0.map(\.id) }
        let encoder = PhoneAppCoding.makeEncoder()
        let overBudget = try runs.map { try encoder.encode($0).count }.filter { $0 > PhoneFrameBudget.detailChunkBytes }
        let oversize = sizes.filter { $0 > 65_519 }

        #expect(first.error == nil)
        #expect(count > 1)
        #expect(ids == expectedIDs)
        #expect(first.result?.tooLarge == false)
        #expect(first.result?.totalBytes == Int(subagent.size))
        #expect(first.result?.text == nil)
        #expect(overBudget.isEmpty, "runs over the chunk budget: \(overBudget)")
        #expect(oversize.isEmpty, "replies over one frame: \(oversize)")
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// A subagent transcript over the limit is too large, and only the whole
    /// lines in its first `subagentCountLimit` bytes are read and served.
    @Test func aSubagentOverTheLimitServesItsFirstPart() async throws {
        let h = try await PhoneServiceHarness.make()
        let fixture = try DetailFixture([
            DetailLine.prompt("m1", "Survey the tests"),
            DetailLine.agent("a1", id: "toolu_agent", description: "Survey the tests"),
            DetailLine.toolResult("r1", toolUseID: "toolu_agent", text: "Done.", agentID: "a-big"),
        ])
        defer { fixture.remove() }
        let lines = (0..<30).map { DetailLine.prompt("s\($0)", String(repeating: "x", count: 40_000), sidechain: true) }
        let subagent = try fixture.writeSubagent("a-big", lines)
        let limit = UInt64(PhoneAppConstants.subagentCountLimit)
        let expectedIDs = subagent.ends.enumerated().filter { $0.element <= limit }.map { "s\($0.offset)" }
        let s = try await Self.openTranscript(h, path: fixture.path)

        let first = try await Self.detail(h, s, itemID: "toolu_agent", part: .subagent, chunk: 0)
        let count = try #require(first.result?.chunkCount)
        var ids = first.result?.items?.map(\.id) ?? []
        for chunk in 1..<max(count, 1) {
            let reply = try await Self.detail(h, s, itemID: "toolu_agent", part: .subagent, chunk: chunk)
            ids += reply.result?.items?.map(\.id) ?? []
        }

        #expect(subagent.size > limit)
        #expect(!expectedIDs.isEmpty && expectedIDs.count < lines.count)
        #expect(first.result?.tooLarge == true)
        #expect(first.result?.totalBytes == Int(subagent.size))
        #expect(ids == expectedIDs)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// An agent ID comes from the transcript, so a crafted line could name
    /// any path. One that is not a plain name reads nothing, though a file
    /// sits where it points.
    @Test func aCraftedAgentIDReadsNothingOutsideTheSession() async throws {
        let h = try await PhoneServiceHarness.make()
        let fixture = try DetailFixture([
            DetailLine.prompt("m1", "Survey the tests"),
            DetailLine.agent("a1", id: "toolu_slash", description: "Survey the tests"),
            DetailLine.toolResult("r1", toolUseID: "toolu_slash", text: "Done.", agentID: "a/b"),
            DetailLine.agent("a2", id: "toolu_dots", description: "Survey the tests"),
            DetailLine.toolResult("r2", toolUseID: "toolu_dots", text: "Done.", agentID: "../escape"),
        ])
        defer { fixture.remove() }
        _ = try fixture.writeSubagent("a/b", [DetailLine.prompt("s1", "planted", sidechain: true)])
        let s = try await Self.openTranscript(h, path: fixture.path)

        let slash = try await Self.detail(h, s, itemID: "toolu_slash", part: .subagent, chunk: 0)
        let dots = try await Self.detail(h, s, itemID: "toolu_dots", part: .subagent, chunk: 0)

        #expect(slash.error?.code == .notFound)
        #expect(dots.error?.code == .notFound)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    // MARK: - Helpers

    /// A connection with one session's transcript open. The connection never
    /// goes live, so the feed's live part never starts and no event comes
    /// between the replies.
    private struct OpenTranscript {
        let session: PhoneSessionRef
        let outbox: CapturingOutbox
        let opened: TranscriptOpenResult
    }

    /// One `transcript.detail` reply: its result or its error, and its size
    /// inside the loader wrapper.
    private struct DetailReply {
        let result: TranscriptDetailResult?
        let error: PhoneAppError?
        let size: Int
    }

    private struct Refused: Error, CustomStringConvertible {
        let error: PhoneAppError
        var description: String { "the request was refused: \(error.code.rawValue): \(error.message)" }
    }

    /// The fields every app body has, so a test can find a reply by its ID.
    private struct BodyHead: Decodable {
        let kind: String
        let requestID: String?
    }

    /// Seeds a Claude terminal whose row names `path` as its transcript,
    /// connects the phone and opens the transcript.
    private static func openTranscript(_ h: PhoneServiceHarness, path: String) async throws -> OpenTranscript {
        let terminal = try await h.seedTerminal()
        try await h.db.terminals.updateSession(id: terminal.id, sessionID: "acme-session", transcriptPath: path)
        let session = PhoneSessionRef.local(terminalID: terminal.id)
        let outbox = await h.connect()
        let bytes = try await ask(
            h, .transcriptOpen, TranscriptOpenParams(session: session, showDetails: false, resume: false), on: outbox)
        if let error = try JSONDecoder().decode(PhoneTestReply.self, from: bytes).error {
            throw Refused(error: error)
        }
        let opened = try JSONDecoder().decode(PhoneReplyEnvelope<TranscriptOpenResult>.self, from: bytes).result
        return OpenTranscript(session: session, outbox: outbox, opened: opened)
    }

    private static func page(_ h: PhoneServiceHarness, _ s: OpenTranscript, cursor: String) async throws -> TranscriptPage {
        let bytes = try await ask(h, .transcriptPage, TranscriptPageParams(session: s.session, cursor: cursor), on: s.outbox)
        if let error = try JSONDecoder().decode(PhoneTestReply.self, from: bytes).error {
            throw Refused(error: error)
        }
        return try JSONDecoder().decode(PhoneReplyEnvelope<TranscriptPage>.self, from: bytes).result
    }

    /// Sends `transcript.detail` for the open session, or for `session`.
    private static func detail(
        _ h: PhoneServiceHarness, _ s: OpenTranscript, session: PhoneSessionRef? = nil,
        itemID: String, part: TranscriptDetailPart, chunk: Int
    ) async throws -> DetailReply {
        let params = TranscriptDetailParams(session: session ?? s.session, itemID: itemID, part: part, chunk: chunk)
        let bytes = try await ask(h, .transcriptDetail, params, on: s.outbox)
        let error = try JSONDecoder().decode(PhoneTestReply.self, from: bytes).error
        let result: TranscriptDetailResult?
        if error == nil {
            result = try JSONDecoder().decode(PhoneReplyEnvelope<TranscriptDetailResult>.self, from: bytes).result
        } else {
            result = nil
        }
        return DetailReply(result: result, error: error, size: PhoneAppCoding.framedSize(bytes))
    }

    /// Sends one request and returns its reply, found by its request ID.
    private static func ask<P: Codable>(
        _ h: PhoneServiceHarness, _ method: PhoneAppMethod, _ params: P, on outbox: CapturingOutbox
    ) async throws -> Data {
        let id = UUID().uuidString
        let body = try PhoneTestRequests.body(method, id: id, params: params)
        await h.service.handleAppMessage(body, from: h.peer)
        let deadline = TestDeadlines.saturatedPass
        switch await pollUntilTrue(timeout: deadline, { reply(id, in: outbox) != nil }) {
        case .satisfied:
            break
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw BoundedWaitTimeout(
                what: "the reply to \(method.rawValue)", observed: "\(outbox.bodies.count) bodies", deadline: deadline)
        }
        return try #require(reply(id, in: outbox))
    }

    /// The reply to `requestID` in `outbox`, or nil.
    private static func reply(_ requestID: String, in outbox: CapturingOutbox) -> Data? {
        for body in outbox.bodies {
            guard let head = try? JSONDecoder().decode(BodyHead.self, from: body),
                  head.kind == "reply", head.requestID == requestID else { continue }
            return body
        }
        return nil
    }

    private static func item(_ id: String) -> PhoneItem {
        PhoneItem(
            id: id, kind: .assistant, at: nil, text: "placeholder", truncated: false, toolName: nil, target: nil,
            toolStatus: nil, added: nil, removed: nil, agentType: nil, itemCount: nil, sender: nil)
    }
}

// MARK: - Transcript files

/// JSONL lines in the shape Claude Code writes and `TranscriptParser` reads.
private enum DetailLine {
    static let timestamp = "2026-05-05T10:00:00.000Z"

    static func prompt(_ uuid: String, _ text: String, sidechain: Bool = false) -> [String: Any] {
        let message: [String: Any] = ["role": "user", "content": text]
        var line: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": timestamp, "message": message]
        if sidechain { line["isSidechain"] = true }
        return line
    }

    static func assistant(_ uuid: String, blocks: [[String: Any]]) -> [String: Any] {
        let message: [String: Any] = ["role": "assistant", "content": blocks]
        return ["type": "assistant", "uuid": uuid, "timestamp": timestamp, "message": message]
    }

    static func toolUse(_ id: String, name: String, input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    /// An assistant line holding one Bash call.
    static func bash(_ uuid: String, id: String, command: String) -> [String: Any] {
        assistant(uuid, blocks: [toolUse(id, name: "Bash", input: ["command": command])])
    }

    /// An assistant line holding one Explore subagent call.
    static func agent(_ uuid: String, id: String, description: String) -> [String: Any] {
        let input: [String: Any] = ["description": description, "prompt": "Look around.", "subagent_type": "Explore"]
        return assistant(uuid, blocks: [toolUse(id, name: "Agent", input: input)])
    }

    /// A user line returning `toolUseID`'s result. With `agentID`, the line
    /// names the subagent the way Claude Code does, in `toolUseResult`.
    static func toolResult(_ uuid: String, toolUseID: String, text: String, agentID: String? = nil) -> [String: Any] {
        let block: [String: Any] = ["type": "tool_result", "tool_use_id": toolUseID, "content": text]
        let message: [String: Any] = ["role": "user", "content": [block]]
        var line: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": timestamp, "message": message]
        if let agentID {
            let toolUseResult: [String: Any] = ["agentId": agentID, "status": "completed"]
            line["toolUseResult"] = toolUseResult
        }
        return line
    }

    /// Prompts `m1`…`m<messages>`, each followed by a Bash call `toolu_<n>` on
    /// line `a<n>` and its result `output <n>` on line `r<n>`.
    static func conversation(messages: Int) -> [[String: Any]] {
        var lines: [[String: Any]] = []
        for n in 1...messages {
            lines.append(prompt("m\(n)", "placeholder prompt \(n)"))
            lines.append(bash("a\(n)", id: "toolu_\(n)", command: "echo \(n)"))
            lines.append(toolResult("r\(n)", toolUseID: "toolu_\(n)", text: "output \(n)"))
        }
        return lines
    }
}

/// A transcript file, `session.jsonl`, in a scratch directory of its own,
/// with each line's offset.
private struct DetailFixture {
    let directory: URL
    let path: String
    /// Each line's `uuid`, nil for a line without one.
    let uuids: [String?]
    /// The offset of each line's first byte.
    let offsets: [UInt64]

    init(_ objects: [[String: Any]]) throws {
        let directory = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-detail"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoded = try Self.encode(objects)
        let path = directory.appendingPathComponent("session.jsonl").path
        try encoded.bytes.write(to: URL(fileURLWithPath: path))
        self.directory = directory
        self.path = path
        self.uuids = objects.map { $0["uuid"] as? String }
        self.offsets = encoded.offsets
    }

    func offset(ofUUID uuid: String) -> UInt64? {
        uuids.firstIndex(of: uuid).map { offsets[$0] }
    }

    /// Writes subagent `agentID`'s transcript where Claude Code keeps it,
    /// beside the session's: `<directory>/session/subagents/agent-<agentID>.jsonl`.
    /// Returns its path, its size, and where each of its lines ends, just past
    /// its `"\n"`.
    func writeSubagent(_ agentID: String, _ objects: [[String: Any]]) throws -> (path: String, size: UInt64, ends: [UInt64]) {
        let url = directory.appendingPathComponent("session/subagents/agent-\(agentID).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = try Self.encode(objects)
        try encoded.bytes.write(to: url)
        let size = UInt64(encoded.bytes.count)
        let ends = Array(encoded.offsets.dropFirst()) + [size]
        return (url.path, size, ends)
    }

    /// Writes `objects` over the session's file, in place.
    func rewrite(_ objects: [[String: Any]]) throws {
        try Self.encode(objects).bytes.write(to: URL(fileURLWithPath: path))
    }

    func size() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `objects` as JSONL, one line each, every line ending in `"\n"`, with
    /// each line's offset.
    static func encode(_ objects: [[String: Any]]) throws -> (bytes: Data, offsets: [UInt64]) {
        var bytes = Data()
        var offsets: [UInt64] = []
        for object in objects {
            offsets.append(UInt64(bytes.count))
            bytes.append(try JSONSerialization.data(withJSONObject: object))
            bytes.append(UInt8(ascii: "\n"))
        }
        return (bytes, offsets)
    }
}
