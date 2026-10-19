import Foundation

/// Whether the session mod is demonstrably running in a session.
public enum SessionModLiveness: Equatable, Sendable {
    /// The process was spawned without the feature.
    case legacy
    case confirmed
    case unknown(UnknownReason)

    public enum UnknownReason: String, Sendable {
        case noAliveFile = "no-alive-file"
        case otherIncarnation = "other-incarnation"
        case staleHeartbeat = "stale-heartbeat"
        case featureNotRunning = "feature-not-running"
        case unreadableFile = "unreadable-file"
    }

    /// Seconds after which a heartbeat no longer counts.
    public static let staleAfter: TimeInterval = 90

    public static func evaluate(
        feature: SessionModFeature,
        spawn: SessionModFiles.ReadResult<SessionModFiles.SpawnRecord>,
        alive: SessionModFiles.ReadResult<SessionModFiles.AliveRecord>,
        liveIncarnationID: UUID?,
        now: Date
    ) -> SessionModLiveness {
        let spawnRecord: SessionModFiles.SpawnRecord
        switch spawn {
        case .missing: return .legacy
        case .unreadable: return .unknown(.unreadableFile)
        case .record(let record): spawnRecord = record
        }
        guard spawnRecord.features.contains(feature.rawValue) else { return .legacy }
        guard let live = liveIncarnationID, sameIncarnation(spawnRecord.incarnationId, live) else {
            return .legacy
        }
        let aliveRecord: SessionModFiles.AliveRecord
        switch alive {
        case .missing: return .unknown(.noAliveFile)
        case .unreadable: return .unknown(.unreadableFile)
        case .record(let record): aliveRecord = record
        }
        guard sameIncarnation(aliveRecord.incarnationId, live) else { return .unknown(.otherIncarnation) }
        guard aliveRecord.features.contains(feature.rawValue) else { return .unknown(.featureNotRunning) }
        let nowMs = (now.timeIntervalSince1970 * 1000).rounded()
        if nowMs - Double(aliveRecord.heartbeatAtMs) > staleAfter * 1000 {
            return .unknown(.staleHeartbeat)
        }
        return .confirmed
    }

    /// Reads the session's files and evaluates liveness. A nil or unsafe
    /// session ID has no directory and reads as legacy.
    public static func evaluate(
        feature: SessionModFeature,
        sessionsDir: URL,
        claudeSessionID: String,
        liveIncarnationID: UUID?,
        now: Date
    ) -> SessionModLiveness {
        guard let dir = SessionModFiles.directory(sessionsDir: sessionsDir, claudeSessionID: claudeSessionID) else {
            return .legacy
        }
        return evaluate(
            feature: feature,
            spawn: SessionModFiles.read(
                SessionModFiles.SpawnRecord.self,
                at: dir.appendingPathComponent(SessionModFiles.spawnFileName)),
            alive: SessionModFiles.read(
                SessionModFiles.AliveRecord.self,
                at: dir.appendingPathComponent(SessionModFiles.aliveFileName)),
            liveIncarnationID: liveIncarnationID,
            now: now)
    }

    private static func sameIncarnation(_ recorded: String, _ live: UUID) -> Bool {
        UUID(uuidString: recorded) == live
    }
}
