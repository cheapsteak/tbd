import Foundation

/// What the daemon and the app both read in a session-mod session's directory,
/// `<sessionsDir>/<claudeSessionID>/`: the path rules, the mod's heartbeat
/// record, and the names of the files the app reads. The daemon's liveness
/// logic (`SessionModLiveness`) and its writers stay in the daemon.
public enum SessionModSessionFiles {
    public static let aliveFileName = "alive.json"
    /// The `transcript-stream` feature's snapshot of the main loop's answer.
    public static let transcriptStreamFileName = "transcript-stream.json"

    /// Seconds after which the mod's heartbeat no longer counts. The mod
    /// writes `alive.json` every 30 s, so three missed beats.
    public static let heartbeatStaleAfter: TimeInterval = 90

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

        /// Whether the heartbeat is older than `heartbeatStaleAfter` at `now`.
        public func isStale(now: Date) -> Bool {
            let nowMs = (now.timeIntervalSince1970 * 1000).rounded()
            return nowMs - Double(heartbeatAtMs) > heartbeatStaleAfter * 1000
        }
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
}
