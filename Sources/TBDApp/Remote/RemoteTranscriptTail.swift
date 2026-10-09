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
///
/// A changed `head` under the same generation means the daemon prepended a
/// page of earlier history and renamed the rewritten file over the old one.
/// Records now sit in front of the read offset, so the file is re-read whole
/// (it stays small); what is on screen is kept if that read fails, because the
/// conversation itself has not changed.
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
    private var marks: [String: (generation: Int, head: Int)] = [:]

    init(source: TranscriptSource = TranscriptSource()) {
        self.source = source
    }

    /// Brings `key` up to date with `path`.
    ///
    /// Returns the session's full item list, or nil for "no news" — the file
    /// could not be read and nothing about the generation changed, so what is
    /// on screen stays. After a generation change an unreadable file returns
    /// `[]` rather than nil: the items held belong to a conversation the
    /// daemon has said is gone. After a `head`-only change it returns nil:
    /// the items held are still this conversation's.
    func read(key: String, path: String, generation: Int, head: Int = 0) async -> [TranscriptItem]? {
        let previous = marks[key]
        marks[key] = (generation, head)
        let reset = previous.map { $0.generation != generation } ?? false
        let prepended = previous.map { $0.generation == generation && $0.head != head } ?? false
        if reset || prepended {
            await source.forget(sessionID: key)
        }
        guard await source.refresh(sessionID: key, path: path) != nil else {
            return reset ? [] : nil
        }
        return await source.items(sessionID: key)
    }

    /// Drops everything held for `key`, so the next `read` starts over.
    func forget(key: String) async {
        marks.removeValue(forKey: key)
        await source.forget(sessionID: key)
    }
}
