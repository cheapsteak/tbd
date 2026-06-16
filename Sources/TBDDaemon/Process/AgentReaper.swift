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

    /// Defense-in-depth ownership check before any signal: true when the process
    /// is a TBD-spawned agent (claude/codex) or carries a TBD spawn marker.
    ///
    /// `sweep`/`reapServerChildren` only ever see children of a known tbd-* server,
    /// so parentage already establishes ownership; this gate additionally avoids
    /// reaping a non-agent process a user detached inside a TBD shell pane (e.g.
    /// `nohup make`, `node script.js`). We recognize the agent binary by the last
    /// path component of argv[0] so a path merely containing "claude" won't match.
    func isTBDOwned(_ pid: Int32) -> Bool {
        isTBDOwned(commandLine: signaller.commandLine(pid))
    }

    /// Ownership check against an already-fetched command line, so callers that
    /// also need the command line (e.g. `sweep`'s log) can avoid a second `ps`.
    func isTBDOwned(commandLine cmd: String?) -> Bool {
        guard let cmd else { return false }
        if cmd.contains("claude-overlay.json") || cmd.contains("/TBD/plugin") { return true }
        return Self.isAgentBinary(cmd)
    }

    /// True if the command line's argv[0] basename is `claude` or `codex`.
    static func isAgentBinary(_ commandLine: String) -> Bool {
        guard let arg0 = commandLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return false
        }
        let basename = arg0.split(separator: "/").last.map(String.init) ?? String(arg0)
        return basename == "claude" || basename == "codex"
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

    /// Reap every structural orphan (gated by ownership) across the given servers.
    public func sweep(servers: [String]) async {
        for server in servers {
            for pid in await findStructuralOrphans(server: server) {
                // Fetch the command line once: used for both the ownership gate
                // and the log line below.
                let cmd = signaller.commandLine(pid)
                guard isTBDOwned(commandLine: cmd) else { continue }
                logger.info("reaper: sweeping orphan pid \(pid, privacy: .public) on \(server, privacy: .public) [\(cmd?.prefix(60) ?? "", privacy: .public)]")
                await reap(pid)
            }
        }
    }

    /// Reap the server's owned child processes before the server itself is
    /// killed, so they don't reparent to launchd and escape.
    public func reapServerChildren(server: String) async {
        guard let serverPID = await tmux.serverPID(server: server) else { return }
        for pid in signaller.children(ofServerPID: serverPID) where isTBDOwned(pid) {
            logger.info("reaper: reaping child pid \(pid, privacy: .public) before kill-server \(server, privacy: .public)")
            await reap(pid)
        }
    }
}
