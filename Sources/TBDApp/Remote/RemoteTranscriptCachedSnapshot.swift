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
    /// `generation` comes from `state.json` beside it, and is 0 when that file
    /// is missing or unreadable. Either way the first sync's generation is
    /// authoritative: a different one makes `RemoteTranscriptTail` drop what
    /// it read here and re-read from the start, the same path a provider
    /// reset takes. `caughtUp` is false — only a sync can say that — and no
    /// sync has published, so `refreshToken` stays 0.
    static func cached(
        for selection: RemoteSessionSelection,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RemoteTranscriptSyncSnapshot? {
        let directory = TBDConstants.remoteTranscriptDir(
            provider: selection.provider, sessionID: selection.sessionID, environment: environment)
        let transcript = directory.appendingPathComponent(TBDConstants.remoteTranscriptFileName)
        guard FileManager.default.fileExists(atPath: transcript.path) else { return nil }
        let state = directory.appendingPathComponent(TBDConstants.remoteTranscriptStateFileName)
        return RemoteTranscriptSyncSnapshot(
            path: transcript.path, generation: cachedGeneration(at: state), caughtUp: false)
    }

    /// Only the field the pane needs; the daemon owns the rest of the file.
    private struct CachedState: Decodable {
        let generation: Int
    }

    private static func cachedGeneration(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(CachedState.self, from: data),
              state.generation >= 0
        else { return 0 }
        return state.generation
    }
}
