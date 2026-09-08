import Foundation

/// One line of a terminal's stream file, `TBDConstants.streamsDir/<terminal-id>.jsonl`.
///
/// The proxy's tee writes these as an assistant turn arrives; the app tails the
/// file and renders the text before the transcript JSONL exists. Every line
/// carries the API message id, so two parent requests in flight against one
/// route interleave rather than clobber each other.
///
/// The encoding is one JSON object per line, keys `type` (`start`, `block`,
/// `text`, `stop`, `aborted`), `message`, `at`, `index`, `text`, `reason`.
public enum ModelProxyStreamLine: Codable, Sendable, Equatable {
    /// `message_start`: a new assistant message began at `at`.
    case start(message: String, at: Date)
    /// `content_block_start` for a text block at `index`.
    case block(message: String, index: Int)
    /// A `text_delta` for the block at `index`.
    case text(message: String, index: Int, text: String)
    /// `message_stop`: the message completed normally.
    case stop(message: String)
    /// The stream ended without `message_stop` — an SSE `error` event, a
    /// dropped connection, or a tee that had to give up.
    case aborted(message: String, reason: String)

    /// The API message id every line is tagged with.
    public var message: String {
        switch self {
        case let .start(message, _): return message
        case let .block(message, _): return message
        case let .text(message, _, _): return message
        case let .stop(message): return message
        case let .aborted(message, _): return message
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, message, at, index, text, reason
    }

    private enum LineType: String, Codable {
        case start, block, text, stop, aborted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(LineType.self, forKey: .type)
        let message = try c.decode(String.self, forKey: .message)
        switch type {
        case .start:
            self = .start(message: message, at: try c.decode(Date.self, forKey: .at))
        case .block:
            self = .block(message: message, index: try c.decode(Int.self, forKey: .index))
        case .text:
            self = .text(
                message: message,
                index: try c.decode(Int.self, forKey: .index),
                text: try c.decode(String.self, forKey: .text)
            )
        case .stop:
            self = .stop(message: message)
        case .aborted:
            self = .aborted(message: message, reason: try c.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(message, forKey: .message)
        switch self {
        case let .start(_, at):
            try c.encode(LineType.start, forKey: .type)
            try c.encode(at, forKey: .at)
        case let .block(_, index):
            try c.encode(LineType.block, forKey: .type)
            try c.encode(index, forKey: .index)
        case let .text(_, index, text):
            try c.encode(LineType.text, forKey: .type)
            try c.encode(index, forKey: .index)
            try c.encode(text, forKey: .text)
        case .stop:
            try c.encode(LineType.stop, forKey: .type)
        case let .aborted(_, reason):
            try c.encode(LineType.aborted, forKey: .type)
            try c.encode(reason, forKey: .reason)
        }
    }

    /// The encoder configuration both ends use. `.sortedKeys` keeps a line
    /// byte-stable for fixtures and diffing; `.withoutEscapingSlashes` keeps a
    /// URL in a `reason` readable; `.iso8601` keeps `at` legible to a human
    /// reading the file.
    ///
    /// Built per call rather than cached in a `static let`: `JSONEncoder` is a
    /// reference type, and the tee writes from a task of its own while the app
    /// reads from another, so a shared instance would be mutable state crossing
    /// isolation domains for no measurable gain over a chunk of network I/O.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// One JSON object, no trailing newline. JSON escapes every newline inside
    /// `text`, so the result is always exactly one line.
    public func encodedLine() throws -> String {
        let data = try Self.makeEncoder().encode(self)
        // Unreachable in practice — JSONEncoder emits UTF-8 — but the failable
        // initializer is what the lint rule asks for, and silently substituting
        // replacement characters would corrupt a delta rather than report it.
        guard let line = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, EncodingError.Context(
                codingPath: [],
                debugDescription: "JSONEncoder produced non-UTF-8 bytes for a stream line"
            ))
        }
        return line
    }

    /// Decodes one line, returning nil for anything malformed — a partial line
    /// the tailer caught mid-append, a truncated file, or a `type` written by a
    /// newer proxy. A reader skips what it cannot read rather than failing.
    public static func decode(line: String) -> ModelProxyStreamLine? {
        try? makeDecoder().decode(ModelProxyStreamLine.self, from: Data(line.utf8))
    }
}
