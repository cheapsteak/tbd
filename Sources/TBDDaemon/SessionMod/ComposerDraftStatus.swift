import Foundation

/// What the daemon knows about a session's unsent composer draft.
public enum ComposerDraftStatus: Equatable, Sendable {
    case legacy
    case confirmed(hasDraft: Bool)
    case unknown(SessionModLiveness.UnknownReason)

    /// A confirmed session's draft decides the rest. A draft is confirmed only
    /// when the mod marked it restorable: one whose text lacks part of what the
    /// box holds (a collapsed paste, an image), or one written without the
    /// mark, reads unknown, so automatic parks skip it and a manual park goes
    /// ahead.
    /// An empty box needs no mark.
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
            case .record(let record):
                if record.hasDraft, record.restorable != true {
                    return .unknown(.draftNotRestorable)
                }
                return .confirmed(hasDraft: record.hasDraft)
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
