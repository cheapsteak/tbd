import Foundation
import TBDShared
import Testing

@testable import TBDApp

/// Which daemon-side authority a panel's `pane.resize` names.
///
/// A holder row carries no tmux coordinates — `windowID` is the empty string —
/// so a resize keyed by window resolves nothing and is dropped without a word.
/// That is how a holder panel's `sizeChanged` came to reach the pty at all:
/// there was no arm here to address the session by name.
@Suite struct TerminalResizeTargetTests {

    private let worktree = UUID()
    private let terminal = UUID()

    @Test func aHolderPanelAddressesItsSessionByName() {
        let target = TerminalResizeTarget.resolve(
            holderPTYIsOwned: true,
            worktreeID: worktree,
            terminalID: terminal,
            controlMode: nil)
        #expect(target == .holderSession(worktreeID: worktree, terminalID: terminal))
    }

    @Test func aControlModePanelAddressesItsWindow() {
        let target = TerminalResizeTarget.resolve(
            holderPTYIsOwned: false,
            worktreeID: worktree,
            terminalID: terminal,
            controlMode: (worktreeID: worktree, windowID: "@7"))
        #expect(target == .controlModeWindow(worktreeID: worktree, windowID: "@7"))
    }

    /// A panel that is neither has nothing to tell the daemon: the local-PTY
    /// path already sized its own child, and a detached panel is not rendered.
    @Test func aPanelWithNeitherTransportAddressesNothing() {
        #expect(
            TerminalResizeTarget.resolve(
                holderPTYIsOwned: false, worktreeID: worktree, terminalID: terminal,
                controlMode: nil) == nil)
    }

    /// The panel is holder-backed but its row could not be resolved, so there
    /// is no worktree to send the resize under.
    @Test func aHolderPanelWithNoResolvableRowAddressesNothing() {
        #expect(
            TerminalResizeTarget.resolve(
                holderPTYIsOwned: true, worktreeID: nil, terminalID: terminal,
                controlMode: nil) == nil)
    }
}

/// `terminalID` is additive on a method an older app already calls, so the
/// params it sends — which carry no such field — must still decode. A required
/// field here would make every pane resize from a stale app a decode failure on
/// a daemon that had been updated.
@Suite struct PaneResizeParamsCompatibilityTests {

    @Test func paramsWithoutATerminalIDStillDecode() throws {
        let worktree = UUID()
        let json = """
            {"worktreeID":"\(worktree.uuidString)","windowID":"@3","cols":120,"rows":40}
            """
        let params = try JSONDecoder().decode(
            PaneResizeParams.self, from: Data(json.utf8))
        #expect(params.terminalID == nil)
        #expect(params.windowID == "@3")
        #expect(params.cols == 120)
        #expect(params.rows == 40)
    }

    @Test func aTerminalIDSurvivesTheRoundTrip() throws {
        let terminal = UUID()
        let sent = PaneResizeParams(
            worktreeID: UUID(), windowID: "", cols: 100, rows: 30, terminalID: terminal)
        let received = try JSONDecoder().decode(
            PaneResizeParams.self, from: JSONEncoder().encode(sent))
        #expect(received.terminalID == terminal)
        #expect(received.windowID.isEmpty)
    }
}
