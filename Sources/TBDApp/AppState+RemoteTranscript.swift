import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.app", category: "remoteTranscript")

/// A weak handle on a pane's sync driver, so the registry in `AppState` never
/// keeps a torn-down pane's driver alive.
@MainActor
final class WeakRemoteTranscriptSyncDriver {
    weak var driver: RemoteTranscriptSyncDriver?

    init(_ driver: RemoteTranscriptSyncDriver) { self.driver = driver }
}

/// App-side wiring for a remote session's transcript pane
/// (docs/specs/2026-09-25-remote-session-transcript-design.md, "App"). The
/// decisions themselves are the pure gates in `RemoteSessionDetailGates`;
/// these accessors only look up their inputs for a selection.
extension AppState {
    /// The `describe.capabilities` the provider behind `selection` declared,
    /// or none while its status has not loaded.
    func remoteProviderCapabilities(for selection: RemoteSessionSelection) -> [String] {
        remoteProviders.first { $0.config.name == selection.provider }?.describe?.capabilities ?? []
    }

    /// Whether the window toolbar offers the Transcript toggle for
    /// `selection`: its provider declares `transcript.read` and it is
    /// attached (`remoteSessionIsAttached`).
    func remoteSessionShowsTranscriptToggle(_ selection: RemoteSessionSelection) -> Bool {
        RemoteSessionDetailGates.showsTranscriptToggle(
            capabilities: remoteProviderCapabilities(for: selection),
            attached: remoteSessionIsAttached(selection))
    }

    /// Whether `selection`'s detail pane shows the transcript half of its
    /// split: always while it is not attached, and while it is attached
    /// unless the toolbar toggle has hidden it for this session's current
    /// connection (`remoteTranscriptHiddenAttach`).
    func remoteSessionShowsTranscriptPane(_ selection: RemoteSessionSelection) -> Bool {
        RemoteSessionDetailGates.showsTranscriptPane(
            capabilities: remoteProviderCapabilities(for: selection),
            attached: remoteSessionIsAttached(selection),
            hiddenByToggle: remoteTranscriptHiddenAttach == remoteAttachMountKey(for: selection))
    }

    /// Whether the transcript is the main side of `selection`'s split, with
    /// the terminal side on the right: its provider declares
    /// `transcript.read` and it is not attached. Attaching and detaching swap
    /// the halves.
    func remoteSessionTranscriptLeads(_ selection: RemoteSessionSelection) -> Bool {
        RemoteSessionDetailGates.transcriptLeads(
            capabilities: remoteProviderCapabilities(for: selection),
            attached: remoteSessionIsAttached(selection))
    }

    /// The toolbar toggle's action: hides the transcript of `selection`'s
    /// current connection, or shows it again when that connection's is the
    /// one hidden. Only one transcript is ever hidden, and nothing is
    /// persisted. A no-op unless the toggle is offered for `selection` and
    /// `selection` is the session on screen, so a session that is not attached
    /// or not selected never records a hide.
    func toggleRemoteTranscript(_ selection: RemoteSessionSelection) {
        guard selection == selectedRemoteSession, remoteSessionShowsTranscriptToggle(selection) else { return }
        let key = remoteAttachMountKey(for: selection)
        remoteTranscriptHiddenAttach = remoteTranscriptHiddenAttach == key ? nil : key
    }

    /// Drops a transcript hide that belongs to any session other than
    /// `selection`, so a hide never outlives its session being on screen.
    /// Called when the selection changes and when the detail view's shown
    /// attach slot changes. A hide on `selection` itself is kept even when it
    /// names an older connection: it no longer hides anything, because the
    /// pane compares it against the current mount key. Writes only when there
    /// is a hide to drop, so the many calls that change nothing emit no
    /// observation.
    func clearRemoteTranscriptHide(unlessFor selection: RemoteSessionSelection?) {
        guard let hidden = remoteTranscriptHiddenAttach, hidden.selection != selection else { return }
        remoteTranscriptHiddenAttach = nil
    }

    /// The key `selection`'s attach terminal is mounted under now: the
    /// connection a transcript hide on it would belong to.
    private func remoteAttachMountKey(for selection: RemoteSessionSelection) -> RemoteAttachMountKey {
        RemoteAttachMountKey(selection: selection, generation: remoteAttachGeneration(for: selection))
    }

    /// The mirrored row for `selection`, or nil while it is not in the mirror.
    func remoteSessionPayload(for selection: RemoteSessionSelection) -> RemoteSessionPayload? {
        remoteSessions.first {
            $0.provider == selection.provider && $0.payload.id == selection.sessionID
        }?.payload
    }

    /// What the transcript pane's composer offers for `selection`: hidden
    /// unless the provider declares `send-submit`; otherwise running, blocked or exited from the provider's own report.
    func remoteComposerState(for selection: RemoteSessionSelection) -> RemoteComposerState {
        RemoteComposerState.resolve(
            capabilities: remoteProviderCapabilities(for: selection),
            session: remoteSessionPayload(for: selection))
    }

    // MARK: - Sync drivers

    /// Called by a pane when its driver starts; newer wins.
    func registerRemoteTranscriptSyncDriver(_ driver: RemoteTranscriptSyncDriver) {
        remoteTranscriptSyncDrivers[driver.selection] = WeakRemoteTranscriptSyncDriver(driver)
    }

    /// Only the registered driver may unregister, so a pane rebuilt while the
    /// old one is still going away does not evict its replacement.
    func unregisterRemoteTranscriptSyncDriver(_ driver: RemoteTranscriptSyncDriver) {
        guard remoteTranscriptSyncDrivers[driver.selection]?.driver === driver else { return }
        remoteTranscriptSyncDrivers.removeValue(forKey: driver.selection)
    }

    /// Sync `selection`'s transcript now rather than on its next tick — after
    /// a composer send succeeded. A no-op when no pane for it is on screen.
    func requestRemoteTranscriptSync(_ selection: RemoteSessionSelection) {
        remoteTranscriptSyncDrivers[selection]?.driver?.syncNow()
    }
}
