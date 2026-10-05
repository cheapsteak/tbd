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

    /// Whether the window toolbar offers the Transcript toggle for `selection`.
    func remoteSessionShowsTranscriptToggle(_ selection: RemoteSessionSelection) -> Bool {
        RemoteSessionDetailGates.showsTranscriptToggle(
            capabilities: remoteProviderCapabilities(for: selection),
            featureEnabled: remoteTranscriptEnabled)
    }

    /// Whether `selection`'s detail pane shows the transcript half of its split.
    func remoteSessionShowsTranscriptPane(_ selection: RemoteSessionSelection) -> Bool {
        RemoteSessionDetailGates.showsTranscriptPane(
            capabilities: remoteProviderCapabilities(for: selection),
            featureEnabled: remoteTranscriptEnabled,
            open: remoteTranscriptOpen)
    }

    /// The toolbar toggle's action. Stores an explicit value, so the choice
    /// survives relaunch and applies to every remote session.
    func toggleRemoteTranscriptOpen() {
        remoteTranscriptOpen.toggle()
    }

    /// The mirrored row for `selection`, or nil while it is not in the mirror.
    func remoteSessionPayload(for selection: RemoteSessionSelection) -> RemoteSessionPayload? {
        remoteSessions.first {
            $0.provider == selection.provider && $0.payload.id == selection.sessionID
        }?.payload
    }

    /// What the transcript pane's composer offers for `selection`: hidden
    /// unless the provider declares `send-submit` and both
    /// `remote_transcript_enabled` and `transcript_composer_enabled` are on;
    /// otherwise running, blocked or exited from the provider's own report.
    func remoteComposerState(for selection: RemoteSessionSelection) -> RemoteComposerState {
        RemoteComposerState.resolve(
            capabilities: remoteProviderCapabilities(for: selection),
            session: remoteSessionPayload(for: selection),
            remoteTranscriptEnabled: remoteTranscriptEnabled,
            composerEnabled: transcriptComposerEnabled)
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

    // MARK: - Settings

    /// Help text for the Settings toggle. A stored constant so it is
    /// assertable.
    static let remoteTranscriptHelp = """
        Adds a Transcript pane beside a remote session's terminal, for \
        providers that can serve one. With the message composer also on, it \
        can send messages to the session too. Off by default (soaking).
        """

    /// Persist `remote_transcript_enabled`, then re-fetch capabilities so the
    /// Settings toggle and every remote pane reflect the daemon's persisted
    /// state. No restart in either direction.
    func setRemoteTranscriptEnabled(_ enabled: Bool) async {
        do {
            try await remoteTranscriptFlagSetter(enabled)
            await refreshDaemonCapabilities()
        } catch {
            logger.error("Failed to set remote transcript: \(error, privacy: .public)")
            showAlert(
                "Failed to set the remote transcript: \(error.localizedDescription)",
                isError: true)
        }
    }
}
