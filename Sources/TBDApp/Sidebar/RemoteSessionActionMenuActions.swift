import AppKit
import os
import TBDShared

private let remoteRowLogger = Logger(subsystem: "com.tbd.app", category: "remote")

/// The dispatcher behind a remote-session row's context menu, the
/// `RowActionMenuActions` of `RemoteSessionActionMenu`. Holding
/// `appState + session + onRename`, it exposes:
///
/// - `items()` — the pure `RemoteSessionActionMenu.items` composition, fed
///   from live `AppState`.
/// - `run(_:)` — the one place every side effect lives, keyed by the typed
///   `RemoteSessionActionMenu.Kind`.
///
/// Both sidebars render the menu from it — `RemoteSessionRowView`'s SwiftUI
/// `contextMenu` and the native sidebar's `NSMenu` — so the two cannot offer
/// different verbs for the same session or act on one differently.
@MainActor
struct RemoteSessionActionMenuActions {
    let appState: AppState
    let session: RemoteSessionInfo
    let onRename: () -> Void

    private var selection: RemoteSessionSelection {
        RemoteSessionSelection(provider: session.provider, sessionID: session.payload.id)
    }

    /// The ordered items to render.
    func items() -> [RemoteSessionActionMenu.Item] {
        let provider = appState.remoteProviders.first { $0.config.name == session.provider }
        let capabilities = provider?.describe?.capabilities ?? []
        return RemoteSessionActionMenu.items(
            capabilities: capabilities, gone: session.gone,
            snapshotFresh: provider?.hasStaleSnapshot != true,
            // Read from the mirror rather than the row's captured `session`,
            // so a dock copy and a section copy of the same session always
            // offer the same verb.
            isPinned: appState.remoteSessionIsPinned(
                provider: session.provider, sessionID: session.payload.id),
            exited: session.payload.state == .exited,
            deleteEnabled: appState.remoteDeleteEnabled,
            isAttached: appState.attachedRemoteSelections.contains(selection),
            liveAttachUnavailable: !appState.remoteSessionAttachesWhenSelected(selection)
        )
    }

    /// Runs the side effect for a typed action `kind`.
    func run(_ kind: RemoteSessionActionMenu.Kind) {
        let session = self.session
        let appState = self.appState
        switch kind {
        case .rename:
            onRename()
        case .attach:
            appState.selectRemoteSession(provider: session.provider, sessionID: session.payload.id, reattach: true)
        case .reconnect:
            appState.reconnectRemoteSession(selection)
        case .sendText:
            // Offered only when the session's pane shows no live attached
            // terminal; selecting it brings up the pane whose send footer
            // takes the text.
            appState.selectRemoteSession(provider: session.provider, sessionID: session.payload.id)
        case .copySessionID:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.payload.id, forType: .string)
        case .stop:
            Task {
                do {
                    try await appState.daemonClient.remoteStop(
                        provider: session.provider, sessionID: session.payload.id)
                } catch {
                    remoteRowLogger.error(
                        "remoteStop failed for \(session.provider, privacy: .public)/\(session.payload.id, privacy: .public): \(error, privacy: .public)")
                }
            }
        case .dismiss:
            Task {
                do {
                    try await appState.daemonClient.remoteDismiss(
                        provider: session.provider, sessionID: session.payload.id)
                } catch {
                    remoteRowLogger.error(
                        "remoteDismiss failed for \(session.provider, privacy: .public)/\(session.payload.id, privacy: .public): \(error, privacy: .public)")
                }
            }
        case .delete:
            // The confirmation, the retain decision and the error toast all
            // live in `AppState.deleteRemoteSession` — the lane row's menu
            // reaches the same method, so the two surfaces cannot come to
            // different conclusions about the same session.
            Task {
                await appState.deleteRemoteSession(
                    provider: session.provider, sessionID: session.payload.id)
            }
        case .pin, .unpin:
            let pinned = kind == .pin
            Task {
                await appState.setRemoteSessionPinned(
                    provider: session.provider, sessionID: session.payload.id, pinned: pinned)
            }
        }
    }
}
