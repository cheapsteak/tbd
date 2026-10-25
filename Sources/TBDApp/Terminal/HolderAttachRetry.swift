import Foundation
import TBDShared

/// When a holder-backed panel asks again after an attach does not go through.
///
/// Most refusals describe a moment rather than the session, and they cluster
/// around daemon restarts and updates: a daemon shutting down or still
/// starting, a session whose reader it has not adopted yet, an attach still
/// pending from a panel that just went away, a sidecar that was not connected
/// when the daemon tried to vend, a descriptor that did not arrive in time, a
/// socket that refused the connection. Painting the placard on the first of
/// those leaves a healthy session unattached until the user acts, so the panel
/// tries again on a bounded backoff and paints the placard only when the
/// attempts run out.
enum HolderAttachRetry {
    /// The waits between attempts: 0.5, 1, 2, 4 and 4 seconds, 11.5 s in all.
    ///
    /// Long enough to cover a daemon restart and a pending attach's 5 s ready
    /// timeout; short enough that a cause which will not clear reaches the
    /// placard, and its Retry, while the user is still looking.
    static let delays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(4),
    ]

    /// Whether an attach that failed with `error` may succeed if asked again.
    ///
    /// Everything is retried except a definitive answer. A status the daemon
    /// returned in place of an attach is one: `"ended"` means the session is
    /// over, and `"unavailable"` comes from a daemon with no holder transport
    /// wired, which it cannot gain while it runs. A pending attach with no
    /// generation is a daemon that does not speak this handshake. Cancellation
    /// means whoever was waiting has stopped.
    static func isRetryable(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if case DaemonClientError.attachUnavailable(_) = error { return false }
        if case HolderAttachError.missingGeneration = error { return false }
        return true
    }
}
