import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// Pure capability gates behind `RemoteSessionDetailView` and the window
/// toolbar's remote-session buttons — `canAttach`, `content`,
/// `showsSendFooter`, `showsStop`.
/// One test per gate direction, per repo policy for behavior-gating
/// conditionals, including the `log`-only shape that once rendered a
/// permanently blank pane.
@Suite("Remote session detail — pure capability gates")
struct RemoteSessionDetailGatesTests {
    // MARK: - canAttach(capabilities:gone:exited:)

    @Test func canAttachWhenAttachDeclaredAndNotGone() {
        #expect(RemoteSessionDetailGates.canAttach(capabilities: ["attach"], gone: false, exited: false))
    }

    @Test func cannotAttachWithoutTheCapability() {
        #expect(!RemoteSessionDetailGates.canAttach(capabilities: [], gone: false, exited: false))
        #expect(!RemoteSessionDetailGates.canAttach(capabilities: ["log", "send"], gone: false, exited: false))
    }

    @Test func cannotAttachWhenGoneEvenIfDeclared() {
        // Consistent with `RemoteSessionActionMenu.items(gone:)` collapsing
        // Attach out of the context menu for a tombstone row.
        #expect(!RemoteSessionDetailGates.canAttach(capabilities: ["attach"], gone: true, exited: false))
    }

    @Test func cannotAttachWhenExitedEvenIfDeclared() {
        // The provider reports the process finished; a Reattach could only fail.
        #expect(!RemoteSessionDetailGates.canAttach(capabilities: ["attach"], gone: false, exited: true))
    }

    // MARK: - content(capabilities:gone:exited:)

    @Test func contentIsAttachWheneverAttachIsPossible() {
        #expect(RemoteSessionDetailGates.content(capabilities: ["attach"], gone: false, exited: false) == .attach)
        // The log never displaces a usable terminal — there is no picker.
        #expect(RemoteSessionDetailGates.content(
            capabilities: ["log", "attach"], gone: false, exited: false) == .attach)
    }

    @Test func contentFallsBackToLogWhenAttachIsNotDeclared() {
        // The shape that once rendered a blank pane: a `log`-only provider.
        #expect(RemoteSessionDetailGates.content(capabilities: ["log"], gone: false, exited: false) == .log)
    }

    @Test func contentFallsBackToLogWhenGone() {
        // A gone session can't attach, but its last scrollback is still
        // worth reading.
        #expect(RemoteSessionDetailGates.content(capabilities: ["attach", "log"], gone: true, exited: false) == .log)
    }

    @Test func contentFallsBackToLogWhenExited() {
        #expect(RemoteSessionDetailGates.content(capabilities: ["attach", "log"], gone: false, exited: true) == .log)
    }

    @Test func contentIsUnsupportedWithNeitherCapability() {
        #expect(RemoteSessionDetailGates.content(capabilities: [], gone: false, exited: false) == .unsupported)
        #expect(RemoteSessionDetailGates.content(
            capabilities: ["events", "rename"], gone: false, exited: false) == .unsupported)
        #expect(RemoteSessionDetailGates.content(capabilities: ["attach"], gone: true, exited: false) == .unsupported)
        #expect(RemoteSessionDetailGates.content(capabilities: ["attach"], gone: false, exited: true) == .unsupported)
    }

    // MARK: - showsSendFooter(capabilities:gone:snapshotFresh:hasLiveAttachedPane:)

    @Test func sendFooterShownWhenNoLiveTerminalIsAttached() {
        // No attach capability at all, the log fallback, and an attach
        // provider whose pane shows the Detached or auth prompt.
        for capabilities in [["send"], ["log", "send"], ["attach", "send"], ["attach", "log", "send"]] {
            #expect(RemoteSessionDetailGates.showsSendFooter(
                capabilities: capabilities, gone: false, snapshotFresh: true, hasLiveAttachedPane: false))
        }
    }

    @Test func sendFooterHiddenWhileALiveTerminalIsAttached() {
        // The attached terminal takes typing directly.
        #expect(!RemoteSessionDetailGates.showsSendFooter(
            capabilities: ["attach", "send"], gone: false, snapshotFresh: true, hasLiveAttachedPane: true))
        #expect(!RemoteSessionDetailGates.showsSendFooter(
            capabilities: ["attach", "log", "send"], gone: false, snapshotFresh: true, hasLiveAttachedPane: true))
    }

    @Test func sendFooterHiddenWithoutTheSendCapability() {
        #expect(!RemoteSessionDetailGates.showsSendFooter(
            capabilities: ["log"], gone: false, snapshotFresh: true, hasLiveAttachedPane: false))
        #expect(!RemoteSessionDetailGates.showsSendFooter(
            capabilities: [], gone: false, snapshotFresh: true, hasLiveAttachedPane: false))
    }

    @Test func sendFooterHiddenWhenGoneOrStale() {
        // A gone session has fallen back to the log even with attach
        // declared, but the provider no longer reports it; a stale snapshot
        // makes mutating a session unsafe.
        #expect(!RemoteSessionDetailGates.showsSendFooter(
            capabilities: ["attach", "log", "send"], gone: true, snapshotFresh: true, hasLiveAttachedPane: false))
        #expect(!RemoteSessionDetailGates.showsSendFooter(
            capabilities: ["log", "send"], gone: false, snapshotFresh: false, hasLiveAttachedPane: false))
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

    @Test func detachedFateLineSaysKeepsRunningOnlyForARunningOrStartingSession() {
        let running = "The session keeps running remotely."
        #expect(RemoteSessionStatePresentation.detachedFateLine(terminalState: .running) == running)
        #expect(RemoteSessionStatePresentation.detachedFateLine(terminalState: .starting) == running)
        #expect(RemoteSessionStatePresentation.detachedFateLine(terminalState: .exited)
            == "The remote session has exited.")
        let neutral = "The remote session is unaffected by detaching."
        #expect(RemoteSessionStatePresentation.detachedFateLine(terminalState: .unknown) == neutral)
        #expect(RemoteSessionStatePresentation.detachedFateLine(terminalState: nil) == neutral)
    }

    @Test func staleSnapshotNoteMentionsAttachOnlyWhenAttachIsAvailable() {
        #expect(RemoteSessionDetailView.staleSnapshotNote(attachAvailable: true)
            == "Attach remains available; changes are paused until inventory refresh recovers.")
        #expect(RemoteSessionDetailView.staleSnapshotNote(attachAvailable: false)
            == "Changes are paused until inventory refresh recovers.")
    }
}
