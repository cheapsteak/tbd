import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "composer-draft")

/// Reads and writes the per-session files the session mod and the daemon
/// share under `<sessionsDir>/<claudeSessionID>/`.
public enum SessionModFiles {
    public static let spawnFileName = "spawn.json"
    public static let aliveFileName = SessionModSessionFiles.aliveFileName
    public static let composerDraftFileName = "composer-draft.json"
    public static let composerDraftUnrestoredFileName = "composer-draft.unrestored"
    public static let usageFileName = "usage.json"

    /// Written by the daemon when it spawns a session.
    public struct SpawnRecord: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var sessionId: String
        public var incarnationId: String
        public var spawnedAtMs: Int64
        public var features: [String]

        public init(schemaVersion: Int = 1, sessionId: String, incarnationId: String,
                    spawnedAtMs: Int64, features: [String]) {
            self.schemaVersion = schemaVersion
            self.sessionId = sessionId
            self.incarnationId = incarnationId
            self.spawnedAtMs = spawnedAtMs
            self.features = features
        }
    }

    /// Written by the mod as a heartbeat. Shared with the app, which reads it
    /// to retire a stale session's provisional transcript rows.
    public typealias AliveRecord = SessionModSessionFiles.AliveRecord

    /// Written by the mod whenever the composer box changes.
    public struct ComposerDraftRecord: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var sessionId: String
        public var hasDraft: Bool
        public var text: String?
        public var cursor: Int?
        /// On a draft, whether `text` holds all of it. False once a change the
        /// mod cannot read (a collapsed paste, an image) left the box
        /// non-empty; nil on an empty box and on a draft written without it.
        public var restorable: Bool?
        public var savedAtMs: Int64

        public init(schemaVersion: Int = 1, sessionId: String, hasDraft: Bool,
                    text: String? = nil, cursor: Int? = nil, restorable: Bool? = nil,
                    savedAtMs: Int64) {
            self.schemaVersion = schemaVersion
            self.sessionId = sessionId
            self.hasDraft = hasDraft
            self.text = text
            self.cursor = cursor
            self.restorable = restorable
            self.savedAtMs = savedAtMs
        }
    }

    /// Written by the mod's `usage` feature at `session.start` and on every
    /// `session.measure`. Only the fields the daemon reads are decoded;
    /// `rateLimits` and `cost` are recorded for later readers and ignored here.
    ///
    /// `$.fs` has no rename, so a reader can meet a torn file. A file that does
    /// not parse, or lacks `measuredAt` or `context`, reads `.unreadable`
    /// through `SessionModFiles.read`. A figure that is present but not a
    /// number of the right shape decodes as nil rather than failing the
    /// record, and `windowIsBoolean` keeps a JSON `true` from passing as a
    /// one-token window: callers validate the window, never the decoder.
    public struct UsageRecord: Decodable, Equatable, Sendable {
        public struct Context: Decodable, Equatable, Sendable {
            /// The window this session resolved, as written. Not validated:
            /// zero, negative and boolean windows are the reader's to refuse.
            public var window: Int?
            /// Whether `window` was written as a JSON boolean.
            public var windowIsBoolean: Bool
            /// Tokens in the window. Absent before the first response.
            public var tokens: Int?
            public var percent: Double?

            public init(window: Int?, windowIsBoolean: Bool = false,
                        tokens: Int? = nil, percent: Double? = nil) {
                self.window = window
                self.windowIsBoolean = windowIsBoolean
                self.tokens = tokens
                self.percent = percent
            }

            private enum CodingKeys: String, CodingKey {
                case window, tokens, percent
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                // Decoding `Bool` succeeds only on a JSON boolean, so this is
                // the one test that tells `true` from `1` on every decoder.
                windowIsBoolean = (try? c.decodeIfPresent(Bool.self, forKey: .window)) != nil
                window = windowIsBoolean ? nil : (try? c.decodeIfPresent(Int.self, forKey: .window))
                tokens = try? c.decodeIfPresent(Int.self, forKey: .tokens)
                percent = try? c.decodeIfPresent(Double.self, forKey: .percent)
            }
        }

        public var claudeSessionID: String?
        public var incarnationID: String?
        /// When the figures were measured, in milliseconds since the epoch.
        public var measuredAt: Int64
        public var context: Context

        public init(claudeSessionID: String? = nil, incarnationID: String? = nil,
                    measuredAt: Int64, context: Context) {
            self.claudeSessionID = claudeSessionID
            self.incarnationID = incarnationID
            self.measuredAt = measuredAt
            self.context = context
        }

        /// The window when it is a positive integer, else nil.
        public var validWindow: Int? {
            guard !context.windowIsBoolean, let window = context.window, window > 0 else { return nil }
            return window
        }
    }

    public enum ReadResult<Record> {
        case missing
        case unreadable
        case record(Record)
    }

    /// A session ID becomes a path component only when it is a plain token.
    public static func isSafeSessionID(_ id: String) -> Bool {
        SessionModSessionFiles.isSafeSessionID(id)
    }

    /// The session's directory, or nil when the ID is not safe to use as a path.
    public static func directory(sessionsDir: URL, claudeSessionID: String) -> URL? {
        SessionModSessionFiles.directory(sessionsDir: sessionsDir, claudeSessionID: claudeSessionID)
    }

    /// Reads and decodes one JSON file. Unknown fields are ignored; a missing
    /// required field or bad JSON is `.unreadable`.
    public static func read<R: Decodable>(_ type: R.Type, at url: URL) -> ReadResult<R> {
        // Only ENOENT is "missing"; any other failure (permissions, ENOTDIR,
        // I/O) is unreadable so callers fail closed rather than read legacy.
        let fd = open(url.path, O_RDONLY)
        if fd < 0 { return errno == ENOENT ? .missing : .unreadable }
        let data: Data
        do {
            data = try FileHandle(fileDescriptor: fd, closeOnDealloc: true).readToEnd() ?? Data()
        } catch {
            return .unreadable
        }
        guard let record = try? JSONDecoder().decode(R.self, from: data) else {
            return .unreadable
        }
        return .record(record)
    }

    public enum WriteError: Error, LocalizedError {
        case unsafeSessionID(String)

        public var errorDescription: String? {
            switch self {
            case .unsafeSessionID(let id): return "unsafe session ID: \(id)"
            }
        }
    }

    /// The mode of the sessions root. Drafts can hold pasted secrets, so only
    /// the owner may enter it, and the per-session directories beneath it are
    /// out of everyone else's reach whatever their own mode.
    public static let sessionsRootPermissions: Int = 0o700

    /// Creates the sessions root when it is missing, and holds it at
    /// `sessionsRootPermissions` either way, so a root created with a wider
    /// mode is narrowed too.
    public static func ensureSessionsRoot(_ sessionsDir: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: sessionsRootPermissions], ofItemAtPath: sessionsDir.path)
    }

    /// Atomically writes the session's `spawn.json`, creating its directory
    /// beneath a sessions root only its owner may enter.
    public static func writeSpawnRecord(_ record: SpawnRecord, sessionsDir: URL) throws {
        guard let dir = directory(sessionsDir: sessionsDir, claudeSessionID: record.sessionId) else {
            throw WriteError.unsafeSessionID(record.sessionId)
        }
        try ensureSessionsRoot(sessionsDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(
            to: dir.appendingPathComponent(spawnFileName), options: .atomic)
    }

    /// Removes the session's directory. No-op when the ID is unsafe or the
    /// directory is absent; failures are logged.
    public static func removeSessionDirectory(sessionsDir: URL, claudeSessionID: String) {
        guard let dir = directory(sessionsDir: sessionsDir, claudeSessionID: claudeSessionID),
              FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            logger.error("remove session dir failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
