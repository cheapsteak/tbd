import Foundation
import Testing
@testable import TBDApp

/// Fix pass 1 (task-10 review finding 2): pure capability gates behind
/// `RemoteSessionDetailView` — `available`, `initialTab`, `showsPicker`,
/// `showsSendField`. One test per gate direction, per repo policy for
/// behavior-gating conditionals, including the exact `log`-only shape that
/// let finding 1 (permanently blank pane) through.
@Suite("Remote session detail — pure capability gates")
struct RemoteSessionDetailGatesTests {
    private typealias Tab = RemoteSessionDetailTab

    // MARK: - available(capabilities:gone:)

    @Test func availableIsEmptyForNoCapabilities() {
        #expect(RemoteSessionDetailGates.available(capabilities: [], gone: false) == [])
    }

    @Test func availableIsAttachOnlyWhenOnlyAttachDeclared() {
        #expect(RemoteSessionDetailGates.available(capabilities: ["attach"], gone: false) == [.attach])
    }

    @Test func availableIsLogOnlyWhenOnlyLogDeclared() {
        // Finding 1's exact shape: a `log`-only provider must not produce an
        // `availableTabs` list `initialTab`/the view can only render blank.
        #expect(RemoteSessionDetailGates.available(capabilities: ["log"], gone: false) == [.log])
    }

    @Test func availableIsAttachThenLogWhenBothDeclared() {
        #expect(RemoteSessionDetailGates.available(capabilities: ["log", "attach"], gone: false) == [.attach, .log])
    }

    @Test func availableIgnoresUnrecognizedCapabilityStrings() {
        #expect(RemoteSessionDetailGates.available(capabilities: ["events", "rename"], gone: false) == [])
    }

    @Test func availableDropsAttachWhenGoneEvenIfDeclared() {
        // Finding 7: consistent with `RemoteSessionActionMenu.items(gone:)`
        // collapsing Attach out of the context menu for a tombstone row.
        #expect(RemoteSessionDetailGates.available(capabilities: ["attach"], gone: true) == [])
    }

    @Test func availableKeepsLogWhenGone() {
        // Log stays available for a gone session — reading the last
        // scrollback is still useful even though the provider no longer
        // reports the session.
        #expect(RemoteSessionDetailGates.available(capabilities: ["log"], gone: true) == [.log])
    }

    @Test func availableDropsOnlyAttachWhenGoneWithBothCapabilities() {
        #expect(RemoteSessionDetailGates.available(capabilities: ["attach", "log"], gone: true) == [.log])
    }

    // MARK: - initialTab(available:requested:)

    @Test func initialTabPrefersRequestedWhenAvailable() {
        #expect(RemoteSessionDetailGates.initialTab(available: [.attach, .log], requested: .log) == .log)
    }

    @Test func initialTabFallsBackToFirstAvailableWhenRequestedIsAbsent() {
        // The core of finding 1: a `.attach`-placeholder request against a
        // `log`-only provider must resolve to `.log`, not nil/blank.
        #expect(RemoteSessionDetailGates.initialTab(available: [.log], requested: .attach) == .log)
    }

    @Test func initialTabFallsBackToFirstAvailableWhenRequestedIsNil() {
        #expect(RemoteSessionDetailGates.initialTab(available: [.attach, .log], requested: nil) == .attach)
    }

    @Test func initialTabIsNilWhenNothingIsAvailable() {
        #expect(RemoteSessionDetailGates.initialTab(available: [], requested: .attach) == nil)
        #expect(RemoteSessionDetailGates.initialTab(available: [], requested: nil) == nil)
    }

    // MARK: - showsPicker(available:)

    @Test func showsPickerIsFalseForZeroAvailableTabs() {
        #expect(RemoteSessionDetailGates.showsPicker(available: []) == false)
    }

    @Test func showsPickerIsFalseForExactlyOneAvailableTab() {
        // Finding 1's other half: a single available tab must render its
        // content unconditionally, which the view achieves by never gating
        // that content on the (suppressed) picker's selection.
        #expect(RemoteSessionDetailGates.showsPicker(available: [.log]) == false)
        #expect(RemoteSessionDetailGates.showsPicker(available: [.attach]) == false)
    }

    @Test func showsPickerIsTrueForTwoAvailableTabs() {
        #expect(RemoteSessionDetailGates.showsPicker(available: [.attach, .log]) == true)
    }

    // MARK: - showsSendField(capabilities:gone:)

    @Test func showsSendFieldIsTrueWhenSendDeclaredAndNotGone() {
        #expect(RemoteSessionDetailGates.showsSendField(capabilities: ["send"], gone: false) == true)
    }

    @Test func showsSendFieldIsFalseWhenSendNotDeclared() {
        #expect(RemoteSessionDetailGates.showsSendField(capabilities: [], gone: false) == false)
    }

    @Test func showsSendFieldIsFalseWhenGoneEvenIfSendDeclared() {
        // Finding 7: consistent with the context menu dropping Send Text…
        // for gone rows.
        #expect(RemoteSessionDetailGates.showsSendField(capabilities: ["send"], gone: true) == false)
    }

    @Test func showsSendFieldIsFalseForEmptyCapabilityProviderRegardlessOfGone() {
        #expect(RemoteSessionDetailGates.showsSendField(capabilities: [], gone: true) == false)
        #expect(RemoteSessionDetailGates.showsSendField(capabilities: [], gone: false) == false)
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
