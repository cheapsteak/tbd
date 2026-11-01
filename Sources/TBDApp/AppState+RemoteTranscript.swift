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

/// What the window toolbar and the detail pane show for one remote session's
/// transcript, decided together (`AppState.remoteTranscriptPresentation(for:)`).
struct RemoteTranscriptPresentation: Equatable {
    /// Whether the session is attached (`AppState.remoteSessionIsAttached`).
    let attached: Bool
    /// Whether the toolbar offers the Transcript toggle.
    let showsToggle: Bool
    /// Whether the detail pane shows the transcript half of its split.
    let showsPane: Bool
    /// Whether the transcript is the split's main side, on the left.
    let transcriptLeads: Bool
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

    /// Every transcript decision for `selection`, from one read of its
    /// provider's capabilities and one of whether it is attached. Whether a
    /// session is attached is `attachedRemoteSelections`, which is rebuilt on
    /// every read, so a view that needs several of these answers asks here
    /// once per evaluation rather than once per answer. The fields come from
    /// the pure gates in `RemoteSessionDetailGates`.
    func remoteTranscriptPresentation(for selection: RemoteSessionSelection) -> RemoteTranscriptPresentation {
        let capabilities = remoteProviderCapabilities(for: selection)
        let attached = remoteSessionIsAttached(selection)
        return RemoteTranscriptPresentation(
            attached: attached,
            showsToggle: RemoteSessionDetailGates.showsTranscriptToggle(
                capabilities: capabilities, attached: attached),
            showsPane: RemoteSessionDetailGates.showsTranscriptPane(
                capabilities: capabilities, attached: attached,
                hiddenByToggle: remoteTranscriptHiddenAttach == remoteAttachMountKey(for: selection)),
            transcriptLeads: RemoteSessionDetailGates.transcriptLeads(
                capabilities: capabilities, attached: attached))
    }

    /// Whether the window toolbar offers the Transcript toggle for
    /// `selection`: its provider declares `transcript.read` and it is
    /// attached (`remoteSessionIsAttached`). One field of
    /// `remoteTranscriptPresentation(for:)`, for a caller that needs only it.
    func remoteSessionShowsTranscriptToggle(_ selection: RemoteSessionSelection) -> Bool {
        remoteTranscriptPresentation(for: selection).showsToggle
    }

    /// Whether `selection`'s detail pane shows the transcript half of its
    /// split: always while it is not attached, and while it is attached
    /// unless the toolbar toggle has hidden it for this session's current
    /// connection (`remoteTranscriptHiddenAttach`). One field of
    /// `remoteTranscriptPresentation(for:)`, for a caller that needs only it.
    func remoteSessionShowsTranscriptPane(_ selection: RemoteSessionSelection) -> Bool {
        remoteTranscriptPresentation(for: selection).showsPane
    }

    /// Whether the transcript is the main side of `selection`'s split, with
    /// the terminal side on the right: its provider declares
    /// `transcript.read` and it is not attached. Attaching and detaching swap
    /// the halves. One field of `remoteTranscriptPresentation(for:)`, for a
    /// caller that needs only it.
    func remoteSessionTranscriptLeads(_ selection: RemoteSessionSelection) -> Bool {
        remoteTranscriptPresentation(for: selection).transcriptLeads
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
