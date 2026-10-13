import Foundation
import TBDShared

/// What a server's declared `status` command said this time.
enum DevServerStatusCheck: Sendable, Equatable {
    case notRun
    case running
    case notRunning
    case timedOut
}

struct DevServerDerivationInput: Sendable {
    let declared: [DeclaredDevServer]
    /// Live running files already attributed to this worktree.
    let liveFiles: [DevServerRunningFileEntry]
    /// The newest non-gone server tab per server name.
    let tabs: [String: DevServerTabObservation]
    let statusChecks: [String: DevServerStatusCheck]
    /// The newest saved last output still attached to each server. Defaulted
    /// so a caller with no history store passes nothing.
    var lastOutputs: [String: TerminalHistoryEntry] = [:]
    /// TBD's tab rows for the worktree could not be read, so `tabs` is empty
    /// for want of an answer rather than because no tab exists.
    var tabsUnreadable = false
    /// Running files attributed to this worktree whose process could not be
    /// read: the server may still run, so it reads *Unknown*, never Stopped.
    var unprobedFiles: [DevServerRunningFileEntry] = []
}

/// The spec's state order: running with URLs (live running file) → running
/// (`status` exit 0, or TBD's tab still running the command) → exited (TBD's
/// tab ended, or — once the tab is gone — a saved last output) → unknown
/// (TBD's tab could not be read, the worktree's tab rows could not be read,
/// a running file's process could not be read, or `status` timed out) →
/// stopped. A server
/// with no declaration is listed when a live running file reports it or TBD
/// still has its tab.
enum DevServerStateDeriver {
    static func derive(_ input: DevServerDerivationInput) -> [DevServerInfo] {
        let declaredNames = Set(input.declared.map(\.name))
        var result = input.declared.map { server in
            info(name: server.name, label: server.displayLabel, source: server.source.rawValue,
                 hasStopCommand: server.stop != nil, hasStatusCommand: server.status != nil, input: input)
        }
        // Undeclared: a live running file names it, or TBD started it and its
        // declaration has since gone — its tab still runs (or ran) the
        // command, so it stays listed and stoppable like any other.
        let reported = Set(input.liveFiles.map(\.file.server))
            .union(input.unprobedFiles.map(\.file.server))
            .union(input.tabs.keys)
        let undeclared = reported.subtracting(declaredNames).sorted()
        for name in undeclared {
            result.append(info(name: name, label: name, source: nil, hasStopCommand: false,
                               hasStatusCommand: false, input: input))
        }
        return result
    }

    private static func info(
        name: String, label: String, source: String?, hasStopCommand: Bool, hasStatusCommand: Bool,
        input: DevServerDerivationInput
    ) -> DevServerInfo {
        let file = input.liveFiles.filter { $0.file.server == name }.sorted { $0.path < $1.path }.first
        let tab = input.tabs[name]
        let check = input.statusChecks[name] ?? .notRun
        let saved = input.lastOutputs[name]
        var state = DevServerStateKind.stopped
        var exitCode: Int32?
        var pid: Int32?
        var endpoints: [DevServerEndpoint] = []
        var lastOutputID: UUID?
        var fromStatus = false
        if let file {
            state = .running
            endpoints = file.file.endpoints
            pid = file.file.pid
        } else if check == .running {
            state = .running
            fromStatus = true
        } else if let tabPID = tab?.status.runningPID {
            state = .running
            pid = tabPID
        } else if case .exited(let code, _)? = tab?.status {
            state = .exited
            // The tab's own saved output only: an entry from an earlier tab
            // is not this exit's.
            let own = saved?.id == tab?.terminal.id ? saved : nil
            exitCode = code ?? own?.exitCode
            lastOutputID = own?.id
        } else if case .unknown? = tab?.status {
            // TBD's tab could not be read: its command may still run.
            state = .unknown
        } else if input.tabsUnreadable {
            // No tab row could be read, so a tab may still run the command:
            // neither Stopped nor an Exited taken from a saved output.
            state = .unknown
        } else if input.unprobedFiles.contains(where: { $0.file.server == name }) {
            // A running file names a process that could not be read: it may
            // still run.
            state = .unknown
        } else if tab == nil, let saved {
            // An ended holder tab's row does not outlive reconcile; its saved
            // output is then the record of the exit.
            state = .exited
            exitCode = saved.exitCode
            lastOutputID = saved.id
        } else if check == .timedOut {
            state = .unknown
            fromStatus = true
        }
        if pid == nil, let tabPID = tab?.status.runningPID { pid = tabPID }
        // Reported whatever decided `state`, so the app can tell the ended
        // tab a `status` answer was given over from a later run of it.
        var exitedTab: DevServerExitedTab?
        if let tab, case .exited(_, let tabPID) = tab.status {
            exitedTab = DevServerExitedTab(terminalID: tab.terminal.id, pid: tabPID)
        } else if tab == nil, let saved {
            exitedTab = DevServerExitedTab(terminalID: saved.id, pid: nil)
        }
        return DevServerInfo(
            name: name, label: label, source: source, state: state, exitCode: exitCode,
            endpoints: endpoints, terminalID: tab?.terminal.id, pid: pid, hasStopCommand: hasStopCommand,
            lastOutputID: lastOutputID, stateFromStatusCommand: fromStatus ? true : nil,
            hasStatusCommand: hasStatusCommand, exitedTab: exitedTab)
    }
}
