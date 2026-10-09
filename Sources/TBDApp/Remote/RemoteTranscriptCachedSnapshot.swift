import Foundation
import TBDShared

extension RemoteTranscriptSyncSnapshot {
    /// What the daemon has already cached for `selection`, read straight from
    /// disk, so a pane can show it at once instead of waiting for the first
    /// `remote.transcriptSync` to name the file.
    ///
    /// The cache path is deterministic (`TBDConstants.remoteTranscriptDir` +
    /// `remoteTranscriptFileName`, honouring `TBD_HOME` exactly as the daemon
    /// does), so the app need not ask for it. Returns nil when there is no
    /// `transcript.jsonl` — nothing to show, and the pane keeps its full
    /// loading state.
    ///
    /// `generation`, `head` and `hasEarlier` come from `state.json` beside it
    /// (`hasEarlier` is whether it records a `before` cursor), and are 0, 0
    /// and false when that file is missing or unreadable. Either way the first
    /// sync's answer is authoritative: a different generation makes
    /// `RemoteTranscriptTail` drop what it read here and re-read from the
    /// start, the same path a provider reset takes, and its `hasEarlier`
    /// replaces the seed's. `caughtUp` is false — only a sync can say that —
    /// and no sync has published, so `refreshToken` stays 0.
    static func cached(
        for selection: RemoteSessionSelection,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RemoteTranscriptSyncSnapshot? {
        let directory = TBDConstants.remoteTranscriptDir(
            provider: selection.provider, sessionID: selection.sessionID, environment: environment)
        let transcript = directory.appendingPathComponent(TBDConstants.remoteTranscriptFileName)
        guard FileManager.default.fileExists(atPath: transcript.path) else { return nil }
        let state = cachedState(
            at: directory.appendingPathComponent(TBDConstants.remoteTranscriptStateFileName))
        var snapshot = RemoteTranscriptSyncSnapshot(
            path: transcript.path, generation: state?.generation ?? 0, caughtUp: false)
        snapshot.head = state?.head ?? 0
        snapshot.hasEarlier = state?.before != nil
        return snapshot
    }

    /// Only the fields the pane needs; the daemon owns the rest of the file.
    /// `head` and `before` are absent from a `state.json` written before
    /// earlier-history loading existed.
    private struct CachedState: Decodable {
        let generation: Int
        let head: Int?
        let before: String?
    }

    private static func cachedState(at url: URL) -> CachedState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(CachedState.self, from: data),
              state.generation >= 0, (state.head ?? 0) >= 0
        else { return nil }
        return state
    }
}
