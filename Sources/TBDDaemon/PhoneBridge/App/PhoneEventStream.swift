import Foundation

/// One device's numbered events, and the recent ones kept for a reconnecting
/// phone to replay (spec section 7, "Reconnect").
///
/// Every event sent to a phone carries `seq`, one more than the last, from 1.
/// A reconnecting phone names the stream it was on and the last `seq` it saw,
/// and gets back only the events after that, provided this is still that
/// stream and the ring still reaches back that far. Otherwise it starts over
/// from a fresh snapshot.
///
/// The ring keeps the newest events, dropping the oldest while it holds more
/// than `ringCount` of them or their bytes come to more than `ringBytes`. So
/// the kept events always run without a gap up to `lastSeq`.
struct PhoneEventStream: Sendable {
    private struct Kept: Sendable {
        let seq: Int
        let bytes: Data
    }

    let streamID: String                                // UUID string, new per device state
    private(set) var lastSeq: Int                       // 0 before the first event
    private let ringCount: Int
    private let ringBytes: Int
    /// Oldest first; seqs run without a gap and end at `lastSeq`.
    private var ring: [Kept] = []
    private var keptBytes = 0

    init(ringCount: Int = PhoneAppConstants.eventRingCount, ringBytes: Int = PhoneAppConstants.eventRingBytes) {
        self.streamID = UUID().uuidString
        self.lastSeq = 0
        self.ringCount = ringCount
        self.ringBytes = ringBytes
    }

    /// Assigns the next seq, encodes the event envelope, keeps it in the ring, returns the bytes to send.
    ///
    /// When the encoding throws, nothing changes: the seq is not used, so the
    /// phone never sees a gap.
    mutating func append<D: Codable>(_ name: PhoneAppEventName, data: D) throws -> Data {
        let seq = lastSeq + 1
        let bytes = try PhoneAppCoding.event(name, seq: seq, data: data)
        lastSeq = seq
        ring.append(Kept(seq: seq, bytes: bytes))
        keptBytes += bytes.count
        var drop = 0
        while ring.count - drop > ringCount || keptBytes > ringBytes, drop < ring.count {
            keptBytes -= ring[drop].bytes.count
            drop += 1
        }
        ring.removeFirst(drop)
        return bytes
    }

    /// The kept events after `sinceSeq`, or nil when `stream` differs or the ring no longer reaches back to sinceSeq + 1.
    ///
    /// - An empty array means the phone has missed nothing: this is its stream
    ///   and `sinceSeq == lastSeq`.
    /// - nil means the phone must start over from a fresh snapshot. That
    ///   covers a missing or different stream ID, a missing `sinceSeq`, one
    ///   below 0, one above `lastSeq` (no phone on this stream can have seen
    ///   it), and a gap the ring has already dropped.
    func replay(stream: String?, sinceSeq: Int?) -> [Data]? {
        guard let stream, stream == streamID, let sinceSeq, sinceSeq >= 0, sinceSeq <= lastSeq else {
            return nil
        }
        if sinceSeq == lastSeq { return [] }
        guard let first = ring.first, first.seq <= sinceSeq + 1 else { return nil }
        return ring[(sinceSeq + 1 - first.seq)...].map(\.bytes)
    }
}
