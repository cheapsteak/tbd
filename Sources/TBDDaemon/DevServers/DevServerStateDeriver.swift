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
}

/// The spec's state order: running with URLs (live running file) → running
/// (`status` exit 0, or TBD's tab still running the command) → exited (TBD's
/// tab ended, or — once the tab is gone — a saved last output) → unknown
/// (`status` timed out) → stopped.
enum DevServerStateDeriver {
    static func derive(_ input: DevServerDerivationInput) -> [DevServerInfo] {
        let declaredNames = Set(input.declared.map(\.name))
        var result = input.declared.map { server in
            info(name: server.name, label: server.displayLabel, source: server.source.rawValue,
                 hasStopCommand: server.stop != nil, input: input)
        }
        let undeclared = Set(input.liveFiles.map(\.file.server)).subtracting(declaredNames).sorted()
        for name in undeclared {
            result.append(info(name: name, label: name, source: nil, hasStopCommand: false, input: input))
        }
        return result
    }

    private static func info(
        name: String, label: String, source: String?, hasStopCommand: Bool,
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
        if let file {
            state = .running
            endpoints = file.file.endpoints
            pid = file.file.pid
        } else if check == .running {
            state = .running
        } else if case .running(let tabPID, _)? = tab?.status {
            state = .running
            pid = tabPID
        } else if case .exited(let code)? = tab?.status {
            state = .exited
            // The tab's own saved output only: an entry from an earlier tab
            // is not this exit's.
            let own = saved?.id == tab?.terminal.id ? saved : nil
            exitCode = code ?? own?.exitCode
            lastOutputID = own?.id
        } else if tab == nil, let saved {
            // An ended holder tab's row does not outlive reconcile; its saved
            // output is then the record of the exit.
            state = .exited
            exitCode = saved.exitCode
            lastOutputID = saved.id
        } else if check == .timedOut {
            state = .unknown
        }
        if pid == nil, case .running(let tabPID, _)? = tab?.status { pid = tabPID }
        return DevServerInfo(
            name: name, label: label, source: source, state: state, exitCode: exitCode,
            endpoints: endpoints, terminalID: tab?.terminal.id, pid: pid, hasStopCommand: hasStopCommand,
            lastOutputID: lastOutputID)
    }
}
