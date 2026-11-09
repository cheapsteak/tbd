import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// Tier 2: each test writes a transcript into a scratch directory of its own
/// and reads it back. Nothing else is touched, and nothing waits on a clock.
@Suite("Transcript pager")
struct TranscriptPagerTests {
    // MARK: - First page

    @Test func theFirstPageEndsAtTheFourthLastMessage() throws {
        let fixture = try PagerFixture(PagerLine.conversation(messages: 10))
        defer { fixture.remove() }

        let build = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let ids = build.page.items.map(\.id)

        #expect(ids == ["m7", "toolu_7", "m8", "toolu_8", "m9", "toolu_9", "m10", "toolu_10"])
        #expect(build.startOffset == fixture.offset(ofUUID: "m7"))
        #expect(build.lineOffsets["toolu_7"] == fixture.offset(ofUUID: "a7"))
        #expect(build.page.cursor != nil)
        #expect(!build.page.reachedStart)
        #expect(build.page.omittedItems == 0)
        #expect(build.unresolvedCalls.isEmpty)
        #expect(build.results["toolu_10"] == ToolResult(text: "output 10", truncatedTo: nil, isError: false))
    }

    @Test func theFirstPageIsAtMost16KB() throws {
        // 4 messages of 4 KB each, each followed by 10 tool rows.
        var objects: [[String: Any]] = []
        var order: [String] = []
        for m in 1...4 {
            objects.append(PagerLine.prompt("m\(m)", String(repeating: "x", count: 4_096)))
            order.append("m\(m)")
            for t in 1...10 {
                let n = (m - 1) * 10 + t
                objects.append(PagerLine.bash("a\(n)", id: "toolu_\(n)", command: "echo \(n)"))
                objects.append(PagerLine.toolResult("r\(n)", toolUseID: "toolu_\(n)", text: "output \(n)"))
                order.append("toolu_\(n)")
            }
        }
        let fixture = try PagerFixture(objects)
        defer { fixture.remove() }

        let build = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let ids = build.page.items.map(\.id)
        let firstID = try #require(ids.first)
        let cursor = try #require(build.page.cursor)
        let older = try TranscriptPager.olderPage(
            filePath: fixture.path, cursor: cursor, generation: 0, ctx: ShapingContext(joinedResults: build.results))
        let olderIDs = older.page.items.map(\.id)

        #expect(try PhoneAppCoding.makeEncoder().encode(build.page).count <= 16_384)
        #expect(ids.last == "toolu_40")
        #expect(!ids.contains("m1"), "the oldest line goes first")
        #expect(build.page.omittedItems == 0)
        #expect(!build.page.reachedStart)
        #expect(build.startOffset == build.lineOffsets[firstID])
        #expect(TranscriptPager.resolveCursor(cursor, generation: 0, filePath: fixture.path) == build.startOffset)
        // The lines the budget dropped are the older page's, and none is lost.
        #expect(olderIDs + ids == order)
        #expect(older.page.reachedStart)
    }

    // MARK: - Older pages

    @Test func olderPagesWalkBackToTheStart() throws {
        let fixture = try PagerFixture(PagerLine.conversation(messages: 95))
        defer { fixture.remove() }

        let first = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        var pages = [first]
        while let cursor = pages.last?.page.cursor, pages.count < 10 {
            let joined = pages.last?.results ?? [:]
            let older = try TranscriptPager.olderPage(
                filePath: fixture.path, cursor: cursor, generation: 0, ctx: ShapingContext(joinedResults: joined))
            pages.append(older)
        }
        let messageCounts = pages.map { build in build.page.items.filter { $0.kind == .user }.count }
        let allIDs = pages.reversed().flatMap { build in build.page.items.map(\.id) }
        let expectedIDs = (1...95).flatMap { ["m\($0)", "toolu_\($0)"] }

        #expect(messageCounts == [4, 20, 20, 20, 20, 11])
        #expect(pages.last?.page.reachedStart == true)
        #expect(pages.last?.page.cursor == nil)
        #expect(pages.last?.startOffset == 0)
        #expect(allIDs == expectedIDs)
    }

    // MARK: - Joins

    @Test func aCallWhoseResultIsInANewerPageShowsItsStatus() throws {
        // toolu_x is called before m2, and its result arrives after m2, so the
        // call is on the older page and its result in the first page's bytes.
        let fixture = try PagerFixture([
            PagerLine.prompt("m1", "placeholder prompt 1"),
            PagerLine.bash("a1", id: "toolu_x", command: "make test"),
            PagerLine.prompt("m2", "placeholder prompt 2"),
            PagerLine.toolResult("rx", toolUseID: "toolu_x", text: "all green"),
            PagerLine.prompt("m3", "placeholder prompt 3"),
            PagerLine.prompt("m4", "placeholder prompt 4"),
            PagerLine.prompt("m5", "placeholder prompt 5"),
        ])
        defer { fixture.remove() }

        let first = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let cursor = try #require(first.page.cursor)
        let joined = try TranscriptPager.olderPage(
            filePath: fixture.path, cursor: cursor, generation: 0, ctx: ShapingContext(joinedResults: first.results))
        let alone = try TranscriptPager.olderPage(
            filePath: fixture.path, cursor: cursor, generation: 0, ctx: ShapingContext())
        let joinedCall = joined.page.items.first { $0.id == "toolu_x" }
        let aloneCall = alone.page.items.first { $0.id == "toolu_x" }
        let firstIDs = first.page.items.map(\.id)

        #expect(firstIDs == ["m2", "m3", "m4", "m5"])
        #expect(first.results["toolu_x"] != nil)
        #expect(joinedCall?.toolStatus == "ok")
        #expect(joined.unresolvedCalls.isEmpty)
        #expect(joined.page.reachedStart)
        // Without the join, the same call is still running.
        #expect(aloneCall?.toolStatus == "running")
        #expect(alone.unresolvedCalls["toolu_x"] == aloneCall)
    }

    @Test func aCallWithNoResultYetIsRunningAndListed() throws {
        let fixture = try PagerFixture([
            PagerLine.prompt("m1", "placeholder prompt 1"),
            PagerLine.prompt("m2", "placeholder prompt 2"),
            PagerLine.bash("live", id: "toolu_live", command: "npm test"),
        ])
        defer { fixture.remove() }

        let build = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let call = try #require(build.page.items.last)

        #expect(call.id == "toolu_live")
        #expect(call.toolStatus == "running")
        #expect(Array(build.unresolvedCalls.keys) == ["toolu_live"])
        #expect(build.unresolvedCalls["toolu_live"] == call)
        #expect(build.lineOffsets["toolu_live"] == fixture.offset(ofUUID: "live"))
        #expect(build.page.reachedStart)
        #expect(build.page.cursor == nil)
    }

    // MARK: - Cursors

    @Test func aCursorSurvivesAPrepend() throws {
        let fixture = try PagerFixture(PagerLine.conversation(messages: 10))
        defer { fixture.remove() }
        let first = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let cursor = try #require(first.page.cursor)

        // A remote sync fetched earlier lines and put them in front.
        let prefix = try PagerFixture.encode((1...30).map { PagerLine.prompt("p\($0)", "earlier placeholder prompt \($0)") })
        let original = try Data(contentsOf: URL(fileURLWithPath: fixture.path))
        try (prefix.bytes + original).write(to: URL(fileURLWithPath: fixture.path))

        let resolved = TranscriptPager.resolveCursor(cursor, generation: 0, filePath: fixture.path)
        let older = try TranscriptPager.olderPage(
            filePath: fixture.path, cursor: cursor, generation: 0, ctx: ShapingContext(joinedResults: first.results))
        let olderMessages = older.page.items.filter { $0.kind == .user }.map(\.id)
        let expectedMessages = (17...30).map { "p\($0)" } + (1...6).map { "m\($0)" }

        #expect(prefix.bytes.count >= 3_072)
        #expect(resolved == first.startOffset + UInt64(prefix.bytes.count))
        #expect(olderMessages == expectedMessages)
    }

    @Test func aCursorFromAnotherGenerationIsStale() throws {
        let fixture = try PagerFixture(PagerLine.conversation(messages: 10))
        defer { fixture.remove() }
        let first = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 1, ctx: ShapingContext()))
        let cursor = try #require(first.page.cursor)

        let error = #expect(throws: PhoneAppError.self) {
            _ = try TranscriptPager.olderPage(filePath: fixture.path, cursor: cursor, generation: 2, ctx: ShapingContext())
        }

        #expect(cursor.hasPrefix("1:"))
        #expect(TranscriptPager.resolveCursor(cursor, generation: 2, filePath: fixture.path) == nil)
        #expect(TranscriptPager.resolveCursor(cursor, generation: 1, filePath: fixture.path) == first.startOffset)
        #expect(error?.code == .staleCursor)
    }

    @Test func aMalformedCursorIsStale() throws {
        let fixture = try PagerFixture(PagerLine.conversation(messages: 10))
        defer { fixture.remove() }
        let first = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let cursor = try #require(first.page.cursor)
        let parts = cursor.split(separator: ":").map(String.init)
        try #require(parts.count == 3)
        let offset = parts[1]
        let anchor = parts[2]

        let malformed = [
            "",
            "garbage",
            "0:\(offset)",
            "0:\(offset):\(anchor):extra",
            "0:abc:\(anchor)",
            "0:-\(offset):\(anchor)",
            "0::\(anchor)",
            "0:99999999999999999999999:\(anchor)",
            "0:\(fixture.size):\(anchor)",
            "0:\(fixture.size + 100):\(anchor)",
            "0:\(offset):ABCDEFABCDEFABCD",
            "0:\(offset):\(anchor.dropLast())",
            "0:\(offset):zzzzzzzzzzzzzzzz",
            "0:\(offset):0000000000000000",
            "+0:\(offset):\(anchor)",
            " 0:\(offset):\(anchor)",
            "0:\(offset):\(anchor)" + String(repeating: " ", count: 200),
        ]
        for bad in malformed {
            let error = #expect(throws: PhoneAppError.self, "cursor \"\(bad)\"") {
                _ = try TranscriptPager.olderPage(filePath: fixture.path, cursor: bad, generation: 0, ctx: ShapingContext())
            }
            #expect(TranscriptPager.resolveCursor(bad, generation: 0, filePath: fixture.path) == nil, "cursor \"\(bad)\"")
            #expect(error?.code == .staleCursor, "cursor \"\(bad)\"")
        }
        // The cursor itself still resolves, so each refusal above is the change.
        #expect(TranscriptPager.resolveCursor(cursor, generation: 0, filePath: fixture.path) == first.startOffset)
    }

    @Test func aCursorInsideALineIsStale() throws {
        let fixture = try PagerFixture(PagerLine.conversation(messages: 10))
        defer { fixture.remove() }
        let m7 = try #require(fixture.offset(ofUUID: "m7"))
        let insideALine = try #require(TranscriptPager.makeCursor(generation: 0, offset: m7 + 1, filePath: fixture.path))

        let error = #expect(throws: PhoneAppError.self) {
            _ = try TranscriptPager.olderPage(filePath: fixture.path, cursor: insideALine, generation: 0, ctx: ShapingContext())
        }

        #expect(TranscriptPager.resolveCursor(insideALine, generation: 0, filePath: fixture.path) == nil)
        #expect(error?.code == .staleCursor)
    }

    // MARK: - Frame fit

    @Test func theLargestPageFitsOneFrame() throws {
        // Previews of quotes, control characters and multi-byte text, each at
        // the 4 KB cap, between tool rows whose names and targets are at
        // their caps too.
        let fillers = [
            String(repeating: "\"", count: 5_000),
            String(repeating: "\u{1}", count: 5_000),
            String(repeating: "😀", count: 2_000),
            String(repeating: "é", count: 3_000),
        ]
        let toolName = "mcp__acme__" + String(repeating: "\"", count: 300)
        var objects: [[String: Any]] = []
        for n in 0..<34 {
            objects.append(PagerLine.prompt(UUID().uuidString, fillers[n % fillers.count]))
            objects.append(PagerLine.assistant(UUID().uuidString, blocks: [PagerLine.toolUse(
                "toolu_\(UUID().uuidString)", name: toolName,
                input: ["file_path": "/repo/" + String(repeating: "\"", count: 1_000)])]))
        }
        let fixture = try PagerFixture(objects)
        defer { fixture.remove() }

        let first = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let cursor = try #require(first.page.cursor)
        let older = try TranscriptPager.olderPage(
            filePath: fixture.path, cursor: cursor, generation: 0, ctx: ShapingContext(joinedResults: first.results))
        let firstBytes = try PhoneAppCoding.makeEncoder().encode(first.page).count
        let olderBytes = try PhoneAppCoding.makeEncoder().encode(older.page).count
        let truncatedCount = older.page.items.filter(\.truncated).count

        #expect(firstBytes <= 16_384)
        #expect(PhoneAppCoding.framedSize(try PhoneAppCoding.reply(requestID: UUID().uuidString, result: first.page)) <= 65_519)
        #expect(olderBytes <= 61_440)
        #expect(olderBytes > 61_440 - 8_192, "the older page should fill close to its budget, holding \(olderBytes) bytes")
        #expect(PhoneAppCoding.framedSize(try PhoneAppCoding.reply(requestID: UUID().uuidString, result: older.page)) <= 65_519)
        #expect(truncatedCount > 0, "the fixture's previews must reach the cap")
        #expect(older.page.cursor != nil)
    }

    @Test func aSingleOversizeLineKeepsTheNewestItemsAndCountsTheRest() throws {
        let blocks = (0..<10).map { _ in PagerLine.text(String(repeating: "x", count: 4_096)) }
        let fixture = try PagerFixture([
            PagerLine.prompt("m1", "placeholder prompt"),
            PagerLine.assistant("big", blocks: blocks),
        ])
        defer { fixture.remove() }

        let build = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let cursor = try #require(build.page.cursor)
        let big = try #require(fixture.offset(ofUUID: "big"))
        let ids = build.page.items.map(\.id)

        #expect(ids == ["big#7", "big#8", "big#9"])
        #expect(build.page.omittedItems == 7)
        #expect(try PhoneAppCoding.makeEncoder().encode(build.page).count <= 16_384)
        #expect(build.startOffset == big)
        #expect(TranscriptPager.resolveCursor(cursor, generation: 0, filePath: fixture.path) == big)
        #expect(!build.page.reachedStart)
    }

    /// Rows carrying a slash command's output and a file edit's path, each
    /// at its cap, still leave every page within its budget and one frame.
    @Test func pagesOfOutputsAndPathsAtTheirCapsFitOneFrame() throws {
        let output = String(repeating: "\"", count: 3_000)
        let directory = "/Users/acme/" + String(repeating: "d/", count: 240)
        var objects: [[String: Any]] = []
        for n in 0..<60 {
            objects.append(PagerLine.slashCommand("c\(n)", name: "context", args: String(repeating: "\u{1}", count: 900)))
            objects.append(PagerLine.commandOutput("o\(n)", parent: "c\(n)", output: output))
            objects.append(PagerLine.edit("e\(n)", id: "toolu_e\(n)", filePath: directory + "f\(n).ts"))
        }
        let fixture = try PagerFixture(objects)
        defer { fixture.remove() }

        let first = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let cursor = try #require(first.page.cursor)
        let older = try TranscriptPager.olderPage(
            filePath: fixture.path, cursor: cursor, generation: 0,
            ctx: ShapingContext(slashOutputs: first.slashOutputs))
        let firstBytes = try PhoneAppCoding.makeEncoder().encode(first.page).count
        let olderBytes = try PhoneAppCoding.makeEncoder().encode(older.page).count
        let outputs = older.page.items.compactMap(\.output)
        let paths = older.page.items.compactMap(\.path)
        let uncut = outputs.filter { !$0.hasSuffix(TranscriptShaper.cutMark) }

        #expect(firstBytes <= 16_384)
        #expect(olderBytes <= 61_440)
        #expect(PhoneAppCoding.framedSize(try PhoneAppCoding.reply(requestID: UUID().uuidString, result: older.page)) <= 65_519)
        #expect(!outputs.isEmpty, "the older page must hold slash rows with output")
        #expect(uncut.isEmpty, "every output in the fixture is over the cap")
        #expect(!paths.isEmpty, "the older page must hold file edits with paths")
    }

    // MARK: - New fields

    @Test func aSlashRowTakesTheOutputInItsWindow() throws {
        let fixture = try PagerFixture([
            PagerLine.prompt("m1", "placeholder prompt 1"),
            PagerLine.slashCommand("c1", name: "model", args: "opus"),
            PagerLine.commandOutput("o1", parent: "c1", output: "Set model to opus"),
        ])
        defer { fixture.remove() }

        let build = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let slash = try #require(build.page.items.last)

        #expect(slash.id == "c1")
        #expect(slash.kind == .slash)
        #expect(slash.output == "Set model to opus")
        #expect(build.slashOutputs == ["c1": "Set model to opus"])
        #expect(build.waitingSlashes.isEmpty)
    }

    @Test func aSlashRowWithNoOutputYetIsListedWaiting() throws {
        let fixture = try PagerFixture([
            PagerLine.prompt("m1", "placeholder prompt 1"),
            PagerLine.slashCommand("c1", name: "model", args: "opus"),
        ])
        defer { fixture.remove() }

        let build = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let slash = try #require(build.page.items.last)

        #expect(slash.output == nil)
        #expect(build.waitingSlashes == [slash])
    }

    @Test func anOlderPageJoinsASlashOutputItDoesNotHold() throws {
        let fixture = try PagerFixture([
            PagerLine.slashCommand("c1", name: "model", args: "opus"),
            PagerLine.prompt("m2", "placeholder prompt 2"),
            PagerLine.prompt("m3", "placeholder prompt 3"),
            PagerLine.prompt("m4", "placeholder prompt 4"),
            PagerLine.prompt("m5", "placeholder prompt 5"),
        ])
        defer { fixture.remove() }

        let first = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let cursor = try #require(first.page.cursor)
        let joined = try TranscriptPager.olderPage(
            filePath: fixture.path, cursor: cursor, generation: 0,
            ctx: ShapingContext(slashOutputs: ["c1": "Set model to opus"]))
        let alone = try TranscriptPager.olderPage(
            filePath: fixture.path, cursor: cursor, generation: 0, ctx: ShapingContext())
        let joinedIDs = joined.page.items.map(\.id)
        let aloneWaiting = alone.waitingSlashes.map(\.id)

        #expect(joinedIDs == ["c1"])
        #expect(joined.page.items.first?.output == "Set model to opus")
        #expect(joined.waitingSlashes.isEmpty)
        #expect(alone.page.items.first?.output == nil)
        #expect(aloneWaiting == ["c1"])
    }

    @Test func anAPIErrorLineIsAnErrorRow() throws {
        let fixture = try PagerFixture([
            PagerLine.prompt("m1", "placeholder prompt 1"),
            PagerLine.apiError("e1", error: "rate_limit", text: "You've hit your limit"),
            PagerLine.apiError(nil, error: nil, text: "API Error: Connection error."),
            PagerLine.assistant("a1", blocks: [PagerLine.text("Back to the redirect.")]),
        ])
        defer { fixture.remove() }

        let build = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let ids = build.page.items.map(\.id)
        let errors = build.page.items.map(\.apiError)
        let positional = "at-\(fixture.offsets[2])#0"

        #expect(ids == ["m1", "e1#0", positional, "a1#0"])
        #expect(errors == [nil, "rate_limit", "unknown", nil])
    }

    @Test func aFileEditOnAPageIsRelativeToTheWorktree() throws {
        let fixture = try PagerFixture([
            PagerLine.prompt("m1", "placeholder prompt 1"),
            PagerLine.edit("e1", id: "toolu_e1", filePath: "/Users/acme/repo/src/auth/redirect.ts"),
            PagerLine.edit("e2", id: "toolu_e2", filePath: "/Users/acme/other/README.md"),
        ])
        defer { fixture.remove() }

        let build = try #require(TranscriptPager.firstPage(
            filePath: fixture.path, generation: 0, ctx: ShapingContext(worktreeRoot: "/Users/acme/repo")))
        let paths = build.page.items.map(\.path)
        let targets = build.page.items.map(\.target)

        #expect(paths == [nil, "src/auth/redirect.ts", "/Users/acme/other/README.md"])
        #expect(targets == [nil, "redirect.ts", "README.md"])
    }

    // MARK: - Subagents

    @Test func aPageCountsOnlyTheSubagentsItKeeps() throws {
        // The budget drops m1, the old subagent call and m2, in that order.
        var objects: [[String: Any]] = [
            PagerLine.prompt("m1", String(repeating: "x", count: 4_096)),
            PagerLine.agent("a-old", id: "toolu_old", description: "Survey the old tests"),
            PagerLine.toolResult("r-old", toolUseID: "toolu_old", text: "done", agentID: "old"),
            PagerLine.prompt("m2", String(repeating: "x", count: 4_096)),
            PagerLine.prompt("m3", String(repeating: "x", count: 4_096)),
            PagerLine.prompt("m4", String(repeating: "x", count: 4_096)),
        ]
        for n in 1...30 {
            objects.append(PagerLine.bash("a\(n)", id: "toolu_\(n)", command: "echo \(n) placeholder output for the row"))
            objects.append(PagerLine.toolResult("r\(n)", toolUseID: "toolu_\(n)", text: "output \(n)"))
        }
        objects.append(PagerLine.agent("a-new", id: "toolu_new", description: "Survey the new tests"))
        objects.append(PagerLine.toolResult("r-new", toolUseID: "toolu_new", text: "done", agentID: "new"))
        let fixture = try PagerFixture(objects)
        defer { fixture.remove() }
        let counted = AgentIDLog()
        let ctx = ShapingContext(subagentItemCount: { agentID in
            counted.record(agentID)
            return 14
        })

        let build = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ctx))
        let ids = build.page.items.map(\.id)
        let newRow = try #require(build.page.items.last)

        #expect(!ids.contains("toolu_old"))
        #expect(!ids.contains("m2"))
        #expect(ids.first == "m3")
        #expect(newRow.id == "toolu_new")
        #expect(newRow.itemCount == 14)
        #expect(newRow.agentType == "Explore")
        #expect(counted.recorded == ["new"])
        #expect(try PhoneAppCoding.makeEncoder().encode(build.page).count <= 16_384)
    }

    @Test func aSubagentIsCountedFromItsOwnFile() throws {
        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-pager"), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let subagents = root.appendingPathComponent("sess-1/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let transcriptPath = root.appendingPathComponent("sess-1.jsonl").path
        let agentPath = subagents.appendingPathComponent("agent-a0123456789abcdef.jsonl").path
        let lines = try PagerFixture.encode([
            PagerLine.prompt("s1", "Survey the tests", sidechain: true),
            PagerLine.assistant(
                "s2", blocks: [PagerLine.thinking("Start with the suites."), PagerLine.text("Found 3 suites.")],
                sidechain: true),
            PagerLine.assistant(
                "s3", blocks: [PagerLine.toolUse("toolu_s", name: "Grep", input: ["pattern": "Suite"])],
                sidechain: true),
            PagerLine.toolResult("s4", toolUseID: "toolu_s", text: "3 matches", sidechain: true),
        ])
        try lines.bytes.write(to: URL(fileURLWithPath: agentPath))

        let path = TranscriptPager.subagentFilePath(transcriptPath: transcriptPath, agentID: "a0123456789abcdef")
        let plain = TranscriptPager.subagentItemCount(
            transcriptPath: transcriptPath, agentID: "a0123456789abcdef", showDetails: false)
        let detailed = TranscriptPager.subagentItemCount(
            transcriptPath: transcriptPath, agentID: "a0123456789abcdef", showDetails: true)
        let missing = TranscriptPager.subagentItemCount(
            transcriptPath: transcriptPath, agentID: "a-missing", showDetails: false)

        #expect(path == agentPath)
        #expect(plain == 3, "the prompt, the text and the Grep call")
        #expect(detailed == 4, "the thinking block too")
        #expect(missing == nil)
    }

    @Test func aSubagentFileOverTheLimitIsNotCounted() throws {
        let root = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-pager"), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let subagents = root.appendingPathComponent("sess-1/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let transcriptPath = root.appendingPathComponent("sess-1.jsonl").path
        let lines = try PagerFixture.encode([
            PagerLine.prompt("s1", String(repeating: "x", count: PhoneAppConstants.subagentCountLimit), sidechain: true),
        ])
        try lines.bytes.write(to: subagents.appendingPathComponent("agent-big.jsonl"))

        let count = TranscriptPager.subagentItemCount(transcriptPath: transcriptPath, agentID: "big", showDetails: false)

        #expect(lines.bytes.count > PhoneAppConstants.subagentCountLimit)
        #expect(count == nil)
    }

    @Test func anAgentIDThatIsNotAPlainNameIsRefused() {
        let transcriptPath = "/acme/projects/sess-1.jsonl"

        #expect(TranscriptPager.subagentFilePath(transcriptPath: transcriptPath, agentID: "../../secrets") == nil)
        #expect(TranscriptPager.subagentFilePath(transcriptPath: transcriptPath, agentID: "a/b") == nil)
        #expect(TranscriptPager.subagentFilePath(transcriptPath: transcriptPath, agentID: "") == nil)
        #expect(TranscriptPager.subagentFilePath(transcriptPath: transcriptPath, agentID: "a_b-C9")
            == "/acme/projects/sess-1/subagents/agent-a_b-C9.jsonl")
    }
}

// MARK: - Fixtures

/// Agent IDs a counting closure was asked for, in order.
private final class AgentIDLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func record(_ id: String) {
        lock.withLock { ids.append(id) }
    }

    var recorded: [String] {
        lock.withLock { ids }
    }
}

/// JSONL lines in the shape Claude Code writes and `TranscriptParser` reads.
private enum PagerLine {
    static let timestamp = "2026-05-05T10:00:00.000Z"

    static func prompt(_ uuid: String, _ text: String, sidechain: Bool = false) -> [String: Any] {
        let message: [String: Any] = ["role": "user", "content": text]
        var line: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": timestamp, "message": message]
        if sidechain { line["isSidechain"] = true }
        return line
    }

    static func assistant(_ uuid: String, blocks: [[String: Any]], sidechain: Bool = false) -> [String: Any] {
        let message: [String: Any] = ["role": "assistant", "content": blocks]
        var line: [String: Any] = ["type": "assistant", "uuid": uuid, "timestamp": timestamp, "message": message]
        if sidechain { line["isSidechain"] = true }
        return line
    }

    static func text(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }

    static func thinking(_ text: String) -> [String: Any] {
        ["type": "thinking", "thinking": text]
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
    static func toolResult(
        _ uuid: String, toolUseID: String, text: String, agentID: String? = nil, sidechain: Bool = false
    ) -> [String: Any] {
        let block: [String: Any] = ["type": "tool_result", "tool_use_id": toolUseID, "content": text]
        let message: [String: Any] = ["role": "user", "content": [block]]
        var line: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": timestamp, "message": message]
        if let agentID {
            let toolUseResult: [String: Any] = ["agentId": agentID, "status": "completed"]
            line["toolUseResult"] = toolUseResult
        }
        if sidechain { line["isSidechain"] = true }
        return line
    }

    /// An assistant line holding one Edit call on `filePath`.
    static func edit(_ uuid: String, id: String, filePath: String) -> [String: Any] {
        assistant(uuid, blocks: [toolUse(
            id, name: "Edit", input: ["file_path": filePath, "old_string": "a", "new_string": "b"])])
    }

    /// The line of a slash command typed as `/<name> <args>`.
    static func slashCommand(_ uuid: String, name: String, args: String) -> [String: Any] {
        let text = "<command-name>/\(name)</command-name>\n<command-message>\(name)</command-message>\n"
            + "<command-args>\(args)</command-args>"
        return prompt(uuid, text)
    }

    /// The output of the slash command on line `parent`, as Claude Code
    /// writes it on a user line of its own.
    static func commandOutput(_ uuid: String, parent: String, output: String) -> [String: Any] {
        var line = prompt(uuid, "<local-command-stdout>\(output)</local-command-stdout>")
        line["parentUuid"] = parent
        return line
    }

    /// An API error, as Claude Code writes it: an assistant line marked
    /// `isApiErrorMessage`, whose text is the message shown. A nil `uuid` or
    /// `error` leaves the key out.
    static func apiError(_ uuid: String?, error: String?, text: String) -> [String: Any] {
        var line = assistant(uuid ?? "", blocks: [self.text(text)])
        if uuid == nil { line.removeValue(forKey: "uuid") }
        line["isApiErrorMessage"] = true
        if let error { line["error"] = error }
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

/// A transcript file in a scratch directory of its own, with each line's
/// offset.
private struct PagerFixture {
    let directory: URL
    let path: String
    /// Each line's `uuid`, nil for a line without one.
    let uuids: [String?]
    /// The offset of each line's first byte.
    let offsets: [UInt64]
    let size: UInt64

    init(_ objects: [[String: Any]]) throws {
        let directory = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-pager"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoded = try Self.encode(objects)
        let path = directory.appendingPathComponent("session.jsonl").path
        try encoded.bytes.write(to: URL(fileURLWithPath: path))

        self.directory = directory
        self.path = path
        self.uuids = objects.map { $0["uuid"] as? String }
        self.offsets = encoded.offsets
        self.size = UInt64(encoded.bytes.count)
    }

    /// `objects` as JSONL, one line each, every line ending in `"\n"`.
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

    func offset(ofUUID uuid: String) -> UInt64? {
        uuids.firstIndex(of: uuid).map { offsets[$0] }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
