import Foundation

/// The one place that decides whether a pane registers with the poll scheduler
/// to read transcript files itself, or leaves the daemon RPC path in charge.
///
/// Keeping the decision in a single function makes "a pane with no path touches
/// no file" a single assertion rather than a survey of every call site.
/// Deregistering on the guarded path matters as much as registering on the
/// happy one: a pane whose session loses its transcript path must stop being
/// polled, not merely stop being re-registered.
///
/// `token` identifies the calling pane on both branches, so the guarded one
/// releases that pane's own hold and nobody else's — see `TranscriptPaneToken`.
///
/// `streamPath` rides along on the registering branch: the model-proxy stream
/// file is optional in a way the transcript path is not — a pane with no stream
/// file still registers and still polls — so it never influences the branch, it
/// is only carried. The transcript path remains the sole gate, and a pane with
/// a stream file but no transcript path deregisters like any other.
///
/// An empty `streamPath` means the same thing as nil and is normalised to it
/// here, the way the transcript path's own guard treats `""` as "no path":
/// `Terminal.transcriptStreamPath` reaches the app as a decoded string, and a
/// registration carrying `""` would have the scheduler stat the pane's working
/// directory on every tick forever.
enum TranscriptPaneRegistration {
    static func apply(
        sessionID: String,
        path: String?,
        streamPath: String? = nil,
        tier: TranscriptPollTier,
        token: TranscriptPaneToken,
        scheduler: TranscriptPollScheduler
    ) async {
        guard let path, !path.isEmpty else {
            await scheduler.deregister(sessionID: sessionID, token: token)
            return
        }
        let stream = (streamPath?.isEmpty ?? true) ? nil : streamPath
        await scheduler.register(
            sessionID: sessionID, path: path, streamPath: stream,
            tier: tier, token: token)
    }
}

/// Which transport a live transcript pane should use for one evaluation.
///
/// The decision is a pure function of the path so it can be asserted directly,
/// rather than only through the behaviour of a SwiftUI `.task`. A pane whose
/// terminal has no usable `transcriptPath` must fall back to the daemon poll —
/// the daemon resolves the session file server-side from the terminal id, so it
/// can render a transcript the app-side reader has no path for. Taking the
/// app-side branch there would leave the pane waiting forever.
enum TranscriptPaneTransport: Equatable {
    /// Read the file in-process, from this path.
    case appSide(path: String)
    /// Poll the daemon over RPC.
    case daemonPoll

    static func resolve(path: String?) -> TranscriptPaneTransport {
        guard let path, !path.isEmpty else { return .daemonPoll }
        return .appSide(path: path)
    }
}

/// Which cadence tier a live transcript pane declares, as a pure function of
/// the pane's worktree and the app's current selection.
///
/// Mounted is not the same as visible, and that difference is the whole point
/// of the background tier. `TerminalContainerView` mounts every worktree in
/// `AppState.keepAliveWorktreeIDs` — the selection plus a warm LRU of
/// recently-visited ones — but only the selection is on screen: in
/// single-select `WorktreePager` pages to the one selected id, and a
/// multi-select renders exactly `selectionOrder`. Membership in
/// `selectedWorktreeIDs` is therefore the on-screen test for a pane, and every
/// other worktree the LRU is holding is alive but off screen. (Only the active
/// tab's layout is mounted within a worktree, so a mounted pane is never
/// hidden behind a background tab.)
///
/// Pure, and taking the selection set rather than an `AppState`, so the
/// decision is assertable without a SwiftUI view tree — the same shape, and
/// for the same reason, as `TranscriptPaneTransport.resolve`.
enum TranscriptPaneVisibility {
    static func tier(worktreeID: UUID, selectedWorktreeIDs: Set<UUID>) -> TranscriptPollTier {
        selectedWorktreeIDs.contains(worktreeID) ? .foreground : .background
    }
}
