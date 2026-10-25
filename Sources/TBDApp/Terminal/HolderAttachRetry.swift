import Foundation
import TBDShared

/// When a holder-backed panel asks again after an attach does not go through,
/// and when a holder request that never reached the daemon is sent again.
///
/// Most attach refusals describe a moment rather than the session, and they
/// cluster around daemon restarts and updates: a daemon shutting down or still
/// starting, a session whose reader it has not adopted yet, a viewer claim
/// whose handback has not landed yet, a sidecar that was not connected when
/// the daemon tried to vend, a descriptor that did not arrive in time, a
/// socket that refused the connection. Painting the placard on the first of
/// those leaves a healthy session unattached until the user acts, so the panel
/// tries again on a bounded backoff and paints the placard only when the
/// attempts run out.
enum HolderAttachRetry {
    /// The waits between attempts: 0.5, 1, 2, 4 and 4 seconds, 11.5 s in all.
    ///
    /// Long enough to outlast a daemon restart and a predecessor's handback;
    /// short enough that a cause which will not clear reaches the placard, and
    /// its Retry, while the user is still looking.
    static let delays: [Duration] = [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(4),
    ]

    /// Whether `error` is the daemon answering that it will never serve this
    /// attach, so neither a retry nor the user's Retry can help.
    ///
    /// A status returned in place of an attach is such an answer — `"ended"`
    /// means the session is over, and `"unavailable"` comes from a daemon with
    /// no holder transport wired, which it cannot gain while it runs — and so
    /// is a pending attach with no generation, from a daemon that does not
    /// speak this handshake.
    static func isPermanentRefusal(_ error: any Error) -> Bool {
        if case DaemonClientError.attachUnavailable(_) = error { return true }
        if case HolderAttachError.missingGeneration = error { return true }
        return false
    }

    /// Whether an attach that failed with `error` may succeed if asked again:
    /// anything but a permanent refusal, or cancellation, which means whoever
    /// was waiting has stopped.
    static func isRetryable(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        return !isPermanentRefusal(error)
    }

    /// Whether a request that failed with `error` got no answer from the
    /// daemon: it never reached it, or the reply never came back.
    ///
    /// The only failures a handback's requests are resent for; any other
    /// error is an answer, and a resend would only repeat it. The daemon
    /// answers a `pane.detach` naming a generation it never minted, or has
    /// already settled, with success and does nothing, and refuses such an
    /// `attach.ready` with an RPC error — so a resend whose first copy did
    /// arrive is harmless, and its refusal is not a reason to send again.
    static func isTransportFailure(_ error: any Error) -> Bool {
        guard let error = error as? DaemonClientError else { return false }
        switch error {
        case .daemonNotRunning, .connectionFailed, .sendFailed, .receiveFailed, .invalidResponse:
            return true
        case .rpcError, .attachUnavailable:
            return false
        }
    }
}
