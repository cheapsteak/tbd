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
    }
}
