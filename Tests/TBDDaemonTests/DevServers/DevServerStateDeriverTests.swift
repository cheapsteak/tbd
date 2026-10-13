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

    /// A tab that could not be read may still run its command: Unknown,
    /// never Stopped — even when the `status` command says not running.
    @Test func anUnreadableTabReadsUnknown() {
        #expect(derive(tab: tab(.unknown(reason: "timed out")))?.state == .unknown)
        #expect(derive(tab: tab(.unknown(reason: "timed out")), check: .notRunning)?.state == .unknown)
        #expect(derive(files: [file()], tab: tab(.unknown(reason: "timed out")))?.state == .running)
    }

    /// The worktree's tab rows could not be read, so a tab may still run the
    /// command: Unknown, never Stopped or a saved Exited — unless a live file
    /// or the `status` command says running.
    @Test func unreadableTabRowsReadUnknown() {
        func deriveUnread(files: [DevServerRunningFileEntry] = [], check: DevServerStatusCheck = .notRun,
                    saved: TerminalHistoryEntry? = nil, unreadable: Bool) -> DevServerInfo? {
            DevServerStateDeriver.derive(DevServerDerivationInput(
                declared: [web], liveFiles: files, tabs: [:], statusChecks: ["web": check],
                lastOutputs: saved.map { ["web": $0] } ?? [:], tabsUnreadable: unreadable)).first
        }
        #expect(deriveUnread(unreadable: true)?.state == .unknown)
        #expect(deriveUnread(unreadable: false)?.state == .stopped)
        #expect(deriveUnread(saved: savedOutput(code: 0), unreadable: true)?.state == .unknown)
        #expect(deriveUnread(saved: savedOutput(code: 0), unreadable: false)?.state == .exited)
        #expect(deriveUnread(files: [file()], unreadable: true)?.state == .running)
        #expect(deriveUnread(check: .running, unreadable: true)?.state == .running)
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

    /// The app remembers a state only when the `status` command decided it,
    /// so the field must be set exactly then.
    @Test func theStatusCommandIsNamedOnlyWhenItDecidedTheState() {
        #expect(derive(check: .running)?.stateFromStatusCommand == true)
        #expect(derive(tab: tab(.exited(code: 0)), check: .running)?.stateFromStatusCommand == true)
        #expect(derive(check: .timedOut)?.stateFromStatusCommand == true)
        // Something ranked above the status command decided it.
        #expect(derive(files: [file()], check: .running)?.stateFromStatusCommand != true)
        #expect(derive(tab: tab(.exited(code: 1)), check: .timedOut)?.stateFromStatusCommand != true)
        let runningTab = derive(tab: tab(.running(pid: 42, expectedStart: nil)), check: .timedOut)
        #expect(runningTab?.stateFromStatusCommand != true)
        // Not run, or said not running.
        #expect(derive()?.stateFromStatusCommand != true)
        #expect(derive(check: .notRunning)?.stateFromStatusCommand != true)
        #expect(derive(tab: tab(.running(pid: 42, expectedStart: nil)))?.stateFromStatusCommand != true)
    }

    /// The ended tab is reported whatever decided the state, with the pid
    /// that ended, so the app can tell the tab a `status` answer was given
    /// over from a later run of the same tab.
    @Test func anEndedTabIsReportedWhateverDecidedTheState() {
        let t = tab(.exited(code: 0, pid: 700))
        let expected = DevServerExitedTab(terminalID: t.terminal.id, pid: 700)
        #expect(derive(tab: t, check: .running)?.exitedTab == expected)
        #expect(derive(tab: t)?.exitedTab == expected)
        #expect(derive(tab: tab(.running(pid: 42, expectedStart: nil)), check: .running)?.exitedTab == nil)
        #expect(derive(check: .running)?.exitedTab == nil)
        // Once the tab's row is gone, its saved output names it.
        let entryID = UUID()
        #expect(derive(check: .running, saved: savedOutput(id: entryID, code: 0))?.exitedTab
            == DevServerExitedTab(terminalID: entryID, pid: nil))
    }

    @Test func aServerSaysWhetherItDeclaresAStatusCommand() {
        let db = DeclaredDevServer(name: "db", command: "docker compose up -d db",
                                   status: "docker compose ps db", source: .repoTOML)
        let all = DevServerStateDeriver.derive(DevServerDerivationInput(
            declared: [web, db], liveFiles: [file("storybook")], tabs: [:], statusChecks: [:]))
        #expect(all.map(\.name) == ["web", "db", "storybook"])
        #expect(all.map(\.hasStatusCommand) == [false, true, false])
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

    /// TBD started it, then its declaration went away: its tab still runs
    /// the command, so it is listed — undeclared, with the tab's state.
    @Test func aServerTabWhoseDeclarationIsGoneIsListedAsUndeclared() {
        var t = Terminal(worktreeID: UUID(), tmuxWindowID: "@2", tmuxPaneID: "%2")
        t.serverName = "old"
        let all = DevServerStateDeriver.derive(DevServerDerivationInput(
            declared: [web], liveFiles: [],
            tabs: ["old": DevServerTabObservation(terminal: t, status: .running(pid: 77, expectedStart: nil))],
            statusChecks: [:]))
        let names: [String] = all.map { $0.name }
        #expect(names == ["web", "old"])
        let old = all.last
        #expect(old?.source == nil)
        #expect(old?.state == .running)
        #expect(old?.pid == 77)
        #expect(old?.terminalID == t.id)
        #expect(old?.hasStopCommand == false)
    }
}
