import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

private typealias Fixture = TranscriptStreamFixtures

/// `TranscriptSource`'s stream leg: reading `transcript-stream.json` on each
/// tick, keeping the last good snapshot through a cut-off read, and the two
/// retire facts it decides — which blocks the JSONL confirmed, and whether the
/// mod's heartbeat went stale.
@Suite("TranscriptSourceStream")
struct TranscriptSourceStreamTests {

    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static let first = Fixture.snapshot([Fixture.step(0, [Fixture.text("Hel")])])
    private static let second = Fixture.snapshot([Fixture.step(0, [Fixture.text("Hello", ended: true, uuid: "r1")])])

    @Test("a tick reads the file and reports the change once")
    func aTickReadsTheSnapshot() async throws {
        let path = try Fixture.streamPath()
        try Fixture.write(Self.first, to: path)
        let source = TranscriptSource()

        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.now))
        #expect(await source.streamSnapshot(sessionID: "s1") == Self.first)
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.now) == false,
                "an unchanged file is no news")

        try Fixture.write(Self.second, to: path)
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.now))
        #expect(await source.streamSnapshot(sessionID: "s1") == Self.second)
    }

    /// The mod's writes are not atomic, so a tick can read half a file. That is
    /// no news: the pane keeps what it showed.
    @Test("a cut-off read keeps the last good snapshot")
    func aCutOffReadKeepsTheLastSnapshot() async throws {
        let path = try Fixture.streamPath()
        try Fixture.write(Self.first, to: path)
        let source = TranscriptSource()
        await source.refreshStream(sessionID: "s1", path: path, now: Self.now)

        let whole = Fixture.json(Self.second)
        try String(whole.prefix(whole.count / 2)).write(toFile: path, atomically: false, encoding: .utf8)
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.now) == false)
        #expect(await source.streamSnapshot(sessionID: "s1") == Self.first)

        // The write finishes; the next tick sees it.
        try Fixture.write(Self.second, to: path)
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.now))
        #expect(await source.streamSnapshot(sessionID: "s1") == Self.second)
    }

    @Test("an unknown schema version keeps the last good snapshot")
    func anUnknownVersionKeepsTheLastSnapshot() async throws {
        let path = try Fixture.streamPath()
        try Fixture.write(Self.first, to: path)
        let source = TranscriptSource()
        await source.refreshStream(sessionID: "s1", path: path, now: Self.now)

        try Fixture.json(Self.second, schemaVersion: 99).write(toFile: path, atomically: false, encoding: .utf8)
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.now) == false)
        #expect(await source.streamSnapshot(sessionID: "s1") == Self.first)
    }

    @Test("a missing file is no stream, and a file that disappears drops the snapshot")
    func aMissingFileIsNoStream() async throws {
        let path = try Fixture.streamPath()
        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.now) == false)
        #expect(await source.streamSnapshot(sessionID: "s1") == nil)

        try Fixture.write(Self.first, to: path)
        await source.refreshStream(sessionID: "s1", path: path, now: Self.now)
        try FileManager.default.removeItem(atPath: path)
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.now))
        #expect(await source.streamSnapshot(sessionID: "s1") == nil)
    }

    /// Retire rule 1's input: only a `uuid` the JSONL holds a row for is
    /// confirmed.
    @Test("the snapshot names exactly the block uuids the JSONL has rows for")
    func confirmedUUIDsAreThoseTheTranscriptHolds() async throws {
        let transcript = try Fixture.transcript([Fixture.assistantRow(uuid: "r1", text: "Hello")])
        let path = try Fixture.streamPath()
        try Fixture.write(Fixture.snapshot([Fixture.step(0, [
            Fixture.text("Hello", ended: true, uuid: "r1"),
            Fixture.text("World", ended: true, uuid: "r2"),
        ])]), to: path)
        let source = TranscriptSource()
        await source.refreshStream(sessionID: "s1", path: path, now: Self.now)

        #expect(await source.snapshot(sessionID: "s1").confirmedUUIDs.isEmpty,
                "nothing confirms before the transcript is read")

        await source.refresh(sessionID: "s1", path: transcript)
        let snapshot = await source.snapshot(sessionID: "s1")
        #expect(snapshot.confirmedUUIDs == ["r1"])
        #expect(snapshot.items.map(\.id) == ["r1#0"])
    }

    /// Retire rule 3's input, measured against the `now` handed in.
    @Test("the heartbeat goes stale past 90 s and back when the mod beats again")
    func theHeartbeatFlag() async throws {
        let path = try Fixture.streamPath()
        try Fixture.write(Self.first, to: path)
        try Fixture.writeHeartbeat(beside: path, at: Self.now)
        let source = TranscriptSource()

        await source.refreshStream(sessionID: "s1", path: path, now: Self.now)
        #expect(await source.snapshot(sessionID: "s1").heartbeatStale == false)

        let later = Self.now.addingTimeInterval(91)
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: later),
                "the heartbeat going stale is news even with the file unchanged")
        #expect(await source.snapshot(sessionID: "s1").heartbeatStale)

        try Fixture.writeHeartbeat(beside: path, at: later)
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: later))
        #expect(await source.snapshot(sessionID: "s1").heartbeatStale == false)
    }

    /// The heartbeat can only retire blocks, so a snapshot with none never
    /// reads it.
    @Test("a snapshot with no blocks never reads the heartbeat as stale")
    func noBlocksNoHeartbeat() async throws {
        let path = try Fixture.streamPath()
        try Fixture.write(Fixture.snapshot([]), to: path)
        try Fixture.writeHeartbeat(beside: path, at: Self.now)
        let source = TranscriptSource()

        await source.refreshStream(sessionID: "s1", path: path, now: Self.now.addingTimeInterval(1_000))
        #expect(await source.snapshot(sessionID: "s1").heartbeatStale == false)
    }

    @Test("a different path under the same session starts from that file")
    func aNewPathStartsOver() async throws {
        let old = try Fixture.streamPath()
        let new = try Fixture.streamPath()
        try Fixture.write(Self.first, to: old)
        try Fixture.write(Self.second, to: new)
        let source = TranscriptSource()

        await source.refreshStream(sessionID: "s1", path: old, now: Self.now)
        #expect(await source.refreshStream(sessionID: "s1", path: new, now: Self.now))
        #expect(await source.streamSnapshot(sessionID: "s1") == Self.second)
    }

    @Test("forget drops the stream snapshot with the transcript")
    func forgetDropsTheStream() async throws {
        let path = try Fixture.streamPath()
        try Fixture.write(Self.first, to: path)
        let source = TranscriptSource()
        await source.refreshStream(sessionID: "s1", path: path, now: Self.now)
        #expect(await source.trackedStreamSessionCount == 1)

        await source.forget(sessionID: "s1")

        #expect(await source.trackedStreamSessionCount == 0)
        #expect(await source.streamSnapshot(sessionID: "s1") == nil)
    }
}
