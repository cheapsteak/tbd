import Foundation
import Testing

@testable import TBDDaemonLib

/// A small event payload that says which event it is.
private struct EventMarker: Codable, Equatable {
    let n: Int
}

/// A payload whose encoding always fails.
private struct Unencodable: Codable {
    init() {}

    init(from decoder: any Decoder) throws {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "test payload"))
    }

    func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(0, .init(codingPath: [], debugDescription: "test payload"))
    }
}

/// Tier 1: a value type and JSON. Nothing touches the disk, the network or a
/// clock.
@Suite("Phone event stream")
struct PhoneEventStreamTests {
    /// Appends events carrying markers `range`, returning the bytes `append`
    /// gave back for each.
    private func append(_ range: ClosedRange<Int>, to stream: inout PhoneEventStream) throws -> [Data] {
        try range.map { try stream.append(.sessionsChanged, data: EventMarker(n: $0)) }
    }

    private func decode(_ bytes: Data) throws -> PhoneEventEnvelope<EventMarker> {
        try JSONDecoder().decode(PhoneEventEnvelope<EventMarker>.self, from: bytes)
    }

    @Test func seqIncreasesByOneFromOne() throws {
        var stream = PhoneEventStream()
        #expect(stream.lastSeq == 0)
        let sent = try append(1...3, to: &stream)
        let envelopes = try sent.map { try decode($0) }
        #expect(envelopes.map(\.seq) == [1, 2, 3])
        #expect(envelopes.map(\.data) == [EventMarker(n: 1), EventMarker(n: 2), EventMarker(n: 3)])
        #expect(envelopes.allSatisfy { $0.kind == "event" && $0.event == "sessions.changed" })
        #expect(stream.lastSeq == 3)
    }

    @Test func eachStateHasItsOwnStreamID() {
        let first = PhoneEventStream()
        let second = PhoneEventStream()
        #expect(UUID(uuidString: first.streamID) != nil)
        #expect(first.streamID != second.streamID)
    }

    @Test func replayReturnsOnlyLaterEvents() throws {
        var stream = PhoneEventStream()
        let sent = try append(1...5, to: &stream)
        let replayed = try #require(stream.replay(stream: stream.streamID, sinceSeq: 3))
        #expect(replayed == Array(sent[3...]))
        #expect(try replayed.map { try decode($0).seq } == [4, 5])
        // From the start, every event comes back.
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 0) == sent)
    }

    @Test func aCaughtUpPhoneGetsAnEmptyReplay() throws {
        var stream = PhoneEventStream()
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 0) == [Data]())
        _ = try append(1...2, to: &stream)
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 2) == [Data]())
    }

    @Test func aForeignStreamGetsNoReplay() throws {
        var stream = PhoneEventStream()
        _ = try append(1...3, to: &stream)
        #expect(stream.replay(stream: "other", sinceSeq: 1) == nil)
        #expect(stream.replay(stream: PhoneEventStream().streamID, sinceSeq: 1) == nil)
        #expect(stream.replay(stream: nil, sinceSeq: 1) == nil)
        // Caught up on another stream is still foreign: nil, not an empty list.
        #expect(stream.replay(stream: "other", sinceSeq: 3) == nil)
        #expect(stream.replay(stream: nil, sinceSeq: nil) == nil)
    }

    /// The stream matches, but the phone's position cannot be on it.
    @Test func aPositionThisStreamNeverReachedGetsNoReplay() throws {
        var stream = PhoneEventStream()
        _ = try append(1...3, to: &stream)
        #expect(stream.replay(stream: stream.streamID, sinceSeq: nil) == nil)
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 4) == nil)
        #expect(stream.replay(stream: stream.streamID, sinceSeq: -1) == nil)
    }

    @Test func aGapPastTheRingGetsNoReplay() throws {
        var stream = PhoneEventStream(ringCount: 3)
        let sent = try append(1...5, to: &stream)
        // Seq 2 is gone, so a phone that saw only 1 cannot catch up.
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 1) == nil)
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 0) == nil)
        // A phone that saw 2 needs 3 to 5, which the ring still holds.
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 2) == Array(sent[2...]))
    }

    @Test func theByteCapEvictsToo() throws {
        // Seqs 1 to 9 take one digit each, so these events are all one size.
        let size = try PhoneAppCoding.event(.sessionsChanged, seq: 1, data: EventMarker(n: 1)).count
        var stream = PhoneEventStream(ringCount: 100, ringBytes: 3 * size)
        let sent = try append(1...5, to: &stream)
        #expect(sent.allSatisfy { $0.count == size })
        // Exactly three events' bytes fit, so seqs 3 to 5 are kept.
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 1) == nil)
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 2) == Array(sent[2...]))
    }

    @Test func anEventLargerThanTheByteCapIsSentButNotKept() throws {
        let size = try PhoneAppCoding.event(.sessionsChanged, seq: 1, data: EventMarker(n: 1)).count
        var stream = PhoneEventStream(ringBytes: size - 1)
        let sent = try stream.append(.sessionsChanged, data: EventMarker(n: 1))
        #expect(try decode(sent).seq == 1)
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 0) == nil)
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 1) == [Data]())
    }

    @Test func aFailedEncodingUsesNoSeq() throws {
        var stream = PhoneEventStream()
        _ = try append(1...2, to: &stream)
        var threw = false
        do {
            _ = try stream.append(.sessionsChanged, data: Unencodable())
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(stream.lastSeq == 2)
        let next = try stream.append(.sessionsChanged, data: EventMarker(n: 3))
        #expect(try decode(next).seq == 3)
        #expect(stream.replay(stream: stream.streamID, sinceSeq: 2) == [next])
    }
}
