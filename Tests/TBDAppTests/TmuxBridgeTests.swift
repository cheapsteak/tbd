import Foundation
import Testing
@testable import TBDApp

@Suite("TmuxBridge")
struct TmuxBridgeTests {
    @Test func sessionNameUsesStablePanelIDPrefix() {
        let panelID = UUID(uuidString: "4C4F1A61-F385-46AB-861D-42A425DB427B")!

        #expect(TmuxBridge.sessionName(for: panelID) == "tbd-view-4c4f1a61")
    }

    @Test func isolatedSessionPlanLinksOnlyTargetWindow() {
        let sessionName = "tbd-view-4c4f1a61"

        #expect(TmuxBridge.newIsolatedSessionArgs(sessionName: sessionName) == [
            "new-session", "-d", "-s", sessionName, "-c", "/tmp",
        ])
        #expect(TmuxBridge.linkWindowArgs(windowID: "@147", sessionName: sessionName) == [
            "link-window", "-s", "@147", "-t", "\(sessionName):",
        ])
        #expect(TmuxBridge.killInitialWindowArgs(sessionName: sessionName) == [
            "kill-window", "-t", "\(sessionName):0",
        ])
        #expect(TmuxBridge.selectWindowArgs(windowID: "@147", sessionName: sessionName) == [
            "select-window", "-t", "\(sessionName):@147",
        ])
        #expect(TmuxBridge.remainOnExitArgs(windowID: "@147") == [
            "set-option", "-wt", "@147", "remain-on-exit", "on",
        ])
        #expect(TmuxBridge.remainOnExitFormatArgs(windowID: "@147") == [
            "set-option", "-wt", "@147", "remain-on-exit-format", "",
        ])
        #expect(TmuxBridge.activeWindowQueryArgs(sessionName: sessionName) == [
            "display-message", "-p", "-t", sessionName, "#{window_id}",
        ])
        #expect(TmuxBridge.viewerAttachCommand(
            server: "tbd-repo", sessionName: sessionName
        ) == [
            "tmux", "-u", "-L", "tbd-repo", "attach", "-t", sessionName,
        ])
        #expect(TmuxBridge.windowInventoryQueryArgs() == [
            "list-windows", "-a", "-F", "#{window_id}",
        ])
        #expect(TmuxBridge.clientSessionQueryArgs() == [
            "list-clients", "-F", "#{client_session}",
        ])
        #expect(TmuxBridge.killSessionArgs(sessionName: sessionName) == [
            "kill-session", "-t", sessionName,
        ])
    }

    @Test func clientInventoryConfirmsOnlyTheExpectedAttachedSession() {
        #expect(TmuxBridge.clientInventoryConfirmsAttachment(
            querySucceeded: true,
            output: "main\ntbd-view-4c4f1a61",
            expectedSessionName: "tbd-view-4c4f1a61"
        ))
        #expect(!TmuxBridge.clientInventoryConfirmsAttachment(
            querySucceeded: true,
            output: "main",
            expectedSessionName: "tbd-view-4c4f1a61"
        ))
        #expect(!TmuxBridge.clientInventoryConfirmsAttachment(
            querySucceeded: false,
            output: "tbd-view-4c4f1a61",
            expectedSessionName: "tbd-view-4c4f1a61"
        ))
    }

    @Test func preparedSessionCarriesViewerCommand() {
        let prepared = TmuxBridge.preparedSession(
            server: "tbd-repo",
            sessionName: "tbd-view-4c4f1a61"
        )
        #expect(prepared == TmuxPreparedSession(
            executablePath: "tmux",
            arguments: ["-u", "-L", "tbd-repo", "attach", "-t", "tbd-view-4c4f1a61"]
        ))
    }

    @Test func viewSessionCreationFailureIsGenericWithoutWindowProbe() {
        #expect(TmuxBridge.classifyPreparationFailure(
            stage: .createViewSession,
            output: "create failure",
            probeSucceeded: nil,
            probeOutput: nil,
            expectedWindowID: "@147"
        ) == .commandFailed(stage: .createViewSession, output: "create failure"))
    }

    @Test func failedWindowStageWithInventoryContainingWindowRemainsGeneric() {
        #expect(TmuxBridge.classifyPreparationFailure(
            stage: .linkWindow,
            output: "link failure",
            probeSucceeded: true,
            probeOutput: "@999\n@147",
            expectedWindowID: "@147"
        ) == .commandFailed(stage: .linkWindow, output: "link failure"))
    }

    @Test func failedWindowStageWithFailedInventoryProbeRemainsGeneric() {
        #expect(TmuxBridge.classifyPreparationFailure(
            stage: .linkWindow,
            output: "link failure",
            probeSucceeded: false,
            probeOutput: "",
            expectedWindowID: "@147"
        ) == .commandFailed(stage: .linkWindow, output: "link failure"))
    }

    @Test func failedWindowStageWithInventoryOmittingWindowMeansMissing() {
        #expect(TmuxBridge.classifyPreparationFailure(
            stage: .linkWindow,
            output: "link failure",
            probeSucceeded: true,
            probeOutput: "@999",
            expectedWindowID: "@147"
        ) == .windowMissing(failedStage: .linkWindow))
    }
}
