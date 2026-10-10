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

// MARK: - Snapshot and roll-up

/// The latest report for one entry (the main entry or one task entry), as the
/// daemon holds it. `title` and `msg` can carry content from the user's work,
/// so this lives only in daemon and app memory — never in `state.db`.
public struct ProgramStatusEntry: Codable, Sendable, Equatable {
    public var state: ProgramStatusState
    public var kind: ProgramStatusBlockKind?
    public var title: String?
    public var msg: String?
    public var progress: Int?
    /// When the reader saw the report that produced this entry.
    public var observedAt: Date

    public init(
        state: ProgramStatusState,
        kind: ProgramStatusBlockKind? = nil,
        title: String? = nil,
        msg: String? = nil,
        progress: Int? = nil,
        observedAt: Date
    ) {
        self.state = state
        self.kind = kind
        self.title = title
        self.msg = msg
        self.progress = progress
        self.observedAt = observedAt
    }

    /// The entry a report writes. A report replaces its entry wholesale: the
    /// sender writes whole entries when they change.
    public init(report: ProgramStatusReport, observedAt: Date) {
        self.init(
            state: report.state,
            kind: report.kind,
            title: report.title,
            msg: report.msg,
            progress: report.progress,
            observedAt: observedAt
        )
    }
}

/// One task entry (a background task or subagent), keyed by its sender id.
public struct ProgramStatusTaskEntry: Codable, Sendable, Equatable {
    public let id: String
    public var entry: ProgramStatusEntry

    public init(id: String, entry: ProgramStatusEntry) {
        self.id = id
        self.entry = entry
    }
}

/// What the daemon holds for one terminal and pushes to the app. Never
/// persisted.
///
/// An empty snapshot (`main == nil`, no tasks) is a retraction: the terminal
/// is no longer OSC-authoritative and carries no task entries.
public struct ProgramStatusSnapshot: Codable, Sendable, Equatable {
    public let terminalID: UUID
    /// The terminal incarnation the reports were accepted for. A reader
    /// compares it with the row's current `sessionIncarnationID` and ignores
    /// a snapshot that names another one.
    public let incarnationID: UUID?
    /// nil → the terminal is not OSC-authoritative.
    public let main: ProgramStatusEntry?
    /// Insertion order.
    public let tasks: [ProgramStatusTaskEntry]
    /// Per-terminal mutation counter. Monotonic within one daemon run and
    /// never reset, so a receiver keeps the newest revision across clears.
    public let revision: UInt64

    public init(
        terminalID: UUID,
        incarnationID: UUID?,
        main: ProgramStatusEntry?,
        tasks: [ProgramStatusTaskEntry],
        revision: UInt64
    ) {
        self.terminalID = terminalID
        self.incarnationID = incarnationID
        self.main = main
        self.tasks = tasks
        self.revision = revision
    }

    public var isAuthoritative: Bool { main != nil }
    public var isEmpty: Bool { main == nil && tasks.isEmpty }
}

/// The state an OSC-authoritative terminal resolves to.
public struct ProgramStatusResolution: Sendable, Equatable {
    public let value: SessionStateValue
    /// Task entries currently `working` — the row's background count. Set in
    /// every branch, not only the working one.
    public let workingTaskCount: Int
    public let observedAt: Date

    public init(value: SessionStateValue, workingTaskCount: Int, observedAt: Date) {
        self.value = value
        self.workingTaskCount = workingTaskCount
        self.observedAt = observedAt
    }
}

/// The spec's mapping and roll-up rules, as pure functions.
/// Design: docs/specs/2026-10-10-program-status-protocol-design.md,
/// "State model" and "Rolling up task entries".
public enum ProgramStatusRollup {
    /// What the main entry alone means.
    public static func mainValue(_ main: ProgramStatusEntry) -> SessionStateValue {
        switch main.state {
        case .working:
            return .working
        case .blocked:
            if main.kind == .auth { return .needsAuth }
            return .awaitingInput(reason: AwaitingInputReason(
                message: main.msg ?? main.title ?? "",
                programStatusBlock: ProgramStatusBlock(kind: main.kind, taskID: nil)))
        case .error:
            return .error
        case .done:
            return .done
        case .idle:
            return .idle
        case .clear:
            // The store deletes on `clear` rather than storing it; defensive.
            return .unknown(why: "program status cleared")
        case .unrecognized(let raw):
            return .unknown(why: "unrecognized program status state '\(raw)'")
        }
    }

    /// The displayed state of a terminal, or nil when it is not
    /// OSC-authoritative (no main entry). The first matching rule wins:
    ///
    /// 1. main is needs-auth, awaiting input or error → main's state;
    /// 2. a task entry is blocked → awaiting input, labelled with that task;
    /// 3. main or any task entry is working → working;
    /// 4. otherwise main's state (done, idle, unknown).
    public static func resolve(_ snapshot: ProgramStatusSnapshot) -> ProgramStatusResolution? {
        guard let main = snapshot.main else { return nil }

        var workingTaskCount = 0
        for task in snapshot.tasks where task.entry.state == .working {
            workingTaskCount += 1
        }

        let mainResolved = mainValue(main)

        // Rule 1.
        switch mainResolved {
        case .needsAuth, .awaitingInput, .error:
            return ProgramStatusResolution(
                value: mainResolved, workingTaskCount: workingTaskCount,
                observedAt: main.observedAt)
        default:
            break
        }

        // Rule 2.
        for task in snapshot.tasks where task.entry.state == .blocked {
            let reason = AwaitingInputReason(
                message: task.entry.title ?? task.entry.msg ?? "",
                programStatusBlock: ProgramStatusBlock(kind: task.entry.kind, taskID: task.id))
            return ProgramStatusResolution(
                value: .awaitingInput(reason: reason), workingTaskCount: workingTaskCount,
                observedAt: task.entry.observedAt)
        }

        // Rule 3.
        let mainWorking = main.state == .working
        if mainWorking || workingTaskCount > 0 {
            var latest: Date? = mainWorking ? main.observedAt : nil
            for task in snapshot.tasks where task.entry.state == .working {
                if let current = latest {
                    if task.entry.observedAt > current { latest = task.entry.observedAt }
                } else {
                    latest = task.entry.observedAt
                }
            }
            return ProgramStatusResolution(
                value: .working, workingTaskCount: workingTaskCount,
                observedAt: latest ?? main.observedAt)
        }

        // Rule 4.
        return ProgramStatusResolution(
            value: mainResolved, workingTaskCount: workingTaskCount,
            observedAt: main.observedAt)
    }
}
