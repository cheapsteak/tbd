import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared
import TestSupport

// Tier 1: a scratch TBD_HOME passed as an explicit environment; no daemon.

/// `RemoteTranscriptSyncSnapshot.cached(for:)`: a pane shows what the daemon
/// already cached before the first `remote.transcriptSync` returns, because
/// the cache path is deterministic.
@MainActor
@Suite("Remote transcript cached snapshot", .clockDriven, .serialized)
struct RemoteTranscriptCachedSnapshotTests {
    private static let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")

    /// A scratch home per test instance; each test removes it on the way out.
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-transcript-cached-\(UUID().uuidString)", isDirectory: true)

    private var environment: [String: String] { ["TBD_HOME": home.path] }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: home)
    }

    private var directory: URL {
        TBDConstants.remoteTranscriptDir(
            provider: Self.selection.provider, sessionID: Self.selection.sessionID,
            environment: environment)
    }

    private func fixtureText() throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: "remote-transcript-sample", withExtension: "jsonl",
            subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Writes the cache the way the daemon leaves it: `transcript.jsonl`, and
    /// `state.json` when `generation` is given.
    private func writeCache(_ text: String, generation: Int?) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = directory.appendingPathComponent(TBDConstants.remoteTranscriptFileName)
        try text.write(to: transcript, atomically: true, encoding: .utf8)
        if let generation {
            let state = #"{"cursor":"c-1","length":\#(text.utf8.count),"generation":\#(generation)}"#
            try state.write(
                to: directory.appendingPathComponent(TBDConstants.remoteTranscriptStateFileName),
                atomically: true, encoding: .utf8)
        }
        return transcript
    }

    @Test("no cache file: nothing to seed, so the pane keeps its full loading state")
    func noCacheFile() {
        defer { cleanUp() }
        #expect(RemoteTranscriptSyncSnapshot.cached(for: Self.selection, environment: environment) == nil)
    }

    @Test("a cache file seeds its path and state.json's generation, not caught up")
    func seedsPathAndGeneration() throws {
        defer { cleanUp() }
        let transcript = try writeCache(try fixtureText(), generation: 4)
        let seed = RemoteTranscriptSyncSnapshot.cached(for: Self.selection, environment: environment)
        #expect(seed == RemoteTranscriptSyncSnapshot(
            path: transcript.path, generation: 4, caughtUp: false, refreshToken: 0))
        #expect(transcript.path.hasPrefix(home.path), "the path must follow TBD_HOME")
    }

    @Test("a cache file seeds state.json's head; hasEarlier waits for a sync even with a before cursor")
    func seedsHeadButNotHasEarlier() throws {
        defer { cleanUp() }
        _ = try writeCache(try fixtureText(), generation: 2)
        let stateURL = directory.appendingPathComponent(TBDConstants.remoteTranscriptStateFileName)

        try #"{"generation":2,"length":0,"head":3,"before":"b-1"}"#
            .write(to: stateURL, atomically: true, encoding: .utf8)
        let seed = try #require(
            RemoteTranscriptSyncSnapshot.cached(for: Self.selection, environment: environment))
        #expect(seed.generation == 2)
        #expect(seed.head == 3)
        #expect(seed.hasEarlier == false, "only a sync may say there is earlier history")
        #expect(seed.earlier == .idle)
    }

    /// With the flag off the daemon refuses `remote.transcriptLoadEarlier`, so
    /// a pane that loaded on the strength of a `before` left on disk would show
    /// a failed load. Before any sync answers, the pane must start no load and
    /// show no header — even at the top of the table.
    @Test("a cache with a before cursor but no sync yet shows no overlay and starts no load")
    func beforeCursorWithoutASyncDoesNothing() async throws {
        defer { cleanUp() }
        _ = try writeCache(try fixtureText(), generation: 2)
        try #"{"generation":2,"length":0,"head":3,"before":"b-1"}"#.write(
            to: directory.appendingPathComponent(TBDConstants.remoteTranscriptStateFileName),
            atomically: true, encoding: .utf8)
        let loads = FireRecorder<Int>()
        let driver = RemoteTranscriptSyncDriver(
            selection: Self.selection,
            sync: { _ in throw CancellationError() },
            loadEarlier: { _ in
                loads.record(1)
                return RemoteTranscriptLoadEarlierResult(
                    generation: 2, head: 4, reachedStart: false, expired: false)
            },
            initialSnapshot: .cached(for: Self.selection, environment: environment),
            clock: EventDrivenTestClock())
        defer { driver.stop() }

        driver.noteNearTop(true)
        driver.loadEarlier(trigger: .button)
        await settle()
        #expect(loads.values.isEmpty, "a load started before any sync reported hasEarlier")
        #expect(driver.snapshot.earlier == .idle)
        #expect(RemoteTranscriptEarlierHeader.Content.resolve(
            state: driver.snapshot.earlier, hasEarlier: driver.snapshot.hasEarlier, nearTop: true)
            == .hidden)
    }

    @Test("a state.json from before head existed seeds head 0")
    func olderStateSeedsHeadZero() throws {
        defer { cleanUp() }
        _ = try writeCache(try fixtureText(), generation: 4)
        let seed = try #require(
            RemoteTranscriptSyncSnapshot.cached(for: Self.selection, environment: environment))
        #expect(seed.generation == 4)
        #expect(seed.head == 0)
        #expect(seed.hasEarlier == false)
    }

    @Test("a missing or unreadable state.json seeds generation 0; the first sync's generation decides")
    func unreadableStateSeedsZero() throws {
        defer { cleanUp() }
        let transcript = try writeCache(try fixtureText(), generation: nil)
        #expect(RemoteTranscriptSyncSnapshot.cached(for: Self.selection, environment: environment)?
            .generation == 0)

        try "not json".write(
            to: directory.appendingPathComponent(TBDConstants.remoteTranscriptStateFileName),
            atomically: true, encoding: .utf8)
        #expect(RemoteTranscriptSyncSnapshot.cached(for: Self.selection, environment: environment)
            == RemoteTranscriptSyncSnapshot(path: transcript.path, generation: 0, caughtUp: false))
    }

    /// The live pane builds its driver with this seed. Before any sync has
    /// answered, the driver's snapshot already names the cache file, and
    /// reading it yields the conversation — so the pane renders at once
    /// instead of spinning until the first sync returns.
    @Test("a pane mounted over an existing cache shows its items before any sync completes")
    func cachedItemsRenderBeforeTheFirstSync() async throws {
        defer { cleanUp() }
        _ = try writeCache(try fixtureText(), generation: 2)
        let clock = EventDrivenTestClock()
        let started = FireRecorder<Int>()
        let gate = RemoteTranscriptSyncGate()
        let driver = RemoteTranscriptSyncDriver(
            selection: Self.selection,
            sync: { _ in
                started.record(1)
                await gate.wait()
                throw CancellationError()
            },
            initialSnapshot: .cached(for: Self.selection, environment: environment),
            clock: clock)
        defer {
            driver.stop()
            gate.open()
        }

        driver.setActive(true)
        #expect(await started.next(timeout: TestDeadlines.saturatedPass) == 1)
        // The first sync is still held: nothing it could return has arrived.
        #expect(driver.snapshot.refreshToken == 0)
        let path = try #require(driver.snapshot.path, "the pane has no file to read until a sync names one")
        let items = try #require(await RemoteTranscriptTail().read(
            key: RemoteTranscriptTail.storeKey(Self.selection), path: path,
            generation: driver.snapshot.generation))
        #expect(!items.isEmpty)
        #expect(driver.snapshot.generation == 2)
    }
}
