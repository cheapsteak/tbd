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
/// that the per-session hide lives and dies where the spec says.
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
    private func seedSession(_ state: AppState, id: String, processState: RemoteProcessState = .running) {
        state.remoteSessions = state.remoteSessions.filter { $0.payload.id != id } + [
            RemoteSessionInfo(
                provider: "acme",
                payload: RemoteSessionPayload(id: id, state: processState),
                gone: false, dismissed: false, lastSeen: Date()
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
            #expect(state.remoteTranscriptHiddenSelection == nil)
        }
    }

    // MARK: - The per-session hide

    @Test func theToggleHidesAndReshowsTheAttachedSession() {
        withState { state in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)

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
            state.setRemoteAttachSlotShown(s1)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionIsAttached(s2))
            state.toggleRemoteTranscript(s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            // The selection change alone drops the hide, before the view
            // reports anything.
            state.selectedRemoteSession = s2
            #expect(state.remoteTranscriptHiddenSelection == nil)
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
            #expect(state.remoteTranscriptHiddenSelection == s1)
            #expect(!state.remoteSessionShowsTranscriptPane(s1))

            // A sidebar click on the row already selected takes the same
            // path through `selectRemoteSession`.
            state.selectRemoteSession(provider: "acme", sessionID: "s1")
            #expect(state.remoteTranscriptHiddenSelection == s1)
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

            // A clean detach. Not attached, the transcript shows and leads
            // on that alone, before the view reports its slot hidden.
            state.markRemoteSessionDetached(s1, exitCode: 0)
            #expect(!state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(state.remoteSessionTranscriptLeads(s1))

            state.setRemoteAttachSlotShown(nil)
            #expect(state.remoteTranscriptHiddenSelection == nil)

            state.reattachRemoteSession(s1)
            state.setRemoteAttachSlotShown(s1)
            #expect(state.remoteSessionIsAttached(s1))
            #expect(state.remoteSessionShowsTranscriptPane(s1))
            #expect(!state.remoteSessionTranscriptLeads(s1))
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

    // MARK: - Persistence

    @Test func nothingIsPersisted() {
        withStateAndDefaults { state, defaults in
            seedProvider(state)
            seedSession(state, id: "s1")
            let s1 = sel("s1")
            attach(state, s1)
            state.setRemoteAttachSlotShown(s1)
            state.toggleRemoteTranscript(s1)
            #expect(state.remoteTranscriptHiddenSelection == s1)

            #expect(defaults.object(forKey: "remoteTranscriptOpen") == nil)
            // A relaunch over the same defaults opens with nothing hidden.
            #expect(AppState(userDefaults: defaults).remoteTranscriptHiddenSelection == nil)
        }
    }
}
