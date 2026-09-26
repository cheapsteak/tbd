import AppKit
import SwiftUI
import TBDShared

/// `RemoteTranscriptPaneView` with its data source attached: feeds each sync's
/// `{path, generation, caughtUp}` and refresh token into the pane.
///
/// The decisions — whether to sync, and stopping the old session's driver
/// before starting the next — live in `RemoteTranscriptSyncSession`; this view
/// only reports what it observes. "On screen" is this view being mounted (the
/// split adds it only when the transcript is open) **and** its session being
/// the selected one: the remote detail tab stays mounted, invisible, while
/// another section is showing, and a hidden pane must not keep polling.
struct RemoteTranscriptLivePane: View {
    let selection: RemoteSessionSelection

    @Environment(AppState.self) private var appState
    @State private var session: RemoteTranscriptSyncSession?

    private var isOnScreen: Bool {
        appState.selectedRemoteSession == selection
    }

    private var agentMark: RemoteTranscriptSyncDriver.AgentStateMark? {
        appState.remoteSessionPayload(for: selection).map {
            .init(state: $0.agentState, at: $0.agentStateAt)
        }
    }

    var body: some View {
        let snapshot = session?.driver?.snapshot ?? RemoteTranscriptSyncSnapshot()
        RemoteTranscriptPaneView(
            selection: selection,
            path: snapshot.path,
            generation: snapshot.generation,
            caughtUp: snapshot.caughtUp,
            refreshToken: snapshot.refreshToken,
            syncError: snapshot.error)
        .onAppear { start(selection) }
        .onDisappear { session?.stop() }
        .onChange(of: selection) { _, new in start(new) }
        .onChange(of: isOnScreen) { _, onScreen in session?.setOnScreen(onScreen) }
        .onChange(of: agentMark) { _, mark in session?.noteAgentState(mark) }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            session?.setAppActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)
        ) { _ in
            session?.setAppActive(false)
        }
    }

    /// Refresh the inputs a remembered session may hold stale, then start.
    private func start(_ selection: RemoteSessionSelection) {
        let session = syncSession()
        session.setOnScreen(isOnScreen)
        session.setAppActive(NSApplication.shared.isActive)
        session.start(selection, agentState: agentMark)
    }

    /// The pane's session, made on first use with the live inputs.
    private func syncSession() -> RemoteTranscriptSyncSession {
        if let session { return session }
        let made = RemoteTranscriptSyncSession(
            isOnScreen: isOnScreen,
            appActive: NSApplication.shared.isActive,
            makeDriver: { [appState] selection in
                RemoteTranscriptSyncDriver(
                    selection: selection,
                    sync: { [appState] selection in
                        try await appState.remoteTranscriptSyncer(selection)
                    },
                    // Show what the daemon already cached before the first
                    // sync returns: a long load can take a minute or more.
                    initialSnapshot: .cached(for: selection))
            },
            didStart: { [appState] in appState.registerRemoteTranscriptSyncDriver($0) },
            didStop: { [appState] in appState.unregisterRemoteTranscriptSyncDriver($0) })
        session = made
        return made
    }
}
