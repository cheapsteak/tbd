import Foundation
import TBDShared

/// The latest transcript hint each remote session reported
/// (`docs/specs/2026-09-25-remote-session-transcript-design.md` § Transcript
/// hint store).
///
/// The hint never enters the mirrored `remote_session` row — its `size` grows
/// with every record the agent writes, and a mirrored hint would rebroadcast
/// `.remoteSessionsChanged` on every poll — so the sightings
/// `RemoteProviderManager` processes feed it here instead. It serves both
/// readers of the current hint: background sync's admission, and the
/// tail-or-forward choice `RemoteTranscriptSync` makes on every sync.
///
/// Memory only. After a daemon restart it is empty until each session's first
/// sighting, and an absent entry means "unknown", never "no hint": a reader
/// must not act on an absence as though the session had stopped reporting one.
actor RemoteTranscriptHints {
    private struct Key: Hashable {
        let provider: String
        let sessionID: String
    }

    private var hints: [Key: RemoteTranscriptHint] = [:]

    /// Records one sighting's hint. A sighting without a hint removes the
    /// session's entry.
    func record(provider: String, sessionID: String, hint: RemoteTranscriptHint?) {
        hints[Key(provider: provider, sessionID: sessionID)] = hint
    }

    /// The session's latest hint, or nil when none is known.
    func latest(provider: String, sessionID: String) -> RemoteTranscriptHint? {
        hints[Key(provider: provider, sessionID: sessionID)]
    }
}
