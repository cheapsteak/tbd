import Foundation
import Observation
import Testing
import TestSupport
@testable import TBDApp
import TBDShared

/// Counts a `withObservationTracking` probe's `onChange` calls. `onChange` is
/// `@Sendable`, so the count lives in a main-actor box rather than a captured
/// local `var`.
@MainActor
private final class PresentationChangeRecord {
    var count = 0
}

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
/// then `reattachRemoteSession`. A hide ends on the selection moving and on
/// the pager's own lifecycle reports, `markRemoteSessionDetached` and
/// `markRemoteAttachUnmounted`, which the tests call where the pager would.
/// The detail view's attach-slot report (`setRemoteAttachSlotShown`) never
/// ends a hide, and the tests that call it pin exactly that.
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

    /// The presentation fields that have a single-answer name of their own.
    private struct SingleAnswers: Equatable {
        let attached: Bool
        let showsToggle: Bool
        let showsPane: Bool
    }

    /// The single-answer names' answers for `selection`, as a toolbar that
    /// builds each item on its own reads them.
    private func singleAnswers(_ state: AppState, _ selection: RemoteSessionSelection) -> SingleAnswers {
        SingleAnswers(
            attached: state.remoteSessionIsAttached(selection),
            showsToggle: state.remoteSessionShowsTranscriptToggle(selection),
            showsPane: state.remoteSessionShowsTranscriptPane(selection))
    }

    /// The same three fields, read from one presentation.
    private func singleAnswers(of presentation: RemoteTranscriptPresentation) -> SingleAnswers {
        SingleAnswers(
            attached: presentation.attached,
            showsToggle: presentation.showsToggle,
            showsPane: presentation.showsPane)
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
            #expect(state.remoteTranscriptPresentation(for: s1).transcriptLeads)
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
            #expect(!state.remoteTranscriptPresentation(for: s1).transcriptLeads)
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
            #expect(!state.remoteTranscriptPresentation(for: s1).transcriptLeads)
            #expect(!state.remoteSessionShowsTranscriptToggle(s1))

            state.reattachRemoteSession(s1)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
            #expect(!state.remoteTranscriptPresentation(for: s1).transcriptLeads)
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
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionIsAttached(s2))
            state.toggleRemoteTranscript(s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            // The selection change alone ends the hide.
            state.selectedRemoteSession = s2
            #expect(state.remoteTranscriptHiddenAttach == nil)

            state.selectedRemoteSession = s1
            #expect(state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    @Test func goingToALocalWorktreeShowsItAgain() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
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

    /// The clean exit is what ends the hide. The reattach that follows
    /// mounts under the same generation 0, so a hide the exit left behind
    /// would hide the new connection's transcript.
    @Test func reattachingShowsItAgain() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            // A clean detach ends the connection, and its hide with it. Not
            // attached, the transcript shows and leads.
            state.markRemoteSessionDetached(s1, exitCode: 0)
            #expect(state.remoteTranscriptHiddenAttach == nil)
            #expect(!state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(state.remoteTranscriptPresentation(for: s1).transcriptLeads)

            state.reattachRemoteSession(s1)
            #expect(state.remoteAttachGeneration(for: s1) == 0)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(!state.remoteTranscriptPresentation(for: s1).transcriptLeads)
        }
    }

    /// Reconnect replaces the attach child under a new generation while the
    /// session stays attached and selected. The new connection shows the
    /// transcript at once, and the pager's unmount of the replaced
    /// connection then ends the old hide.
    @Test func reconnectingShowsItAgain() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            let reconnected = state.reconnectRemoteSession(s1)
            #expect(reconnected)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))

            state.markRemoteAttachUnmounted(s1, generation: 0)
            #expect(state.remoteTranscriptHiddenAttach == nil)
            #expect(state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// An unexpected exit ends the hide itself. A reattach then mounts under
    /// the same generation, so only the clear keeps the old hide from
    /// matching the new connection.
    @Test func anExitEndsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
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

    /// The pager tears a tab down without an exit when the session leaves
    /// eligibility — here its provider needs sign-in — and reports the
    /// unmount. That ends the hide. The session is then re-admitted under the
    /// same generation 0, so a hide the unmount left behind would hide the
    /// new connection's transcript.
    @Test func anUnmountEndsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1))

            seedProvider(state, health: .needsAuth)
            #expect(!state.remoteSessionIsAttached(s1))
            state.markRemoteAttachUnmounted(s1, generation: 0)
            #expect(state.remoteTranscriptHiddenAttach == nil)

            seedProvider(state)
            #expect(state.remoteAttachGeneration(for: s1) == 0)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// After a reconnect the pager unmounts the replaced generation-0 tab.
    /// That report names the old connection, so it leaves alone a hide on the
    /// generation-1 connection that replaced it.
    @Test func anUnmountOfAnOldConnectionKeepsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            let reconnected = state.reconnectRemoteSession(s1)
            #expect(reconnected)
            #expect(state.remoteAttachGeneration(for: s1) == 1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1, generation: 1))

            state.markRemoteAttachUnmounted(s1, generation: 0)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1, generation: 1))
            #expect(state.remoteSessionIsAttached(s1))
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// The detail view reports its shown attach slot on every change it
    /// sees, often for the same session. A repeat report keeps the hide.
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

    /// The slot report drives focus only. Even reporting no slot and then
    /// the session again, as a view that briefly draws the not-attached
    /// state would, leaves the hide to the selection and the pager's
    /// lifecycle reports.
    @Test func reportingTheAttachSlotNeverEndsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1))

            state.setRemoteAttachSlotShown(nil)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1))
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
            #expect(state.remoteTranscriptPresentation(for: s1).transcriptLeads)
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
            #expect(state.remoteTranscriptPresentation(for: s1).transcriptLeads)
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
            #expect(state.remoteTranscriptPresentation(for: s1).transcriptLeads)
            #expect(!state.remoteSessionShowsTranscriptToggle(s1))
        }
    }

    // MARK: - One presentation per evaluation

    /// The views read `remoteTranscriptPresentation(for:)` once; a toolbar
    /// that builds each item on its own reads the single-answer names. Each
    /// state is pinned to its expected value as well, so the comparison
    /// cannot pass by both sides being wrong the same way.
    @Test func presentationMatchesTheWrappers() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            state.selectedRemoteSession = s1

            let notAttached: RemoteTranscriptPresentation = state.remoteTranscriptPresentation(for: s1)
            let notAttachedAnswers: SingleAnswers = singleAnswers(of: notAttached)
            let notAttachedWrappers: SingleAnswers = singleAnswers(state, s1)
            let notAttachedExpected = RemoteTranscriptPresentation(
                attached: false, showsToggle: false, showsPane: true, transcriptLeads: true)
            #expect(notAttachedAnswers == notAttachedWrappers)
            #expect(notAttached == notAttachedExpected)

            state.reattachRemoteSession(s1)
            let attached: RemoteTranscriptPresentation = state.remoteTranscriptPresentation(for: s1)
            let attachedAnswers: SingleAnswers = singleAnswers(of: attached)
            let attachedWrappers: SingleAnswers = singleAnswers(state, s1)
            let attachedExpected = RemoteTranscriptPresentation(
                attached: true, showsToggle: true, showsPane: true, transcriptLeads: false)
            #expect(attachedAnswers == attachedWrappers)
            #expect(attached == attachedExpected)

            state.toggleRemoteTranscript(s1)
            let hidden: RemoteTranscriptPresentation = state.remoteTranscriptPresentation(for: s1)
            let hiddenAnswers: SingleAnswers = singleAnswers(of: hidden)
            let hiddenWrappers: SingleAnswers = singleAnswers(state, s1)
            let hiddenExpected = RemoteTranscriptPresentation(
                attached: true, showsToggle: true, showsPane: false, transcriptLeads: false)
            #expect(hiddenAnswers == hiddenWrappers)
            #expect(hidden == hiddenExpected)

            // The provider stops declaring `transcript.read`; it can still
            // attach, so only the transcript answers change.
            seedProvider(state, capabilities: ["attach", "log"])
            let noCapability: RemoteTranscriptPresentation = state.remoteTranscriptPresentation(for: s1)
            let noCapabilityAnswers: SingleAnswers = singleAnswers(of: noCapability)
            let noCapabilityWrappers: SingleAnswers = singleAnswers(state, s1)
            let noCapabilityExpected = RemoteTranscriptPresentation(
                attached: true, showsToggle: false, showsPane: false, transcriptLeads: false)
            #expect(noCapabilityAnswers == noCapabilityWrappers)
            #expect(noCapability == noCapabilityExpected)
        }
    }

    /// Spawn reports write `remoteAttachGenerations` for every session, so
    /// the presentation reads a restart generation only while a hide exists.
    /// With nothing hidden, B's spawn report leaves A's presentation alone.
    /// The control hides A and arms the probe again: the same report then
    /// reaches it once, so the probe can see the dependency when it is there.
    @Test func presentationIgnoresSpawnReportsWhileNothingIsHidden() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "a")
            seedSession(state, id: "b")
            let a = sel("a")
            let b = sel("b")
            attach(state, b)
            attach(state, a)
            #expect(state.selectedRemoteSession == a)
            #expect(state.remoteSessionIsAttached(a))
            #expect(state.remoteSessionIsAttached(b))
            #expect(state.remoteTranscriptHiddenAttach == nil)

            let shown = PresentationChangeRecord()
            withObservationTracking {
                _ = state.remoteTranscriptPresentation(for: a)
            } onChange: {
                MainActor.assumeIsolated { shown.count += 1 }
            }
            state.markRemoteAttachStarted(
                b, generation: state.remoteAttachGeneration(for: b), at: Date(timeIntervalSince1970: 1))
            #expect(shown.count == 0, "B's spawn report re-evaluated A's presentation with nothing hidden")

            // The control: hidden, A's presentation reads the generation.
            state.toggleRemoteTranscript(a)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(a))
            let hidden = PresentationChangeRecord()
            withObservationTracking {
                _ = state.remoteTranscriptPresentation(for: a)
            } onChange: {
                MainActor.assumeIsolated { hidden.count += 1 }
            }
            state.markRemoteAttachStarted(
                b, generation: state.remoteAttachGeneration(for: b), at: Date(timeIntervalSince1970: 2))
            #expect(hidden.count == 1, "B's spawn report never reached A's presentation while A was hidden")
        }
    }

    // MARK: - Persistence

    @Test func nothingIsPersisted() {
        withStateAndDefaults { state, defaults in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenAttach == mountKey(s1))

            #expect(defaults.object(forKey: "remoteTranscriptOpen") == nil)
            // A relaunch over the same defaults opens with nothing hidden.
            #expect(AppState(userDefaults: defaults).remoteTranscriptHiddenAttach == nil)
        }
    }
}
