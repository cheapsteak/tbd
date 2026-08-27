import Foundation

/// The one place the `appSideTranscriptRead` flag decides whether a pane reads
/// transcript files itself or leaves the daemon RPC path in charge.
///
/// Keeping the decision in a single function makes "flag off touches no file" a
/// single assertion rather than a survey of every call site. Deregistering on
/// the guarded path matters as much as registering on the happy one: a pane
/// whose session loses its transcript path — or whose flag is turned off while
/// it is open — must stop being polled, not merely stop being re-registered.
enum TranscriptPaneRegistration {
    static func apply(
        enabled: Bool,
        sessionID: String,
        path: String?,
        tier: TranscriptPollTier,
        scheduler: TranscriptPollScheduler
    ) async {
        guard enabled, let path, !path.isEmpty else {
            await scheduler.deregister(sessionID: sessionID)
            return
        }
        await scheduler.register(sessionID: sessionID, path: path, tier: tier)
    }
}
