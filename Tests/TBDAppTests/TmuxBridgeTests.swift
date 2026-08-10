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
        #expect(TmuxBridge.windowIdentityQueryArgs(windowID: "@147") == [
            "display-message", "-p", "-t", "@147", "#{window_id}",
        ])
        #expect(TmuxBridge.killSessionArgs(sessionName: sessionName) == [
            "kill-session", "-t", sessionName,
        ])
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

    @Test func failedWindowStageWithMatchingProbeRemainsGeneric() {
        #expect(TmuxBridge.classifyPreparationFailure(
            stage: .linkWindow,
            output: "link failure",
            probeSucceeded: true,
            probeOutput: "@147",
            expectedWindowID: "@147"
        ) == .commandFailed(stage: .linkWindow, output: "link failure"))
    }

    @Test func failedWindowStageWithFailedProbeMeansWindowMissing() {
        #expect(TmuxBridge.classifyPreparationFailure(
            stage: .linkWindow,
            output: "link failure",
            probeSucceeded: false,
            probeOutput: "",
            expectedWindowID: "@147"
        ) == .windowMissing(failedStage: .linkWindow))
    }

    @Test func failedWindowStageWithMismatchedProbeRemainsGeneric() {
        #expect(TmuxBridge.classifyPreparationFailure(
            stage: .linkWindow,
            output: "link failure",
            probeSucceeded: true,
            probeOutput: "@999",
            expectedWindowID: "@147"
        ) == .commandFailed(stage: .linkWindow, output: "link failure"))
    }
}
