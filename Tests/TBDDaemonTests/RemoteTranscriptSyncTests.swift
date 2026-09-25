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
        _ provider: ScriptedProvider, pageCap: Int = RemoteTranscriptSync.defaultPageCap
    ) -> RemoteTranscriptSync {
        RemoteTranscriptSync(environment: environment, pageCap: pageCap) { _, verb in
            try await provider.call(verb)
        }
    }

    private func fileText(_ result: RemoteTranscriptSyncResult) throws -> String {
        try String(contentsOfFile: result.path, encoding: .utf8)
    }

    private func read(since cursor: String? = nil) -> [String] {
        RemoteVerb.transcriptRead(sessionID: "s-1", since: cursor)
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

    // MARK: - Paging

    @Test func pagesWhileMoreAndStopsWhenCaughtUp() async throws {
        let provider = ScriptedProvider([
            Self.page("{\"n\":1}\n", #"{"cursor": "c-1", "more": true}"#),
            Self.page("{\"n\":2}\n", #"{"cursor": "c-2", "more": true}"#),
            Self.page("{\"n\":3}\n", #"{"cursor": "c-3"}"#),
        ])
        let sync = makeSync(provider)
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
        let sync = makeSync(provider)
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
        let sync = makeSync(provider)
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
}
