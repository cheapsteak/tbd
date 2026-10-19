import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "composer-draft")

/// Reads and writes the per-session files the session mod and the daemon
/// share under `<sessionsDir>/<claudeSessionID>/`.
public enum SessionModFiles {
    public static let spawnFileName = "spawn.json"
    public static let aliveFileName = "alive.json"
    public static let composerDraftFileName = "composer-draft.json"
    public static let composerDraftUnrestoredFileName = "composer-draft.unrestored"

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

    /// Written by the mod as a heartbeat.
    public struct AliveRecord: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var sessionId: String
        public var incarnationId: String
        public var modVersion: Int
        public var features: [String]
        public var heartbeatAtMs: Int64

        public init(schemaVersion: Int = 1, sessionId: String, incarnationId: String,
                    modVersion: Int = 1, features: [String], heartbeatAtMs: Int64) {
            self.schemaVersion = schemaVersion
            self.sessionId = sessionId
            self.incarnationId = incarnationId
            self.modVersion = modVersion
            self.features = features
            self.heartbeatAtMs = heartbeatAtMs
        }
    }

    /// Written by the mod whenever the composer box changes.
    public struct ComposerDraftRecord: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var sessionId: String
        public var hasDraft: Bool
        public var text: String?
        public var cursor: Int?
        public var savedAtMs: Int64

        public init(schemaVersion: Int = 1, sessionId: String, hasDraft: Bool,
                    text: String? = nil, cursor: Int? = nil, savedAtMs: Int64) {
            self.schemaVersion = schemaVersion
            self.sessionId = sessionId
            self.hasDraft = hasDraft
            self.text = text
            self.cursor = cursor
            self.savedAtMs = savedAtMs
        }
    }

    public enum ReadResult<Record> {
        case missing
        case unreadable
        case record(Record)
    }

    /// A session ID becomes a path component only when it is a plain token.
    public static func isSafeSessionID(_ id: String) -> Bool {
        guard (1...128).contains(id.utf8.count) else { return false }
        return id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F || byte == 0x2D
        }
    }

    /// The session's directory, or nil when the ID is not safe to use as a path.
    public static func directory(sessionsDir: URL, claudeSessionID: String) -> URL? {
        guard isSafeSessionID(claudeSessionID) else { return nil }
        return sessionsDir.appendingPathComponent(claudeSessionID, isDirectory: true)
    }

    /// Reads and decodes one JSON file. Unknown fields are ignored; a missing
    /// required field or bad JSON is `.unreadable`.
    public static func read<R: Decodable>(_ type: R.Type, at url: URL) -> ReadResult<R> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(R.self, from: data) else {
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

    /// Atomically writes the session's `spawn.json`, creating its directory.
    public static func writeSpawnRecord(_ record: SpawnRecord, sessionsDir: URL) throws {
        guard let dir = directory(sessionsDir: sessionsDir, claudeSessionID: record.sessionId) else {
            throw WriteError.unsafeSessionID(record.sessionId)
        }
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
