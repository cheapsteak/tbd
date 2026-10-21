import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

private typealias Fixture = TranscriptStreamFixtures

/// `StreamFileReader` — the whole-file decoder for the session mod's
/// `transcript-stream.json`, and the heartbeat read beside it.
@Suite("StreamFileReader")
struct StreamFileReaderTests {

    private static let snapshot = Fixture.snapshot(completion: "answer", [
        Fixture.step(0, ended: true, stopReason: "tool_use", [
            Fixture.thinking("Plan", ended: true, uuid: "r1"),
            Fixture.text("Answer", ended: true, uuid: "r2"),
        ]),
        Fixture.step(1, [Fixture.text("More")]),
    ])

    @Test("a good file decodes to the snapshot the mod wrote")
    func aGoodFileDecodes() throws {
        let path = try Fixture.streamPath()
        try Fixture.write(Self.snapshot, to: path)

        #expect(StreamFileReader.read(path: path) == .snapshot(Self.snapshot))
    }

    @Test("a missing file is no stream")
    func aMissingFileIsMissing() throws {
        let path = try Fixture.streamPath()
        #expect(StreamFileReader.read(path: path) == .missing)
    }

    /// `$.fs` writes are not atomic, so a read can land mid-write.
    @Test("a cut-off file is no news")
    func aCutOffFileIsNoNews() throws {
        let path = try Fixture.streamPath()
        let whole = Fixture.json(Self.snapshot)
        try String(whole.prefix(whole.count / 2)).write(toFile: path, atomically: false, encoding: .utf8)

        #expect(StreamFileReader.read(path: path) == .noNews)
    }

    @Test("an empty file is no news")
    func anEmptyFileIsNoNews() throws {
        let path = try Fixture.streamPath()
        try "".write(toFile: path, atomically: false, encoding: .utf8)
        #expect(StreamFileReader.read(path: path) == .noNews)
    }

    @Test("an unknown schema version is no news")
    func anUnknownVersionIsNoNews() throws {
        let path = try Fixture.streamPath()
        try Fixture.json(Self.snapshot, schemaVersion: 2).write(toFile: path, atomically: false, encoding: .utf8)

        #expect(StreamFileReader.read(path: path) == .noNews)
        #expect(StreamFileReader.decode(Data(Fixture.json(Self.snapshot).utf8)) == Self.snapshot)
    }

    /// A newer mod may stream a kind this build cannot show; the file still
    /// decodes, and the block keeps its position.
    @Test("an unknown block kind decodes as other")
    func anUnknownBlockKindDecodes() throws {
        let stream = Fixture.snapshot([Fixture.step(0, [.init(kind: .other("image"), text: "", ended: true, uuid: nil)])])
        #expect(StreamFileReader.decode(Data(Fixture.json(stream).utf8))?.steps.first?.blocks.first?.kind
                == .other("image"))
    }

    @Test("a turn with no completion and a step with no stop reason decode as nil")
    func nullsDecodeAsNil() throws {
        let stream = Fixture.snapshot([Fixture.step(0, [Fixture.text("Hi")])])
        let decoded = try #require(StreamFileReader.decode(Data(Fixture.json(stream).utf8)))
        #expect(decoded.turn == .init(id: "turn-1", completion: nil))
        #expect(decoded.steps.first?.stopReason == nil)
        #expect(decoded.blockUUIDs.isEmpty)
    }

    // MARK: - Heartbeat

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("no alive.json is not a stale heartbeat")
    func noHeartbeatIsNotStale() throws {
        let path = try Fixture.streamPath()
        #expect(StreamFileReader.heartbeatIsStale(streamPath: path, now: Self.now) == false)
    }

    @Test("a heartbeat inside 90 s is fresh and one past it is stale")
    func theHeartbeatGoesStalePastNinetySeconds() throws {
        let path = try Fixture.streamPath()

        try Fixture.writeHeartbeat(beside: path, at: Self.now.addingTimeInterval(-89))
        #expect(StreamFileReader.heartbeatIsStale(streamPath: path, now: Self.now) == false)

        try Fixture.writeHeartbeat(beside: path, at: Self.now.addingTimeInterval(-91))
        #expect(StreamFileReader.heartbeatIsStale(streamPath: path, now: Self.now))
    }

    @Test("the shared alive record goes stale strictly after 90 s")
    func theSharedRecordBoundary() {
        let record = SessionModSessionFiles.AliveRecord(
            sessionId: "s1", incarnationId: "x", features: [], heartbeatAtMs: 1_000_000)
        #expect(SessionModSessionFiles.heartbeatStaleAfter == 90)
        #expect(!record.isStale(now: Date(timeIntervalSince1970: 1_000 + 90)))
        #expect(record.isStale(now: Date(timeIntervalSince1970: 1_000 + 90.001)))
    }
}
