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
    /// the pure gates in `RemoteSessionDetailGates`, and the hide they apply
    /// is `remoteTranscriptHiddenSelection`.
    func remoteTranscriptPresentation(for selection: RemoteSessionSelection) -> RemoteTranscriptPresentation {
        let capabilities = remoteProviderCapabilities(for: selection)
        let attached = remoteSessionIsAttached(selection)
        return RemoteTranscriptPresentation(
            attached: attached,
            showsToggle: RemoteSessionDetailGates.showsTranscriptToggle(
                capabilities: capabilities, attached: attached),
            showsPane: RemoteSessionDetailGates.showsTranscriptPane(
                capabilities: capabilities, attached: attached,
                hiddenByToggle: remoteTranscriptHiddenSelection == selection),
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
    /// unless the toolbar toggle has hidden it
    /// (`remoteTranscriptHiddenSelection`).
    ///
    /// The single-answer name a window toolbar calls when it builds each item
    /// on its own, as an AppKit toolbar does. A caller that needs several
    /// answers reads `remoteTranscriptPresentation(for:)` once instead.
    func remoteSessionShowsTranscriptPane(_ selection: RemoteSessionSelection) -> Bool {
        remoteTranscriptPresentation(for: selection).showsPane
    }

    /// The toolbar toggle's action: hides `selection`'s transcript, or shows
    /// it again when `selection` is the one hidden. Only one transcript is
    /// ever hidden, and nothing is persisted; how long a hide lasts is the
    /// rule on `remoteTranscriptHiddenSelection`. A no-op unless the toggle is
    /// offered for `selection` and `selection` is the session on screen, so a
    /// session that is not attached or not selected never records a hide.
    func toggleRemoteTranscript(_ selection: RemoteSessionSelection) {
        guard selection == selectedRemoteSession, remoteSessionShowsTranscriptToggle(selection) else { return }
        remoteTranscriptHiddenSelection = remoteTranscriptHiddenSelection == selection ? nil : selection
    }

    /// Ends the transcript hide on `selection` if it is the one hidden: the
    /// single clear behind every gesture that ends a hide (the rule is on
    /// `remoteTranscriptHiddenSelection`). Writes only when the value changes,
    /// so a call that ends nothing emits no observation.
    func endRemoteTranscriptHide(for selection: RemoteSessionSelection) {
        guard remoteTranscriptHiddenSelection == selection else { return }
        remoteTranscriptHiddenSelection = nil
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
