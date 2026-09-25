import Foundation
import TBDShared

/// Tails one remote session's transcript cache file into items the transcript
/// renderer can show.
///
/// The daemon owns the file (`~/tbd/remote-transcripts/<provider>/<id>/`) and
/// hands the app `{path, generation, caughtUp}` from each sync. Appends are
/// read incrementally through the same `TranscriptSource` the local panes
/// use. A changed `generation` means the daemon replaced the file with a
/// conversation that starts over — a provider `reset`, a `/clear`, a resume —
/// so everything held for the session is dropped and the file is re-read from
/// byte zero. `TranscriptSource` detects most rewrites on its own; the
/// generation is the daemon saying so outright, and it is what the spec
/// promises readers rely on.
@MainActor
final class RemoteTranscriptTail {
    /// The `AppState.sessionTranscripts` key for a remote session. Prefixed so
    /// it can never collide with a Claude session UUID a local pane publishes
    /// under.
    static func storeKey(provider: String, sessionID: String) -> String {
        "remote:\(provider)/\(sessionID)"
    }

    static func storeKey(_ selection: RemoteSessionSelection) -> String {
        storeKey(provider: selection.provider, sessionID: selection.sessionID)
    }

    private let source: TranscriptSource
    private var generations: [String: Int] = [:]

    init(source: TranscriptSource = TranscriptSource()) {
        self.source = source
    }

    /// Brings `key` up to date with `path`.
    ///
    /// Returns the session's full item list, or nil for "no news" — the file
    /// could not be read and nothing about the generation changed, so what is
    /// on screen stays. After a generation change an unreadable file returns
    /// `[]` rather than nil: the items held belong to a conversation the
    /// daemon has said is gone.
    func read(key: String, path: String, generation: Int) async -> [TranscriptItem]? {
        let previous = generations[key]
        generations[key] = generation
        let reset = previous != nil && previous != generation
        if reset {
            await source.forget(sessionID: key)
        }
        guard await source.refresh(sessionID: key, path: path) != nil else {
            return reset ? [] : nil
        }
        return await source.items(sessionID: key)
    }

    /// Drops everything held for `key`, so the next `read` starts over.
    func forget(key: String) async {
        generations.removeValue(forKey: key)
        await source.forget(sessionID: key)
    }
}
