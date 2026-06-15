import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "reaper")

/// The two tmux queries AgentReaper needs. TmuxManager conforms; tests inject a fake.
public protocol TmuxProcessQuerying: Sendable {
    func serverPID(server: String) async -> Int32?
    func livePanePIDs(server: String) async -> Set<Int32>
}

extension TmuxManager: TmuxProcessQuerying {}

public struct AgentReaper: Sendable {
    let tmux: TmuxProcessQuerying
    let signaller: ProcessSignaller
    /// Number of liveness polls before escalating / giving up.
    let graceAttempts: Int
    /// Delay between liveness polls.
    let pollInterval: Duration

    public init(
        tmux: TmuxProcessQuerying,
        signaller: ProcessSignaller,
        graceAttempts: Int = 30,
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.tmux = tmux
        self.signaller = signaller
        self.graceAttempts = graceAttempts
        self.pollInterval = pollInterval
    }

    /// Children of the server process that are not any live pane's pane_pid.
    /// Structural: no pane references them, so the UI cannot reach them.
    func findStructuralOrphans(server: String) async -> [Int32] {
        guard let serverPID = await tmux.serverPID(server: server) else { return [] }
        let children = Set(signaller.children(ofServerPID: serverPID))
        let panes = await tmux.livePanePIDs(server: server)
        return Array(children.subtracting(panes))
    }

    /// Defense-in-depth ownership check before any signal.
    func isTBDOwned(_ pid: Int32) -> Bool {
        guard let cmd = signaller.commandLine(pid) else { return false }
        return cmd.contains("claude-overlay.json") || cmd.contains("/TBD/plugin")
    }
}
