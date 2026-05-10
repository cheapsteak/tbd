import Foundation

/// One JSONL line in a channel file. `(channel, seq)` is the message identity.
public struct ChannelMessage: Codable, Equatable, Sendable {
    public let seq: Int
    public let ts: Date
    public let fromSession: String
    public let fromLabel: String
    public let body: String

    public init(seq: Int, ts: Date, fromSession: String, fromLabel: String, body: String) {
        self.seq = seq
        self.ts = ts
        self.fromSession = fromSession
        self.fromLabel = fromLabel
        self.body = body
    }

    enum CodingKeys: String, CodingKey {
        case seq, ts, fromSession = "from_session", fromLabel = "from_label", body
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Encode this message as one JSONL line ending in `\n`. Throws if encoding fails.
    public func encodeLine() throws -> Data {
        var data = try Self.encoder.encode(self)
        data.append(0x0A)  // '\n'
        return data
    }

    /// Decode one JSONL line (with or without trailing newline) into a message.
    public static func decodeLine(_ data: Data) throws -> ChannelMessage {
        let trimmed: Data
        if data.last == 0x0A {
            trimmed = data.subdata(in: 0..<data.count - 1)
        } else {
            trimmed = data
        }
        return try decoder.decode(ChannelMessage.self, from: trimmed)
    }
}
