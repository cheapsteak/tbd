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

    // MARK: - Live-sync fields

    private func writeRawState(_ json: String) throws {
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: cache.stateURL)
    }

    private func encode(_ state: RemoteTranscriptCacheState) throws -> Data {
        try JSONEncoder().encode(state)
    }

    /// A `state.json` an older daemon wrote has none of the new keys. It loads
    /// with them empty, and loading it writes nothing.
    @Test func anOldStateFileDecodesWithTheNewFieldsEmpty() throws {
        let json = #"{"cursor":"c","length":0,"generation":2}"#
        try writeRawState(json)
        let loaded = try cache.load()
        #expect(loaded.cursor == "c")
        #expect(loaded.generation == 2)
        #expect(loaded.before == nil)
        #expect(loaded.head == 0)
        #expect(loaded.hint == nil)
        #expect(loaded.pendingPrepend == false)
        #expect(try String(contentsOf: cache.stateURL, encoding: .utf8) == json)
    }

    @Test func aTailResetRecordsBefore() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"old\":1}\n".utf8), cursor: "c-0", to: state)
        state = try cache.reset(to: Data("{\"n\":1}\n".utf8), cursor: "c", before: "b", from: state)
        #expect(state.before == "b")
        #expect(state.cursor == "c")
        #expect(state.generation == 1)
        #expect(try storedState() == state)
    }

    @Test func aForwardResetClearsBefore() throws {
        var state = try cache.load()
        state = try cache.reset(to: Data("{\"n\":1}\n".utf8), cursor: "c-1", before: "b", from: state)
        state = try cache.reset(to: Data("{\"n\":1}\n{\"n\":2}\n".utf8), cursor: "c", from: state)
        #expect(state.before == nil)
        #expect(try storedState().before == nil)
    }

    @Test func anUnchangedTailResetKeepsTheGenerationButUpdatesBefore() throws {
        var state = try cache.load()
        state = try cache.reset(to: Data("{\"n\":1}\n".utf8), cursor: "c-1", before: "b-1", from: state)
        let generation = state.generation
        state = try cache.reset(to: Data("{\"n\":1}\n".utf8), cursor: "c-2", before: "b-2", from: state)
        #expect(state.generation == generation)
        #expect(state.before == "b-2")
        #expect(state.cursor == "c-2")
        #expect(try storedState() == state)
    }

    /// A reset that changes the file clears the recorded hint: it described
    /// the conversation the cache no longer holds the same way.
    @Test func aChangingResetClearsTheHint() throws {
        var state = try cache.load()
        state = try cache.reset(to: Data("{\"n\":1}\n".utf8), cursor: "c-1", from: state)
        state = try cache.commitHint(RemoteTranscriptHint(id: "c1", size: 10), to: state)
        state = try cache.reset(to: Data("{\"n\":2}\n".utf8), cursor: "c-2", from: state)
        #expect(state.hint == nil)
    }

    @Test func prependPutsThePageFirstAndBumpsHead() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"n\":3}\n".utf8), cursor: "c-3", to: state)
        let generation = state.generation
        state = try cache.prepend(Data("{\"n\":1}\n{\"n\":2}".utf8), before: "b-0", to: state)
        #expect(try fileText() == "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
        let size = try #require(
            try FileManager.default.attributesOfItem(atPath: cache.transcriptURL.path)[.size] as? NSNumber)
        #expect(state.length == size.intValue)
        #expect(state.head == 1)
        #expect(state.before == "b-0")
        #expect(state.generation == generation)
        #expect(state.pendingPrepend == false)
        #expect(state.cursor == "c-3")
        #expect(try storedState() == state)
        // The round trip: a later load reads it back unchanged.
        #expect(try cache.load() == state)
        let names = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") })
    }

    @Test func prependToTheStartClearsBefore() throws {
        var state = try cache.load()
        state = try cache.reset(to: Data("{\"n\":2}\n".utf8), cursor: "c-2", before: "b-1", from: state)
        state = try cache.prepend(Data("{\"n\":1}\n".utf8), before: nil, to: state)
        #expect(state.before == nil)
        #expect(try fileText() == "{\"n\":1}\n{\"n\":2}\n")
    }

    /// A crash between a prepend's rename and its last state write: the file
    /// is longer than `length`, and truncating it would cut the prepended file
    /// in the wrong place. The marker makes `load()` start over instead.
    @Test func aPendingPrependFoundOnLoadResetsTheCache() throws {
        var state = try cache.load()
        state = try cache.reset(to: Data("{\"n\":3}\n".utf8), cursor: "c-3", before: "b-2", from: state)
        var marked = state
        marked.pendingPrepend = true
        try encode(marked).write(to: cache.stateURL)
        try Data("{\"n\":2}\n{\"n\":3}\n".utf8).write(to: cache.transcriptURL)

        let loaded = try cache.load()
        #expect(try fileText().isEmpty)
        #expect(loaded.length == 0)
        #expect(loaded.cursor == nil)
        #expect(loaded.before == nil)
        #expect(loaded.hint == nil)
        #expect(loaded.generation == state.generation + 1)
        #expect(loaded.pendingPrepend == false)
        #expect(try storedState() == loaded)
    }

    /// The crash before the rename leaves the file as it was, with the marker
    /// set. The same reset: one tail refetch is the documented cost.
    @Test func aPendingPrependWithTheFileUntouchedAlsoResets() throws {
        var state = try cache.load()
        state = try cache.reset(to: Data("{\"n\":3}\n".utf8), cursor: "c-3", before: "b-2", from: state)
        var marked = state
        marked.pendingPrepend = true
        try encode(marked).write(to: cache.stateURL)

        let loaded = try cache.load()
        #expect(try fileText().isEmpty)
        #expect(loaded.cursor == nil)
        #expect(loaded.before == nil)
        #expect(loaded.generation == state.generation + 1)
        #expect(loaded.pendingPrepend == false)
    }

    @Test func aStrandedPrependTempFileIsSwept() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"n\":1}\n".utf8), cursor: "c-1", to: state)
        let stranded = cache.directory.appendingPathComponent(".transcript.jsonl.\(UUID().uuidString).tmp")
        try Data("stranded".utf8).write(to: stranded)
        _ = try cache.load()
        #expect(FileManager.default.fileExists(atPath: stranded.path) == false)
    }

    @Test func commitHintWritesOnlyTheHint() throws {
        var state = try cache.load()
        state = try cache.reset(to: Data("{\"n\":1}\n".utf8), cursor: "c-1", before: "b-1", from: state)
        let bytes = try Data(contentsOf: cache.transcriptURL)
        let hint = RemoteTranscriptHint(id: "c1", size: 100)
        let next = try cache.commitHint(hint, to: state)
        var expected = state
        expected.hint = hint
        #expect(next == expected)
        #expect(try storedState() == expected)
        #expect(try Data(contentsOf: cache.transcriptURL) == bytes)
    }

    @Test func clearBeforeWritesOnlyBefore() throws {
        var state = try cache.load()
        state = try cache.reset(to: Data("{\"n\":1}\n".utf8), cursor: "c-1", before: "b-1", from: state)
        state = try cache.commitHint(RemoteTranscriptHint(id: "c1", size: 100), to: state)
        let bytes = try Data(contentsOf: cache.transcriptURL)
        let next = try cache.clearBefore(in: state)
        var expected = state
        expected.before = nil
        #expect(next == expected)
        #expect(try storedState() == expected)
        #expect(try Data(contentsOf: cache.transcriptURL) == bytes)
    }

    /// `peekState` is for readers outside the lane: it never repairs, so an
    /// uncommitted tail stays on disk for the lane's own `load()` to cut.
    @Test func peekStateNeverRepairs() throws {
        var state = try cache.load()
        state = try cache.append(Data("{\"a\":1}\n".utf8), cursor: "c-1", to: state)
        let handle = try FileHandle(forWritingTo: cache.transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"uncommitted\":1}\n".utf8))
        try handle.close()

        #expect(cache.peekState() == state)
        #expect(try fileText() == "{\"a\":1}\n{\"uncommitted\":1}\n")
    }

    @Test func peekStateOfAMissingCacheIsNilAndCreatesNothing() {
        #expect(cache.peekState() == nil)
        #expect(FileManager.default.fileExists(atPath: cache.directory.path) == false)
    }

    @Test func appendKeepsBeforeHeadAndHint() throws {
        var state = try cache.load()
        state = try cache.reset(to: Data("{\"n\":2}\n".utf8), cursor: "c-2", before: "b-1", from: state)
        state = try cache.prepend(Data("{\"n\":1}\n".utf8), before: "b-0", to: state)
        let hint = RemoteTranscriptHint(id: "c1", size: 100)
        state = try cache.commitHint(hint, to: state)
        state = try cache.append(Data("{\"n\":3}\n".utf8), cursor: "c-3", to: state)
        #expect(state.before == "b-0")
        #expect(state.head == 1)
        #expect(state.hint == hint)
        #expect(state.cursor == "c-3")
        #expect(try fileText() == "{\"n\":1}\n{\"n\":2}\n{\"n\":3}\n")
    }
}
