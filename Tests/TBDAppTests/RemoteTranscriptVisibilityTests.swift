import Foundation
import Testing
import TestSupport
@testable import TBDApp
import TBDShared

/// Whether a remote session's detail pane shows its transcript, which half
/// leads, and whether the toolbar offers the Transcript toggle — through
/// `AppState`, over the same attach state the pager reads
/// (docs/specs/2026-09-25-remote-session-transcript-design.md, "Opening the
/// transcript" and "Layout"). The pure gates are covered in
/// `RemoteTranscriptGatesTests`; these tests prove the plumbing feeds them and
/// that the hide, which belongs to one attach connection, lives and dies
/// where the spec says.
///
/// "Attached" is made the way the Attach button makes it: select the session,
/// then `reattachRemoteSession`. Where `RemoteSessionDetailView` would report
/// its shown attach slot, the test calls `setRemoteAttachSlotShown` itself.
///
/// Every test constructs `AppState(userDefaults:)` against a throwaway
/// `TestDefaultsSuite`: `UserDefaults.standard` on this unbundled executable
/// is the developer's real `TBDApp.plist`.
@MainActor
@Suite("Remote transcript visibility")
struct RemoteTranscriptVisibilityTests {
    private func withStateAndDefaults(_ body: (AppState, UserDefaults) -> Void) {
        let suite = TestDefaultsSuite("TBDAppTests.RemoteTranscriptVisibility")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        body(AppState(userDefaults: defaults), defaults)
    }

    private func withState(_ body: (AppState) -> Void) {
        withStateAndDefaults { state, _ in body(state) }
    }

    /// Re-calling replaces the roster entry, which is how a test moves the
    /// provider's health.
    private func seedProvider(
        _ state: AppState,
        capabilities: [String] = ["attach", "log", "transcript.read"],
        health: ProviderHealth = .ok
    ) {
        state.remoteProviders = state.remoteProviders.filter { $0.config.name != "acme" } + [
            RemoteProviderStatus(
                config: RemoteProviderConfig(name: "acme", exec: "/usr/bin/true"),
                describe: ProviderDescribe(name: "acme", capabilities: capabilities),
                health: health, errorMessage: nil, remediationLabel: nil, remediationCommand: nil
            )
        ]
    }

    /// Re-calling with the same `id` replaces that session's mirror row.
    private func seedSession(
        _ state: AppState, id: String, processState: RemoteProcessState = .running, gone: Bool = false
    ) {
        state.remoteSessions = state.remoteSessions.filter { $0.payload.id != id } + [
            RemoteSessionInfo(
                provider: "acme",
                payload: RemoteSessionPayload(id: id, state: processState),
                gone: gone, dismissed: false, lastSeen: Date()
            )
        ]
    }

    private func sel(_ id: String) -> RemoteSessionSelection {
        RemoteSessionSelection(provider: "acme", sessionID: id)
    }

    /// The connection a hide on `selection` names: the session plus the
    /// restart generation its terminal is mounted under.
    private func mountKey(_ selection: RemoteSessionSelection, generation: Int = 0) -> RemoteAttachMountKey {
        RemoteAttachMountKey(selection: selection, generation: generation)
    }

    /// The Attach button's path: select, then request the connection.
    private func attach(_ state: AppState, _ selection: RemoteSessionSelection) {
        state.selectedRemoteSession = selection
        state.reattachRemoteSession(selection)
    }

    /// The presentation as the separate wrappers report it, field by field —
    /// the answers the AppKit toolbar reads one at a time.
    private func presentationFromWrappers(
        _ state: AppState, _ selection: RemoteSessionSelection
    ) -> RemoteTranscriptPresentation {
        RemoteTranscriptPresentation(
            attached: state.remoteSessionIsAttached(selection),
            showsToggle: state.remoteSessionShowsTranscriptToggle(selection),
            showsPane: state.remoteSessionShowsTranscriptPane(selection),
            transcriptLeads: state.remoteSessionTranscriptLeads(selection))
    }

    // MARK: - Which half leads, and when the toggle is offered

    @Test func notAttachedLeadsWithTheTranscriptAndHidesTheToggle() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            state.selectedRemoteSession = s1

            #expect(!state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(state.remoteSessionTranscriptLeads(s1))
            #expect(!state.remoteSessionShowsTranscriptToggle(s1))

            // The toggle is not offered, so its action records no hide.
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == nil)
            #expect(state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    @Test func attachedPutsTheTranscriptOnTheRightWithTheToggle() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)

            // No daemon capabilities fetched: only the provider's
            // `transcript.read` gates the transcript.
            #expect(state.daemonCapabilities == nil)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(!state.remoteSessionTranscriptLeads(s1))
            #expect(state.remoteSessionShowsTranscriptToggle(s1))
        }
    }

    @Test func withoutTranscriptReadTheTerminalSideIsAlone() {
        withState { state in
            seedProvider(state, capabilities: ["attach", "log"])
            seedSession(state, id: "s1")
            let s1 = sel("s1")

            state.selectedRemoteSession = s1
            #expect(!state.remoteSessionIsAttached(s1))
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
            #expect(!state.remoteSessionTranscriptLeads(s1))
            #expect(!state.remoteSessionShowsTranscriptToggle(s1))

            state.reattachRemoteSession(s1)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
            #expect(!state.remoteSessionTranscriptLeads(s1))
            #expect(!state.remoteSessionShowsTranscriptToggle(s1))

            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == nil)
        }
    }

    // MARK: - The hide, for one session's connection

    @Test func theToggleHidesAndReshowsTheAttachedSession() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)

            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1))
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
            // Still offered, so the transcript can be shown again.
            #expect(state.remoteSessionShowsTranscriptToggle(s1))

            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == nil)
            #expect(state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    @Test func switchingSessionsShowsItAgain() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            seedSession(state, id: "s2")
            let s1 = sel("s1")
            let s2 = sel("s2")
            attach(state, s1)
            attach(state, s2)

            state.selectedRemoteSession = s1
            state.setRemoteAttachSlotShown(s1)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionIsAttached(s2))
            state.toggleRemoteTranscript(s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            // The selection change alone drops the hide, before the view
            // reports anything.
            state.selectedRemoteSession = s2
            #expect(state.remoteTranscriptHiddenAttach == nil)
            state.setRemoteAttachSlotShown(s2)

            state.selectedRemoteSession = s1
            state.setRemoteAttachSlotShown(s1)
            #expect(state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    @Test func goingToALocalWorktreeShowsItAgain() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1))

            // Selecting a local worktree clears the remote selection.
            state.selectedRemoteSession = nil
            #expect(state.remoteTranscriptHiddenAttach == nil)
        }
    }

    @Test func hidingOneSessionLeavesAnotherShown() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            seedSession(state, id: "s2")
            let s1 = sel("s1")
            let s2 = sel("s2")
            attach(state, s2)
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)
            #expect(state.remoteSessionIsAttached(s2))

            state.toggleRemoteTranscript(s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s2))
        }
    }

    @Test func reselectingTheSameSessionKeepsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)
            state.toggleRemoteTranscript(s1)

            state.selectedRemoteSession = s1
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1))
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            // A sidebar click on the row already selected takes the same
            // path through `selectRemoteSession`.
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1))
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    @Test func reattachingShowsItAgain() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)
            state.toggleRemoteTranscript(s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            // A clean detach ends the connection, and its hide with it,
            // before the view reports its slot hidden. Not attached, the
            // transcript shows and leads.
            state.markRemoteSessionDetached(s1, exitCode: 0)
            #expect(state.remoteTranscriptHiddenAttach == nil)
            #expect(!state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(state.remoteSessionTranscriptLeads(s1))

            state.setRemoteAttachSlotShown(nil)
            #expect(state.remoteTranscriptHiddenAttach == nil)

            state.reattachRemoteSession(s1)
            state.setRemoteAttachSlotShown(s1)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(!state.remoteSessionTranscriptLeads(s1))
        }
    }

    /// Reconnect replaces the attach child under a new generation while the
    /// session stays attached, so neither selection hook runs. The new
    /// connection shows the transcript anyway.
    @Test func reconnectingShowsItAgain() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)
            state.toggleRemoteTranscript(s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            let reconnected = state.reconnectRemoteSession(s1)
            #expect(reconnected)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// An unexpected exit ends the hide itself, with no slot hook. A
    /// reattach then mounts under the same generation, so only the clear
    /// keeps the old hide from matching the new connection.
    @Test func anExitEndsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1))

            // Exit 3 is the contract's transient class.
            let transientExit: Int32 = 3
            #expect(RemoteAttachExitClass.classify(exitCode: transientExit) == .unexpected)
            state.markRemoteSessionDetached(s1, exitCode: transientExit)
            #expect(state.remoteTranscriptHiddenAttach == nil)

            state.reattachRemoteSession(s1)
            #expect(state.remoteAttachGeneration(for: s1) == 0)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// The killed child's late exit, from the generation Reconnect replaced,
    /// is dropped, so it cannot end the hide on the connection that replaced
    /// it.
    @Test func aSupersededExitKeepsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)
            let reconnected = state.reconnectRemoteSession(s1)
            #expect(reconnected)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1, generation: 1))

            state.markRemoteSessionDetached(s1, exitCode: 0, generation: 0)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1, generation: 1))
            #expect(state.remoteSessionIsAttached(s1))
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// The detail view reports its shown slot on every change it sees, often
    /// for the same session. A repeat report keeps the hide.
    @Test func reportingTheSameSlotKeepsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)
            state.toggleRemoteTranscript(s1)

            state.setRemoteAttachSlotShown(s1)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1))
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// s2 is attached in the background and its provider declares
    /// `transcript.read`, so the toggle's own gate passes for it. Only the
    /// session on screen can be hidden.
    @Test func togglingAnUnselectedSessionDoesNothing() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            seedSession(state, id: "s2")
            let s1 = sel("s1")
            let s2 = sel("s2")
            attach(state, s2)
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)
            #expect(state.selectedRemoteSession == s1)
            #expect(state.remoteSessionIsAttached(s2))
            #expect(state.remoteSessionShowsTranscriptToggle(s2))

            state.toggleRemoteTranscript(s2)
            #expect(state.remoteTranscriptHiddenAttach == nil)
            #expect(state.remoteSessionShowsTranscriptPane(s2))
        }
    }

    // MARK: - Sessions that drop out of attach eligibility

    @Test func exitedWhileAttachedLeadsWithTheTranscript() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            #expect(state.remoteSessionIsAttached(s1))

            seedSession(state, id: "s1", processState: .exited)
            #expect(!state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(state.remoteSessionTranscriptLeads(s1))
            #expect(!state.remoteSessionShowsTranscriptToggle(s1))
        }
    }

    @Test func goneWhileAttachedLeadsWithTheTranscript() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            #expect(state.remoteSessionIsAttached(s1))

            seedSession(state, id: "s1", gone: true)
            #expect(!state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(state.remoteSessionTranscriptLeads(s1))
            #expect(!state.remoteSessionShowsTranscriptToggle(s1))
        }
    }

    @Test func needsSignInLeadsWithTheTranscript() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            #expect(state.remoteSessionIsAttached(s1))

            // The attach request is still held; the provider cannot sign in.
            seedProvider(state, health: .needsAuth)
            #expect(state.recentlyAttachedRemoteSessions.contains(s1))
            #expect(!state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(state.remoteSessionTranscriptLeads(s1))
            #expect(!state.remoteSessionShowsTranscriptToggle(s1))
        }
    }

    // MARK: - One presentation per evaluation

    /// The views read `remoteTranscriptPresentation(for:)` once; the AppKit
    /// toolbar reads the wrappers. Each state is pinned to its expected
    /// value as well, so the comparison cannot pass by both sides being
    /// wrong the same way.
    @Test func presentationMatchesTheWrappers() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            state.selectedRemoteSession = s1

            let notAttached: RemoteTranscriptPresentation = state.remoteTranscriptPresentation(for: s1)
            let notAttachedWrappers: RemoteTranscriptPresentation = presentationFromWrappers(state, s1)
            let notAttachedExpected = RemoteTranscriptPresentation(
                attached: false, showsToggle: false, showsPane: true, transcriptLeads: true)
            #expect(notAttached == notAttachedWrappers)
            #expect(notAttached == notAttachedExpected)

            state.reattachRemoteSession(s1)
            state.setRemoteAttachSlotShown(s1)
            let attached: RemoteTranscriptPresentation = state.remoteTranscriptPresentation(for: s1)
            let attachedWrappers: RemoteTranscriptPresentation = presentationFromWrappers(state, s1)
            let attachedExpected = RemoteTranscriptPresentation(
                attached: true, showsToggle: true, showsPane: true, transcriptLeads: false)
            #expect(attached == attachedWrappers)
            #expect(attached == attachedExpected)

            state.toggleRemoteTranscript(s1)
            let hidden: RemoteTranscriptPresentation = state.remoteTranscriptPresentation(for: s1)
            let hiddenWrappers: RemoteTranscriptPresentation = presentationFromWrappers(state, s1)
            let hiddenExpected = RemoteTranscriptPresentation(
                attached: true, showsToggle: true, showsPane: false, transcriptLeads: false)
            #expect(hidden == hiddenWrappers)
            #expect(hidden == hiddenExpected)

            // The provider stops declaring `transcript.read`; it can still
            // attach, so only the transcript answers change.
            seedProvider(state, capabilities: ["attach", "log"])
            let noCapability: RemoteTranscriptPresentation = state.remoteTranscriptPresentation(for: s1)
            let noCapabilityWrappers: RemoteTranscriptPresentation = presentationFromWrappers(state, s1)
            let noCapabilityExpected = RemoteTranscriptPresentation(
                attached: true, showsToggle: false, showsPane: false, transcriptLeads: false)
            #expect(noCapability == noCapabilityWrappers)
            #expect(noCapability == noCapabilityExpected)
        }
    }

    // MARK: - Persistence

    @Test func nothingIsPersisted() {
        withStateAndDefaults { state, defaults in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1))

            #expect(defaults.object(forKey: "remoteTranscriptOpen") == nil)
            // A relaunch over the same defaults opens with nothing hidden.
            #expect(AppState(userDefaults: defaults).remoteTranscriptHiddenAttach == nil)
        }
    }
}
