import Foundation
import TBDShared

/// TBD's own refusals of a remote session's transcript sync or earlier
/// history load.
///
/// Each is TBD's fixed words with its code (`CodedRefusal`), so a client may
/// show it: a paired phone hears it as it is.
enum RemoteTranscriptRefusal {
    /// The session is dismissed, so its transcript cache is not kept.
    static let dismissed = CodedRefusal(
        text: "this session is dismissed; its transcript is no longer kept", code: .remoteSessionDismissed)

    /// `remote_transcript_live_sync_enabled` is off, so earlier history does
    /// not load.
    static let loadEarlierOff = CodedRefusal(
        text: "loading earlier transcript history is off (remote_transcript_live_sync_enabled)",
        code: .loadEarlierOff)

    /// The session was removed while its transcript synced, so its cache was
    /// discarded. The words are `RemoteTranscriptSyncError.discarded`'s own.
    static let removed = CodedRefusal(
        text: RemoteTranscriptSyncError.discarded.localizedDescription, code: .remoteSessionRemoved)

    /// The cache has no `before`: nothing above it to load.
    static let nothingEarlier = CodedRefusal(text: "no earlier transcript history to load", code: .nothingEarlier)
}
