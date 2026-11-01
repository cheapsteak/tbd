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
/// that the hide, which belongs to the session on screen, lives and dies
/// where the spec says.
///
/// "Attached" is made the way the Attach button makes it: select the session,
/// then `reattachRemoteSession`. A hide ends only on a gesture: the selection
/// moving, a reattach, or a reconnect the user asks for. Everything the app
/// does on its own keeps it — the pager's lifecycle reports,
/// `markRemoteSessionDetached` and `markRemoteAttachUnmounted`, which the
/// tests call where the pager would, and the restart after a network change,
/// `restartRemoteAttachChildren(startedBefore:)`. The detail view's
/// attach-slot report (`setRemoteAttachSlotShown`) never ends a hide, and the
/// tests that call it pin exactly that.
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
            #expect(state.remoteTranscriptHiddenSelection == nil)
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
            #expect(state.remoteTranscriptHiddenSelection == nil)
        }
    }

    // MARK: - The hide, for the session on screen

    @Test func theToggleHidesAndReshowsTheAttachedSession() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)

            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenSelection == s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
            // Still offered, so the transcript can be shown again.
            #expect(state.remoteSessionShowsTranscriptToggle(s1))

            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenSelection == nil)
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
            #expect(state.remoteTranscriptHiddenSelection == nil)

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
            #expect(state.remoteTranscriptHiddenSelection == s1)

            // Selecting a local worktree clears the remote selection.
            state.selectedRemoteSession = nil
            #expect(state.remoteTranscriptHiddenSelection == nil)
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
            #expect(state.remoteTranscriptHiddenSelection == s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            // A sidebar click on the row already selected takes the same
            // path through `selectRemoteSession`.
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.remoteTranscriptHiddenSelection == s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// A clean exit is not a gesture, so it keeps the hide; not attached, the
    /// transcript shows and leads regardless. The Reattach that follows is a
    /// gesture, and ends it.
    @Test func reattachingShowsItAgain() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            state.markRemoteSessionDetached(s1, exitCode: 0)
            #expect(state.remoteTranscriptHiddenSelection == s1)
            #expect(!state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(state.remoteTranscriptPresentation(for: s1).transcriptLeads)

            state.reattachRemoteSession(s1)
            #expect(state.remoteTranscriptHiddenSelection == nil)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(!state.remoteTranscriptPresentation(for: s1).transcriptLeads)
        }
    }

    /// The context menu's Attach is the same gesture as the Attach button,
    /// though it reaches the attach state through `selectRemoteSession`
    /// rather than `reattachRemoteSession`. A plain click on the same row
    /// keeps the hide (`reselectingTheSameSessionKeepsTheHide`).
    @Test func theContextMenuAttachShowsItAgain() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            state.markRemoteSessionDetached(s1, exitCode: 0)
            #expect(state.remoteTranscriptHiddenSelection == s1)

            state.selectRemoteSession(provider: "acme", sessionID: "s1", reattach: true)
            #expect(state.remoteTranscriptHiddenSelection == nil)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// The toolbar's and the context menu's Reconnect, and the CLI's
    /// `remote.reconnect`, all call `reconnectRemoteSession` with its default,
    /// which ends the hide when the reconnect goes ahead.
    @Test func aUserReconnectShowsItAgain() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            let reconnected = state.reconnectRemoteSession(s1)
            #expect(reconnected)
            #expect(state.remoteTranscriptHiddenSelection == nil)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// A reconnect that is refused changes nothing, the hide included. Here
    /// the provider needs sign-in, so the session is not attach-eligible.
    @Test func aRefusedReconnectKeepsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenSelection == s1)

            seedProvider(state, health: .needsAuth)
            let reconnected = state.reconnectRemoteSession(s1)
            #expect(!reconnected)
            #expect(state.remoteTranscriptHiddenSelection == s1)
        }
    }

    /// A network change or a wake restarts every child that predates it,
    /// through `restartRemoteAttachChildren(startedBefore:)`. Nobody asked
    /// for that restart, so the new connection keeps the hide.
    @Test func anAutomaticRestartKeepsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
            #expect(state.remoteAttachGeneration(for: s1) == 0)
            state.markRemoteAttachStarted(
                s1, generation: state.remoteAttachGeneration(for: s1), at: Date(timeIntervalSince1970: 100))

            let restarted = state.restartRemoteAttachChildren(startedBefore: Date(timeIntervalSince1970: 200))
            #expect(restarted == 1)
            #expect(state.remoteAttachGeneration(for: s1) == 1)
            #expect(state.remoteTranscriptHiddenSelection == s1)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// An unexpected exit puts the session into backoff, and the app
    /// re-attaches it on its own once that elapses. Neither is a gesture, so
    /// the hide survives both.
    @Test func anUnexpectedExitKeepsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenSelection == s1)

            // Exit 3 is the contract's transient class. Its backoff is
            // measured from an instant long past, so it has already elapsed
            // and the session is re-admitted with no gesture.
            let transientExit: Int32 = 3
            #expect(RemoteAttachExitClass.classify(exitCode: transientExit) == .unexpected)
            state.markRemoteSessionDetached(s1, exitCode: transientExit, now: Date(timeIntervalSince1970: 0))
            #expect(state.remoteTranscriptHiddenSelection == s1)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// The pager tears a tab down without an exit when the session leaves
    /// eligibility — here its provider needs sign-in — and reports the
    /// unmount. That keeps the hide, and once the provider can sign in again
    /// the app re-attaches the session on its own with the hide in force.
    @Test func anUnmountKeepsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenSelection == s1)

            seedProvider(state, health: .needsAuth)
            #expect(!state.remoteSessionIsAttached(s1))
            state.markRemoteAttachUnmounted(s1, generation: state.remoteAttachGeneration(for: s1))
            #expect(state.remoteTranscriptHiddenSelection == s1)
            // Not attached, the transcript shows regardless of the hide.
            #expect(state.remoteSessionShowsTranscriptPane(s1))

            seedProvider(state)
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
            #expect(state.remoteTranscriptHiddenSelection == s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))
        }
    }

    /// The slot report drives focus only. Even reporting no slot and then
    /// the session again, as a view that briefly draws the not-attached
    /// state would, leaves the hide to the gestures that end it.
    @Test func reportingTheAttachSlotNeverEndsTheHide() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenSelection == s1)

            state.setRemoteAttachSlotShown(nil)
            #expect(state.remoteTranscriptHiddenSelection == s1)
            state.setRemoteAttachSlotShown(s1)
            #expect(state.remoteTranscriptHiddenSelection == s1)
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
            #expect(state.remoteTranscriptHiddenSelection == nil)
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

    /// Spawn reports write `remoteAttachGenerations` for every session, and
    /// the presentation reads no restart generation, so B's spawn report
    /// leaves A's presentation alone. The control is a mutation the
    /// presentation does read: hiding A changes
    /// `remoteTranscriptHiddenSelection` and reaches a fresh probe once, so
    /// the probe can see a dependency when it is there.
    @Test func presentationIgnoresSpawnReports() {
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
            #expect(state.remoteTranscriptHiddenSelection == nil)

            let spawn = PresentationChangeRecord()
            withObservationTracking {
                _ = state.remoteTranscriptPresentation(for: a)
            } onChange: {
                MainActor.assumeIsolated { spawn.count += 1 }
            }
            state.markRemoteAttachStarted(
                b, generation: state.remoteAttachGeneration(for: b), at: Date(timeIntervalSince1970: 1))
            #expect(spawn.count == 0, "B's spawn report re-evaluated A's presentation")

            // The control: a mutation the presentation reads.
            let hide = PresentationChangeRecord()
            withObservationTracking {
                _ = state.remoteTranscriptPresentation(for: a)
            } onChange: {
                MainActor.assumeIsolated { hide.count += 1 }
            }
            state.toggleRemoteTranscript(a)
            #expect(state.remoteTranscriptHiddenSelection == a)
            #expect(hide.count == 1, "hiding A never reached A's presentation")
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
            #expect(state.remoteTranscriptHiddenSelection == s1)

            #expect(defaults.object(forKey: "remoteTranscriptOpen") == nil)
            // A relaunch over the same defaults opens with nothing hidden.
            #expect(AppState(userDefaults: defaults).remoteTranscriptHiddenSelection == nil)
        }
    }
}
