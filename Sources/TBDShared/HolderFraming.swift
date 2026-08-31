import Foundation

public enum HolderFramingError: LocalizedError, Equatable {
    /// A length word from the wire claimed more bytes than any real frame can
    /// carry. Refused rather than trusted: a desynced peer would otherwise make
    /// the reader allocate gigabytes on its behalf.
    case oversizedFrame(bytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .oversizedFrame(let bytes, let limit):
            return "holder frame claims \(bytes) bytes, over the \(limit)-byte limit"
        }
    }
}

/// The holder wire framing: `[UInt32 little-endian byte count][JSON]`, both
/// directions.
///
/// It lives in `TBDShared` because both ends speak it — the holder binary
/// serving requests and the daemon-side `HolderClient` issuing them. A second
/// implementation on the daemon side would be two chances to get the length
/// word's endianness, the size cap, or the partial-frame carry wrong, and a
/// framing disagreement between two processes shows up as a desync rather than
/// as an error anybody can read.
public enum HolderFraming {
    /// The largest frame either side will decode. Holder descriptions are a few
    /// hundred bytes; a megabyte is slack for a launch request with a large
    /// environment, and far below "allocate whatever the peer said".
    public static let maximumFrameSize = 1 << 20

    public static func frame(_ response: HolderResponse) throws -> Data { try encode(response) }
    public static func frame(_ request: HolderRequest) throws -> Data { try encode(request) }

    private static func encode<Message: Encodable>(_ message: Message) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        var length = UInt32(payload.count).littleEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }

    /// Pulls every complete frame out of `buffer`, leaving any partial tail
    /// behind for the next read.
    ///
    /// Returning *every* decoded frame rather than the first is the contract,
    /// and callers must queue what they do not use immediately: one `recvmsg`
    /// routinely carries a response and an unsolicited push together, and a
    /// reader that returns the head and discards the tail then hits EOF on its
    /// next read and reports a closed peer for a message that did arrive.
    public static func drain<Message: Decodable>(_ type: Message.Type, from buffer: inout Data) throws -> [Message] {
        var messages: [Message] = []
        while true {
            guard buffer.count >= MemoryLayout<UInt32>.size else { return messages }
            let header = buffer.prefix(MemoryLayout<UInt32>.size)
            let length = Int(header.withUnsafeBytes { raw in
                UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))
            })
            guard length <= maximumFrameSize else {
                throw HolderFramingError.oversizedFrame(bytes: length, limit: maximumFrameSize)
            }
            let total = MemoryLayout<UInt32>.size + length
            guard buffer.count >= total else { return messages }
            let payload = buffer.dropFirst(MemoryLayout<UInt32>.size).prefix(length)
            messages.append(try JSONDecoder().decode(Message.self, from: Data(payload)))
            buffer = Data(buffer.dropFirst(total))
        }
    }

    public static func drainRequests(from buffer: inout Data) throws -> [HolderRequest] {
        try drain(HolderRequest.self, from: &buffer)
    }

    public static func drainResponses(from buffer: inout Data) throws -> [HolderResponse] {
        try drain(HolderResponse.self, from: &buffer)
    }
}
