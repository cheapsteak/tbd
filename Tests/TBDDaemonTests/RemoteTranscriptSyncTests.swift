import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// `RemoteTranscriptSync`: the per-session fetch lane behind
/// `remote.transcriptSync` — cursor round trip, reset, paging and its cap,
/// per-page persistence, and coalescing.
///
/// Tier 2: a scripted in-process provider and a temp `TBD_HOME`; no subprocess.
@Suite("RemoteTranscriptSync")
struct RemoteTranscriptSyncTests: ~Copyable {
    let home: URL
    let environment: [String: String]

    init() {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-transcript-sync-\(UUID().uuidString)", isDirectory: true)
        environment = ["TBD_HOME": home.path]
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    /// A one-shot gate the test opens from outside.
    private actor Gate {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            opened = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Answers each `transcript read` with the next scripted result and
    /// records the argv it was asked for. `holdFirst` parks the first call
    /// until the gate opens.
    private actor ScriptedProvider {
        private var script: [ProviderResult]
        private(set) var calls: [[String]] = []
        private let holdFirst: Gate?

        init(_ script: [ProviderResult], holdFirst: Gate? = nil) {
            self.script = script
            self.holdFirst = holdFirst
        }

        func call(_ verb: [String]) async throws -> ProviderResult {
            calls.append(verb)
            precondition(!script.isEmpty, "ScriptedProvider script exhausted for \(verb)")
            let result = script.removeFirst()
            if calls.count == 1, let holdFirst { await holdFirst.wait() }
            return result
        }
    }

    private static func page(_ records: String, _ envelope: String = "") -> ProviderResult {
        ProviderResult(exitCode: 0, stdout: Data(records.utf8), stderr: envelope)
    }

    private func makeSync(
        _ provider: ScriptedProvider, pageCap: Int = RemoteTranscriptSync.defaultPageCap,
        policy: RemoteTranscriptSyncPolicy = .forwardOnly
    ) -> RemoteTranscriptSync {
        RemoteTranscriptSync(
            environment: environment, pageCap: pageCap, policy: { _, _ in policy }
        ) { _, verb in
            try await provider.call(verb)
        }
    }

    private func fileText(_ result: RemoteTranscriptSyncResult) throws -> String {
        try String(contentsOfFile: result.path, encoding: .utf8)
    }

    private func read(since cursor: String? = nil) -> [String] {
        RemoteVerb.transcriptRead(sessionID: "s-1", since: cursor)
    }

    private func tail() -> [String] {
        RemoteVerb.transcriptReadTail(sessionID: "s-1", count: 12)
    }

    private func readBefore(_ cursor: String) -> [String] {
        RemoteVerb.transcriptReadBefore(sessionID: "s-1", before: cursor, count: 12)
    }

    // MARK: - Cursor round trip and reset

    @Test func cursorRoundTripsAndPagesAppend() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1"}"#),
            Self.page("{\"n\":2}\n", #"{"cursor": "c-2"}"#),
        ])
        let sync = makeSync(provider)

        let first = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        let second = try await sync.sync(provider: "agentbox", sessionID: "s-1")

        #expect(await provider.calls == [read(), read(since: "c-1")])
        #expect(try fileText(second) == "{\"n\":1}\n{\"n\":2}\n")
        // The first answer came without --since, so it was a reset into an
        // empty cache; the second appended under the same generation.
        #expect(first.generation == 1)
        #expect(second.generation == 1)
        #expect(second.caughtUp)
        let expectedPath = TBDConstants.remoteTranscriptDir(
            provider: "agentbox", sessionID: "s-1", environment: environment)
            .appendingPathComponent(TBDConstants.remoteTranscriptFileName).path
        #expect(second.path == expectedPath)
        #expect(second.path.hasPrefix(home.path))
    }

    @Test func resetRewritesTheFileAndIncrementsGeneration() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"old\":1}\n", #"{"cursor": "c-1"}"#),
            Self.page("{\"new\":1}\n", #"{"cursor": "n-1", "reset": true}"#),
        ])
        let sync = makeSync(provider)
        let before = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        let after = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(try fileText(after) == "{\"new\":1}\n")
        #expect(after.generation == before.generation + 1)
        #expect(await provider.calls == [read(), read(since: "c-1")])
    }

    /// No envelope: every answer is the whole conversation, caught up, and no
    /// cursor is ever sent back.
    @Test func aProviderWithoutAnEnvelopeRefetchesTheWholeTranscript() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n"),
            Self.page("{\"n\":1}\n{\"n\":2}\n"),
        ])
        let sync = makeSync(provider)
        _ = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read(), read()])
        #expect(try fileText(result) == "{\"n\":1}\n{\"n\":2}\n")
        #expect(result.caughtUp)
    }

    // MARK: - A --since answer without a real envelope

    /// A `--since` answer is only the delta, so an envelope that is absent or
    /// malformed must never turn it into a whole-conversation reset: the sync
    /// discards that output, drops the cursor, and refetches from the
    /// beginning, keeping everything held until the full answer arrives.
    @Test(arguments: [
        #"{"cursor": 42}"#,      // an envelope that fails the strict decode
        #"{"reset": "yes"}"#,
        "",                      // no envelope at all
    ])
    func aSinceAnswerWithoutAValidEnvelopeRefetchesFromTheBeginning(stderr: String) async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1"}"#),
            Self.page("{\"n\":2}\n", stderr),
            Self.page("{\"n\":1}\n{\"n\":2}\n", #"{"cursor": "c-2"}"#),
            Self.page("{\"n\":3}\n", #"{"cursor": "c-3"}"#),
        ])
        let sync = makeSync(provider)
        let first = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        let second = try await sync.sync(provider: "agentbox", sessionID: "s-1")

        #expect(await provider.calls == [read(), read(since: "c-1"), read()])
        #expect(try fileText(second) == "{\"n\":1}\n{\"n\":2}\n")
        #expect(second.caughtUp)
        #expect(second.generation == first.generation + 1)

        // The refetch's cursor is the one stored.
        let third = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls.last == read(since: "c-2"))
        #expect(try fileText(third) == "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
    }

    /// The discarded answer does not count toward the page cap; the refetch
    /// does. With a cap of one the refetch still runs inside the same sync —
    /// were the discard to use the sync up, the next one would send the same
    /// cursor, be discarded again, and never make progress.
    @Test func aDiscardedAnswerDoesNotUseUpTheSync() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1"}"#),
            Self.page("{\"n\":2}\n", #"{"cursor": 42}"#),
            Self.page("{\"n\":1}\n{\"n\":2}\n", #"{"cursor": "c-2", "more": true}"#),
        ])
        let sync = makeSync(provider, pageCap: 1)
        let first = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        let second = try await sync.sync(provider: "agentbox", sessionID: "s-1")

        #expect(await provider.calls == [read(), read(since: "c-1"), read()])
        #expect(try fileText(second) == "{\"n\":1}\n{\"n\":2}\n")
        #expect(second.generation == first.generation + 1)
        // The refetch was the one counted page, and it said `more`.
        #expect(!second.caughtUp)
    }

    // MARK: - Paging

    @Test func pagesWhileMoreAndStopsWhenCaughtUp() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1", "more": true}"#),
            Self.page("{\"n\":2}\n", #"{"cursor": "c-2", "more": true}"#),
            Self.page("{\"n\":3}\n", #"{"cursor": "c-3"}"#),
        ])
        let sync = makeSync(provider, pageCap: 3)
        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read(), read(since: "c-1"), read(since: "c-2")])
        #expect(try fileText(result) == "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
        #expect(result.caughtUp)
    }

    /// A provider that never clears `more` cannot hold the lane: the sync stops
    /// at the cap, says it is not caught up, and the next resumes from the
    /// stored cursor.
    @Test func stopsAtThePageCapWithoutBeingCaughtUp() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1", "more": true}"#),
            Self.page("{\"n\":2}\n", #"{"cursor": "c-2", "more": true}"#),
            Self.page("{\"n\":3}\n", #"{"cursor": "c-3"}"#),
        ])
        let sync = makeSync(provider, pageCap: 2)
        let capped = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(!capped.caughtUp)
        #expect(await provider.calls == [read(), read(since: "c-1")])
        #expect(try fileText(capped) == "{\"n\":1}\n{\"n\":2}\n")

        let resumed = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(resumed.caughtUp)
        #expect(await provider.calls.last == read(since: "c-2"))
        #expect(try fileText(resumed) == "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
    }

    /// The default cap is one page: a sync returns after every page of a long
    /// load, so the app can render the prefix while the rest streams in, and
    /// each following sync resumes from the stored cursor.
    @Test func theDefaultCapReturnsAfterEveryPage() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1", "more": true}"#),
            Self.page("{\"n\":2}\n", #"{"cursor": "c-2", "more": true}"#),
            Self.page("{\"n\":3}\n", #"{"cursor": "c-3"}"#),
        ])
        let sync = makeSync(provider)

        let first = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read()])
        #expect(!first.caughtUp)
        #expect(try fileText(first) == "{\"n\":1}\n")

        let second = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read(), read(since: "c-1")])
        #expect(!second.caughtUp)
        #expect(try fileText(second) == "{\"n\":1}\n{\"n\":2}\n")

        let third = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read(), read(since: "c-1"), read(since: "c-2")])
        #expect(third.caughtUp)
        #expect(try fileText(third) == "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
        #expect(third.generation == first.generation)
    }

    /// Each page is written before the next is fetched: a failure on page two
    /// leaves page one, and its cursor, in place.
    @Test func eachPageIsPersistedBeforeTheNextIsFetched() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1", "more": true}"#),
            ProviderResult(
                exitCode: 1, stdout: Data(#"{"error": {"code": "boom", "message": "transport dropped"}}"#.utf8),
                stderr: ""),
            Self.page("{\"n\":2}\n", #"{"cursor": "c-2"}"#),
        ])
        let sync = makeSync(provider, pageCap: 2)
        await #expect(throws: RemoteTranscriptSyncError.providerFailed(message: "transport dropped")) {
            try await sync.sync(provider: "agentbox", sessionID: "s-1")
        }
        #expect(await sync.activeLaneCount == 0)

        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read(), read(since: "c-1"), read(since: "c-1")])
        #expect(try fileText(result) == "{\"n\":1}\n{\"n\":2}\n")
    }

    /// `reset` mid-stream: the page that resets replaces everything held,
    /// including earlier pages of the same sync, and later pages append to it.
    @Test func resetMidStreamReplacesEarlierPages() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"old\":1}\n", #"{"cursor": "c-1", "more": true}"#),
            Self.page("{\"new\":1}\n", #"{"cursor": "n-1", "reset": true, "more": true}"#),
            Self.page("{\"new\":2}\n", #"{"cursor": "n-2"}"#),
        ])
        let sync = makeSync(provider, pageCap: 3)
        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(try fileText(result) == "{\"new\":1}\n{\"new\":2}\n")
        #expect(result.generation == 2)
        #expect(result.caughtUp)
        #expect(await provider.calls == [read(), read(since: "c-1"), read(since: "n-1")])
    }

    /// Crash repair runs at the start of a sync: an uncommitted tail is cut and
    /// the generation bumped before the next page is appended.
    @Test func anUncommittedTailIsTruncatedBeforeTheNextFetch() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1"}"#),
            Self.page("{\"n\":2}\n", #"{"cursor": "c-2"}"#),
        ])
        let sync = makeSync(provider)
        let first = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: first.path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"n\":2}\n".utf8))
        try handle.close()

        let second = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(try fileText(second) == "{\"n\":1}\n{\"n\":2}\n")
        #expect(second.generation == first.generation + 1)
    }

    // MARK: - Coalescing

    /// A burst of requests while a fetch is in flight costs at most two
    /// fetches: the running one, and one follow-up every later request shares.
    @Test func concurrentRequestsCoalesceIntoAtMostTwoFetches() async throws {
        let gate = Gate()
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1"}"#),
            Self.page("{\"n\":2}\n", #"{"cursor": "c-2"}"#),
        ], holdFirst: gate)
        let sync = makeSync(provider)

        async let first = sync.sync(provider: "agentbox", sessionID: "s-1")
        let started = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await provider.calls.count == 1
        }
        async let second = sync.sync(provider: "agentbox", sessionID: "s-1")
        async let third = sync.sync(provider: "agentbox", sessionID: "s-1")
        async let fourth = sync.sync(provider: "agentbox", sessionID: "s-1")
        let arrived = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await sync.receivedRequestCount == 4
        }
        let queued = await sync.hasQueuedFollowUp(provider: "agentbox", sessionID: "s-1")
        await gate.open()

        let results = try await [first, second, third, fourth]
        #expect(started == .satisfied)
        #expect(arrived == .satisfied)
        #expect(queued)
        #expect(await provider.calls == [read(), read(since: "c-1")])
        // The follow-up's answer reflects both fetches.
        #expect(try fileText(results[1]) == "{\"n\":1}\n{\"n\":2}\n")
        #expect(results[1] == results[2])
        #expect(results[2] == results[3])
        #expect(await sync.activeLaneCount == 0)
    }

    /// Lanes are per session: two sessions never wait on each other's fetch.
    @Test func differentSessionsDoNotCoalesce() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"a\":1}\n", #"{"cursor": "a-1"}"#),
            Self.page("{\"b\":1}\n", #"{"cursor": "b-1"}"#),
        ])
        let sync = makeSync(provider)
        let a = try await sync.sync(provider: "agentbox", sessionID: "s-a")
        let b = try await sync.sync(provider: "agentbox", sessionID: "s-b")
        #expect(a.path != b.path)
        #expect(await provider.calls == [
            RemoteVerb.transcriptRead(sessionID: "s-a"), RemoteVerb.transcriptRead(sessionID: "s-b"),
        ])
    }

    // MARK: - Discard

    /// `discard` removes the session's cache directory and leaves another
    /// session's alone.
    @Test func discardRemovesOnlyThatSessionsCache() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"a\":1}\n", #"{"cursor": "a-1"}"#),
            Self.page("{\"b\":1}\n", #"{"cursor": "b-1"}"#),
        ])
        let sync = makeSync(provider)
        let a = try await sync.sync(provider: "agentbox", sessionID: "s-a")
        let b = try await sync.sync(provider: "agentbox", sessionID: "s-b")

        await sync.discard(provider: "agentbox", sessionID: "s-a")

        let aDirectory = URL(fileURLWithPath: a.path).deletingLastPathComponent().path
        #expect(FileManager.default.fileExists(atPath: aDirectory) == false)
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    /// A fetch in flight when its session is discarded drops the page it was
    /// fetching instead of recreating the directory, and throws `.discarded`.
    /// Once that lane is gone, a sync asked for afterwards runs normally.
    @Test func aDiscardDuringAFetchDropsItsPageAndLeavesNoDirectory() async throws {
        let gate = Gate()
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1"}"#),
            Self.page("{\"n\":2}\n", #"{"cursor": "c-2"}"#),
        ], holdFirst: gate)
        let sync = makeSync(provider)
        let directory = TBDConstants.remoteTranscriptDir(
            provider: "agentbox", sessionID: "s-1", environment: environment)

        async let first = sync.sync(provider: "agentbox", sessionID: "s-1")
        let started = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await provider.calls.count == 1
        }
        await sync.discard(provider: "agentbox", sessionID: "s-1")
        let discardedBeforeRelease = FileManager.default.fileExists(atPath: directory.path)
        await gate.open()

        var thrown: RemoteTranscriptSyncError?
        do {
            _ = try await first
        } catch let error as RemoteTranscriptSyncError {
            thrown = error
        }
        #expect(thrown == .discarded)
        #expect(started == .satisfied)
        #expect(discardedBeforeRelease == false)
        #expect(FileManager.default.fileExists(atPath: directory.path) == false,
                "the in-flight page recreated the discarded cache")
        #expect(await sync.activeLaneCount == 0)

        let again = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(try fileText(again) == "{\"n\":2}\n")
    }

    /// A follow-up queued behind the held fetch when the discard lands is in
    /// the same marked lane: it persists nothing either and throws
    /// `.discarded`, so neither fetch recreates the directory.
    @Test func aDiscardAlsoDropsAQueuedFollowUp() async throws {
        let gate = Gate()
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1"}"#),
            Self.page("{\"n\":2}\n", #"{"cursor": "c-2"}"#),
        ], holdFirst: gate)
        let sync = makeSync(provider)
        let directory = TBDConstants.remoteTranscriptDir(
            provider: "agentbox", sessionID: "s-1", environment: environment)

        async let first = sync.sync(provider: "agentbox", sessionID: "s-1")
        let started = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await provider.calls.count == 1
        }
        async let second = sync.sync(provider: "agentbox", sessionID: "s-1")
        let queued = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await sync.hasQueuedFollowUp(provider: "agentbox", sessionID: "s-1")
        }
        await sync.discard(provider: "agentbox", sessionID: "s-1")
        await gate.open()

        var firstThrown: RemoteTranscriptSyncError?
        do { _ = try await first } catch let error as RemoteTranscriptSyncError { firstThrown = error }
        var secondThrown: RemoteTranscriptSyncError?
        do { _ = try await second } catch let error as RemoteTranscriptSyncError { secondThrown = error }
        #expect(started == .satisfied)
        #expect(queued == .satisfied)
        #expect(firstThrown == .discarded)
        #expect(secondThrown == .discarded)
        #expect(FileManager.default.fileExists(atPath: directory.path) == false,
                "a queued follow-up recreated the discarded cache")
        #expect(await sync.activeLaneCount == 0)
    }

    // MARK: - Tail or forward

    private static let liveTail = RemoteTranscriptSyncPolicy(liveSyncEnabled: true, tailDeclared: true, hint: nil)

    private static func policy(
        enabled: Bool = true, tail: Bool = true, hint: RemoteTranscriptHint?
    ) -> RemoteTranscriptSyncPolicy {
        RemoteTranscriptSyncPolicy(liveSyncEnabled: enabled, tailDeclared: tail, hint: hint)
    }

    private func cache(_ sync: RemoteTranscriptSync) -> RemoteTranscriptCache {
        sync.cache(provider: "agentbox", sessionID: "s-1")
    }

    /// A cache built by a forward read (cursor `c-1`), optionally with a
    /// recorded hint, written through the cache's own API.
    @discardableResult
    private func seedForward(
        _ sync: RemoteTranscriptSync, hint: RemoteTranscriptHint? = nil
    ) throws -> RemoteTranscriptCacheState {
        let store = cache(sync)
        var state = try store.load()
        state = try store.reset(to: Data("{\"n\":1}\n".utf8), cursor: "c-1", from: state)
        if let hint { state = try store.commitHint(hint, to: state) }
        return state
    }

    /// A cache built by a tail reset: cursor `c-1`, history above it at `b-1`.
    @discardableResult
    private func seedTail(_ sync: RemoteTranscriptSync) throws -> RemoteTranscriptCacheState {
        let store = cache(sync)
        var state = try store.load()
        state = try store.reset(to: Data("{\"n\":5}\n".utf8), cursor: "c-1", before: "b-1", from: state)
        return state
    }

    private func stored(_ sync: RemoteTranscriptSync) throws -> RemoteTranscriptCacheState {
        try #require(cache(sync).peekState())
    }

    @Test func theThresholdsArePinned() {
        #expect(RemoteTranscriptSync.tailRecordCount == 12)
        #expect(RemoteTranscriptSync.tailResetGrowthThreshold == 524_288)
    }

    @Test func flagOnTailsAnEmptyCache() async throws {
        let hint = RemoteTranscriptHint(id: "c1", size: 100)
        let provider = ScriptedProvider([
            Self.page("{\"n\":11}\n{\"n\":12}\n", #"{"cursor":"c-1","before":"b-1"}"#),
        ])
        let sync = makeSync(provider, policy: Self.policy(hint: hint))
        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")

        #expect(await provider.calls == [tail()])
        #expect(try fileText(result) == "{\"n\":11}\n{\"n\":12}\n")
        let state = try stored(sync)
        #expect(state.before == "b-1")
        #expect(state.cursor == "c-1")
        #expect(state.hint == hint)
        #expect(result.caughtUp)
        #expect(result.hasEarlier)
        #expect(result.head == 0)
    }

    @Test func flagOnTailsWhenTheHintIDChanges() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"new\":1}\n", #"{"cursor":"n-1","before":"nb-1"}"#),
        ])
        let sync = makeSync(provider, policy: Self.policy(hint: RemoteTranscriptHint(id: "c2", size: 10)))
        let seeded = try seedForward(sync, hint: RemoteTranscriptHint(id: "c1", size: 100))

        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [tail()])
        #expect(result.generation == seeded.generation + 1)
        #expect(try fileText(result) == "{\"new\":1}\n")
    }

    @Test func flagOnTailsWhenSizeGrowsPastTheThreshold() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":9}\n", #"{"cursor":"c-9","before":"b-8"}"#),
        ])
        let sync = makeSync(provider, policy: Self.policy(hint: RemoteTranscriptHint(id: "c1", size: 100 + 524_289)))
        try seedForward(sync, hint: RemoteTranscriptHint(id: "c1", size: 100))

        _ = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [tail()])
    }

    @Test func flagOnReadsForwardAtTheThreshold() async throws {
        let current = RemoteTranscriptHint(id: "c1", size: 100 + 524_288)
        let provider = ScriptedProvider([Self.page("{\"n\":2}\n", #"{"cursor":"c-2"}"#)])
        let sync = makeSync(provider, policy: Self.policy(hint: current))
        try seedForward(sync, hint: RemoteTranscriptHint(id: "c1", size: 100))

        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read(since: "c-1")])
        #expect(result.caughtUp)
        #expect(try stored(sync).hint == current)
    }

    @Test func flagOnReadsForwardWithNoHint() async throws {
        let provider = ScriptedProvider([Self.page("{\"n\":2}\n", #"{"cursor":"c-2"}"#)])
        let sync = makeSync(provider, policy: Self.liveTail)
        try seedForward(sync, hint: RemoteTranscriptHint(id: "c1", size: 100))

        _ = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read(since: "c-1")])
    }

    /// A cache written before hints existed has nothing to compare with: it
    /// reads forward even when the current hint is far past any threshold, and
    /// records the hint for next time.
    @Test func aCacheWithNoRecordedHintReadsForward() async throws {
        let current = RemoteTranscriptHint(id: "c9", size: 999_999_999)
        let provider = ScriptedProvider([Self.page("{\"n\":2}\n", #"{"cursor":"c-2"}"#)])
        let sync = makeSync(provider, policy: Self.policy(hint: current))
        try seedForward(sync)

        _ = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read(since: "c-1")])
        #expect(try stored(sync).hint == current)
    }

    @Test func aShrunkSizeForTheSameIDReadsForward() async throws {
        let provider = ScriptedProvider([Self.page("{\"n\":2}\n", #"{"cursor":"c-2"}"#)])
        let sync = makeSync(provider, policy: Self.policy(hint: RemoteTranscriptHint(id: "c1", size: 100)))
        try seedForward(sync, hint: RemoteTranscriptHint(id: "c1", size: 900))

        _ = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read(since: "c-1")])
    }

    @Test func withoutTailDeclaredTheFlagOnNeverTails() async throws {
        let provider = ScriptedProvider([Self.page("{\"n\":1}\n", #"{"cursor":"c-1"}"#)])
        let sync = makeSync(
            provider, policy: Self.policy(tail: false, hint: RemoteTranscriptHint(id: "c1", size: 100)))
        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read()])
        #expect(!result.hasEarlier)
    }

    @Test func flagOffNeverTailsEvenOnAnEmptyCache() async throws {
        let provider = ScriptedProvider([Self.page("{\"n\":1}\n", #"{"cursor":"c-1"}"#)])
        let sync = makeSync(
            provider, policy: Self.policy(enabled: false, hint: RemoteTranscriptHint(id: "c1", size: 100)))
        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read()])
        #expect(!result.hasEarlier)
    }

    /// With the flag off, a cache holding history above it (left from a period
    /// with the flag on) is refetched in full, so the whole conversation
    /// returns. The same holds with the flag on for a provider without
    /// `transcript.tail`, whose `before` can never be followed.
    @Test(arguments: [
        RemoteTranscriptSyncPolicy.forwardOnly,
        RemoteTranscriptSyncPolicy(liveSyncEnabled: true, tailDeclared: false, hint: nil),
    ])
    func withoutTailModeACacheHoldingBeforeIsRefetchedInFull(policy: RemoteTranscriptSyncPolicy) async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n{\"n\":5}\n", #"{"cursor":"c-2"}"#),
        ])
        let sync = makeSync(provider, policy: policy)
        let seeded = try seedTail(sync)

        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read()])
        #expect(try stored(sync).before == nil)
        #expect(result.generation == seeded.generation + 1)
        #expect(!result.hasEarlier)
        #expect(try fileText(result) == "{\"n\":1}\n{\"n\":5}\n")
    }

    /// The other branch of the same gate: in tail mode a cache holding a
    /// `before` reads forward and keeps it.
    @Test func inTailModeACacheHoldingBeforeReadsForwardAndKeepsIt() async throws {
        let provider = ScriptedProvider([Self.page("{\"n\":6}\n", #"{"cursor":"c-2"}"#)])
        let sync = makeSync(provider, policy: Self.liveTail)
        try seedTail(sync)

        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read(since: "c-1")])
        #expect(try stored(sync).before == "b-1")
        #expect(result.hasEarlier)
    }

    /// A tail answer with no envelope, or one without a cursor, gives the cache
    /// nothing to continue forward from. It is discarded and the same sync
    /// ends in a full forward read.
    @Test(arguments: ["", #"{"before":"b"}"#, "{not json"])
    func aTailAnswerWithoutACursorFallsBackToAFullRead(stderr: String) async throws {
        let provider = ScriptedProvider([
            Self.page("{\"tail\":1}\n", stderr),
            Self.page("{\"n\":1}\n{\"n\":2}\n", #"{"cursor":"c-2"}"#),
        ])
        let sync = makeSync(provider, pageCap: 1, policy: Self.liveTail)
        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")

        #expect(await provider.calls == [tail(), read()])
        #expect(try fileText(result) == "{\"n\":1}\n{\"n\":2}\n")
        #expect(try stored(sync).before == nil)
        #expect(try stored(sync).cursor == "c-2")
        #expect(result.caughtUp)
        #expect(!result.hasEarlier)
    }

    /// `--tail` never sets `more`; one that does is ignored.
    @Test func aTailResetIsCaughtUpEvenIfMoreIsSet() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor":"c","before":"b","more":true}"#),
        ])
        let sync = makeSync(provider, policy: Self.liveTail)
        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(result.caughtUp)
        #expect(await provider.calls == [tail()])
    }

    /// After a daemon restart the hint store is empty: the on-screen sync
    /// must not overwrite the recorded hint with nothing, or the first
    /// sighting would read as a change and refetch.
    @Test func anUnknownHintLeavesTheRecordedHintAlone() async throws {
        let recorded = RemoteTranscriptHint(id: "c1", size: 100)
        let provider = ScriptedProvider([Self.page("{\"n\":2}\n", #"{"cursor":"c-2"}"#)])
        let sync = makeSync(provider, policy: Self.liveTail)
        try seedForward(sync, hint: recorded)

        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(result.caughtUp)
        #expect(try stored(sync).hint == recorded)
    }

    @Test func theHintIsRecordedOnlyWhenCaughtUp() async throws {
        let recorded = RemoteTranscriptHint(id: "c1", size: 100)
        let provider = ScriptedProvider([Self.page("{\"n\":2}\n", #"{"cursor":"c-2","more":true}"#)])
        let sync = makeSync(
            provider, pageCap: 1, policy: Self.policy(hint: RemoteTranscriptHint(id: "c1", size: 200)))
        try seedForward(sync, hint: recorded)

        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(!result.caughtUp)
        #expect(try stored(sync).hint == recorded)
    }

    /// The flag governs decisions, not bookkeeping.
    @Test func theHintIsRecordedWithTheFlagOff() async throws {
        let hint = RemoteTranscriptHint(id: "c1", size: 5)
        let provider = ScriptedProvider([Self.page("{\"n\":1}\n", #"{"cursor":"c-1"}"#)])
        let sync = makeSync(provider, policy: Self.policy(enabled: false, tail: false, hint: hint))
        let result = try await sync.sync(provider: "agentbox", sessionID: "s-1")
        #expect(await provider.calls == [read()])
        #expect(result.caughtUp)
        #expect(try stored(sync).hint == hint)
    }

    // MARK: - Load earlier

    @Test func loadEarlierPrependsAndBumpsHead() async throws {
        let provider = ScriptedProvider([Self.page("{\"n\":3}\n{\"n\":4}\n", #"{"before":"b-0"}"#)])
        let sync = makeSync(provider, policy: Self.liveTail)
        let seeded = try seedTail(sync)

        let outcome = try await sync.loadEarlier(
            provider: "agentbox", sessionID: "s-1", requestGeneration: seeded.generation)

        #expect(await provider.calls == [readBefore("b-1")])
        #expect(outcome == RemoteTranscriptLoadEarlierOutcome(
            generation: seeded.generation, head: 1, reachedStart: false, expired: false, discarded: false))
        let state = try stored(sync)
        #expect(state.cursor == "c-1")
        #expect(state.before == "b-0")
        #expect(try String(contentsOf: cache(sync).transcriptURL, encoding: .utf8)
            == "{\"n\":3}\n{\"n\":4}\n{\"n\":5}\n")
    }

    @Test func loadEarlierReachingTheStartClearsBefore() async throws {
        let provider = ScriptedProvider([Self.page("{\"n\":4}\n", "")])
        let sync = makeSync(provider, policy: Self.liveTail)
        let seeded = try seedTail(sync)

        let outcome = try await sync.loadEarlier(
            provider: "agentbox", sessionID: "s-1", requestGeneration: seeded.generation)
        #expect(outcome.reachedStart)
        #expect(!outcome.expired)
        #expect(outcome.head == 1)
        #expect(try stored(sync).before == nil)
    }

    @Test func loadEarlierOnCursorExpiredClearsBeforeAndReportsExpired() async throws {
        let provider = ScriptedProvider([
            ProviderResult(
                exitCode: 1, stdout: Data(#"{"error":{"code":"cursor_expired","message":"gone"}}"#.utf8),
                stderr: ""),
        ])
        let sync = makeSync(provider, policy: Self.liveTail)
        let seeded = try seedTail(sync)
        let bytes = try Data(contentsOf: cache(sync).transcriptURL)

        let outcome = try await sync.loadEarlier(
            provider: "agentbox", sessionID: "s-1", requestGeneration: seeded.generation)
        #expect(outcome.reachedStart)
        #expect(outcome.expired)
        #expect(outcome.head == seeded.head)
        #expect(try stored(sync).before == nil)
        #expect(try Data(contentsOf: cache(sync).transcriptURL) == bytes)
    }

    @Test func loadEarlierWithAMalformedEnvelopeWritesNothing() async throws {
        let provider = ScriptedProvider([Self.page("{\"n\":4}\n", #"{"before":7}"#)])
        let sync = makeSync(provider, policy: Self.liveTail)
        let seeded = try seedTail(sync)
        let bytes = try Data(contentsOf: cache(sync).transcriptURL)

        await #expect(throws: RemoteTranscriptSyncError.providerFailed(
            message: "malformed transcript read --before envelope")) {
            try await sync.loadEarlier(provider: "agentbox", sessionID: "s-1", requestGeneration: seeded.generation)
        }
        #expect(try stored(sync) == seeded)
        #expect(try Data(contentsOf: cache(sync).transcriptURL) == bytes)
    }

    @Test func loadEarlierWithAnyOtherFailureWritesNothing() async throws {
        let provider = ScriptedProvider([
            ProviderResult(
                exitCode: 1, stdout: Data(#"{"error":{"code":"boom","message":"transport dropped"}}"#.utf8),
                stderr: ""),
        ])
        let sync = makeSync(provider, policy: Self.liveTail)
        let seeded = try seedTail(sync)

        await #expect(throws: RemoteTranscriptSyncError.providerFailed(message: "transport dropped")) {
            try await sync.loadEarlier(provider: "agentbox", sessionID: "s-1", requestGeneration: seeded.generation)
        }
        #expect(try stored(sync) == seeded)
    }

    /// A page that cannot advance — empty with a `before`, or whose `before`
    /// is the cursor just sent — must not let a scroll-up loop forever on the
    /// same request: `before` is cleared and the start reported, and a
    /// non-empty page is still prepended.
    @Test(arguments: [("", "b-0"), ("{\"n\":0}\n", "b-1")])
    func loadEarlierThatMakesNoProgressStopsAtTheStart(page: String, nextBefore: String) async throws {
        let provider = ScriptedProvider([Self.page(page, #"{"before":"\#(nextBefore)"}"#)])
        let sync = makeSync(provider, policy: Self.liveTail)
        let seeded = try seedTail(sync)

        let outcome = try await sync.loadEarlier(
            provider: "agentbox", sessionID: "s-1", requestGeneration: seeded.generation)
        #expect(outcome.reachedStart)
        #expect(!outcome.expired)
        #expect(try stored(sync).before == nil)
        let text = try String(contentsOf: cache(sync).transcriptURL, encoding: .utf8)
        #expect(text == page + "{\"n\":5}\n")
        #expect(outcome.head == (page.isEmpty ? seeded.head : seeded.head + 1))
    }

    @Test func loadEarlierWithNoBeforeReportsTheStartWithoutACall() async throws {
        let provider = ScriptedProvider([])
        let sync = makeSync(provider, policy: Self.liveTail)
        let seeded = try seedForward(sync)

        let outcome = try await sync.loadEarlier(
            provider: "agentbox", sessionID: "s-1", requestGeneration: seeded.generation)
        #expect(outcome.reachedStart)
        #expect(await provider.calls.isEmpty)
    }

    /// The caller's generation is stale: no provider call, `discarded`, and
    /// the cache's own generation to resync from.
    @Test func aLoadEarlierPageIsDiscardedWhenTheGenerationChanged() async throws {
        let provider = ScriptedProvider([])
        let sync = makeSync(provider, policy: Self.liveTail)
        let seeded = try seedTail(sync)
        let bytes = try Data(contentsOf: cache(sync).transcriptURL)

        let outcome = try await sync.loadEarlier(
            provider: "agentbox", sessionID: "s-1", requestGeneration: seeded.generation - 1)
        #expect(outcome.discarded)
        #expect(outcome.generation == seeded.generation)
        #expect(await provider.calls.isEmpty)
        #expect(try Data(contentsOf: cache(sync).transcriptURL) == bytes)
    }

    /// A load queued on the lane behind a sync that resets the cache sees the
    /// new generation when its turn comes, and makes no provider call.
    @Test func aLoadEarlierQueuedBehindAResettingSyncIsDiscarded() async throws {
        let gate = Gate()
        let provider = ScriptedProvider([
            Self.page("{\"r\":1}\n", #"{"cursor":"c","reset":true}"#),
        ], holdFirst: gate)
        let sync = makeSync(provider, policy: Self.liveTail)
        let seeded = try seedTail(sync)

        async let synced = sync.sync(provider: "agentbox", sessionID: "s-1")
        let started = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await provider.calls.count == 1
        }
        async let loaded = sync.loadEarlier(
            provider: "agentbox", sessionID: "s-1", requestGeneration: seeded.generation)
        let queued = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await sync.laneWaiterCount(provider: "agentbox", sessionID: "s-1") == 1
        }
        await gate.open()

        let syncResult = try await synced
        let outcome = try await loaded
        #expect(started == .satisfied)
        #expect(queued == .satisfied)
        #expect(await provider.calls == [read(since: "c-1")])
        #expect(syncResult.generation == seeded.generation + 1)
        #expect(outcome.discarded)
        #expect(outcome.generation == seeded.generation + 1)
    }

    /// A load and a sync never run at once on one lane: the load waits for
    /// the sync's provider call, then runs.
    @Test func loadEarlierAndSyncNeverOverlapOnOneLane() async throws {
        let gate = Gate()
        let provider = ScriptedProvider([
            Self.page("{\"n\":6}\n", #"{"cursor":"c-2"}"#),
            Self.page("{\"n\":4}\n", #"{"before":"b-0"}"#),
        ], holdFirst: gate)
        let sync = makeSync(provider, policy: Self.liveTail)
        let seeded = try seedTail(sync)

        async let synced = sync.sync(provider: "agentbox", sessionID: "s-1")
        let started = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await provider.calls.count == 1
        }
        async let loaded = sync.loadEarlier(
            provider: "agentbox", sessionID: "s-1", requestGeneration: seeded.generation)
        let queued = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await sync.laneWaiterCount(provider: "agentbox", sessionID: "s-1") == 1
        }
        let callsWhileHeld = await provider.calls.count
        await gate.open()

        _ = try await synced
        let outcome = try await loaded
        #expect(started == .satisfied)
        #expect(queued == .satisfied)
        #expect(callsWhileHeld == 1)
        #expect(await provider.calls == [read(since: "c-1"), readBefore("b-1")])
        #expect(!outcome.discarded)
        #expect(try String(contentsOf: cache(sync).transcriptURL, encoding: .utf8)
            == "{\"n\":4}\n{\"n\":5}\n{\"n\":6}\n")
    }

    /// A discard that lands while a load's provider call is in flight drops
    /// the page instead of recreating the directory.
    @Test func aDiscardDropsAnInFlightLoadEarlier() async throws {
        let gate = Gate()
        let provider = ScriptedProvider([
            Self.page("{\"n\":4}\n", #"{"before":"b-0"}"#),
        ], holdFirst: gate)
        let sync = makeSync(provider, policy: Self.liveTail)
        let seeded = try seedTail(sync)
        let directory = cache(sync).directory

        async let loaded = sync.loadEarlier(
            provider: "agentbox", sessionID: "s-1", requestGeneration: seeded.generation)
        let started = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await provider.calls.count == 1
        }
        await sync.discard(provider: "agentbox", sessionID: "s-1")
        await gate.open()

        var thrown: RemoteTranscriptSyncError?
        do { _ = try await loaded } catch let error as RemoteTranscriptSyncError { thrown = error }
        #expect(started == .satisfied)
        #expect(thrown == .discarded)
        #expect(FileManager.default.fileExists(atPath: directory.path) == false,
                "the in-flight page recreated the discarded cache")
    }

    // MARK: - Hint store

    /// Unknown until sighted; a sighting without a hint removes the entry
    /// rather than keeping a stale one; sessions are keyed apart.
    @Test func theHintStoreRecordsReplacesAndForgets() async {
        let hints = RemoteTranscriptHints()
        #expect(await hints.latest(provider: "agentbox", sessionID: "s-1") == nil)
        await hints.record(provider: "agentbox", sessionID: "s-1", hint: RemoteTranscriptHint(id: "c1", size: 1))
        await hints.record(provider: "agentbox", sessionID: "s-1", hint: RemoteTranscriptHint(id: "c1", size: 2))
        await hints.record(provider: "agentbox", sessionID: "s-2", hint: RemoteTranscriptHint(id: "d1", size: 9))
        #expect(await hints.latest(provider: "agentbox", sessionID: "s-1") == RemoteTranscriptHint(id: "c1", size: 2))
        await hints.record(provider: "agentbox", sessionID: "s-1", hint: nil)
        #expect(await hints.latest(provider: "agentbox", sessionID: "s-1") == nil)
        #expect(await hints.latest(provider: "agentbox", sessionID: "s-2") == RemoteTranscriptHint(id: "d1", size: 9))
    }
}
