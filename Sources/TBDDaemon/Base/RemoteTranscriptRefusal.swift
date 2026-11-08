import Foundation

/// TBD's own refusals of a remote session's transcript sync or earlier
/// history load.
///
/// They live in `Base` because the router (`Server`) writes them and the
/// phone app service (`PhoneBridge`) tells them from a provider's own words:
/// a phone hears these as they are, and never a provider's text, which can
/// quote a secret.
enum RemoteTranscriptRefusal {
    /// The session is dismissed, so its transcript cache is not kept.
    static let dismissed = "this session is dismissed; its transcript is no longer kept"

    /// `remote_transcript_live_sync_enabled` is off, so earlier history does
    /// not load.
    static let loadEarlierOff =
        "loading earlier transcript history is off (remote_transcript_live_sync_enabled)"

    /// The cache has no `before`: nothing above it to load.
    static let nothingEarlier = "no earlier transcript history to load"
}
