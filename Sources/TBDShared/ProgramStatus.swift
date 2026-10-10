import Foundation
import os

/// Constants of the Program Status Protocol (OSC 7501): a program running in
/// a terminal reports its own state (working, blocked, done, ...) through an
/// OSC sequence, after the terminal answers a `?` probe.
public enum ProgramStatusProtocol {
    public static let oscCode: Int = 7501
    /// ESC ] 7501 ; ? BEL
    public static let probeReply: String = "\u{1b}]7501;?\u{07}"
    public static let expectedApp: String = "claude-code"
    public static let titleMaxBytes: Int = 192
    public static let msgMaxBytes: Int = 2048
    public static let maxTaskEntries: Int = 32
    public static let maxTaskIDLength: Int = 32
}

/// The `state` value of a report. Unknown values are kept as
/// `.unrecognized(raw)` rather than rejected, so a newer program does not
/// lose its reports against an older terminal.
public enum ProgramStatusState: Sendable, Equatable, Hashable, Codable {
    case working
    case blocked
    case done
    case idle
    case error
    case clear
    case unrecognized(String)

    public init(rawValue: String) {
        switch rawValue {
        case "working": self = .working
        case "blocked": self = .blocked
        case "done": self = .done
        case "idle": self = .idle
        case "error": self = .error
        case "clear": self = .clear
        default: self = .unrecognized(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .working: return "working"
        case .blocked: return "blocked"
        case .done: return "done"
        case .idle: return "idle"
        case .error: return "error"
        case .clear: return "clear"
        case .unrecognized(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self.init(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

/// The `kind` value of a report: why the program is blocked.
public enum ProgramStatusBlockKind: Sendable, Equatable, Hashable, Codable {
    case permission
    case question
    case auth
    case unrecognized(String)

    public init(rawValue: String) {
        switch rawValue {
        case "permission": self = .permission
        case "question": self = .question
        case "auth": self = .auth
        default: self = .unrecognized(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .permission: return "permission"
        case .question: return "question"
        case .auth: return "auth"
        case .unrecognized(let raw): return raw
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self.init(rawValue: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

/// One parsed OSC 7501 report.
public struct ProgramStatusReport: Sendable, Equatable {
    public let state: ProgramStatusState
    public let app: String?
    /// nil = the main entry; otherwise a sanitized task id.
    public let id: String?
    public let kind: ProgramStatusBlockKind?
    /// Clamped to 0...100.
    public let progress: Int?
    public let title: String?
    public let msg: String?

    public init(
        state: ProgramStatusState,
        app: String? = nil,
        id: String? = nil,
        kind: ProgramStatusBlockKind? = nil,
        progress: Int? = nil,
        title: String? = nil,
        msg: String? = nil
    ) {
        self.state = state
        self.app = app
        self.id = id
        self.kind = kind
        self.progress = progress
        self.title = title
        self.msg = msg
    }
}

/// What the data after `7501;` turned out to be.
public enum ProgramStatusPayload: Sendable, Equatable {
    case probe
    case report(ProgramStatusReport)
}

/// Pure parser for OSC 7501 data (the bytes after `7501;`, terminator
/// excluded — the terminator is SwiftTerm's concern).
public enum ProgramStatusParser {
    /// nil = rejected (empty, not UTF-8, no `state` key).
    public static func parse<S: Sequence>(_ data: S) -> ProgramStatusPayload? where S.Element == UInt8 {
        let bytes: [UInt8] = Array(data)
        if bytes.isEmpty { return nil }
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        if text == "?" { return .probe }

        var fields: [String: String] = [:]
        for piece in text.split(separator: ":", omittingEmptySubsequences: true) {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[piece.startIndex..<eq])
            if key.isEmpty { continue }
            let value = String(piece[piece.index(after: eq)...])
            // Duplicate key: last wins.
            fields[key] = value
        }

        guard let stateRaw = fields["state"] else { return nil }
        let state = ProgramStatusState(rawValue: stateRaw)

        let app: String? = fields["app"]

        var id: String? = nil
        if let rawID = fields["id"] {
            let sanitized = sanitizedID(rawID)
            id = sanitized.isEmpty ? nil : sanitized
        }

        var kind: ProgramStatusBlockKind? = nil
        if let rawKind = fields["kind"] {
            kind = ProgramStatusBlockKind(rawValue: rawKind)
        }

        var progress: Int? = nil
        if let rawProgress = fields["progress"], let value = Int(rawProgress) {
            progress = min(max(value, 0), 100)
        }

        var title: String? = nil
        if let rawTitle = fields["title"] {
            title = decodedBase64Text(rawTitle, maxBytes: ProgramStatusProtocol.titleMaxBytes)
        }

        var msg: String? = nil
        if let rawMsg = fields["msg"] {
            msg = decodedBase64Text(rawMsg, maxBytes: ProgramStatusProtocol.msgMaxBytes)
        }

        let report = ProgramStatusReport(
            state: state,
            app: app,
            id: id,
            kind: kind,
            progress: progress,
            title: title,
            msg: msg
        )
        return .report(report)
    }

    /// Cheap check used inside the synchronous OSC handler: data is exactly "?".
    public static func isProbe<S: Sequence>(_ data: S) -> Bool where S.Element == UInt8 {
        var iterator = data.makeIterator()
        guard let first = iterator.next(), first == UInt8(ascii: "?") else { return false }
        return iterator.next() == nil
    }

    /// Exposed for tests: truncate to `maxBytes` on a UTF-8 scalar boundary.
    /// Returns nil when the bytes are not valid UTF-8.
    static func truncatedUTF8(_ bytes: [UInt8], maxBytes: Int) -> String? {
        if bytes.count <= maxBytes {
            return String(bytes: bytes, encoding: .utf8)
        }
        var prefix: [UInt8] = Array(bytes.prefix(max(maxBytes, 0)))
        if let text = String(bytes: prefix, encoding: .utf8) { return text }
        var dropped = 0
        while dropped < 3 && !prefix.isEmpty {
            prefix.removeLast()
            dropped += 1
            if let text = String(bytes: prefix, encoding: .utf8) { return text }
        }
        return nil
    }

    /// Keep only `[A-Za-z0-9_.+-]`, then the first `maxTaskIDLength` characters.
    private static func sanitizedID(_ raw: String) -> String {
        var out = ""
        var count = 0
        for scalar in raw.unicodeScalars {
            if count >= ProgramStatusProtocol.maxTaskIDLength { break }
            let v = scalar.value
            let isUpper = v >= 0x41 && v <= 0x5A
            let isLower = v >= 0x61 && v <= 0x7A
            let isDigit = v >= 0x30 && v <= 0x39
            let isPunct = v == 0x5F || v == 0x2E || v == 0x2B || v == 0x2D // _ . + -
            if isUpper || isLower || isDigit || isPunct {
                out.unicodeScalars.append(scalar)
                count += 1
            }
        }
        return out
    }

    /// Base64-decode (tolerating missing `=` padding) and truncate on a UTF-8
    /// boundary. nil when undecodable.
    private static func decodedBase64Text(_ raw: String, maxBytes: Int) -> String? {
        var padded = raw
        let remainder = padded.utf8.count % 4
        if remainder != 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return truncatedUTF8([UInt8](data), maxBytes: maxBytes)
    }
}

/// A lock-guarded Bool, readable synchronously from any thread (the SwiftTerm
/// parse thread reads it inside `registerOscHandler`).
public final class ProgramStatusGate: Sendable {
    private let state: OSAllocatedUnfairLock<Bool>

    public init(enabled: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: enabled)
    }

    public var isEnabled: Bool {
        state.withLock { $0 }
    }

    public func set(_ enabled: Bool) {
        state.withLock { $0 = enabled }
    }
}
