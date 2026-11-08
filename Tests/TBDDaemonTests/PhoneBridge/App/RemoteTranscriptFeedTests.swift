import Foundation
import TBDShared
import Testing
import TestSupport

@testable import TBDDaemonLib

/// A remote session's transcript on the phone: the feed over the daemon's
/// transcript cache, the `RemoteTranscriptFollower` that syncs the cache
/// while the transcript is open, its older pages that load earlier history,
/// and `transcript.open` for a remote session with the session's
/// `prompt.changed` beside it. Tier 2: each test's fake session actions write
/// the cache file into a scratch directory of its own, as the daemon's sync
/// and load would, and the follower ticks on an injected
/// `EventDrivenTestClock`. The service tests run over the harness's
/// in-memory database, its own `StateSubscriptionManager` and fake session
/// actions.
@Suite("Phone remote transcripts", .clockDriven)
struct RemoteTranscriptFeedTests {
    private static let provider = RemoteDirectFeed.provider
    private static let session = RemoteDirectFeed.session
    private static let unreachable = "The provider is unreachable."
    private static let allow = PromptAnswer.permission(decision: .allow, message: nil)

    // MARK: - The feed on its own

    /// Opening syncs the cache once and pages the file the sync named, and
    /// starts nothing.
    @Test func openSyncsThenPagesTheCache() async throws {
        let cache = try FakeCache(CacheLine.conversation("m", messages: 2))
        defer { cache.remove() }
        let d = RemoteDirectFeed(cache: cache)

        let page = try await d.feed.open()

        let pageIDs = page.items.map(\.id)
        #expect(pageIDs == ["m1", "toolu_m1", "m2", "toolu_m2"])
        #expect(page.reachedStart)
        #expect(page.cursor == nil)
        let syncs = d.actions.remoteSyncs
        try #require(syncs.count == 1)
        #expect(syncs[0].provider == Self.provider)
        #expect(syncs[0].sessionID == "rs-1")
        #expect(await d.feed.transcriptPath == cache.path)
        #expect(await d.feed.isSyncing == false, "open starts nothing")
        #expect(!d.clock.hasSleeper)
        await d.feed.close()
    }

    /// Each tick syncs once, and the records the sync appended reach the
    /// phone as one `transcript.append`. The loop then waits for the next
    /// interval.
    @Test func eachTickAppendsNewRecords() async throws {
        let cache = try FakeCache(CacheLine.conversation("m", messages: 2))
        defer { cache.remove() }
        let d = RemoteDirectFeed(cache: cache)
        _ = try await d.feed.open()
        await d.feed.start()
        #expect(await d.feed.isWatching == false, "a remote cache has no watcher")

        cache.queueAppend([CacheLine.prompt("m3", "placeholder prompt 3"), CacheLine.bash("am3", id: "toolu_m3")])
        try await d.clock.requireAdvanceWhenArmed(by: .seconds(3))
        let event = await d.events.next()

        let appended = try #require(Self.appended(event))
        let ids = appended.items.map(\.id)
        #expect(ids == ["m3", "toolu_m3"])
        #expect(appended.session == Self.session)
        #expect(d.actions.remoteSyncs.count == 2)
        #expect(await d.feed.generation == 0)
        try await d.clock.requireSleeperArmed()
        #expect(d.events.values.count == 1)
        await d.feed.close()
    }

    /// A sync that names a newer cache generation starts over with reason
    /// `generation` and the new file's first page, and the live part then
    /// follows the new file.
    @Test func aNewGenerationResets() async throws {
        let cache = try FakeCache(CacheLine.conversation("m", messages: 2))
        defer { cache.remove() }
        let d = RemoteDirectFeed(cache: cache)
        _ = try await d.feed.open()
        await d.feed.start()

        cache.queueReplacement(CacheLine.conversation("n", messages: 3))
        try await d.clock.requireAdvanceWhenArmed(by: .seconds(3))
        let event = await d.events.next()

        let reset = try #require(Self.resetData(event))
        #expect(reset.reason == TranscriptFeed.generationReason)
        let ids = reset.page.items.map(\.id)
        #expect(ids == ["n1", "toolu_n1", "n2", "toolu_n2", "n3", "toolu_n3"])
        #expect(await d.feed.generation == 1)

        cache.queueAppend([CacheLine.prompt("n4", "placeholder prompt 4")])
        try await d.clock.requireAdvanceWhenArmed(by: .seconds(3))
        let next = await d.events.next()
        let appended = Self.appended(next)?.items.map(\.id)
        #expect(appended == ["n4"])
        await d.feed.close()
    }

    /// Scrolling to the top of the cache loads earlier history, which the
    /// cache prepends: the older page holds it, a call on it takes its status
    /// from a result on the first page, and the next tick's records still
    /// arrive as an append, not a reset.
    @Test func aPrependKeepsTheFeedAndOlderPagesStillJoin() async throws {
        let lines = [
            CacheLine.prompt("m1", "placeholder prompt 1"),
            CacheLine.bash("aj", id: "toolu_j"),
            CacheLine.prompt("m2", "placeholder prompt 2"),
            CacheLine.prompt("m3", "placeholder prompt 3"),
            CacheLine.prompt("m4", "placeholder prompt 4"),
            CacheLine.prompt("m5", "placeholder prompt 5"),
            CacheLine.toolResult("rj", toolUseID: "toolu_j"),
        ]
        let earlier = [CacheLine.prompt("e1", "placeholder earlier 1"), CacheLine.prompt("e2", "placeholder earlier 2")]
        let cache = try FakeCache(lines, earlier: [earlier])
        defer { cache.remove() }
        let d = RemoteDirectFeed(cache: cache)
        let page = try await d.feed.open()
        let pageIDs = page.items.map(\.id)
        #expect(pageIDs == ["m2", "m3", "m4", "m5"])
        let cursor = try #require(page.cursor)
        await d.feed.start()
        try await waitUntil("the feed's first read") { await d.feed.readCount >= 1 }

        let older = try await d.feed.olderPage(cursor: cursor)

        let olderIDs = older.items.map(\.id)
        #expect(olderIDs == ["e1", "e2", "m1", "toolu_j"])
        let call = older.items.first(where: { $0.id == "toolu_j" })
        #expect(call?.toolStatus == TranscriptShaper.okStatus)
        #expect(older.reachedStart)
        #expect(older.cursor == nil)
        #expect(d.actions.remoteLoadEarliers.count == 1)

        cache.queueAppend([CacheLine.prompt("m6", "placeholder prompt 6")])
        try await d.clock.requireAdvanceWhenArmed(by: .seconds(3))
        let event = await d.events.next()
        let appended = Self.appended(event)?.items.map(\.id)
        #expect(appended == ["m6"])
        #expect(Self.resets(d.events.values).isEmpty)
        #expect(await d.feed.generation == 0)
        await d.feed.close()
    }

    /// A first page that holds the whole cache while earlier history can be
    /// loaded has not reached the start: its cursor asks for the page before
    /// it. Each older page past the cache loads one page of earlier history
    /// and holds what the load prepended, until the start is reached.
    @Test func scrollingPastTheCacheLoadsEarlier() async throws {
        let oldest = [CacheLine.prompt("d1", "placeholder earliest")]
        let newer = [CacheLine.prompt("e1", "placeholder earlier 1"), CacheLine.prompt("e2", "placeholder earlier 2")]
        let cache = try FakeCache(CacheLine.conversation("m", messages: 2), earlier: [oldest, newer])
        defer { cache.remove() }
        let d = RemoteDirectFeed(cache: cache)
        let page = try await d.feed.open()
        let pageIDs = page.items.map(\.id)
        #expect(pageIDs == ["m1", "toolu_m1", "m2", "toolu_m2"])
        #expect(!page.reachedStart)
        let top = try #require(page.cursor)

        let first = try await d.feed.olderPage(cursor: top)

        let firstIDs = first.items.map(\.id)
        #expect(firstIDs == ["e1", "e2"])
        #expect(!first.reachedStart)
        #expect(d.actions.remoteLoadEarliers.count == 1)
        let next = try #require(first.cursor)

        let second = try await d.feed.olderPage(cursor: next)

        let secondIDs = second.items.map(\.id)
        #expect(secondIDs == ["d1"])
        #expect(second.reachedStart)
        #expect(second.cursor == nil)
        #expect(d.actions.remoteLoadEarliers.count == 2)
        await d.feed.close()
    }

    /// A load that fails leaves the cache as it was: the phone gets the
    /// cache's page, whose cursor still asks for more, and with nothing left
    /// in the cache the load's refusal is the error. A later try loads.
    @Test func aFailedLoadShowsTheCacheThenRefuses() async throws {
        let cache = try FakeCache(
            CacheLine.conversation("m", messages: 6), earlier: [[CacheLine.prompt("e1", "placeholder earlier 1")]])
        defer { cache.remove() }
        cache.failLoads(Self.unreachable)
        let d = RemoteDirectFeed(cache: cache)
        let page = try await d.feed.open()
        let cursor = try #require(page.cursor)

        let cached = try await d.feed.olderPage(cursor: cursor)

        let cachedIDs = cached.items.map(\.id)
        #expect(cachedIDs == ["m1", "toolu_m1", "m2", "toolu_m2"])
        #expect(!cached.reachedStart)
        let top = try #require(cached.cursor)
        #expect(d.actions.remoteLoadEarliers.count == 1)

        await #expect(throws: PhoneAppError(code: .refused, message: Self.unreachable)) {
            _ = try await d.feed.olderPage(cursor: top)
        }
        #expect(d.actions.remoteLoadEarliers.count == 2)

        cache.failLoads(nil)
        let loaded = try await d.feed.olderPage(cursor: top)
        let loadedIDs = loaded.items.map(\.id)
        #expect(loadedIDs == ["e1"])
        #expect(loaded.reachedStart)
        await d.feed.close()
    }

    /// History the provider can no longer fetch ends the scroll: the page
    /// reaches the start, and a later sync that still offers earlier history
    /// does not bring the load back.
    @Test func anExpiredHistoryEndsTheScroll() async throws {
        let cache = try FakeCache(
            CacheLine.conversation("m", messages: 6), earlier: [[CacheLine.prompt("e1", "placeholder earlier 1")]])
        defer { cache.remove() }
        cache.expireLoads()
        let d = RemoteDirectFeed(cache: cache)
        let page = try await d.feed.open()
        let cursor = try #require(page.cursor)

        let older = try await d.feed.olderPage(cursor: cursor)

        let olderIDs = older.items.map(\.id)
        #expect(olderIDs == ["m1", "toolu_m1", "m2", "toolu_m2"])
        #expect(older.reachedStart)
        #expect(older.cursor == nil)
        #expect(d.actions.remoteLoadEarliers.count == 1)

        await d.feed.start()
        try await waitUntil("the feed's first read") { await d.feed.readCount >= 1 }
        try await d.clock.requireAdvanceWhenArmed(by: .seconds(3))
        try await waitUntil("the feed to apply the tick's sync") { await d.feed.readCount >= 2 }
        #expect(d.actions.remoteSyncs.count == 2)
        let again = try await d.feed.olderPage(cursor: cursor)
        #expect(again.reachedStart)
        #expect(d.actions.remoteLoadEarliers.count == 1)
        await d.feed.close()
    }

    /// A load whose result names a newer generation fetched nothing, since a
    /// sync replaced the cache first: the cursor is stale, the feed starts
    /// over with reason `generation`, and the next tick appends to the new
    /// file without a second reset.
    @Test func aLoadThatMeetsANewGenerationIsStaleAndResets() async throws {
        let cache = try FakeCache(
            CacheLine.conversation("m", messages: 6), earlier: [[CacheLine.prompt("e1", "placeholder earlier 1")]])
        defer { cache.remove() }
        let d = RemoteDirectFeed(cache: cache)
        let page = try await d.feed.open()
        let cursor = try #require(page.cursor)
        await d.feed.start()
        try await waitUntil("the feed's first read") { await d.feed.readCount >= 1 }
        cache.replaceBeforeLoad(CacheLine.conversation("n", messages: 2))

        await #expect(throws: PhoneAppError(code: .staleCursor, message: TranscriptPager.staleCursorMessage)) {
            _ = try await d.feed.olderPage(cursor: cursor)
        }

        let event = await d.events.next()
        let reset = try #require(Self.resetData(event))
        #expect(reset.reason == TranscriptFeed.generationReason)
        let ids = reset.page.items.map(\.id)
        #expect(ids == ["n1", "toolu_n1", "n2", "toolu_n2"])

        cache.queueAppend([CacheLine.prompt("n3", "placeholder prompt 3")])
        try await d.clock.requireAdvanceWhenArmed(by: .seconds(3))
        let next = await d.events.next()
        let appended = Self.appended(next)?.items.map(\.id)
        #expect(appended == ["n3"])
        #expect(Self.resets(d.events.values).count == 1)
        await d.feed.close()
    }

    /// A sync that fails sends nothing, and the loop goes on: the next
    /// interval is armed, and the next sync that succeeds brings the records
    /// the phone missed.
    @Test func aFailedSyncSendsNothingAndTheNextCatchesUp() async throws {
        let cache = try FakeCache(CacheLine.conversation("m", messages: 2))
        defer { cache.remove() }
        let d = RemoteDirectFeed(cache: cache)
        _ = try await d.feed.open()
        await d.feed.start()
        cache.failSyncs(Self.unreachable)
        cache.queueAppend([CacheLine.prompt("m3", "placeholder prompt 3")])

        try await d.clock.requireAdvanceWhenArmed(by: .seconds(3))
        try await d.clock.requireSleeperArmed()

        #expect(d.actions.remoteSyncs.count == 2)
        #expect(d.events.values.isEmpty)
        cache.failSyncs(nil)
        try await d.clock.requireAdvanceWhenArmed(by: .seconds(3))
        let event = await d.events.next()
        let appended = Self.appended(event)?.items.map(\.id)
        #expect(appended == ["m3"])
        await d.feed.close()
    }

    /// Closing the feed ends the follower's syncs: its interval is
    /// cancelled, and time passing syncs nothing more.
    @Test func closeEndsTheSyncs() async throws {
        let cache = try FakeCache(CacheLine.conversation("m", messages: 2))
        defer { cache.remove() }
        let d = RemoteDirectFeed(cache: cache)
        _ = try await d.feed.open()
        await d.feed.start()
        try await d.clock.requireSleeperArmed()
        #expect(await d.feed.isSyncing)

        await d.feed.close()

        #expect(await d.feed.isSyncing == false)
        try await waitUntil("the follower's interval to be cancelled") { !d.clock.hasSleeper }
        cache.queueAppend([CacheLine.prompt("m3", "placeholder prompt 3")])
        await d.clock.advance(by: .seconds(3))
        await settle()
        #expect(d.actions.remoteSyncs.count == 1)
        #expect(d.events.values.isEmpty)
    }

    // MARK: - transcript.open for a remote session

    /// A provider that does not declare `transcript.read` opens nothing:
    /// `unsupported`, with no sync and no feed.
    @Test func noTranscriptReadIsUnsupported() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider(Self.provider, capabilities: [RemoteCapability.answer])
        try Self.listSession(h)
        let outbox = try await Self.liveConnection(h)

        let bytes = try await Self.ask(h, .transcriptOpen, id: "open", Self.openParams(Self.session), on: outbox)

        #expect(try Self.error(bytes) == PhoneAppError(
            code: .unsupported, message: PhoneAppService.noTranscriptReadReason))
        #expect(h.actions.remoteSyncs.isEmpty)
        let feed = await h.service.transcriptFeed(for: h.peer.deviceID)
        #expect(feed == nil)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// The phone opens only a session it can see: a dismissed session, one
    /// missing from the list and one whose provider is not registered are
    /// `not_found`, with no sync.
    @Test func aRemoteSessionThePhoneCannotSeeIsNotFound() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider(Self.provider, capabilities: [RemoteCapability.transcriptRead])
        try Self.listSession(h, dismissed: true)
        let outbox = try await Self.liveConnection(h)

        let dismissed = try await Self.ask(h, .transcriptOpen, id: "dismissed", Self.openParams(Self.session), on: outbox)
        #expect(try Self.error(dismissed) == PhoneAppError(code: .notFound, message: PhoneAppService.noSuchSessionReason))

        try Self.listSession(h)
        let missing = try await Self.ask(
            h, .transcriptOpen, id: "missing",
            Self.openParams(.remote(provider: Self.provider, sessionID: "rs-2")), on: outbox)
        #expect(try Self.error(missing) == PhoneAppError(code: .notFound, message: PhoneAppService.noSuchSessionReason))

        let unregistered = try await Self.ask(
            h, .transcriptOpen, id: "unregistered",
            Self.openParams(.remote(provider: "acme-other", sessionID: "rs-1")), on: outbox)
        #expect(try Self.error(unregistered) == PhoneAppError(
            code: .notFound, message: PhoneAppService.noSuchProviderReason))
        #expect(h.actions.remoteSyncs.isEmpty)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// A sync that fails at open is the reply's error, with the laptop's
    /// reason, and leaves nothing open.
    @Test func aFailedOpenSyncIsRefused() async throws {
        let h = try await PhoneServiceHarness.make()
        try h.actions.registerProvider(Self.provider, capabilities: [RemoteCapability.transcriptRead])
        try Self.listSession(h)
        h.actions.respond(to: .remoteTranscriptSync, with: RPCResponse(error: Self.unreachable))
        let outbox = try await Self.liveConnection(h)

        let bytes = try await Self.ask(h, .transcriptOpen, id: "open", Self.openParams(Self.session), on: outbox)

        #expect(try Self.error(bytes) == PhoneAppError(code: .refused, message: Self.unreachable))
        #expect(h.actions.remoteSyncs.count == 1)
        let feed = await h.service.transcriptFeed(for: h.peer.deviceID)
        #expect(feed == nil)
        await h.service.phoneRevoked(deviceID: h.peer.deviceID)
    }

    /// Opening a remote session replies with the cache's first page, starts
    /// the follower's syncs with no relay and no watcher, and sends the
    /// session's open prompt, read again on every `.remoteSessionsChanged`.
    /// Every body fits a frame.
    @Test func aRemoteOpenPagesTheCacheAndFollowsThePrompt() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let cache = try FakeCache(CacheLine.conversation("m", messages: 2))
        defer { cache.remove() }
        try Self.serve(h, cache: cache, prompt: Self.makePrompt)
        let outbox = try await Self.liveConnection(h)
        let baseline = h.subscriptions.subscriberCount

        let opened = try await Self.open(h, id: "open", on: outbox)

        let pageIDs = opened.page?.items.map(\.id) ?? []
        #expect(pageIDs == ["m1", "toolu_m1", "m2", "toolu_m2"])
        let first = try await Self.promptEvent(0, in: outbox)
        let firstIDs = first.data.prompts.map(\.id)
        #expect(firstIDs == ["rp-1"])
        #expect(first.data.prompts.first?.target == "make")
        #expect(first.data.session == Self.session)
        let feed = try #require(await h.service.transcriptFeed(for: deviceID))
        try await waitUntil("the syncs and the prompt source to start") {
            let syncing = await feed.isSyncing
            return syncing && h.subscriptions.subscriberCount == baseline + 1
        }
        #expect(await feed.isWatching == false)

        try Self.listSession(h)
        h.subscriptions.broadcast(delta: .remoteSessionsChanged)
        let closed = try await Self.promptEvent(1, in: outbox)
        #expect(closed.data == PromptChangedData(
            session: Self.session, prompts: [],
            resolved: [PhonePromptResolution(promptID: "rp-1", answeredBy: .unknown, deviceID: nil)]))

        for body in outbox.bodies {
            #expect(PhoneAppCoding.framedSize(body) <= PhoneFrameBudget.maxPlaintext)
        }
        await h.service.phoneRevoked(deviceID: deviceID)
        #expect(h.subscriptions.subscriberCount == 0)
    }

    /// A prompt read that waits for the phone's answer to a prompt that
    /// closed never holds up the transcript: the follower's ticks go on, and
    /// the prompt's closing follows once the answer finishes.
    @Test func aSlowPromptReadNeverHoldsUpTheTicks() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let cache = try FakeCache(CacheLine.conversation("m", messages: 2))
        defer { cache.remove() }
        try Self.serve(h, cache: cache, prompt: Self.makePrompt)
        let gate = PhoneTestGate()
        h.actions.hold(.answerRemotePrompt, on: gate)
        h.actions.respond(to: .answerRemotePrompt, with: try RPCResponse(result: PromptAnswerResult(outcome: .delivered)))
        let outbox = try await Self.liveConnection(h)
        _ = try await Self.open(h, id: "open", on: outbox)
        _ = try await Self.promptEvent(0, in: outbox)

        let answer = try PhoneTestRequests.body(
            .promptAnswer, id: "answer-1",
            params: PhonePromptAnswerParams(session: Self.session, promptID: "rp-1", answer: Self.allow))
        await h.service.handleAppMessage(answer, from: h.peer)
        try await waitUntil("the answer to reach the core") { h.actions.remoteAnswers.count == 1 }
        try Self.listSession(h)
        h.subscriptions.broadcast(delta: .remoteSessionsChanged)
        try await waitUntil("the prompt read to wait for the phone's answer") {
            await h.service.phoneAnswerWaiterCount() > 0
        }

        cache.queueAppend([CacheLine.prompt("m3", "placeholder prompt 3")])
        try await h.clock.advanceUntil(
            "the append of m3", by: PhoneAppConstants.remoteSyncInterval, timeout: TestDeadlines.saturatedPass
        ) {
            Self.appendedIDs(in: outbox) == ["m3"]
        }
        #expect(try Self.events(.promptChanged, PromptChangedData.self, in: outbox).count == 1)

        gate.open()
        let closed = try await Self.promptEvent(1, in: outbox)
        #expect(closed.data.resolved == [PhonePromptResolution(promptID: "rp-1", answeredBy: .phone, deviceID: deviceID)])
        await h.service.phoneRevoked(deviceID: deviceID)
    }

    /// `transcript.close`, another open and a revoke each end the syncs of
    /// the feed they stop, and time passing then syncs nothing more.
    @Test func closingReopeningAndRevokingEndTheSyncs() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let cache = try FakeCache(CacheLine.conversation("m", messages: 2))
        defer { cache.remove() }
        try Self.serve(h, cache: cache)
        let outbox = try await Self.liveConnection(h)

        _ = try await Self.open(h, id: "open-1", on: outbox)
        let closedFeed = try #require(await h.service.transcriptFeed(for: deviceID))
        try await waitUntil("the first feed's syncs to start") { await closedFeed.isSyncing }
        let closeReply = try await Self.ask(h, .transcriptClose, id: "close", PhoneEmpty(), on: outbox)
        #expect(try Self.error(closeReply) == nil)
        try await waitUntil("the close to end the first feed's syncs") {
            let syncing = await closedFeed.isSyncing
            return !syncing
        }

        _ = try await Self.open(h, id: "open-2", on: outbox)
        let replaced = try #require(await h.service.transcriptFeed(for: deviceID))
        #expect(replaced !== closedFeed)
        try await waitUntil("the second feed's syncs to start") { await replaced.isSyncing }
        _ = try await Self.open(h, id: "open-3", on: outbox)
        let last = try #require(await h.service.transcriptFeed(for: deviceID))
        #expect(last !== replaced)
        try await waitUntil("another open to end the second feed's syncs") {
            let replacedSyncing = await replaced.isSyncing
            let lastSyncing = await last.isSyncing
            return !replacedSyncing && lastSyncing
        }

        await h.service.phoneRevoked(deviceID: deviceID)
        try await waitUntil("the revoke to end the last feed's syncs") {
            let syncing = await last.isSyncing
            return !syncing && h.subscriptions.subscriberCount == 0
        }
        let syncs = h.actions.remoteSyncs.count
        await h.clock.advance(by: PhoneAppConstants.remoteSyncInterval)
        await settle()
        #expect(h.actions.remoteSyncs.count == syncs, "a stopped feed's follower synced")
    }

    /// When the grace after a disconnect runs out, the feed stops with the
    /// rest of the phone's state, its syncs and its prompt source with it.
    @Test func graceExpiryEndsTheSyncs() async throws {
        let h = try await PhoneServiceHarness.make()
        let deviceID = h.peer.deviceID
        let cache = try FakeCache(CacheLine.conversation("m", messages: 2))
        defer { cache.remove() }
        try Self.serve(h, cache: cache)
        let outbox = try await Self.liveConnection(h)
        _ = try await Self.open(h, id: "open", on: outbox)
        let feed = try #require(await h.service.transcriptFeed(for: deviceID))
        try await waitUntil("the syncs to start") { await feed.isSyncing }

        await h.service.phoneDisconnected(h.peer)
        // The sessions publisher's catch-up window, the grace, and the
        // follower's interval.
        try await h.clock.requireSleepersArmed(count: 3, timeout: TestDeadlines.saturatedPass)
        await h.clock.advance(by: PhoneAppConstants.parseStateGrace)

        try await waitUntil("the grace to stop the feed, its syncs and its prompt source") {
            let gone = await h.service.streamID(for: deviceID) == nil
            let syncing = await feed.isSyncing
            return gone && !syncing && h.subscriptions.subscriberCount == 0
        }
    }

    // MARK: - Helpers

    /// The fields every app body has, so a test can tell replies from events.
    private struct BodyHead: Decodable {
        let kind: String
        let event: String?
        let requestID: String?
    }

    private struct OpenRefused: Error, CustomStringConvertible {
        let error: PhoneAppError
        var description: String { "transcript.open was refused: \(error.code.rawValue): \(error.message)" }
    }

    /// A permission prompt the session has open.
    private static let makePrompt = RemotePendingPrompt(
        id: "rp-1", kind: .permission, toolName: "Bash", toolInputJSON: #"{"command":"make"}"#)

    /// The provider registered with `transcript.read` and `answer`, the
    /// session listed with `prompt`, and the cache served by the fake's sync
    /// and load.
    private static func serve(_ h: PhoneServiceHarness, cache: FakeCache, prompt: RemotePendingPrompt? = nil) throws {
        cache.serve(h.actions)
        try h.actions.registerProvider(provider, capabilities: [RemoteCapability.transcriptRead, RemoteCapability.answer])
        try listSession(h, prompt: prompt)
    }

    /// Every later `phoneRemoteSessions` lists session `rs-1` of `provider`,
    /// with `prompt` open.
    private static func listSession(
        _ h: PhoneServiceHarness, prompt: RemotePendingPrompt? = nil, dismissed: Bool = false
    ) throws {
        let info = RemoteSessionInfo(
            provider: provider, payload: RemoteSessionPayload(id: "rs-1", state: .running, pendingPrompt: prompt),
            gone: false, dismissed: dismissed, lastSeen: Date(timeIntervalSince1970: 1_800_000_000))
        h.actions.respond(to: .remoteSessions, with: try RPCResponse(result: RemoteSessionsResult(sessions: [info])))
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

    private static func openParams(_ session: PhoneSessionRef) -> TranscriptOpenParams {
        TranscriptOpenParams(session: session, showDetails: false, resume: false)
    }

    /// Sends `transcript.open` for the remote session and returns its
    /// result, or throws the error it replied.
    private static func open(_ h: PhoneServiceHarness, id: String, on outbox: CapturingOutbox) async throws -> TranscriptOpenResult {
        let bytes = try await ask(h, .transcriptOpen, id: id, openParams(session), on: outbox)
        if let error = try self.error(bytes) {
            throw OpenRefused(error: error)
        }
        return try JSONDecoder().decode(PhoneReplyEnvelope<TranscriptOpenResult>.self, from: bytes).result
    }

    /// Sends one request and returns its reply, found by its request ID
    /// among the events around it.
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

    /// The `index`th `prompt.changed` (from 0), once it has arrived.
    private static func promptEvent(
        _ index: Int, in outbox: CapturingOutbox
    ) async throws -> PhoneEventEnvelope<PromptChangedData> {
        try await waitUntil("prompt.changed #\(index)") {
            ((try? events(.promptChanged, PromptChangedData.self, in: outbox)) ?? []).count > index
        }
        return try events(.promptChanged, PromptChangedData.self, in: outbox)[index]
    }

    /// The IDs of every item `outbox`'s `transcript.append` events carried,
    /// in order.
    private static func appendedIDs(in outbox: CapturingOutbox) -> [String] {
        let appends = (try? events(.transcriptAppend, TranscriptItemsData.self, in: outbox)) ?? []
        return appends.flatMap { $0.data.items.map(\.id) }
    }

    private static func appended(_ event: TranscriptFeedEvent?) -> TranscriptItemsData? {
        if case .append(let data)? = event { return data }
        return nil
    }

    private static func resetData(_ event: TranscriptFeedEvent?) -> TranscriptResetData? {
        if case .reset(let data)? = event { return data }
        return nil
    }

    private static func resets(_ events: [TranscriptFeedEvent]) -> [TranscriptResetData] {
        events.compactMap { resetData($0) }
    }
}

// MARK: - A remote feed on its own

/// A feed over `cache`, synced by a follower whose fake session actions the
/// cache serves, with a recorder of every event the feed emits and the clock
/// the follower ticks on.
private struct RemoteDirectFeed {
    static let provider = "acme-cloud"
    static let session = PhoneSessionRef.remote(provider: provider, sessionID: "rs-1")

    let actions: FakeSessionActions
    let feed: TranscriptFeed
    let events: FireRecorder<TranscriptFeedEvent>
    let clock: EventDrivenTestClock

    init(cache: FakeCache) {
        let actions = FakeSessionActions()
        cache.serve(actions)
        let events = FireRecorder<TranscriptFeedEvent>()
        let clock = EventDrivenTestClock()
        let follower = RemoteTranscriptFollower(
            provider: Self.provider, sessionID: "rs-1", actions: actions, clock: clock)
        self.actions = actions
        self.events = events
        self.clock = clock
        self.feed = TranscriptFeed(
            session: Self.session, showDetails: false, source: .remote(follower),
            emit: { event in events.record(event) },
            clock: clock)
    }
}

// MARK: - The cache

/// A remote session's transcript cache as the daemon keeps it, in a scratch
/// directory of its own, written by the fake's `remote.transcriptSync` and
/// `remote.transcriptLoadEarlier` as the daemon's would be.
///
/// - **A sync** appends what was queued for it, or first replaces the file
///   in a new generation, and says earlier history can be loaded while any
///   batch of it is left.
/// - **A load** prepends the newest batch of earlier history left and bumps
///   `head`, or reports the start reached, the history expired, or a
///   replacement in a new generation that fetched nothing.
private final class FakeCache: @unchecked Sendable {
    let directory: URL
    let path: String
    private let lock = NSLock()
    private var generation = 1
    private var head = 0
    private var appends: [Data] = []
    private var replacement: Data?
    /// Earlier history, oldest batch first.
    private var earlier: [Data]
    private var syncFailure: String?
    private var loadFailure: String?
    private var expired = false
    private var replacementBeforeLoad: Data?

    init(_ objects: [[String: Any]], earlier: [[[String: Any]]] = []) throws {
        let directory = URL(fileURLWithPath: fencedScratchRoot(prefix: "tbd-phone-remote"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        self.path = directory.appendingPathComponent("rs-1.jsonl").path
        self.earlier = try earlier.map(CacheLine.encode)
        try CacheLine.encode(objects).write(to: URL(fileURLWithPath: path))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Answers the fake's syncs and loads from this cache.
    func serve(_ actions: FakeSessionActions) {
        actions.handle(.remoteTranscriptSync) { self.sync() }
        actions.handle(.remoteTranscriptLoadEarlier) { self.loadEarlier() }
    }

    /// The next sync appends `objects`.
    func queueAppend(_ objects: [[String: Any]]) {
        let bytes = (try? CacheLine.encode(objects)) ?? Data()
        lock.withLock { appends.append(bytes) }
    }

    /// The next sync replaces the file with `objects`, in a new generation.
    func queueReplacement(_ objects: [[String: Any]]) {
        let bytes = (try? CacheLine.encode(objects)) ?? Data()
        lock.withLock { replacement = bytes }
    }

    /// The next load finds the file replaced with `objects` in a new
    /// generation, as a sync that ran first would leave it, and fetches
    /// nothing.
    func replaceBeforeLoad(_ objects: [[String: Any]]) {
        let bytes = (try? CacheLine.encode(objects)) ?? Data()
        lock.withLock { replacementBeforeLoad = bytes }
    }

    /// Every later sync is refused with `reason`; nil lets them through.
    func failSyncs(_ reason: String?) {
        lock.withLock { syncFailure = reason }
    }

    /// Every later load is refused with `reason`; nil lets them through.
    func failLoads(_ reason: String?) {
        lock.withLock { loadFailure = reason }
    }

    /// Every later load finds the history expired.
    func expireLoads() {
        lock.withLock { expired = true }
    }

    private func sync() -> RPCResponse {
        lock.withLock { () -> RPCResponse in
            if let syncFailure {
                return RPCResponse(error: syncFailure)
            }
            do {
                if let replacement {
                    try replacement.write(to: URL(fileURLWithPath: path))
                    self.replacement = nil
                    generation += 1
                    head = 0
                }
                for chunk in appends {
                    try Self.append(chunk, to: path)
                }
                appends = []
            } catch {
                return RPCResponse(error: "The fake cache could not be written.")
            }
            return Self.response(RemoteTranscriptSyncResult(
                path: path, generation: generation, caughtUp: true, head: head, hasEarlier: !earlier.isEmpty))
        }
    }

    private func loadEarlier() -> RPCResponse {
        lock.withLock { () -> RPCResponse in
            if let loadFailure {
                return RPCResponse(error: loadFailure)
            }
            do {
                if let replacementBeforeLoad {
                    try replacementBeforeLoad.write(to: URL(fileURLWithPath: path))
                    self.replacementBeforeLoad = nil
                    generation += 1
                    head = 0
                    earlier = []
                    return Self.response(RemoteTranscriptLoadEarlierResult(
                        generation: generation, head: head, reachedStart: false, expired: false))
                }
                if expired {
                    return Self.response(RemoteTranscriptLoadEarlierResult(
                        generation: generation, head: head, reachedStart: true, expired: true))
                }
                guard let batch = earlier.popLast() else {
                    return Self.response(RemoteTranscriptLoadEarlierResult(
                        generation: generation, head: head, reachedStart: true, expired: false))
                }
                let current = try Data(contentsOf: URL(fileURLWithPath: path))
                try (batch + current).write(to: URL(fileURLWithPath: path))
                head += 1
                return Self.response(RemoteTranscriptLoadEarlierResult(
                    generation: generation, head: head, reachedStart: earlier.isEmpty, expired: false))
            } catch {
                return RPCResponse(error: "The fake cache could not be written.")
            }
        }
    }

    private static func append(_ bytes: Data, to path: String) throws {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    private static func response<R: Encodable>(_ result: R) -> RPCResponse {
        (try? RPCResponse(result: result)) ?? RPCResponse(error: "The fake result does not encode.")
    }
}

// MARK: - Cache lines

/// JSONL lines in the shape Claude Code writes and `TranscriptParser` reads.
private enum CacheLine {
    static let timestamp = "2026-05-05T10:00:00.000Z"

    static func prompt(_ uuid: String, _ text: String) -> [String: Any] {
        let message: [String: Any] = ["role": "user", "content": text]
        return ["type": "user", "uuid": uuid, "timestamp": timestamp, "message": message]
    }

    /// An assistant line holding one Bash call.
    static func bash(_ uuid: String, id: String) -> [String: Any] {
        let block: [String: Any] = ["type": "tool_use", "id": id, "name": "Bash", "input": ["command": "make"]]
        let message: [String: Any] = ["role": "assistant", "content": [block]]
        return ["type": "assistant", "uuid": uuid, "timestamp": timestamp, "message": message]
    }

    /// A user line returning `toolUseID`'s result.
    static func toolResult(_ uuid: String, toolUseID: String) -> [String: Any] {
        let block: [String: Any] = ["type": "tool_result", "tool_use_id": toolUseID, "content": "placeholder output"]
        let message: [String: Any] = ["role": "user", "content": [block]]
        return ["type": "user", "uuid": uuid, "timestamp": timestamp, "message": message]
    }

    /// Prompts `<prefix>1`…`<prefix><messages>`, each followed by a Bash
    /// call `toolu_<prefix><n>` and its result.
    static func conversation(_ prefix: String, messages: Int) -> [[String: Any]] {
        var lines: [[String: Any]] = []
        for n in 1...messages {
            lines.append(prompt("\(prefix)\(n)", "placeholder prompt \(n)"))
            lines.append(bash("a\(prefix)\(n)", id: "toolu_\(prefix)\(n)"))
            lines.append(toolResult("r\(prefix)\(n)", toolUseID: "toolu_\(prefix)\(n)"))
        }
        return lines
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
