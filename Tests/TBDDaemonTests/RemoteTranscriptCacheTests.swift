import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The on-disk cache under `remote-transcripts/<provider>/<sessionID>/`: append,
/// reset, and the crash repair `load()` performs.
///
/// Tier 1: a temp directory, no daemon.
@Suite("RemoteTranscriptCache")
struct RemoteTranscriptCacheTests: ~Copyable {
    let home: URL
    let cache: RemoteTranscriptCache

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-transcript-cache-\(UUID().uuidString)", isDirectory: true)
        cache = RemoteTranscriptCache(
            provider: "agentbox", sessionID: "s-1", environment: ["TBD_HOME": home.path])
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    private func fileText() throws -> String {
        try String(contentsOf: cache.transcriptURL, encoding: .utf8)
    }

    private func storedState() throws -> RemoteTranscriptCacheState {
        try JSONDecoder().decode(RemoteTranscriptCacheState.self, from: Data(contentsOf: cache.stateURL))
    }

    @Test func pathsFollowTBDHome() {
        #expect(cache.directory.path.hasPrefix(home.appendingPathComponent("remote-transcripts").path))
        #expect(cache.transcriptURL.lastPathComponent == TBDConstants.remoteTranscriptFileName)
        #expect(cache.stateURL.lastPathComponent == TBDConstants.remoteTranscriptStateFileName)
    }

    @Test func aFreshCacheLoadsEmpty() throws {
        #expect(try cache.load() == .empty)
    }

    @Test func appendWritesBytesThenCommitsCursorAndLength() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"a\":1}\n".utf8), cursor: "c-1", to: state)
        state = try cache.append(Data("{\"b\":2}\n".utf8), cursor: "c-2", to: state)
        #expect(try fileText() == "{\"a\":1}\n{\"b\":2}\n")
        #expect(state == RemoteTranscriptCacheState(cursor: "c-2", length: 16, generation: 0))
        #expect(try storedState() == state)
        // The round trip: a later load reads back exactly what was committed.
        #expect(try cache.load() == state)
    }

    @Test func aPageWithoutATrailingNewlineGetsOne() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"a\":1}".utf8), cursor: "c-1", to: state)
        state = try cache.append(Data("{\"b\":2}".utf8), cursor: "c-2", to: state)
        #expect(try fileText() == "{\"a\":1}\n{\"b\":2}\n")
        #expect(state.length == 16)
    }

    @Test func anEmptyPageCommitsOnlyTheCursor() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"a\":1}\n".utf8), cursor: "c-1", to: state)
        state = try cache.append(Data(), cursor: "c-2", to: state)
        #expect(state == RemoteTranscriptCacheState(cursor: "c-2", length: 8, generation: 0))
        #expect(try fileText() == "{\"a\":1}\n")
    }

    @Test func resetReplacesTheFileAndIncrementsGeneration() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"old\":1}\n".utf8), cursor: "c-1", to: state)
        state = try cache.reset(to: Data("{\"new\":1}\n".utf8), cursor: "n-1", from: state)
        #expect(try fileText() == "{\"new\":1}\n")
        #expect(state == RemoteTranscriptCacheState(cursor: "n-1", length: 10, generation: 1))
        #expect(try storedState() == state)
        // No temp file is left beside the transcript.
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).sorted()
        #expect(names == [TBDConstants.remoteTranscriptStateFileName, TBDConstants.remoteTranscriptFileName])
    }

    /// A provider with no incremental support answers every call with the
    /// whole conversation; an unchanged answer must not make readers start over.
    @Test func resetWithIdenticalContentKeepsTheGeneration() throws {
        var state = try cache.load()
        state = try cache.reset(to: Data("{\"a\":1}\n".utf8), cursor: nil, from: state)
        #expect(state.generation == 1)
        state = try cache.reset(to: Data("{\"a\":1}\n".utf8), cursor: nil, from: state)
        #expect(state.generation == 1)
        state = try cache.reset(to: Data("{\"a\":1}\n{\"b\":2}\n".utf8), cursor: nil, from: state)
        #expect(state.generation == 2)
    }

    /// The crash between an append's two writes: bytes on disk past the
    /// recorded length. `load()` truncates them and bumps the generation, so a
    /// reader that already consumed the tail rereads rather than rendering the
    /// re-fetched page twice.
    @Test func loadTruncatesAnUncommittedTailAndBumpsGeneration() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"a\":1}\n".utf8), cursor: "c-1", to: state)
        let handle = try FileHandle(forWritingTo: cache.transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"uncommitted\":1}\n".utf8))
        try handle.close()

        let loaded = try cache.load()
        #expect(try fileText() == "{\"a\":1}\n")
        #expect(loaded == RemoteTranscriptCacheState(cursor: "c-1", length: 8, generation: 1))
        #expect(try storedState() == loaded)
    }

    @Test func loadOfAConsistentPairChangesNothing() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"a\":1}\n".utf8), cursor: "c-1", to: state)
        #expect(try cache.load() == state)
        #expect(try cache.load().generation == 0)
    }

    /// Bytes the state vouches for are gone: no cursor can be trusted, so the
    /// cache starts over under the next generation.
    @Test func loadOfAFileShorterThanItsStateStartsOver() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8), cursor: "c-2", to: state)
        try Data("{\"a\":1}\n".utf8).write(to: cache.transcriptURL)
        let loaded = try cache.load()
        #expect(loaded == RemoteTranscriptCacheState(cursor: nil, length: 0, generation: 1))
        #expect(try fileText().isEmpty)
    }

    /// A crash inside a reset — after the "empty" state commit, before the
    /// final one — repairs to an empty cache that refetches from the start.
    @Test func aResetInterruptedAfterItsFirstStateWriteRepairsToEmpty() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"a\":1}\n".utf8), cursor: "c-1", to: state)
        // What the reset leaves on disk if it dies right after renaming.
        let encoder = JSONEncoder()
        try encoder.encode(RemoteTranscriptCacheState(cursor: nil, length: 0, generation: 1))
            .write(to: cache.stateURL)
        try Data("{\"new\":1}\n".utf8).write(to: cache.transcriptURL)
        try Data("stranded".utf8).write(
            to: cache.directory.appendingPathComponent(".transcript.jsonl.stranded.tmp"))

        let loaded = try cache.load()
        #expect(loaded.cursor == nil)
        #expect(loaded.length == 0)
        #expect(loaded.generation == 2)
        #expect(try fileText().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") })
    }

    @Test func anUnreadableStateWithANonEmptyFileStartsOver() throws {
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data("{\"a\":1}\n".utf8).write(to: cache.transcriptURL)
        try Data("not json".utf8).write(to: cache.stateURL)
        let loaded = try cache.load()
        #expect(loaded == RemoteTranscriptCacheState(cursor: nil, length: 0, generation: 1))
        #expect(try fileText().isEmpty)
    }
}
