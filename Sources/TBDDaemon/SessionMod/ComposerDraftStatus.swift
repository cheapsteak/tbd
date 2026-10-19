import Foundation

/// What the daemon knows about a session's unsent composer draft.
public enum ComposerDraftStatus: Equatable, Sendable {
    case legacy
    case confirmed(hasDraft: Bool)
    case unknown(SessionModLiveness.UnknownReason)

    /// False only for `.legacy`.
    public var spawnedWithFeature: Bool {
        if case .legacy = self { return false }
        return true
    }

    public static func evaluate(
        liveness: SessionModLiveness,
        draft: SessionModFiles.ReadResult<SessionModFiles.ComposerDraftRecord>
    ) -> ComposerDraftStatus {
        switch liveness {
        case .legacy: return .legacy
        case .unknown(let reason): return .unknown(reason)
        case .confirmed:
            switch draft {
            case .missing: return .confirmed(hasDraft: false)
            case .unreadable: return .unknown(.unreadableFile)
            case .record(let record): return .confirmed(hasDraft: record.hasDraft)
            }
        }
    }

    /// Reads the session's files. A nil or unsafe session ID reads `.legacy`.
    public static func read(
        sessionsDir: URL,
        claudeSessionID: String?,
        liveIncarnationID: UUID?,
        now: Date
    ) -> ComposerDraftStatus {
        guard let id = claudeSessionID,
              let dir = SessionModFiles.directory(sessionsDir: sessionsDir, claudeSessionID: id) else {
            return .legacy
        }
        let liveness = SessionModLiveness.evaluate(
            feature: .composerDraft, sessionsDir: sessionsDir, claudeSessionID: id,
            liveIncarnationID: liveIncarnationID, now: now)
        return evaluate(
            liveness: liveness,
            draft: SessionModFiles.read(
                SessionModFiles.ComposerDraftRecord.self,
                at: dir.appendingPathComponent(SessionModFiles.composerDraftFileName)))
    }
}
