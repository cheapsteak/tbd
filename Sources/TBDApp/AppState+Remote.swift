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

    /// Maps a `RemoteSessionAttentionDelta.kind` (the agent state's raw
    /// value that triggered the delta — `"waiting_input"` or `"exited"`) to
    /// the same `NotificationType` vocabulary local unread bookkeeping uses,
    /// so `RowStatusIndicator.shouldBoldName` and severity-merge logic work
    /// unmodified for remote rows. `exitCode` disambiguates `"exited"`:
    /// nonzero is an error, zero or unknown is a clean completion. Returns
    /// nil for any other kind (shouldn't occur per the contract — only
    /// these two agent-state transitions are attention-worthy).
    nonisolated static func remoteUnreadType(kind: String, exitCode: Int?) -> NotificationType? {
        switch kind {
        case RemoteAgentState.waitingInput.rawValue:
            return .attentionNeeded
        case RemoteAgentState.exited.rawValue:
            return (exitCode ?? 0) != 0 ? .error : .responseComplete
        default:
            return nil
        }
    }

    /// Post a user-facing banner for a remote session crossing a
    /// notify-worthy agent-state edge, and record it in `unreadByRemoteSession`
    /// so the sidebar row's name bolds (`RowStatusIndicator.shouldBoldName`,
    /// same as local worktree rows). Remote sessions have no worktree, so
    /// this does NOT go through `handleNotificationDelta`'s worktree-routing
    /// — it posts directly via the dedicated, worktree-free
    /// `MacNotificationManager.postRemoteAttention`, and writes the unread
    /// map itself rather than reusing that function's bookkeeping.
    ///
    /// Note this bookkeeping is edge-triggered (fires once per delta,
    /// cleared on `selectRemoteSession`) — separate from the STEADY-state
    /// `waiting_input` suffix glyph the row renders directly from
    /// `agentState` on every poll (see `RemoteSessionRowView`). The bold
    /// name says "you haven't looked since this happened"; the suffix glyph
    /// says "this is still true right now". They can disagree (bold clears
    /// on select even though the session may still be waiting for input),
    /// and that's intentional.
    func handleRemoteSessionAttentionDelta(_ delta: RemoteSessionAttentionDelta) {
        macNotificationManager.postRemoteAttention(
            identifier: "remote:\(delta.provider):\(delta.sessionID)",
            title: AppState.remoteAttentionTitle(delta),
            body: AppState.remoteAttentionBody(delta)
        )

        let selection = RemoteSessionSelection(provider: delta.provider, sessionID: delta.sessionID)
        // Currently viewing this session — no unread to record, mirrors the
        // `visible` guard in `handleNotificationDelta`.
        guard selectedRemoteSession != selection else { return }
        let exitCode = remoteSessions.first {
            $0.provider == delta.provider && $0.payload.id == delta.sessionID
        }?.payload.exitCode
        guard let type = AppState.remoteUnreadType(kind: delta.kind, exitCode: exitCode) else { return }

        let incoming = UnreadSummary(type: type, mostRecentAt: Date())
        if let existing = unreadByRemoteSession[selection] {
            let winnerType = incoming.type.severity > existing.type.severity ? incoming.type : existing.type
            unreadByRemoteSession[selection] = UnreadSummary(type: winnerType, mostRecentAt: incoming.mostRecentAt)
        } else {
            unreadByRemoteSession[selection] = incoming
        }
    }
}
