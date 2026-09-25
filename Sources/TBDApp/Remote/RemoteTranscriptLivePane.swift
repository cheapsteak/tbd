import AppKit
import SwiftUI
import TBDShared

/// `RemoteTranscriptPaneView` with its data source attached: owns the
/// session's `RemoteTranscriptSyncDriver` and feeds each sync's
/// `{path, generation, caughtUp}` and refresh token into the pane.
///
/// The driver runs only while the pane is actually on screen and the app is
/// active. "On screen" is this view being mounted (the split adds it only when
/// the transcript is open) **and** its session being the selected one: the
/// remote detail tab stays mounted, invisible, while another section is
/// showing, and a hidden pane must not keep polling.
struct RemoteTranscriptLivePane: View {
    let selection: RemoteSessionSelection

    @Environment(AppState.self) private var appState
    @State private var driver: RemoteTranscriptSyncDriver?
    @State private var appActive = NSApplication.shared.isActive

    private var isOnScreen: Bool {
        appState.selectedRemoteSession == selection
    }

    private var agentMark: RemoteTranscriptSyncDriver.AgentStateMark? {
        appState.remoteSessionPayload(for: selection).map {
            .init(state: $0.agentState, at: $0.agentStateAt)
        }
    }

    var body: some View {
        let snapshot = driver?.snapshot ?? RemoteTranscriptSyncSnapshot()
        RemoteTranscriptPaneView(
            selection: selection,
            path: snapshot.path,
            generation: snapshot.generation,
            caughtUp: snapshot.caughtUp,
            refreshToken: snapshot.refreshToken,
            syncError: snapshot.error)
        .onAppear { start(selection) }
        .onDisappear { stop() }
        .onChange(of: selection) { _, new in
            stop()
            start(new)
        }
        .onChange(of: isOnScreen) { updateActivity() }
        .onChange(of: agentMark) { _, mark in driver?.noteAgentState(mark) }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            appActive = true
            updateActivity()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)
        ) { _ in
            appActive = false
            updateActivity()
        }
    }

    private func start(_ selection: RemoteSessionSelection) {
        let driver = RemoteTranscriptSyncDriver(
            selection: selection,
            sync: { [appState] selection in
                try await appState.remoteTranscriptSyncer(selection)
            })
        self.driver = driver
        appState.registerRemoteTranscriptSyncDriver(driver)
        driver.noteAgentState(agentMark)
        driver.setActive(isOnScreen && appActive)
    }

    private func stop() {
        guard let driver else { return }
        driver.stop()
        appState.unregisterRemoteTranscriptSyncDriver(driver)
        self.driver = nil
    }

    private func updateActivity() {
        driver?.setActive(isOnScreen && appActive)
    }
}
