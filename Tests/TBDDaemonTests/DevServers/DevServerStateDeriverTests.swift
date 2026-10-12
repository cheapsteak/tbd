import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Dev server state derivation")
struct DevServerStateDeriverTests {
    private let web = DeclaredDevServer(name: "web", command: "pnpm dev", label: "Web app", source: .repoTOML)
    private func tab(_ status: DevServerTabStatus) -> DevServerTabObservation {
        var t = Terminal(worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1")
        t.serverName = "web"
        return DevServerTabObservation(terminal: t, status: status)
    }
    private func file(_ server: String = "web") -> DevServerRunningFileEntry {
        DevServerRunningFileEntry(path: "/x/\(server).json", file: DevServerRunningFile(
            root: "/tmp/acme/w", server: server,
            endpoints: [DevServerEndpoint(name: "app", url: "http://localhost:3000")],
            pid: 900, startTime: 1), modifiedAt: nil)
    }
    private func derive(files: [DevServerRunningFileEntry] = [], tab t: DevServerTabObservation? = nil,
                        check: DevServerStatusCheck = .notRun,
                        saved: TerminalHistoryEntry? = nil) -> DevServerInfo? {
        DevServerStateDeriver.derive(DevServerDerivationInput(
            declared: [web], liveFiles: files, tabs: t.map { ["web": $0] } ?? [:],
            statusChecks: ["web": check], lastOutputs: saved.map { ["web": $0] } ?? [:])).first
    }
    private func savedOutput(id: UUID = UUID(), code: Int32?) -> TerminalHistoryEntry {
        TerminalHistoryEntry(id: id, worktreeID: UUID(), label: "Web app", kind: .shell,
                             lineCount: 1, serverName: "web", exitCode: code)
    }

    @Test func aLiveFileIsRunningWithURLs() {
        let info = derive(files: [file()], tab: tab(.exited(code: 1)))
        #expect(info?.state == .running)
        #expect(info?.mainURL == "http://localhost:3000")
        #expect(info?.pid == 900)
    }

    @Test func aRunningTabIsRunningWithoutURLs() {
        let info = derive(tab: tab(.running(pid: 42, expectedStart: nil)))
        #expect(info?.state == .running)
        #expect(info?.endpoints.isEmpty == true)
        #expect(info?.pid == 42)
    }

    @Test func aStatusExitZeroIsRunningEvenWhenTheTabExited() {
        #expect(derive(tab: tab(.exited(code: 1)), check: .running)?.state == .running)
    }

    /// Review Focus 3.
    @Test func anExitedTabWithACodeReadsExited() {
        let info = derive(tab: tab(.exited(code: 127)))
        #expect(info?.state == .exited)
        #expect(info?.exitCode == 127)
        #expect(info?.terminalID != nil)
    }

    /// D2: an ended holder tab reads no code from the transport after a
    /// restart; its own saved output supplies the code and the entry.
    @Test func anExitedTabTakesItsCodeAndOutputFromItsOwnSavedEntry() {
        let t = tab(.exited(code: nil))
        let info = derive(tab: t, saved: savedOutput(id: t.terminal.id, code: 3))
        #expect(info?.state == .exited)
        #expect(info?.exitCode == 3)
        #expect(info?.lastOutputID == t.terminal.id)
    }

    @Test func anEntryFromAnotherTabIsNotThisExitsOutput() {
        let info = derive(tab: tab(.exited(code: 1)), saved: savedOutput(code: 9))
        #expect(info?.exitCode == 1)
        #expect(info?.lastOutputID == nil)
    }

    /// D2: reconcile removed the ended holder tab; the saved entry alone
    /// still says the server exited.
    @Test func aSavedOutputAloneReadsExitedOnceTheTabIsGone() {
        let entryID = UUID()
        let info = derive(saved: savedOutput(id: entryID, code: 137))
        #expect(info?.state == .exited)
        #expect(info?.exitCode == 137)
        #expect(info?.lastOutputID == entryID)
        #expect(info?.terminalID == nil)
    }

    @Test func aRunningTabOutranksASavedOutput() {
        let info = derive(tab: tab(.running(pid: 42, expectedStart: nil)), saved: savedOutput(code: 1))
        #expect(info?.state == .running)
        #expect(info?.lastOutputID == nil)
    }

    @Test func aSavedOutputOutranksATimedOutStatus() {
        #expect(derive(check: .timedOut, saved: savedOutput(code: 1))?.state == .exited)
    }

    @Test func exitedOutranksATimedOutStatus() {
        #expect(derive(tab: tab(.exited(code: 1)), check: .timedOut)?.state == .exited)
    }

    @Test func aTimedOutStatusAloneIsUnknown() {
        #expect(derive(check: .timedOut)?.state == .unknown)
    }

    @Test func nothingAtAllIsStopped() {
        let info = derive(check: .notRunning)
        #expect(info?.state == .stopped)
        #expect(info?.label == "Web app")
        #expect(info?.source == "tbd.toml")
    }

    @Test func aFileForAnUndeclaredServerIsListedAsUndeclared() {
        let all = DevServerStateDeriver.derive(DevServerDerivationInput(
            declared: [web], liveFiles: [file("storybook")], tabs: [:], statusChecks: [:]))
        #expect(all.map(\.name) == ["web", "storybook"])
        #expect(all.last?.source == nil)
        #expect(all.last?.state == .running)
    }
}
