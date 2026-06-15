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

    /// SIGTERM → poll for `graceAttempts × pollInterval` → SIGKILL if still alive.
    /// Used by the sweep (no prior SIGHUP) and by `escalateAfterHangup`.
    func reap(_ pid: Int32) async {
        signaller.terminate(pid)
        for _ in 0..<graceAttempts {
            if !signaller.isAlive(pid) { return }
            try? await Task.sleep(for: pollInterval)
        }
        if signaller.isAlive(pid) {
            logger.warning("reaper: pid \(pid, privacy: .public) survived SIGTERM — sending SIGKILL")
            signaller.forceKill(pid)
        }
    }

    /// Called right after `kill-window` (which already sent SIGHUP). A healthy
    /// agent exits within the grace window — only a wedged one survives, and is
    /// then escalated. No-op if the pid is already gone.
    func escalateAfterHangup(_ pid: Int32) async {
        for _ in 0..<graceAttempts {
            if !signaller.isAlive(pid) { return }
            try? await Task.sleep(for: pollInterval)
        }
        guard signaller.isAlive(pid) else { return }
        logger.warning("reaper: agent pid \(pid, privacy: .public) survived kill-window SIGHUP — escalating")
        await reap(pid)
    }
}
