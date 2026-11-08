import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// `transcript.open`, `transcript.page` and `transcript.close`, and the feed
/// behind them: the first page, live appends and updates, resets, and how the
/// feed lives through another open, a resume and the grace. Tier 2: each test
/// writes its transcripts into a scratch directory of its own and watches
/// them with a real `FileWatcher` on an injected `EventDrivenTestClock`. The
/// service tests run over the harness's in-memory database, its own
/// `StateSubscriptionManager` and fake session actions.
@Suite("Phone transcript feed", .clockDriven)
struct TranscriptFeedTests {
    // MARK: - The feed on its own

    /// The first page is the file's tail, and a line appended after the
    /// feed's first read reaches the phone through the watcher alone: with
    /// no state delta, and only once the watcher's debounce has run out.
    @Test func openReturnsTheFirstPageAndAppendsArriveLive() async throws {
        let fixture = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { fixture.remove() }
        let d = DirectFeed(path: fixture.path)

        let page = try await d.feed.open()
        let pageIDs = page.items.map(\.id)
        #expect(pageIDs == ["m1", "toolu_1", "m2", "toolu_2"])
        #expect(page.reachedStart)
        #expect(page.cursor == nil)

        await d.feed.start()
        // The read `start()` asks for is behind us, so nothing but the
        // watcher can read the line appended next.
        try await waitUntil("the feed's first read") { await d.feed.readCount >= 1 }
        try fixture.append([FeedLine.prompt("m3", "placeholder prompt 3")])
        let events = d.events
        let arrived: @Sendable () async -> Bool = { Self.appendedIDs(events.values) == ["m3"] }
        try await Self.appendUntilArmed(fixture.path, clock: d.clock, or: arrived)
        let early = Self.appendedIDs(d.events.values)
        #expect(early.isEmpty, "the line arrived before the watcher's debounce ran out")
        // One step per armed debounce: a write event that lands after an
        // advance replaces the debounce it fired, so a single advance can
        // lose the tick.
        try await d.clock.advanceUntil(
            "the append of m3", by: FileWatcher.debounceInterval, timeout: TestDeadlines.saturatedPass
        ) {
            await arrived()
        }

        let appended = Self.appendedIDs(d.events.values)
        #expect(appended == ["m3"])
        let kinds = d.events.values.compactMap { $0.appended }.flatMap { $0.items.map(\.kind) }
        #expect(kinds == [.user])
        #expect(await d.feed.generation == 0)
        await d.feed.close()
    }

    /// A call on the first page has no result yet. When its result is
    /// appended, the phone gets the row again as `ok`, and nothing new.
    @Test func aLateResultForAPageLoadedCallSendsAnUpdate() async throws {
        let fixture = try FeedFixture([
            FeedLine.prompt("m1", "placeholder prompt 1"),
            FeedLine.bash("a1", id: "toolu_1", command: "echo 1"),
        ])
        defer { fixture.remove() }
        let d = DirectFeed(path: fixture.path)

        let page = try await d.feed.open()
        let status = page.items.first(where: { $0.id == "toolu_1" })?.toolStatus
        #expect(status == TranscriptShaper.runningStatus)

        await d.feed.start()
        try fixture.append([FeedLine.toolResult("r1", toolUseID: "toolu_1", text: "output 1")])
        await d.nudge()

        let update = try #require(await d.events.next(timeout: TestDeadlines.saturatedPass)?.updated)
        let ids = update.items.map(\.id)
        #expect(ids == ["toolu_1"])
        #expect(update.items.first?.toolStatus == TranscriptShaper.okStatus)
        #expect(update.session == d.session)
        #expect(d.events.values.count == 1)
        await d.feed.close()
    }

    /// A call on an older page whose result sits on the page after it, which
    /// is itself an older page, shows the result's status: the feed keeps
    /// every page's results to join into the pages before it.
    @Test func aCallWhoseResultIsOnTheNextOlderPageShowsItsStatus() async throws {
        // Oldest first: a prompt and a call; twenty prompts, the call's result
        // after the first of them; a line longer than the first page's first
        // read (`TranscriptParser.windowInitialChunkBytes`, 64 KiB), so the
        // first page never reads the result; and the first page's four
        // prompts.
        var lines: [[String: Any]] = [
            FeedLine.prompt("x0", "placeholder prompt x0"),
            FeedLine.bash("a0", id: "toolu_0", command: "echo 0"),
            FeedLine.prompt("y1", "placeholder prompt y1"),
            FeedLine.toolResult("r0", toolUseID: "toolu_0", text: "output 0"),
        ]
        lines += (2...20).map { FeedLine.prompt("y\($0)", "placeholder prompt y\($0)") }
        lines.append(FeedLine.toolResult("pad", toolUseID: "toolu_pad", text: String(repeating: "x", count: 100_000)))
        lines += (1...4).map { FeedLine.prompt("z\($0)", "placeholder prompt z\($0)") }
        let fixture = try FeedFixture(lines)
        defer { fixture.remove() }
        let d = DirectFeed(path: fixture.path)

        let first = try await d.feed.open()
        let firstIDs = first.items.map(\.id)
        #expect(firstIDs == ["z1", "z2", "z3", "z4"])
        let firstCursor = try #require(first.cursor)
        let newer = try await d.feed.olderPage(cursor: firstCursor)
        let newerIDs = newer.items.map(\.id)
        let expectedNewerIDs = (1...20).map { "y\($0)" }
        #expect(newerIDs == expectedNewerIDs)
        let newerCursor = try #require(newer.cursor)
        let older = try await d.feed.olderPage(cursor: newerCursor)
        let olderIDs = older.items.map(\.id)
        #expect(olderIDs == ["x0", "toolu_0"])
        #expect(older.reachedStart)
        let status = older.items.first(where: { $0.id == "toolu_0" })?.toolStatus
        #expect(status == TranscriptShaper.okStatus)
        await d.feed.close()
    }

    /// A file rewritten after the first page was read, before the live part
    /// starts, is a new transcript: the first live read resets rather than
    /// reading the new file on from the old page's end.
    @Test func aRewriteBeforeTheFirstLiveReadResets() async throws {
        let fixture = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { fixture.remove() }
        let d = DirectFeed(path: fixture.path)
        _ = try await d.feed.open()
        let size = try fixture.size()

        // Larger than before, so only the bytes before the page's end show
        // the file is not the one the page came from.
        let padding = String(repeating: "r", count: 256)
        try fixture.rewrite((1...6).map { FeedLine.prompt("x\($0)", "placeholder rewritten prompt \($0) \(padding)") })
        let rewrittenSize = try fixture.size()
        #expect(rewrittenSize > size)
        await d.feed.start()

        let reset = try #require(await d.events.next(timeout: TestDeadlines.saturatedPass)?.resetData)
        let resetIDs = reset.page.items.map(\.id)
        #expect(reset.reason == TranscriptFeed.rewriteReason)
        #expect(resetIDs == ["x3", "x4", "x5", "x6"])
        #expect(await d.feed.generation == 1)
        await d.feed.close()
    }

    /// A line with no `uuid`, or a `null` one, gets the same ID live as a
    /// page gives it: `at-<offset>`.
    @Test func aLineWithoutAStringUUIDHasThePagersIDLive() async throws {
        let fixture = try FeedFixture([FeedLine.prompt("m1", "placeholder prompt 1")])
        defer { fixture.remove() }
        let d = DirectFeed(path: fixture.path)
        _ = try await d.feed.open()
        await d.feed.start()
        try await waitUntil("the feed's first read") { await d.feed.readCount >= 1 }

        try fixture.append([
            FeedLine.promptWithoutUUID("placeholder prompt with no uuid"),
            FeedLine.promptWithoutUUID("placeholder prompt with a null uuid", uuid: NSNull()),
        ])
        await d.nudge()
        let appended = try #require(await d.events.next(timeout: TestDeadlines.saturatedPass)?.appended)
        let liveIDs = appended.items.map(\.id)
        let positional = liveIDs.filter { $0.hasPrefix("at-") }

        let build = try #require(TranscriptPager.firstPage(filePath: fixture.path, generation: 0, ctx: ShapingContext()))
        let pageIDs = build.page.items.map(\.id)
        #expect(liveIDs.count == 2)
        #expect(positional == liveIDs)
        #expect(pageIDs == ["m1"] + liveIDs)
        await d.feed.close()
    }

    /// Once the live transcript holds `liveItemLimit` items it starts over,
    /// and a call still running in it updates as before when its result
    /// arrives.
    @Test func aFullLiveTranscriptStartsOverAndItsRunningCallStillResolves() async throws {
        let fixture = try FeedFixture([FeedLine.prompt("m1", "placeholder prompt 1")])
        defer { fixture.remove() }
        let d = DirectFeed(path: fixture.path, liveItemLimit: 3)
        _ = try await d.feed.open()
        await d.feed.start()
        try await waitUntil("the feed's first read") { await d.feed.readCount >= 1 }

        try fixture.append([
            FeedLine.bash("a1", id: "toolu_live", command: "echo live"),
            FeedLine.prompt("m2", "placeholder prompt 2"),
            FeedLine.prompt("m3", "placeholder prompt 3"),
        ])
        await d.nudge()
        let appended = try #require(await d.events.next(timeout: TestDeadlines.saturatedPass)?.appended)
        let appendedIDs = appended.items.map(\.id)
        #expect(appendedIDs == ["toolu_live", "m2", "m3"])
        let call = try #require(appended.items.first)
        #expect(call.toolStatus == TranscriptShaper.runningStatus)
        #expect(await d.feed.liveItemCount == 0)

        try fixture.append([FeedLine.toolResult("r1", toolUseID: "toolu_live", text: "output live")])
        await d.nudge()
        let update = try #require(await d.events.next(timeout: TestDeadlines.saturatedPass)?.updated)
        let expected = PhoneItem(
            id: call.id, kind: call.kind, at: call.at, text: call.text, truncated: call.truncated,
            toolName: call.toolName, target: call.target, toolStatus: TranscriptShaper.okStatus,
            added: call.added, removed: call.removed, agentType: call.agentType, itemCount: call.itemCount,
            sender: call.sender)
        #expect(update.items == [expected])
        #expect(d.events.values.count == 2)
        await d.feed.close()
    }

    /// A file rewritten to the same size with a later date is a new
    /// transcript: the feed starts over in a new generation and sends its
    /// tail in a reset.
    @Test func aSameSizeRewriteResets() async throws {
        let fixture = try FeedFixture([FeedLine.prompt("m1", "first"), FeedLine.prompt("m2", "second")])
        defer { fixture.remove() }
        let d = DirectFeed(path: fixture.path)
        _ = try await d.feed.open()
        await d.feed.start()

        // A read that takes the file's size and date.
        try fixture.append([FeedLine.prompt("m3", "third")])
        await d.nudge()
        let appended = try #require(await d.events.next(timeout: TestDeadlines.saturatedPass)?.appended)
        let appendedIDs = appended.items.map(\.id)
        #expect(appendedIDs == ["m3"])

        let size = try fixture.size()
        try fixture.rewrite([
            FeedLine.prompt("x1", "first"), FeedLine.prompt("x2", "second"), FeedLine.prompt("x3", "third"),
        ])
        let rewrittenSize = try fixture.size()
        #expect(rewrittenSize == size)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: fixture.path)
        await d.nudge()

        let reset = try #require(await d.events.next(timeout: TestDeadlines.saturatedPass)?.resetData)
        let resetIDs = reset.page.items.map(\.id)
        #expect(reset.reason == TranscriptFeed.rewriteReason)
        #expect(resetIDs == ["x1", "x2", "x3"])
        #expect(await d.feed.generation == 1)
        await d.feed.close()
    }

    /// A session whose file does not exist yet opens on an empty page. Once
    /// the file is written, the next delta sends its tail in a reset.
    @Test func aTranscriptWrittenAfterOpenArrivesInAReset() async throws {
        let fixture = try FeedFixture([])
        defer { fixture.remove() }
        let later = fixture.sibling("later.jsonl")
        let d = DirectFeed(path: later)

        let page = try await d.feed.open()
        #expect(page == TranscriptFeed.emptyPage)
        await d.feed.start()
        #expect(await d.feed.isWatching == false)

        try FeedFixture.write([FeedLine.prompt("m1", "placeholder prompt 1")], to: later)
        await d.nudge()

        let reset = try #require(await d.events.next(timeout: TestDeadlines.saturatedPass)?.resetData)
        let ids = reset.page.items.map(\.id)
        #expect(ids == ["m1"])
        #expect(await d.feed.generation == 1)
        let watching = try await Self.eventually("the feed to watch the new file") { await d.feed.isWatching }
        #expect(watching)
        await d.feed.close()
    }

    /// `close()` ends the watcher, and the feed reads and sends nothing more.
    @Test func closeEndsTheWatcher() async throws {
        let fixture = try FeedFixture(FeedLine.conversation(messages: 1))
        defer { fixture.remove() }
        let d = DirectFeed(path: fixture.path)
        _ = try await d.feed.open()
        await d.feed.start()
        #expect(await d.feed.isWatching)
        #expect((Self.watchers(fixture.path) ?? 1) == 1)

        await d.feed.close()

        #expect(await d.feed.isWatching == false)
        let released = try await Self.eventually("the watcher to release the file") {
            (Self.watchers(fixture.path) ?? 0) == 0
        }
        #expect(released)
        try fixture.append([FeedLine.prompt("m2", "placeholder prompt 2")])
        await d.nudge()
        await d.feed.start()
        await settle()
        #expect(d.events.values.isEmpty)
        #expect(await d.feed.isWatching == false)
    }

    /// A page waiting for the read turn when the feed closes reads nothing:
    /// it is stale, though its cursor still names a line of the file. A
    /// device's pages wait in its one open feed's turn, so this keeps a page
    /// queued on a feed that a later open replaced from scanning beside the
    /// new feed's reads.
    @Test func aPageWaitingForTheReadTurnWhenTheFeedClosesReadsNothing() async throws {
        let fixture = try FeedFixture(FeedLine.conversation(messages: 10))
        defer { fixture.remove() }
        let resolver = HeldLaterResolve(path: fixture.path)
        defer { resolver.gate.open() }
        let terminalID = UUID()
        let feed = TranscriptFeed(
            session: .local(terminalID: terminalID), showDetails: false,
            source: .local(terminalID: terminalID, resolvePath: { await resolver.resolve() }),
            emit: { _ in },
            clock: EventDrivenTestClock())
        let page = try await feed.open()
        let cursor = try #require(page.cursor)
        // The worker's first read resolves the path again and holds the read
        // turn until the gate opens or the worker is cancelled.
        await feed.start()
        try await waitUntil("the worker's read to hold the read turn") { resolver.calls >= 2 }
        let pageTask = Task { try await feed.olderPage(cursor: cursor) }
        try await waitUntil("the page to wait for the read turn") { await feed.readTurnWaiterCount == 1 }

        await feed.close()
        resolver.gate.open()

        await #expect(throws: PhoneAppError(code: .staleCursor, message: TranscriptPager.staleCursorMessage)) {
            _ = try await pageTask.value
        }
    }

    // MARK: - Frames and the bounded index

    /// Items go out in order, as few to a frame as fit the budget, and an
    /// item too large for any frame is left out.
    @Test func framesSplitByTheBudget() throws {
        let session = PhoneSessionRef.local(terminalID: UUID())
        let encoder = PhoneAppCoding.makeEncoder()
        let empty = try encoder.encode(TranscriptItemsData(session: session, items: [])).count
        let items = (1...5).map { Self.item("i\($0)") }
        let size = try encoder.encode(items[0]).count
        // Two items and the comma between them, exactly.
        let budget = empty + 2 * size + 1

        let frames = TranscriptFeed.frames(items, session: session, budget: budget)

        let counts = frames.map(\.items.count)
        let ids = frames.flatMap { $0.items.map(\.id) }
        #expect(counts == [2, 2, 1])
        #expect(ids == ["i1", "i2", "i3", "i4", "i5"])
        for frame in frames {
            let bytes = try encoder.encode(frame).count
            #expect(bytes <= budget)
        }

        let huge = Self.item("huge", text: String(repeating: "x", count: 2 * size))
        let kept = TranscriptFeed.frames([items[0], huge, items[1]], session: session, budget: budget)
        let keptIDs = kept.flatMap { $0.items.map(\.id) }
        #expect(keptIDs == ["i1", "i2"])
        #expect(TranscriptFeed.frames([], session: session, budget: budget).isEmpty)
    }

    /// Past its limit the index drops the entry added first. Updating a key
    /// keeps its place; removing and adding it again puts it last.
    @Test func theIndexDropsTheOldestAdded() {
        var index = TranscriptFeedIndex<Int>(limit: 3)
        for (value, key) in ["a", "b", "c", "d"].enumerated() {
            index.set(value, for: key)
        }
        #expect(index.dictionary == ["b": 1, "c": 2, "d": 3])

        index.set(10, for: "b")
        index.set(4, for: "e")
        #expect(index.dictionary == ["c": 2, "d": 3, "e": 4])

        let removed = index.remove("c")
        #expect(removed == 2)
        index.set(5, for: "f")
        #expect(index.dictionary == ["d": 3, "e": 4, "f": 5])

        index.remove("d")
        index.set(6, for: "d")
        index.set(7, for: "g")
        #expect(index.dictionary == ["f": 5, "d": 6, "g": 7])
        #expect(index["f"] == 5)
        #expect(index.count == 3)

        index.removeAll()
        #expect(index.count == 0)
    }

    /// Many keys through a small index keep exactly the newest ones.
    @Test func theIndexStaysBoundedOverManyKeys() {
        var index = TranscriptFeedIndex<Int>(limit: 2)
        for n in 0...1_000 {
            index.set(n, for: "k\(n)")
            if n % 3 == 0 {
                index.remove("k\(n)")
            }
        }
        #expect(index.dictionary == ["k998": 998, "k1000": 1_000])
    }

    // MARK: - Through the service

    /// A Codex tab's transcript is not served yet, and a shell tab has none.
    @Test func codexOpenIsUnavailable() async throws {
        let h = try await PhoneServiceHarness.make()
        let codex = try await h.seedTerminal(kind: .codex)
        let shell = try await h.seedTerminal(kind: .shell)
        let outbox = await h.connect()

        let codexReply = try await Self.ask(
            h, .transcriptOpen, id: "codex", Self.openParams(.local(terminalID: codex.id)), on: outbox)
        let shellReply = try await Self.ask(
            h, .transcriptOpen, id: "shell", Self.openParams(.local(terminalID: shell.id)), on: outbox)
        let missingReply = try await Self.ask(
            h, .transcriptOpen, id: "missing", Self.openParams(.local(terminalID: UUID())), on: outbox)

        #expect(try Self.error(codexReply)?.code == .unavailable)
        #expect(try Self.error(codexReply)?.message == PhoneSessionStatus.codexTranscriptReason)
        #expect(try Self.error(shellReply)?.code == .unsupported)
        #expect(try Self.error(missingReply)?.code == .notFound)
        #expect(await h.service.transcriptFeed(for: h.peer.deviceID) == nil)
    }

    /// `transcript.page` needs an open feed for the same session.
    @Test func pageWithoutOpenIsNotOpen() async throws {
        let h = try await PhoneServiceHarness.make()
        let fixture = try FeedFixture(FeedLine.conversation(messages: 10))
        defer { fixture.remove() }
        let terminal = try await Self.seedTerminal(h, path: fixture.path)
        let session = PhoneSessionRef.local(terminalID: terminal.id)
        let outbox = await h.connect()

        let before = try await Self.ask(
            h, .transcriptPage, id: "before", TranscriptPageParams(session: session, cursor: "0:0:0000000000000000"),
            on: outbox)
        #expect(try Self.error(before)?.code == .notOpen)

        let opened = try await Self.open(h, session, id: "open", on: outbox)
        let cursor = try #require(opened.page?.cursor)
        let other = try await Self.ask(
            h, .transcriptPage, id: "other",
            TranscriptPageParams(session: .local(terminalID: UUID()), cursor: cursor), on: outbox)
        #expect(try Self.error(other)?.code == .notOpen)

        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// The page before the first page's cursor holds the older lines.
    @Test func pageReadsTheLinesBeforeTheFirstPage() async throws {
        let h = try await PhoneServiceHarness.make()
        let fixture = try FeedFixture(FeedLine.conversation(messages: 10))
        defer { fixture.remove() }
        let s = try await Self.openLive(h, path: fixture.path)
        let firstIDs = s.opened.page?.items.map(\.id) ?? []
        #expect(firstIDs == ["m7", "toolu_7", "m8", "toolu_8", "m9", "toolu_9", "m10", "toolu_10"])
        let cursor = try #require(s.opened.page?.cursor)

        let bytes = try await Self.ask(
            h, .transcriptPage, id: "older", TranscriptPageParams(session: s.session, cursor: cursor), on: s.outbox)
        let older = try JSONDecoder().decode(PhoneReplyEnvelope<TranscriptPage>.self, from: bytes).result

        let olderIDs = older.items.map(\.id)
        let expectedIDs = (1...6).flatMap { ["m\($0)", "toolu_\($0)"] }
        #expect(olderIDs == expectedIDs)
        #expect(older.reachedStart)
        let statuses = Set(older.items.compactMap(\.toolStatus))
        #expect(statuses == [TranscriptShaper.okStatus])
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// The session's file changes (`/clear` starts a new session): the feed
    /// sends the new file's tail in a `rollover` reset, then reads and
    /// watches the new file in place of the old one.
    @Test func aRolloverSendsResetWithTheNewTail() async throws {
        let h = try await PhoneServiceHarness.make()
        let fixture = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { fixture.remove() }
        let s = try await Self.openLive(h, path: fixture.path)

        let rolled = fixture.sibling("rolled.jsonl")
        try FeedFixture.write([FeedLine.prompt("n1", "placeholder prompt after the rollover")], to: rolled)
        try await h.db.terminals.updateSession(id: s.terminal.id, sessionID: "acme-session-2", transcriptPath: rolled)
        h.subscriptions.broadcast(delta: .terminalSessionUpdated(TerminalSessionDelta(
            terminalID: s.terminal.id, worktreeID: s.terminal.worktreeID,
            sessionID: "acme-session-2", transcriptPath: rolled)))

        try await waitUntil("the rollover reset") {
            ((try? Self.events(.transcriptReset, TranscriptResetData.self, in: s.outbox)) ?? []).count == 1
        }
        let reset = try #require(try Self.events(.transcriptReset, TranscriptResetData.self, in: s.outbox).first)
        let resetIDs = reset.data.page.items.map(\.id)
        #expect(reset.data.reason == TranscriptFeed.rolloverReason)
        #expect(reset.data.session == s.session)
        #expect(resetIDs == ["n1"])
        #expect(await s.feed.transcriptPath == rolled)
        #expect(await s.feed.generation == 1)

        try FeedFixture.append([FeedLine.prompt("n2", "placeholder prompt 2")], to: rolled)
        h.subscriptions.broadcast(delta: Self.activity(s.terminal))
        try await waitUntil("the append to the new file") { Self.appendedIDs(in: s.outbox).contains("n2") }
        let appended = Self.appendedIDs(in: s.outbox)
        #expect(appended == ["n2"])
        let moved = try await Self.eventually("the watcher to move to the new file") {
            (Self.watchers(fixture.path) ?? 0) == 0 && (Self.watchers(rolled) ?? 1) == 1
        }
        #expect(moved)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// Opening a second session replaces the first: its feed, watcher, relay
    /// and prompt feed stop, and only the second session's lines reach the
    /// phone.
    @Test func openingAnotherSessionClosesTheFirst() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let first = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { first.remove() }
        let second = try FeedFixture([FeedLine.prompt("n1", "placeholder prompt 1")])
        defer { second.remove() }
        let s = try await Self.openLive(h, path: first.path)
        let other = try await Self.seedTerminal(h, path: second.path)
        let otherSession = PhoneSessionRef.local(terminalID: other.id)

        let opened = try await Self.open(h, otherSession, id: "open-second", on: s.outbox)
        let openedIDs = opened.page?.items.map(\.id) ?? []
        #expect(openedIDs == ["n1"])
        let otherFeed = try #require(await h.service.transcriptFeed(for: deviceID))
        #expect(otherFeed !== s.feed)
        try await waitUntil("the first feed to stop and the second to start") {
            let firstWatching = await s.feed.isWatching
            let secondWatching = await otherFeed.isWatching
            return !firstWatching && secondWatching && h.subscriptions.subscriberCount == s.baseline + 2
        }
        #expect(await h.service.transcriptSession(for: deviceID) == otherSession)
        #expect(await h.service.promptsSession(for: deviceID) == otherSession)
        let moved = try await Self.eventually("the watcher to move to the second file") {
            (Self.watchers(first.path) ?? 0) == 0 && (Self.watchers(second.path) ?? 1) == 1
        }
        #expect(moved)

        try first.append([FeedLine.prompt("m3", "placeholder prompt 3")])
        h.subscriptions.broadcast(delta: Self.activity(s.terminal))
        try second.append([FeedLine.prompt("n2", "placeholder prompt 2")])
        h.subscriptions.broadcast(delta: Self.activity(other))
        try await waitUntil("the second session's append") { Self.appendedIDs(in: s.outbox).contains("n2") }
        let appended = Self.appendedIDs(in: s.outbox)
        #expect(appended == ["n2"])
        await h.service.phoneRevoked(deviceID: deviceID)
        #expect(h.subscriptions.subscriberCount == 0)
    }

    /// A transcript opened before `sessions.subscribe` gets its reply at
    /// once, and its live part waits for the connection to go live. A line
    /// appended in between reaches the phone after the subscribe reply.
    @Test func openBeforeSubscribeLosesNoAppend() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let fixture = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { fixture.remove() }
        let terminal = try await Self.seedTerminal(h, path: fixture.path)
        let session = PhoneSessionRef.local(terminalID: terminal.id)
        let outbox = await h.connect()

        let opened = try await Self.open(h, session, id: "open", on: outbox)
        let openedIDs = opened.page?.items.map(\.id) ?? []
        #expect(openedIDs == ["m1", "toolu_1", "m2", "toolu_2"])
        let feed = try #require(await h.service.transcriptFeed(for: deviceID))
        #expect(await feed.isWatching == false)
        try fixture.append([FeedLine.prompt("m3", "placeholder prompt 3")])

        // The subscribe reply is the next body: nothing went out before it.
        let (subscribed, bytes) = try await h.request(
            .sessionsSubscribe, id: "subscribe", params: SessionsSubscribeParams(stream: nil, sinceSeq: nil), on: outbox)
        #expect(subscribed.error == nil)
        let subscribeSeq = try JSONDecoder().decode(PhoneReplyEnvelope<SessionsSubscribeResult>.self, from: bytes).result.seq

        try await waitUntil("the append after the subscribe reply") { Self.appendedIDs(in: outbox) == ["m3"] }
        let replyIndex = try #require(Self.replyIndices("subscribe", in: outbox).first)
        let appends = try Self.events(.transcriptAppend, TranscriptItemsData.self, in: outbox)
        let appendIndex = try #require(Self.eventIndices(.transcriptAppend, in: outbox).first)
        let appendSeq = try #require(appends.first?.seq)
        #expect(appendIndex > replyIndex)
        #expect(appendSeq > subscribeSeq)
        #expect(await h.service.promptsSession(for: deviceID) == session)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A resent `transcript.open`, after the first one's reply, opens again
    /// in place of the first: one feed, one watcher, one relay and one prompt
    /// feed. `transcript.close` stops them all.
    @Test func aResentOpenLeaksNoWatcherOrSubscriber() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let fixture = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { fixture.remove() }
        let s = try await Self.openLive(h, path: fixture.path, id: "open-once")

        let resent = try await Self.open(h, s.session, id: "open-once", on: s.outbox)
        #expect(resent.page != nil)
        #expect(Self.replyIndices("open-once", in: s.outbox).count == 2)
        let replacement = try #require(await h.service.transcriptFeed(for: deviceID))
        #expect(replacement !== s.feed)
        try await waitUntil("one feed, one relay, one prompt feed") {
            let firstWatching = await s.feed.isWatching
            let replacementWatching = await replacement.isWatching
            return !firstWatching && replacementWatching && h.subscriptions.subscriberCount == s.baseline + 2
        }
        let oneWatcher = try await Self.eventually("one watcher on the file") {
            (Self.watchers(fixture.path) ?? 1) == 1
        }
        #expect(oneWatcher)

        let closed = try await Self.ask(h, .transcriptClose, id: "close", PhoneEmpty(), on: s.outbox)
        #expect(try Self.error(closed) == nil)
        try await waitUntil("the close to stop the feed, the relay and the prompt feed") {
            let watching = await replacement.isWatching
            return !watching && h.subscriptions.subscriberCount == s.baseline
        }
        let released = try await Self.eventually("the watcher to release the file") {
            (Self.watchers(fixture.path) ?? 0) == 0
        }
        #expect(released)
        #expect(await h.service.transcriptSession(for: deviceID) == nil)
        #expect(await h.service.promptsSession(for: deviceID) == nil)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// An open sent after another takes effect even when it finishes first:
    /// the earlier open, finishing late, installs nothing, is refused, and
    /// starts no watcher, relay or prompt feed.
    @Test func anOpenThatFinishesAfterALaterOneIsDiscarded() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let first = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { first.remove() }
        let second = try FeedFixture([FeedLine.prompt("n1", "placeholder prompt 1")])
        defer { second.remove() }
        let firstTerminal = try await Self.seedTerminal(h, path: first.path)
        let secondTerminal = try await Self.seedTerminal(h, path: second.path)
        let firstSession = PhoneSessionRef.local(terminalID: firstTerminal.id)
        let secondSession = PhoneSessionRef.local(terminalID: secondTerminal.id)
        let gate = PhoneTestGate()
        await Self.holdOpens(of: firstSession, on: gate, in: h)
        let outbox = try await Self.liveConnection(h)
        let baseline = h.subscriptions.subscriberCount

        let firstBody = try PhoneTestRequests.body(.transcriptOpen, id: "open-first", params: Self.openParams(firstSession))
        await h.service.handleAppMessage(firstBody, from: h.peer)
        let opened = try await Self.open(h, secondSession, id: "open-second", on: outbox)
        #expect(opened.page != nil)
        let secondFeed = try #require(await h.service.transcriptFeed(for: deviceID))
        try await waitUntil("the second feed's live part to start") {
            let watching = await secondFeed.isWatching
            return watching && h.subscriptions.subscriberCount == baseline + 2
        }

        gate.open()
        try await waitUntil("the first open's reply") { !Self.replyIndices("open-first", in: outbox).isEmpty }
        let firstReply = outbox.bodies[Self.replyIndices("open-first", in: outbox)[0]]
        #expect(try Self.error(firstReply)?.message == PhoneAppService.transcriptChangedReason)
        let current = await h.service.transcriptFeed(for: deviceID)
        #expect(current === secondFeed)
        #expect(await h.service.transcriptSession(for: deviceID) == secondSession)
        #expect(await h.service.promptsSession(for: deviceID) == secondSession)
        #expect(h.subscriptions.subscriberCount == baseline + 2)
        #expect((Self.watchers(first.path) ?? 0) == 0)

        try first.append([FeedLine.prompt("m3", "placeholder prompt 3")])
        h.subscriptions.broadcast(delta: Self.activity(firstTerminal))
        try second.append([FeedLine.prompt("n2", "placeholder prompt 2")])
        h.subscriptions.broadcast(delta: Self.activity(secondTerminal))
        try await waitUntil("the second session's append") { Self.appendedIDs(in: outbox).contains("n2") }
        let appended = Self.appendedIDs(in: outbox)
        #expect(appended == ["n2"])
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A close sent after an open wins even when the open finishes later: no
    /// feed is left open, and nothing the open built runs.
    @Test func aCloseSentAfterAnOpenInProgressLeavesNothingOpen() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let fixture = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { fixture.remove() }
        let terminal = try await Self.seedTerminal(h, path: fixture.path)
        let session = PhoneSessionRef.local(terminalID: terminal.id)
        let gate = PhoneTestGate()
        await Self.holdOpens(of: session, on: gate, in: h)
        let outbox = try await Self.liveConnection(h)
        let baseline = h.subscriptions.subscriberCount

        let openBody = try PhoneTestRequests.body(.transcriptOpen, id: "open", params: Self.openParams(session))
        await h.service.handleAppMessage(openBody, from: h.peer)
        let closed = try await Self.ask(h, .transcriptClose, id: "close", PhoneEmpty(), on: outbox)
        #expect(try Self.error(closed) == nil)

        gate.open()
        try await waitUntil("the open's reply") { !Self.replyIndices("open", in: outbox).isEmpty }
        let openReply = outbox.bodies[Self.replyIndices("open", in: outbox)[0]]
        #expect(try Self.error(openReply)?.message == PhoneAppService.transcriptChangedReason)
        #expect(await h.service.transcriptFeed(for: deviceID) == nil)
        #expect(await h.service.promptsSession(for: deviceID) == nil)
        #expect(h.subscriptions.subscriberCount == baseline)
        #expect((Self.watchers(fixture.path) ?? 0) == 0)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// An open whose phone disconnects before its reply is queued installs
    /// nothing and closes the feed it built, so neither the feed nor its
    /// follower outlives the request. The stand-in handler builds and opens
    /// the feed itself, so the test holds it, and replies the way
    /// `transcriptOpen` does.
    @Test func anOpenWhosePhoneLeftBeforeItsReplyClosesItsFeed() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let terminalID = UUID()
        let session = PhoneSessionRef.local(terminalID: terminalID)
        let feed = TranscriptFeed(
            session: session, showDetails: false, source: .local(terminalID: terminalID, resolvePath: { nil }),
            emit: { _ in }, clock: h.clock)
        let page = try await feed.open()
        let gate = PhoneTestGate()
        await h.service.setHandler({ body, context in
            let params = try PhoneAppCoding.params(TranscriptOpenParams.self, from: body)
            await gate.wait()
            return PhoneAppService.openedTranscriptReply(
                params, feed: feed, token: 1, stamp: context.transcriptStamp ?? 0, page: page,
                requestID: context.requestID, deviceID: context.peer.deviceID)
        }, for: .transcriptOpen)
        let outbox = try await Self.liveConnection(h)

        let openBody = try PhoneTestRequests.body(.transcriptOpen, id: "open", params: Self.openParams(session))
        await h.service.handleAppMessage(openBody, from: h.peer)
        await h.service.phoneDisconnected(h.peer)
        gate.open()

        try await waitUntil("the dropped open to close its feed") { await feed.isClosed }
        #expect(Self.replyIndices("open", in: outbox).isEmpty)
        #expect(await h.service.transcriptFeed(for: deviceID) == nil)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// The phone comes back inside the grace, its `sessions.subscribe`
    /// replays the stream, and its `transcript.open` with `resume` keeps the
    /// feed: the reply has no page, and the line appended while it was away
    /// came in the replay.
    @Test func resumeKeepsTheFeedAndReplays() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let fixture = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { fixture.remove() }
        let s = try await Self.openLive(h, path: fixture.path)
        try await waitUntil("the prompt feed's first event") {
            ((try? Self.events(.promptChanged, PromptChangedData.self, in: s.outbox)) ?? []).count == 1
        }
        let streamID = try #require(await h.service.streamID(for: deviceID))
        let seen = Self.lastSeqSeen(in: s.outbox)

        await h.service.phoneDisconnected(h.peer)
        try fixture.append([FeedLine.prompt("m3", "placeholder prompt 3")])
        let before = try #require(await h.service.lastSeq(for: deviceID))
        h.subscriptions.broadcast(delta: Self.activity(s.terminal))
        try await waitUntil("the append while the phone is away") {
            (await h.service.lastSeq(for: deviceID) ?? 0) > before
        }

        let outbox = await h.connect()
        let (subscribed, bytes) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: streamID, sinceSeq: seen), on: outbox)
        #expect(subscribed.error == nil)
        let result = try JSONDecoder().decode(PhoneReplyEnvelope<SessionsSubscribeResult>.self, from: bytes).result
        #expect(result.replayed)
        try await waitUntil("the replayed append") { Self.appendedIDs(in: outbox) == ["m3"] }

        let resumed = try await Self.open(h, s.session, id: "resume", resume: true, on: outbox)
        #expect(resumed.resumed)
        #expect(resumed.page == nil)
        #expect(resumed.seq == result.seq)
        let kept = await h.service.transcriptFeed(for: deviceID)
        #expect(kept === s.feed)
        #expect(await s.feed.isWatching)
        let appended = Self.appendedIDs(in: outbox)
        #expect(appended == ["m3"])
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// The prompt feed runs on while the phone is away, so the replay brings
    /// the set up to date, and after the resumed open the feed carries on.
    @Test func aResumedOpenLeavesTheCurrentPromptSet() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let fixture = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { fixture.remove() }
        let s = try await Self.openLive(h, path: fixture.path)
        try await waitUntil("the prompt feed's first event") {
            ((try? Self.events(.promptChanged, PromptChangedData.self, in: s.outbox)) ?? []).count == 1
        }
        let streamID = try #require(await h.service.streamID(for: deviceID))
        let seen = Self.lastSeqSeen(in: s.outbox)

        await h.service.phoneDisconnected(h.peer)
        await h.pendingPrompts.open(
            terminalID: s.terminal.id, sessionID: nil, toolUseID: "toolu-9", toolName: "Bash",
            toolInputJSON: #"{"command":"ls -la"}"#, suggestionsJSON: nil)
        let before = try #require(await h.service.lastSeq(for: deviceID))
        await h.subscriptions.broadcastPendingPrompts(terminalID: s.terminal.id, from: h.pendingPrompts)
        try await waitUntil("the prompt change while the phone is away") {
            (await h.service.lastSeq(for: deviceID) ?? 0) > before
        }

        let outbox = await h.connect()
        let (subscribed, _) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: streamID, sinceSeq: seen), on: outbox)
        #expect(subscribed.error == nil)
        let resumed = try await Self.open(h, s.session, id: "resume", resume: true, on: outbox)
        #expect(resumed.resumed)

        let replayed = try Self.events(.promptChanged, PromptChangedData.self, in: outbox)
        let replayedIDs = replayed.first?.data.prompts.map(\.id)
        #expect(replayed.count == 1)
        #expect(replayedIDs == ["toolu-9"])
        #expect(await h.service.promptsSession(for: deviceID) == s.session)

        await h.pendingPrompts.closed(terminalID: s.terminal.id, toolUseID: "toolu-9")
        await h.subscriptions.broadcastPendingPrompts(terminalID: s.terminal.id, from: h.pendingPrompts)
        try await waitUntil("the prompt change after the resume") {
            ((try? Self.events(.promptChanged, PromptChangedData.self, in: outbox)) ?? []).count == 2
        }
        let after = try Self.events(.promptChanged, PromptChangedData.self, in: outbox)[1].data
        #expect(after.prompts.isEmpty)
        #expect(after.resolved == [PhonePromptResolution(promptID: "toolu-9", answeredBy: .laptop, deviceID: nil)])
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A resumed open that arrives before its connection's
    /// `sessions.subscribe` reply waits for it: the phone gets the subscribe
    /// reply and the replayed events first, then `{resumed: true}` with the
    /// subscribe reply's `seq`.
    @Test func aResumeBeforeTheSubscribeReplyFollowsItsReplay() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let fixture = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { fixture.remove() }
        let s = try await Self.openLive(h, path: fixture.path)
        let streamID = try #require(await h.service.streamID(for: deviceID))
        let seen = Self.lastSeqSeen(in: s.outbox)

        await h.service.phoneDisconnected(h.peer)
        try fixture.append([FeedLine.prompt("m3", "placeholder prompt 3")])
        let before = try #require(await h.service.lastSeq(for: deviceID))
        h.subscriptions.broadcast(delta: Self.activity(s.terminal))
        try await waitUntil("the append while the phone is away") {
            (await h.service.lastSeq(for: deviceID) ?? 0) > before
        }

        let gate = PhoneTestGate()
        await Self.holdSubscribes(on: gate, in: h)
        let outbox = await h.connect()
        let subscribeBody = try PhoneTestRequests.body(
            .sessionsSubscribe, id: "subscribe", params: SessionsSubscribeParams(stream: streamID, sinceSeq: seen))
        await h.service.handleAppMessage(subscribeBody, from: h.peer)
        let resumeBody = try PhoneTestRequests.body(
            .transcriptOpen, id: "resume", params: Self.openParams(s.session, resume: true))
        await h.service.handleAppMessage(resumeBody, from: h.peer)
        try await waitUntil("the resumed open to wait for the subscribe reply") {
            await h.service.hasPendingTranscriptResume(for: deviceID)
        }
        #expect(outbox.bodies.isEmpty)

        gate.open()
        try await waitUntil("the resumed open's reply") { !Self.replyIndices("resume", in: outbox).isEmpty }
        let bodies = outbox.bodies
        let subscribeIndex = try #require(Self.replyIndices("subscribe", in: outbox).first)
        let appendIndex = try #require(Self.eventIndices(.transcriptAppend, in: outbox).first)
        let resumeIndex = try #require(Self.replyIndices("resume", in: outbox).first)
        #expect(subscribeIndex < appendIndex)
        #expect(appendIndex < resumeIndex)
        let subscribed = try JSONDecoder().decode(
            PhoneReplyEnvelope<SessionsSubscribeResult>.self, from: bodies[subscribeIndex]).result
        let resumed = try JSONDecoder().decode(
            PhoneReplyEnvelope<TranscriptOpenResult>.self, from: bodies[resumeIndex]).result
        #expect(subscribed.replayed)
        #expect(resumed.resumed)
        #expect(resumed.seq == subscribed.seq)
        let kept = await h.service.transcriptFeed(for: deviceID)
        #expect(kept === s.feed)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A resume needs a sessions publisher to carry the stream on. A phone
    /// that opened a transcript but never subscribed gets a fresh open, even
    /// when its reconnect's `sessions.subscribe` decided to replay.
    @Test func aResumeWithNoSessionsPublisherOpensAfresh() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let fixture = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { fixture.remove() }
        let terminal = try await Self.seedTerminal(h, path: fixture.path)
        let session = PhoneSessionRef.local(terminalID: terminal.id)
        let first = await h.connect()
        let opened = try await Self.open(h, session, id: "open", on: first)
        #expect(!opened.resumed)
        let firstFeed = try #require(await h.service.transcriptFeed(for: deviceID))
        let streamID = try #require(await h.service.streamID(for: deviceID))
        let seq = try #require(await h.service.lastSeq(for: deviceID))
        #expect(await h.service.sessionsPublisher(for: deviceID) == nil)

        await h.service.phoneDisconnected(h.peer)
        let gate = PhoneTestGate()
        await Self.holdSubscribes(on: gate, in: h)
        let outbox = await h.connect()
        let subscribeBody = try PhoneTestRequests.body(
            .sessionsSubscribe, id: "subscribe", params: SessionsSubscribeParams(stream: streamID, sinceSeq: seq))
        await h.service.handleAppMessage(subscribeBody, from: h.peer)
        let decision = await h.service.resumeDecision(for: deviceID)
        #expect(decision == PhoneResumeDecision.replay)

        let reopened = try await Self.open(h, session, id: "resume", resume: true, on: outbox)
        #expect(!reopened.resumed)
        #expect(reopened.page != nil)
        let fresh = await h.service.transcriptFeed(for: deviceID)
        #expect(fresh != nil)
        #expect(fresh !== firstFeed)

        gate.open()
        try await waitUntil("the subscribe reply") { !Self.replyIndices("subscribe", in: outbox).isEmpty }
        let subscribeIndex = Self.replyIndices("subscribe", in: outbox)[0]
        let subscribed = try JSONDecoder().decode(
            PhoneReplyEnvelope<SessionsSubscribeResult>.self, from: outbox.bodies[subscribeIndex]).result
        #expect(!subscribed.replayed)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// A cursor from before a reset names the old generation, so
    /// `transcript.page` refuses it as `stale_cursor`, even where the new
    /// file holds the same line at the same offset.
    @Test func aCursorFromBeforeAResetIsStale() async throws {
        let h = try await PhoneServiceHarness.make()
        let fixture = try FeedFixture(FeedLine.conversation(messages: 10))
        defer { fixture.remove() }
        let s = try await Self.openLive(h, path: fixture.path)
        let cursor = try #require(s.opened.page?.cursor)

        let rolled = fixture.sibling("rolled.jsonl")
        try FeedFixture.write(FeedLine.conversation(messages: 10), to: rolled)
        try await h.db.terminals.updateSession(id: s.terminal.id, sessionID: "acme-session-2", transcriptPath: rolled)
        h.subscriptions.broadcast(delta: .terminalSessionUpdated(TerminalSessionDelta(
            terminalID: s.terminal.id, worktreeID: s.terminal.worktreeID,
            sessionID: "acme-session-2", transcriptPath: rolled)))
        try await waitUntil("the rollover reset") {
            ((try? Self.events(.transcriptReset, TranscriptResetData.self, in: s.outbox)) ?? []).count == 1
        }

        let reply = try await Self.ask(
            h, .transcriptPage, id: "stale", TranscriptPageParams(session: s.session, cursor: cursor), on: s.outbox)
        #expect(try Self.error(reply)?.code == .staleCursor)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// When the grace runs out the feed stops with the rest of the phone's
    /// state, and a later `transcript.open` with `resume` opens afresh from
    /// the tail.
    @Test func resumeAfterGraceExpiryReopensFromTheTail() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let fixture = try FeedFixture(FeedLine.conversation(messages: 2))
        defer { fixture.remove() }
        let s = try await Self.openLive(h, path: fixture.path)
        let streamID = try #require(await h.service.streamID(for: deviceID))
        let seen = Self.lastSeqSeen(in: s.outbox)

        await h.service.phoneDisconnected(h.peer)
        // The sessions publisher's catch-up window and the grace.
        try await h.clock.requireSleepersArmed(count: 2, timeout: TestDeadlines.saturatedPass)
        await h.clock.advance(by: PhoneAppConstants.parseStateGrace)
        try await waitUntil("the grace to drop the phone's state and stop the feed") {
            let gone = await h.service.streamID(for: deviceID) == nil
            let watching = await s.feed.isWatching
            return gone && !watching && h.subscriptions.subscriberCount == 0
        }
        let released = try await Self.eventually("the watcher to release the file") {
            (Self.watchers(fixture.path) ?? 0) == 0
        }
        #expect(released)

        let outbox = await h.connect()
        let (subscribed, bytes) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: streamID, sinceSeq: seen), on: outbox)
        #expect(subscribed.error == nil)
        let result = try JSONDecoder().decode(PhoneReplyEnvelope<SessionsSubscribeResult>.self, from: bytes).result
        #expect(!result.replayed)
        let reopened = try await Self.open(h, s.session, id: "resume", resume: true, on: outbox)
        #expect(!reopened.resumed)
        let reopenedIDs = reopened.page?.items.map(\.id) ?? []
        #expect(reopenedIDs == ["m1", "toolu_1", "m2", "toolu_2"])
        let fresh = await h.service.transcriptFeed(for: deviceID)
        #expect(fresh != nil)
        #expect(fresh !== s.feed)
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    // MARK: - Helpers

    /// The fields every app body has, so a test can tell replies from events.
    private struct BodyHead: Decodable {
        let kind: String
        let event: String?
        let requestID: String?
        let seq: Int?
    }

    /// The `seq` of a reply's result, which the subscribe and open replies
    /// both carry.
    private struct SeqResult: Codable {
        let seq: Int?
    }

    private struct OpenRefused: Error, CustomStringConvertible {
        let error: PhoneAppError
        var description: String { "transcript.open was refused: \(error.code.rawValue): \(error.message)" }
    }

    /// A live connection with a session open and its live part started: the
    /// feed watches the file, and the feed's relay and the prompt feed are
    /// subscribed beside the sessions publisher.
    private struct OpenSession {
        let terminal: TBDShared.Terminal
        let session: PhoneSessionRef
        let outbox: CapturingOutbox
        let opened: TranscriptOpenResult
        let feed: TranscriptFeed
        /// The subscriber count before the open: the sessions publisher.
        let baseline: Int
    }

    private static func openLive(
        _ h: PhoneServiceHarness, path: String, id: String = "open"
    ) async throws -> OpenSession {
        let terminal = try await seedTerminal(h, path: path)
        let session = PhoneSessionRef.local(terminalID: terminal.id)
        let outbox = try await liveConnection(h)
        let baseline = h.subscriptions.subscriberCount
        let opened = try await open(h, session, id: id, on: outbox)
        let feed = try #require(await h.service.transcriptFeed(for: h.peer.deviceID))
        try await waitUntil("the feed's live part to start") {
            let watching = await feed.isWatching
            return watching && h.subscriptions.subscriberCount == baseline + 2
        }
        return OpenSession(
            terminal: terminal, session: session, outbox: outbox, opened: opened, feed: feed, baseline: baseline)
    }

    /// A Claude terminal whose row names `path` as its transcript.
    private static func seedTerminal(_ h: PhoneServiceHarness, path: String) async throws -> TBDShared.Terminal {
        let terminal = try await h.seedTerminal()
        try await h.db.terminals.updateSession(id: terminal.id, sessionID: "acme-session", transcriptPath: path)
        return terminal
    }

    /// Connects the phone and makes the connection live with a fresh
    /// `sessions.subscribe`, returning once the sessions publisher holds its
    /// subscriber.
    private static func liveConnection(_ h: PhoneServiceHarness) async throws -> CapturingOutbox {
        let outbox = await h.connect()
        let (reply, _) = try await h.request(
            .sessionsSubscribe, params: SessionsSubscribeParams(stream: nil, sinceSeq: nil), on: outbox)
        #expect(reply.error == nil)
        let deviceID = h.peer.deviceID
        try await waitUntil("the sessions publisher to subscribe") {
            await h.service.sessionsPublisher(for: deviceID)?.isSubscribed == true
        }
        return outbox
    }

    /// Holds every `transcript.open` of `session` on `gate` before its
    /// handler runs, so a request sent after it can finish first.
    private static func holdOpens(of session: PhoneSessionRef, on gate: PhoneTestGate, in h: PhoneServiceHarness) async {
        let service = h.service
        await service.setHandler({ body, context in
            let params = try PhoneAppCoding.params(TranscriptOpenParams.self, from: body)
            if params.session == session {
                await gate.wait()
            }
            return try await service.transcriptOpen(params, context)
        }, for: .transcriptOpen)
    }

    /// Holds every `sessions.subscribe` on `gate` before its handler runs.
    /// The resume decision is made as the request arrives, so it is made at
    /// once.
    private static func holdSubscribes(on gate: PhoneTestGate, in h: PhoneServiceHarness) async {
        let service = h.service
        await service.setHandler({ body, context in
            await gate.wait()
            let params = try PhoneAppCoding.params(SessionsSubscribeParams.self, from: body)
            return try await service.sessionsSubscribe(params, context)
        }, for: .sessionsSubscribe)
    }

    private static func openParams(_ session: PhoneSessionRef, resume: Bool = false) -> TranscriptOpenParams {
        TranscriptOpenParams(session: session, showDetails: false, resume: resume)
    }

    /// Sends `transcript.open` and returns its result, or throws the error
    /// it replied.
    private static func open(
        _ h: PhoneServiceHarness, _ session: PhoneSessionRef, id: String, resume: Bool = false,
        on outbox: CapturingOutbox
    ) async throws -> TranscriptOpenResult {
        let bytes = try await ask(h, .transcriptOpen, id: id, openParams(session, resume: resume), on: outbox)
        if let error = try self.error(bytes) {
            throw OpenRefused(error: error)
        }
        return try JSONDecoder().decode(PhoneReplyEnvelope<TranscriptOpenResult>.self, from: bytes).result
    }

    /// Sends one request and returns its reply, found by its request ID
    /// among the events around it. A repeated ID returns the newest reply.
    private static func ask<P: Codable>(
        _ h: PhoneServiceHarness, _ method: PhoneAppMethod, id: String, _ params: P, on outbox: CapturingOutbox
    ) async throws -> Data {
        let before = replyIndices(id, in: outbox).count
        let body = try PhoneTestRequests.body(method, id: id, params: params)
        await h.service.handleAppMessage(body, from: h.peer)
        try await waitUntil("the reply to \(id)") { replyIndices(id, in: outbox).count > before }
        let bodies = outbox.bodies
        let index = replyIndices(id, in: outbox)[before]
        return bodies[index]
    }

    /// The error a reply carries, or nil for a result.
    private static func error(_ bytes: Data) throws -> PhoneAppError? {
        try JSONDecoder().decode(PhoneTestReply.self, from: bytes).error
    }

    /// The positions in `outbox` of the replies to `requestID`.
    private static func replyIndices(_ requestID: String, in outbox: CapturingOutbox) -> [Int] {
        var indices: [Int] = []
        for (index, body) in outbox.bodies.enumerated() {
            guard let head = try? JSONDecoder().decode(BodyHead.self, from: body),
                  head.kind == "reply", head.requestID == requestID else { continue }
            indices.append(index)
        }
        return indices
    }

    /// The positions in `outbox` of the `name` events.
    private static func eventIndices(_ name: PhoneAppEventName, in outbox: CapturingOutbox) -> [Int] {
        var indices: [Int] = []
        for (index, body) in outbox.bodies.enumerated() {
            guard let head = try? JSONDecoder().decode(BodyHead.self, from: body),
                  head.kind == "event", head.event == name.rawValue else { continue }
            indices.append(index)
        }
        return indices
    }

    /// Every `name` event `outbox` has received, in order.
    private static func events<D: Codable>(
        _ name: PhoneAppEventName, _ type: D.Type, in outbox: CapturingOutbox
    ) throws -> [PhoneEventEnvelope<D>] {
        var found: [PhoneEventEnvelope<D>] = []
        for body in outbox.bodies {
            let head = try JSONDecoder().decode(BodyHead.self, from: body)
            guard head.kind == "event", head.event == name.rawValue else { continue }
            found.append(try JSONDecoder().decode(PhoneEventEnvelope<D>.self, from: body))
        }
        return found
    }

    /// The IDs of every item `outbox`'s `transcript.append` events carried,
    /// in order.
    private static func appendedIDs(in outbox: CapturingOutbox) -> [String] {
        let appends = (try? events(.transcriptAppend, TranscriptItemsData.self, in: outbox)) ?? []
        return appends.flatMap { $0.data.items.map(\.id) }
    }

    /// The IDs of every item the feed's `append` events carried, in order.
    private static func appendedIDs(_ events: [TranscriptFeedEvent]) -> [String] {
        events.compactMap { $0.appended }.flatMap { $0.items.map(\.id) }
    }

    /// The newest `seq` the phone has seen: its events', and its subscribe
    /// and open replies'.
    private static func lastSeqSeen(in outbox: CapturingOutbox) -> Int {
        var seen = 0
        for body in outbox.bodies {
            guard let head = try? JSONDecoder().decode(BodyHead.self, from: body) else { continue }
            if head.kind == "event", let seq = head.seq {
                seen = max(seen, seq)
            } else if head.kind == "reply",
                      let seq = (try? JSONDecoder().decode(PhoneReplyEnvelope<SeqResult>.self, from: body))?.result.seq {
                seen = max(seen, seq)
            }
        }
        return seen
    }

    private static func activity(_ terminal: TBDShared.Terminal) -> StateDelta {
        .terminalActivityUpdated(TerminalActivityDelta(
            terminalID: terminal.id, worktreeID: terminal.worktreeID, activityState: .working))
    }

    private static func item(_ id: String, text: String = "placeholder") -> PhoneItem {
        PhoneItem(
            id: id, kind: .assistant, at: nil, text: text, truncated: false, toolName: nil, target: nil,
            toolStatus: nil, added: nil, removed: nil, agentType: nil, itemCount: nil, sender: nil)
    }

    /// Live watcher streams on `path`, or nil in a build without the count.
    private static func watchers(_ path: String) -> Int? {
        #if DEBUG
        return FileWatcher.liveStreamCount(forPath: path)
        #else
        return nil
        #endif
    }

    /// `waitUntil`, returning true, for a check a test then asserts.
    private static func eventually(_ what: String, _ condition: () async -> Bool) async throws -> Bool {
        try await waitUntil(what, condition)
        return true
    }

    /// Not a guard: the time after which a write is taken as missed by the
    /// watcher, as `FileWatcherTests` decides it.
    private static let writeAttemptWindow: Duration = .seconds(4)

    /// Appends blank lines, which add no item, until the feed's watcher arms
    /// its debounce or `done` holds. A write right after the watcher opens the
    /// file can be lost while its dispatch source registers, so the line the
    /// test appended may arm nothing.
    private static func appendUntilArmed(
        _ path: String, clock: EventDrivenTestClock, or done: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: TestDeadlines.saturatedPass)
        while ContinuousClock.now < deadline {
            let outcome = await pollUntilTrue(timeout: writeAttemptWindow) {
                if await done() { return true }
                return clock.hasSleeper
            }
            switch outcome {
            case .satisfied:
                return
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                try FeedFixture.appendRaw(Data("\n".utf8), to: path)
            }
        }
        if await done() || clock.hasSleeper { return }
        throw BoundedWaitTimeout(
            what: "the feed's watcher to arm its debounce", observed: "no sleeper", deadline: TestDeadlines.saturatedPass)
    }
}

// MARK: - A held resolve

/// A local feed's `resolvePath` whose first call returns `path` at once and
/// whose later calls each wait until `gate` opens or their task is
/// cancelled, so a test can hold the worker's read, and the read turn with
/// it.
private final class HeldLaterResolve: @unchecked Sendable {
    let gate = PhoneTestGate()
    private let path: String
    private let lock = NSLock()
    private var count = 0

    init(path: String) {
        self.path = path
    }

    /// How many calls have started, the held ones included.
    var calls: Int { lock.withLock { count } }

    func resolve() async -> String? {
        let isFirst = lock.withLock { () -> Bool in
            count += 1
            return count == 1
        }
        if !isFirst {
            await gate.wait()
        }
        return path
    }
}

// MARK: - A feed on its own

/// A local feed whose session's transcript is `path`, with a recorder of
/// every event it emits and the clock its watcher debounces on.
private struct DirectFeed {
    let terminalID: UUID
    let feed: TranscriptFeed
    let events: FireRecorder<TranscriptFeedEvent>
    let clock: EventDrivenTestClock

    var session: PhoneSessionRef { .local(terminalID: terminalID) }

    init(path: String?, liveItemLimit: Int = TranscriptFeed.liveItemLimit) {
        let terminalID = UUID()
        let events = FireRecorder<TranscriptFeedEvent>()
        let clock = EventDrivenTestClock()
        self.terminalID = terminalID
        self.events = events
        self.clock = clock
        self.feed = TranscriptFeed(
            session: .local(terminalID: terminalID), showDetails: false,
            source: .local(terminalID: terminalID, resolvePath: { path }),
            emit: { event in events.record(event) },
            liveItemLimit: liveItemLimit,
            clock: clock)
    }

    /// A state delta for the feed's terminal that asks for a read.
    func nudge() async {
        await feed.noteDelta(.terminalActivityUpdated(TerminalActivityDelta(
            terminalID: terminalID, worktreeID: UUID(), activityState: .working)))
    }
}

private extension TranscriptFeedEvent {
    var appended: TranscriptItemsData? {
        if case .append(let data) = self { return data }
        return nil
    }

    var updated: TranscriptItemsData? {
        if case .update(let data) = self { return data }
        return nil
    }

    var resetData: TranscriptResetData? {
        if case .reset(let data) = self { return data }
        return nil
    }
}

// MARK: - Transcript files

/// JSONL lines in the shape Claude Code writes and `TranscriptParser` reads.
private enum FeedLine {
    static let timestamp = "2026-05-05T10:00:00.000Z"

    static func prompt(_ uuid: String, _ text: String) -> [String: Any] {
        let message: [String: Any] = ["role": "user", "content": text]
        return ["type": "user", "uuid": uuid, "timestamp": timestamp, "message": message]
    }

    /// A prompt line whose `uuid` is `uuid` when one is given (`NSNull()`
    /// writes `null`), and absent otherwise.
    static func promptWithoutUUID(_ text: String, uuid: Any? = nil) -> [String: Any] {
        var line = prompt("", text)
        line.removeValue(forKey: "uuid")
        if let uuid {
            line["uuid"] = uuid
        }
        return line
    }

    /// An assistant line holding one Bash call.
    static func bash(_ uuid: String, id: String, command: String) -> [String: Any] {
        let block: [String: Any] = ["type": "tool_use", "id": id, "name": "Bash", "input": ["command": command]]
        let message: [String: Any] = ["role": "assistant", "content": [block]]
        return ["type": "assistant", "uuid": uuid, "timestamp": timestamp, "message": message]
    }

    /// A user line returning `toolUseID`'s result.
    static func toolResult(_ uuid: String, toolUseID: String, text: String) -> [String: Any] {
        let block: [String: Any] = ["type": "tool_result", "tool_use_id": toolUseID, "content": text]
        let message: [String: Any] = ["role": "user", "content": [block]]
        return ["type": "user", "uuid": uuid, "timestamp": timestamp, "message": message]
    }

    /// Prompts `m1`…`m<messages>`, each followed by a Bash call `toolu_<n>` on
    /// line `a<n>` and its result on line `r<n>`.
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

/// A transcript file in a scratch directory of its own.
private struct FeedFixture {
    let directory: URL
    let path: String

    init(_ objects: [[String: Any]]) throws {
        let directory = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-feed"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.path = directory.appendingPathComponent("session.jsonl").path
        if !objects.isEmpty {
            try Self.write(objects, to: path)
        }
    }

    /// Another file's path in the same directory.
    func sibling(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    func append(_ objects: [[String: Any]]) throws {
        try Self.append(objects, to: path)
    }

    /// Writes `objects` over the file, in place.
    func rewrite(_ objects: [[String: Any]]) throws {
        try Self.write(objects, to: path)
    }

    func size() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func write(_ objects: [[String: Any]], to path: String) throws {
        try encode(objects).write(to: URL(fileURLWithPath: path))
    }

    static func append(_ objects: [[String: Any]], to path: String) throws {
        try appendRaw(encode(objects), to: path)
    }

    static func appendRaw(_ bytes: Data, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    /// `objects` as JSONL, one line each, every line ending in `"\n"`.
    static func encode(_ objects: [[String: Any]]) throws -> Data {
        var bytes = Data()
        for object in objects {
            bytes.append(try JSONSerialization.data(withJSONObject: object))
            bytes.append(UInt8(ascii: "\n"))
        }
        return bytes
    }
}
