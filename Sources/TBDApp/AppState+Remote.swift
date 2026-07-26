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
            pruneRemoteSessionState(toKnownSessions: sessions.sessions)
        } catch {
            switch AppState.classifyRemoteRefreshFailure(error) {
            case .unavailable:
                // Deliberately does NOT prune: the daemon hasn't reported
                // anything here (the feature is off), so `remoteSessions`
                // is being cleared locally, not authoritatively replaced. A
                // transient disabled state must not delete the user's
                // rename overrides or unread bookkeeping.
                remoteProviders = []
                remoteSessions = []
            case .error:
                remoteLogger.error("Failed to refresh remote backends: \(error, privacy: .public)")
            }
        }
    }

    /// Prunes `unreadByRemoteSession` and `remoteSessionDisplayNames` down to
    /// the sessions the daemon just authoritatively returned, and clears
    /// `selectedRemoteSession` if the selected session is no longer among
    /// them. Mirrors `unreadByWorktree`'s wholesale-replace-on-refresh
    /// pattern: a remote session that goes `gone` and is then dismissed is
    /// filtered out of the row list (`RemoteSectionView.sessions`) but never
    /// deleted from the daemon's mirror the way an archived worktree's DB row
    /// eventually is, so without this call both maps grow forever —
    /// `remoteSessionDisplayNames` in particular is persisted to
    /// `UserDefaults` and would accumulate dead keys across restarts. Called
    /// only from the success path of `refreshRemote()` — see the doc comment
    /// on the `.unavailable` branch there for why the disabled path must NOT
    /// prune.
    func pruneRemoteSessionState(toKnownSessions sessions: [RemoteSessionInfo]) {
        let selections = Set(sessions.map { RemoteSessionSelection(provider: $0.provider, sessionID: $0.payload.id) })
        let keys = Set(sessions.map { AppState.remoteSessionKey(provider: $0.provider, sessionID: $0.payload.id) })
        unreadByRemoteSession = unreadByRemoteSession.filter { selections.contains($0.key) }
        remoteSessionDisplayNames = remoteSessionDisplayNames.filter { keys.contains($0.key) }
        pruneRemoteAttachState(toKnownSelections: selections)
        if let selected = selectedRemoteSession, !selections.contains(selected) {
            selectedRemoteSession = nil
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
        // Classify from the delta's own `exitCode` first — the attention
        // delta and the `.remoteSessionsChanged` mirror refresh are broadcast
        // independently, so the mirror may not have this session's exit code
        // yet when this delta arrives (see `RemoteSessionAttentionDelta.exitCode`
        // doc comment). Only fall back to the (possibly stale) mirror lookup
        // for payloads from an older daemon that never set the field.
        let exitCode = delta.exitCode ?? remoteSessions.first {
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

    // MARK: - Rename push (docs/remote-provider-contract.md § `rename`)

    /// Whether a provider's declared capability list includes the optional
    /// `rename` verb. Pure gate extracted for direct testing — mirrors
    /// `classifyRemoteRefreshFailure`.
    nonisolated static func supportsRenamePush(capabilities: [String]) -> Bool {
        capabilities.contains("rename")
    }

    /// Pushes a display-name rename to the provider when — and only when —
    /// it declares the `rename` capability, so other clients of the same
    /// backend (another machine, or the provider's own UI) see the new title
    /// too. Best-effort: any failure is logged, never surfaced to the user —
    /// `remoteSessionDisplayNames` is already the source of truth for THIS
    /// client regardless of whether the push lands, and the contract
    /// requires the verb to stay entirely optional (a provider without it —
    /// or one that fails this call — must keep working with a local-only
    /// name). Never invoked with an empty `title`: clearing a local override
    /// back to the provider's own reported title isn't a rename to push
    /// upstream. Exposed as a plain `async` function (not itself
    /// `Task`-wrapped) so tests can await it deterministically —
    /// `renameRemoteSession` is what wraps it in a fire-and-forget `Task`.
    func pushRemoteRenameIfSupported(provider: String, sessionID: String, title: String) async {
        guard !title.isEmpty else { return }
        let capabilities = remoteProviders.first { $0.config.name == provider }?.describe?.capabilities ?? []
        guard AppState.supportsRenamePush(capabilities: capabilities) else { return }
        do {
            try await remoteRenamePusher(provider, sessionID, title)
        } catch {
            remoteLogger.error(
                "remoteRename push failed for \(provider, privacy: .public)/\(sessionID, privacy: .public): \(error, privacy: .public)")
        }
    }

    // MARK: - Settings toggle (Task 11)

    /// Persist the remote-backends master switch, then re-fetch capabilities
    /// so the Settings toggle reflects the daemon's persisted state — mirrors
    /// `setControlModeEnabled`'s keep-last-known-value refresh (R8-M1): a
    /// transient RPC failure right after a successful set must not snap the
    /// toggle back off. The daemon only constructs its `RemoteProviderManager`
    /// at boot (`RPCRouter+RemoteHandlers.swift`), so a successful set here
    /// does NOT itself start polling — `remoteBackendsLive` in the refreshed
    /// capabilities is what tells the Settings view whether a restart has
    /// happened yet (see `remoteBackendsStatusCaption`).
    func setRemoteBackendsEnabled(_ enabled: Bool) async {
        do {
            try await remoteBackendsSetter(enabled)
            await refreshDaemonCapabilities()
        } catch {
            remoteLogger.error("Failed to set remote backends: \(error, privacy: .public)")
            showAlert("Failed to set remote backends: \(error.localizedDescription)", isError: true)
        }
    }

    /// Caption for the Remote Sessions toggle, telling the user which of the
    /// four `(remoteBackendsEnabled, remoteBackendsLive)` states they're
    /// actually in. The daemon only builds its `RemoteProviderManager` at
    /// boot, so the persisted flag and the live manager can disagree in
    /// BOTH directions:
    /// - `(true, false)`: the flag was flipped on since the daemon last
    ///   booted — polling has not started yet.
    /// - `(false, true)`: the flag was flipped off after the manager was
    ///   already live — the daemon never tears the manager down on disable
    ///   (only on process exit), so a poller from before this change keeps
    ///   running even though every `remote.*` RPC is now gated off.
    /// Pure mapping, directly testable without a daemon — mirrors
    /// `classifyRemoteRefreshFailure`.
    nonisolated static func remoteBackendsStatusCaption(enabled: Bool, live: Bool) -> String {
        switch (enabled, live) {
        case (false, false):
            return "Off. Turning this on requires a daemon restart before polling starts."
        case (true, false):
            return "On, but restart the daemon to start polling."
        case (true, true):
            return "On and running — polling registered providers."
        case (false, true):
            return "Off, but a poller from before this change is still running in the daemon — restart to fully stop it."
        }
    }
}
