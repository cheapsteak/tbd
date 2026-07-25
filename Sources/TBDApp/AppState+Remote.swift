import Foundation
import TBDShared
import os

private let remoteLogger = Logger(subsystem: "com.tbd.app", category: "remote")

extension AppState {
    /// The exact string every `remote.*` RPC returns when
    /// `config.remoteBackendsEnabled` is off (or the daemon booted before the
    /// flag was turned on) — see `RPCRouter+RemoteHandlers.remoteBackendsDisabledResponse`.
    /// There's no dedicated `RPCErrorCode` for this refusal, so it's matched
    /// by exact message text.
    nonisolated static let remoteBackendsDisabledMessage = "remote backends disabled"

    /// How a failed `remote.*` fetch should be handled. Pure classification,
    /// separated from `refreshRemote()` itself so it's directly testable —
    /// mirrors the existing `MacNotificationManager.shouldPost`-style pure
    /// seam (the effectful caller can't be unit-tested without a daemon).
    enum RemoteRefreshFailure: Equatable {
        /// The feature is off — not an error, just nothing to show.
        case unavailable
        /// A genuine RPC failure — should be logged, not silently swallowed.
        case error
    }

    nonisolated static func classifyRemoteRefreshFailure(_ error: Error) -> RemoteRefreshFailure {
        if let daemonError = error as? DaemonClientError,
           case .rpcError(let message, _) = daemonError,
           message == remoteBackendsDisabledMessage {
            return .unavailable
        }
        return .error
    }

    /// Fetch the remote-provider roster + session mirror. The daemon refuses
    /// every `remote.*` verb with `remoteBackendsDisabledMessage` when the
    /// feature is off — that refusal means "not available", not an error, so
    /// both arrays are cleared silently. Any other failure is logged and the
    /// last-known arrays are left in place (best-effort, mirrors
    /// `loadHibernationConfig`'s keep-last-known-value semantics).
    func refreshRemote() async {
        do {
            let providers = try await remoteProvidersFetcher()
            let sessions = try await remoteSessionsFetcher()
            remoteProviders = providers.providers
            remoteSessions = sessions.sessions
        } catch {
            switch AppState.classifyRemoteRefreshFailure(error) {
            case .unavailable:
                remoteProviders = []
                remoteSessions = []
            case .error:
                remoteLogger.error("Failed to refresh remote backends: \(error, privacy: .public)")
            }
        }
    }

    /// The banner title for a remote-session attention delta: the session's
    /// title, falling back to its raw id, followed by what happened. Pure
    /// seam (mirrors `MacNotificationManager.bannerTitle`) so it's testable
    /// without a bundle — `postRemoteAttention` itself early-returns
    /// unbundled.
    nonisolated static func remoteAttentionTitle(_ delta: RemoteSessionAttentionDelta) -> String {
        let finished = delta.kind == "exited"
        return "\(delta.title ?? delta.sessionID) — \(finished ? "finished" : "needs input")"
    }

    /// The banner body for a remote-session attention delta: the reason when
    /// present, falling back to the provider name. Pure seam, mirrors
    /// `MacNotificationManager.bannerBody`.
    nonisolated static func remoteAttentionBody(_ delta: RemoteSessionAttentionDelta) -> String {
        delta.reason ?? delta.provider
    }

    /// Post a user-facing banner for a remote session crossing a
    /// notify-worthy agent-state edge. Remote sessions have no worktree, so
    /// this does NOT go through `handleNotificationDelta`'s worktree-routing
    /// / unread bookkeeping — it posts directly via the dedicated,
    /// worktree-free `MacNotificationManager.postRemoteAttention`.
    func handleRemoteSessionAttentionDelta(_ delta: RemoteSessionAttentionDelta) {
        macNotificationManager.postRemoteAttention(
            identifier: "remote:\(delta.provider):\(delta.sessionID)",
            title: AppState.remoteAttentionTitle(delta),
            body: AppState.remoteAttentionBody(delta)
        )
    }
}
