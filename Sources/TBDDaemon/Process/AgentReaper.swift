import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "reaper")

/// The two tmux queries AgentReaper needs. TmuxManager conforms; tests inject a fake.
public protocol TmuxProcessQuerying: Sendable {
    func serverPID(server: String) async -> Int32?
    func livePanePIDs(server: String) async -> Set<Int32>
}

extension TmuxManager: TmuxProcessQuerying {}

/// One holder-transport session, reduced to what the reaper's holder leg needs
/// to decide whether its job is an orphan.
///
/// Deliberately not a `Terminal`: the leg reads four facts and must not be able
/// to reach for a fifth, and a narrow record is what lets a test state a case
/// in one line.
public struct HolderChildRecord: Sendable, Equatable {
    /// The session the pids belong to. Logged, never signalled.
    public var terminalID: UUID
    /// The `TBDHolder` that owns the pty master, as recorded on the row.
    /// Nil on a row whose holder was never recorded — a session still being
    /// established, which the leg leaves alone.
    public var holderPID: Int32?
    /// The job the holder `forkpty`'d, as recorded on the row.
    public var childPID: Int32
    /// When the session row was written. The anchor for the start-time half of
    /// the identity check — see `decideHolderChild`.
    public var createdAt: Date

    public init(terminalID: UUID, holderPID: Int32?, childPID: Int32, createdAt: Date) {
        self.terminalID = terminalID
        self.holderPID = holderPID
        self.childPID = childPID
        self.createdAt = createdAt
    }
}

/// What the holder leg decided about one recorded child pid.
///
/// Every `keep` carries the reason it kept, because the whole risk in this leg
/// is a kill nobody can explain afterwards, and a soak needs to read what the
/// sweep declined to touch as easily as what it reaped.
public enum HolderChildDecision: Sendable, Equatable {
    case keep(reason: String)
    case reap
}

public struct AgentReaper: Sendable {
    let tmux: TmuxProcessQuerying
    let signaller: ProcessSignaller
    /// Number of liveness polls before escalating / giving up.
    let graceAttempts: Int
    /// Delay between liveness polls.
    let pollInterval: Duration
    /// The holder-transport sessions to sweep, with their recorded pids.
    /// Injected as a closure so the reaper stays a database-free value type —
    /// the same division of labor `HolderRendezvousCollector` keeps with
    /// `OrphanGC`. Defaulted to empty so every existing call site and test is
    /// unchanged by the leg's arrival.
    let holderSessions: @Sendable () async -> [HolderChildRecord]
    /// How far a child's start time may sit from its session row's `createdAt`
    /// and still be believed to be that session's job.
    let holderIdentityWindow: TimeInterval

    public init(
        tmux: TmuxProcessQuerying,
        signaller: ProcessSignaller,
        graceAttempts: Int = 30,
        pollInterval: Duration = .milliseconds(100),
        holderSessions: @escaping @Sendable () async -> [HolderChildRecord] = { [] },
        holderIdentityWindow: TimeInterval = AgentReaper.defaultHolderIdentityWindow
    ) {
        self.tmux = tmux
        self.signaller = signaller
        self.graceAttempts = graceAttempts
        self.pollInterval = pollInterval
        self.holderSessions = holderSessions
        self.holderIdentityWindow = holderIdentityWindow
    }

    /// Five minutes, and the number is doing real work.
    ///
    /// A holder's job is forked within milliseconds of its session row being
    /// written — today the holder is spawned just *before* the row, and the
    /// design's creation ordering puts it just after, so the window is
    /// symmetric around `createdAt` to cover both. Five minutes is therefore
    /// enormously generous for the true child and still excludes pid reuse:
    /// wrapping macOS's pid space inside the window would take on the order of
    /// hundreds of process spawns per second sustained, which is orders of
    /// magnitude past what this machine does with ~1000 agent processes live.
    public static let defaultHolderIdentityWindow: TimeInterval = 300

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
            // swiftlint:disable:next no_raw_task_sleep - already seamed: `graceAttempts` / `pollInterval` are injected `init` parameters (and `WorktreeLifecycle` re-exposes both as `reaperGraceAttempts` / `reaperPollInterval`), exercised by Tests/TBDDaemonTests/Process/AgentReaperTests.swift at .milliseconds(1); see docs/specs/2026-07-24-test-hardening-design.md
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
            // swiftlint:disable:next no_raw_task_sleep - already seamed: `graceAttempts` / `pollInterval` are injected `init` parameters (and `WorktreeLifecycle` re-exposes both as `reaperGraceAttempts` / `reaperPollInterval`), exercised by Tests/TBDDaemonTests/Process/AgentReaperTests.swift at .milliseconds(1); see docs/specs/2026-07-24-test-hardening-design.md
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

    // MARK: - Holder transport

    /// Executable basenames a holder's job can legitimately present.
    ///
    /// The holder always forks `$SHELL <flags> <command>`
    /// (`WorktreeLifecycle.holderLaunch` → `TmuxManager.shellInvocation`), and
    /// a shell running a single simple command with `-c` is free to `exec` it
    /// rather than fork — so by the time a sweep looks, the pid presents either
    /// the login shell or the agent binary the shell replaced itself with.
    /// Both are accepted; anything else is a stranger.
    static let holderChildShellBasenames: Set<String> = [
        "zsh", "bash", "sh", "dash", "ksh", "fish", "tcsh", "csh",
    ]

    /// The executable half of the identity check: does this pid present a
    /// command a holder's job could have?
    ///
    /// It is a **membership** test rather than equality against a value
    /// recorded at spawn, and that is forced by the `exec` above: a string
    /// captured when the child was born names the login shell, and matching it
    /// later would reject every session whose shell handed itself to `claude` —
    /// which is nearly all of them. The anti-pid-reuse work is done by the
    /// start time, which `exec` does not move; this narrows what a colliding
    /// pid could be on top of that.
    static func isHolderChildExecutable(_ commandLine: String) -> Bool {
        if isAgentBinary(commandLine) { return true }
        guard let arg0 = commandLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return false
        }
        let basename = arg0.split(separator: "/").last.map(String.init) ?? String(arg0)
        return holderChildShellBasenames.contains(basename)
    }

    /// Whether one holder session's recorded child pid is an orphan this sweep
    /// may kill — and when it is not, why not.
    ///
    /// Every gate fails toward keeping, because the two mistakes are not
    /// symmetric: a missed orphan is one leaked process a later sweep can still
    /// find, while a wrong kill destroys a stranger's work on a machine running
    /// ~40 worktrees and ~1000 agent processes. **"We are not certain this is
    /// the same process" is spelled `.keep` throughout.**
    ///
    /// The order of the gates is the argument:
    ///
    /// 1. `childPID > 1`. A `0` reaching a signal would hit the daemon's own
    ///    process group — the hazard `HolderRegistry.jobProcessGroup` guards
    ///    against in the same words — and `1` is launchd.
    /// 2. **A live holder ends it.** The holder exits when its child does, so a
    ///    holder that is still running means a session that is still running,
    ///    and nothing under it is an orphan. A row that never recorded a holder
    ///    pid is a session still being established, and is kept for the same
    ///    reason the reconcilers are keep-biased for young resources.
    /// 3. **A pid naming nothing is not killed blindly.** `isAlive` false means
    ///    there is nothing to reap, and the recorded number must never become a
    ///    signal target on the strength of the row alone.
    /// 4. **Identity.** The process now holding the pid must have started
    ///    within `holderIdentityWindow` of the row's `createdAt`, and must
    ///    present an executable a holder's job could have. An unreadable start
    ///    time or command line is an uncertain identity and keeps.
    func decideHolderChild(_ record: HolderChildRecord) -> HolderChildDecision {
        guard record.childPID > 1 else { return .keep(reason: "invalid-child-pid") }
        guard let holderPID = record.holderPID, holderPID > 1 else {
            return .keep(reason: "holder-unrecorded")
        }
        guard !signaller.isAlive(holderPID) else { return .keep(reason: "holder-alive") }
        guard signaller.isAlive(record.childPID) else { return .keep(reason: "child-gone") }
        guard let started = signaller.startTime(record.childPID) else {
            return .keep(reason: "start-time-unreadable")
        }
        guard abs(started.timeIntervalSince(record.createdAt)) <= holderIdentityWindow else {
            return .keep(reason: "start-time-mismatch")
        }
        // Empty counts as unreadable, not as a foreign command. `ps` prints
        // nothing at all for a pid that vanished between the liveness check
        // above and this call, and the production reader trims that to "" —
        // reporting it as a stranger's executable would name the wrong reason
        // for the right decision.
        guard let cmd = signaller.commandLine(record.childPID), !cmd.isEmpty else {
            return .keep(reason: "command-unreadable")
        }
        guard Self.isHolderChildExecutable(cmd) else { return .keep(reason: "foreign-executable") }
        return .reap
    }

    /// The holder-transport leg of the sweep
    /// (`docs/specs/2026-08-30-pty-holder-session-transport-design.md`,
    /// "Reconciliation").
    ///
    /// `sweep` above walks the children of tmux server pids, and a holder's job
    /// is not one: when the holder dies the job re-parents to launchd, so no
    /// enumeration rooted at a tmux server can ever reach it. This leg walks
    /// the other way — from each holder session's **recorded child pid** — and
    /// so is the only thing that can see a job the daemon was down for.
    ///
    /// It is the **backstop**, not the prompt path: a holder death observed by
    /// a running daemon is handled by the daemon's own holder-connection watch,
    /// and this sweep exists for the deaths nobody was watching.
    ///
    /// **Scope: rows that still exist.** A row deleted while the daemon was
    /// down took its recorded child pid with it, so a row-less holder's job is
    /// unreachable from here by construction; that case is the
    /// holder-versus-database check the design gives to `OrphanGC`, which
    /// recovers the pid from the holder's own handshake. This leg covers the
    /// half the database can still name.
    ///
    /// Gated: `enabled` is `Config.reapHolderChildrenEnabled`, read by the
    /// caller once per sweep. Off, this walks nothing and signals nothing —
    /// deliberately not even enumerating, so a disabled flag costs no `ps`.
    public func sweepHolderChildren(enabled: Bool) async {
        guard enabled else { return }
        for record in await holderSessions() {
            switch decideHolderChild(record) {
            case .keep(let reason):
                logger.debug("""
                reaper: keep \(reason, privacy: .public) holder child \
                \(record.childPID, privacy: .public) \
                (session \(record.terminalID.uuidString, privacy: .public))
                """)
            case .reap:
                logger.info("""
                reaper: reaping orphaned holder child \(record.childPID, privacy: .public) \
                (session \(record.terminalID.uuidString, privacy: .public), \
                holder \(record.holderPID ?? 0, privacy: .public) gone)
                """)
                await reapVerified(record)
            }
        }
    }

    /// SIGTERM → poll → SIGKILL, re-proving identity before the escalation.
    ///
    /// The re-check is not paranoia about the first one. `reap`'s grace window
    /// is seconds long by design, the job usually dies inside it, and a pid
    /// freed at the start of that window can be handed to something new before
    /// the end of it — at which point the unconditional `forceKill` would land
    /// on a stranger. Re-deciding means the escalation is aimed at a process
    /// that is still, right now, the one the sweep chose.
    ///
    /// **Both signals deliberately take the group-widening door, not the
    /// pid-exact one**, and the choice is the opposite of what it looks like
    /// from `ProcessSignaller` alone. The job is a session and process-group
    /// leader (`setsid` then `forkpty` in the holder), so `signal` widens to
    /// `kill(-pid, …)` — which is the point: the thing being reclaimed is an
    /// orphaned job *and its descendants*. A job that ignores SIGHUP while
    /// holding `/dev/null` on its stdio survives a pid-exact kill; that was
    /// measured, and it is why teardown moved to a group kill in `c12c0386`.
    /// Reaping pid-exact here would leave behind exactly what this leg exists
    /// to collect.
    ///
    /// The pid-reuse worry that argues for the pid-exact door is real but is
    /// answered elsewhere and only narrowed, never closed, by that door: if a
    /// stranger has inherited the number, `kill(pid, …)` lands on the stranger
    /// just as surely as `kill(-pid, …)` lands on its group. What actually
    /// protects the escalation is the re-decision below, and the widening is
    /// itself conditional on `getpgid(pid) == pid`, so a reused pid that is not
    /// a group leader degrades to pid-exact on its own.
    private func reapVerified(_ record: HolderChildRecord) async {
        let pid = record.childPID
        // Fresh by construction: the caller signalled `.reap` from
        // `decideHolderChild` immediately before calling in, so this SIGTERM is
        // aimed at a decision that is as current as one can be. Only the
        // escalation, which waits out the grace window, needs re-deciding.
        signaller.terminate(pid)
        for _ in 0..<graceAttempts {
            if !signaller.isAlive(pid) { return }
            // swiftlint:disable:next no_raw_task_sleep - already seamed: `graceAttempts` / `pollInterval` are injected `init` parameters, exercised at .milliseconds(1) by Tests/TBDDaemonTests/Process/AgentReaperHolderLegTests.swift; see docs/specs/2026-07-24-test-hardening-design.md
            try? await Task.sleep(for: pollInterval)
        }
        guard signaller.isAlive(pid) else { return }
        guard decideHolderChild(record) == .reap else {
            logger.warning("""
            reaper: holder child \(pid, privacy: .public) no longer verifies after SIGTERM — \
            leaving it alone rather than escalating
            """)
            return
        }
        logger.warning("""
        reaper: holder child \(pid, privacy: .public) survived SIGTERM — sending SIGKILL
        """)
        signaller.forceKill(pid)
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
