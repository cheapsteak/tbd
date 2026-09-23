import Foundation
import Testing
@testable import TBDApp

/// Pure capability gates behind `RemoteSessionDetailView` and the window
/// toolbar's remote-session buttons — `canAttach`, `content`, `showsStop`.
/// One test per gate direction, per repo policy for behavior-gating
/// conditionals, including the `log`-only shape that once rendered a
/// permanently blank pane.
@Suite("Remote session detail — pure capability gates")
struct RemoteSessionDetailGatesTests {
    // MARK: - canAttach(capabilities:gone:)

    @Test func canAttachWhenAttachDeclaredAndNotGone() {
        #expect(RemoteSessionDetailGates.canAttach(capabilities: ["attach"], gone: false))
    }

    @Test func cannotAttachWithoutTheCapability() {
        #expect(!RemoteSessionDetailGates.canAttach(capabilities: [], gone: false))
        #expect(!RemoteSessionDetailGates.canAttach(capabilities: ["log", "send"], gone: false))
    }

    @Test func cannotAttachWhenGoneEvenIfDeclared() {
        // Consistent with `RemoteSessionActionMenu.items(gone:)` collapsing
        // Attach out of the context menu for a tombstone row.
        #expect(!RemoteSessionDetailGates.canAttach(capabilities: ["attach"], gone: true))
    }

    // MARK: - content(capabilities:gone:)

    @Test func contentIsAttachWheneverAttachIsPossible() {
        #expect(RemoteSessionDetailGates.content(capabilities: ["attach"], gone: false) == .attach)
        // The log never displaces a usable terminal — there is no picker.
        #expect(RemoteSessionDetailGates.content(capabilities: ["log", "attach"], gone: false) == .attach)
    }

    @Test func contentFallsBackToLogWhenAttachIsNotDeclared() {
        // The shape that once rendered a blank pane: a `log`-only provider.
        #expect(RemoteSessionDetailGates.content(capabilities: ["log"], gone: false) == .log)
    }

    @Test func contentFallsBackToLogWhenGone() {
        // A gone session can't attach, but its last scrollback is still
        // worth reading.
        #expect(RemoteSessionDetailGates.content(capabilities: ["attach", "log"], gone: true) == .log)
    }

    @Test func contentIsUnsupportedWithNeitherCapability() {
        #expect(RemoteSessionDetailGates.content(capabilities: [], gone: false) == .unsupported)
        #expect(RemoteSessionDetailGates.content(capabilities: ["events", "rename"], gone: false) == .unsupported)
        #expect(RemoteSessionDetailGates.content(capabilities: ["attach"], gone: true) == .unsupported)
    }

    // MARK: - showsStop(sessionExists:gone:snapshotFresh:)

    @Test func showsStopForAPresentLiveSessionWithAFreshSnapshot() {
        #expect(RemoteSessionDetailGates.showsStop(sessionExists: true, gone: false, snapshotFresh: true))
    }

    @Test func hidesStopWhenTheSessionIsNotInTheMirror() {
        #expect(!RemoteSessionDetailGates.showsStop(sessionExists: false, gone: false, snapshotFresh: true))
    }

    @Test func hidesStopWhenGone() {
        #expect(!RemoteSessionDetailGates.showsStop(sessionExists: true, gone: true, snapshotFresh: true))
    }

    @Test func hidesStopWhenTheSnapshotIsStale() {
        // Mutating a session from a stale inventory is unsafe; the context
        // menu withholds Stop under the same condition.
        #expect(!RemoteSessionDetailGates.showsStop(sessionExists: true, gone: false, snapshotFresh: false))
    }
}

/// Tier 1: pure state-to-copy mapping with no I/O, clock, or process.
@Suite("Remote session state presentation")
struct RemoteSessionStatePresentationTests {
    @Test func labelsDistinguishRunningTerminalFromUnavailableAgentState() {
        #expect(RemoteSessionStatePresentation.terminalLabel(.running) == "Terminal: Running")
        #expect(RemoteSessionStatePresentation.agentLabel(.unknown) == "Agent: State unavailable")
    }

    @Test func labelsPreserveKnownAgentActivity() {
        #expect(RemoteSessionStatePresentation.agentLabel(.working) == "Agent: Working")
        #expect(RemoteSessionStatePresentation.agentLabel(.idle) == "Agent: Idle")
        #expect(RemoteSessionStatePresentation.agentLabel(.waitingInput) == "Agent: Waiting for input")
        #expect(RemoteSessionStatePresentation.agentLabel(.exited) == "Agent: Exited")
    }

    @Test func terminalLabelsCoverEveryProcessState() {
        #expect(RemoteSessionStatePresentation.terminalLabel(.starting) == "Terminal: Starting")
        #expect(RemoteSessionStatePresentation.terminalLabel(.exited) == "Terminal: Exited")
        #expect(RemoteSessionStatePresentation.terminalLabel(.unknown) == "Terminal: State unavailable")
    }

    @Test func warningAppearsOnlyForPresentTerminalWithUnknownAgentState() {
        let expected = "Agent activity is unavailable; terminal liveness alone does not confirm agent health."
        #expect(RemoteSessionStatePresentation.activityUnavailableWarning(
            terminalState: .running, agentState: .unknown, gone: false) == expected)
        #expect(RemoteSessionStatePresentation.activityUnavailableWarning(
            terminalState: .running, agentState: .working, gone: false) == nil)
        #expect(RemoteSessionStatePresentation.activityUnavailableWarning(
            terminalState: .running, agentState: .idle, gone: false) == nil)
        #expect(RemoteSessionStatePresentation.activityUnavailableWarning(
            terminalState: .starting, agentState: .unknown, gone: false) == nil)
        #expect(RemoteSessionStatePresentation.activityUnavailableWarning(
            terminalState: .exited, agentState: .unknown, gone: false) == nil)
        #expect(RemoteSessionStatePresentation.activityUnavailableWarning(
            terminalState: .unknown, agentState: .unknown, gone: false) == nil)
        #expect(RemoteSessionStatePresentation.activityUnavailableWarning(
            terminalState: .running, agentState: .unknown, gone: true) == nil)
    }
}
