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
    /// the pure gates in `RemoteSessionDetailGates`. The pane is hidden only
    /// while the session is attached under exactly the hidden key, so a
    /// replaced connection shows its transcript at once.
    func remoteTranscriptPresentation(for selection: RemoteSessionSelection) -> RemoteTranscriptPresentation {
        let capabilities = remoteProviderCapabilities(for: selection)
        let attached = remoteSessionIsAttached(selection)
        return RemoteTranscriptPresentation(
            attached: attached,
            showsToggle: RemoteSessionDetailGates.showsTranscriptToggle(
                capabilities: capabilities, attached: attached),
            showsPane: RemoteSessionDetailGates.showsTranscriptPane(
                capabilities: capabilities, attached: attached,
                // The restart generation is read only while a hide exists:
                // spawn and unmount reports write it for every session, and
                // reading it unconditionally re-renders views on that traffic.
                hiddenByToggle: remoteTranscriptHiddenAttach.map {
                    $0.selection == selection && $0.generation == remoteAttachGeneration(for: selection)
                } ?? false),
            transcriptLeads: RemoteSessionDetailGates.transcriptLeads(
                capabilities: capabilities, attached: attached))
    }

    /// Whether the window toolbar offers the Transcript toggle for
    /// `selection`: its provider declares `transcript.read` and it is
    /// attached (`remoteSessionIsAttached`).
    ///
    /// The single-answer name a window toolbar calls when it builds each item
    /// on its own, as an AppKit toolbar does; `toggleRemoteTranscript` gates
    /// on it too. A caller that needs several answers reads
    /// `remoteTranscriptPresentation(for:)` once instead.
    func remoteSessionShowsTranscriptToggle(_ selection: RemoteSessionSelection) -> Bool {
        remoteTranscriptPresentation(for: selection).showsToggle
    }

    /// Whether `selection`'s detail pane shows the transcript half of its
    /// split: always while it is not attached, and while it is attached
    /// unless the toolbar toggle has hidden it for this session's current
    /// connection (`remoteTranscriptHiddenAttach`).
    ///
    /// The single-answer name a window toolbar calls when it builds each item
    /// on its own, as an AppKit toolbar does. A caller that needs several
    /// answers reads `remoteTranscriptPresentation(for:)` once instead.
    func remoteSessionShowsTranscriptPane(_ selection: RemoteSessionSelection) -> Bool {
        remoteTranscriptPresentation(for: selection).showsPane
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

    /// Ends a transcript hide on any session other than `selection`, because
    /// the user has left the session it belongs to (the rule is on
    /// `remoteTranscriptHiddenAttach`). Called when the selection changes. A
    /// hide on `selection` itself is kept, so reselecting the session on
    /// screen leaves it hidden. Writes only when there is a hide to end, so a
    /// call that changes nothing emits no observation.
    func clearRemoteTranscriptHide(unlessFor selection: RemoteSessionSelection?) {
        guard let hidden = remoteTranscriptHiddenAttach, hidden.selection != selection else { return }
        remoteTranscriptHiddenAttach = nil
    }

    /// Ends the transcript hide on `connection`, because that connection has
    /// ended (the rule is on `remoteTranscriptHiddenAttach`). Called with the
    /// key of a connection that exited or was unmounted. Writes only when
    /// `connection` is the one hidden, so a hide on any other connection,
    /// including a later one of the same session, is left alone.
    func clearRemoteTranscriptHide(ofConnection connection: RemoteAttachMountKey) {
        guard remoteTranscriptHiddenAttach == connection else { return }
        remoteTranscriptHiddenAttach = nil
    }

    /// The key `selection`'s attach terminal is mounted under now: the
    /// connection a transcript hide on it would belong to.
    func remoteAttachMountKey(for selection: RemoteSessionSelection) -> RemoteAttachMountKey {
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
