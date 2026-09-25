import Foundation
import TBDShared

/// App-side wiring for a remote session's transcript pane
/// (docs/specs/2026-09-25-remote-session-transcript-design.md, "App"). The
/// decisions themselves are the pure gates in `RemoteSessionDetailGates`;
/// these accessors only look up their inputs for a selection.
extension AppState {
    /// `remote_transcript_enabled`. Always false in this build: the config
    /// column and its daemon plumbing land separately, and this accessor is
    /// the single place that wires them in. Until then the toggle, the pane
    /// and the remote composer stay off everywhere.
    var remoteTranscriptEnabled: Bool { false }

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
}
