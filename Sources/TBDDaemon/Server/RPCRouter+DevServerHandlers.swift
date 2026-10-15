import Foundation
import os
import TBDShared

private let devServerLogger = Logger(subsystem: "com.tbd.daemon", category: "dev-servers")

enum DevServerStartError: LocalizedError {
    case cwdMissing(String)
    /// The exited tab the start meant to reuse is no longer that tab.
    case tabChanged(UUID)
    /// The exited tab's pane could not be proved to be the server's.
    case paneNotOwned(UUID, String)
    var errorDescription: String? {
        switch self {
        case .cwdMissing(let path):
            return "working directory does not exist: \(path)"
        case .tabChanged(let id):
            return "the server's tab \(id) changed while it was being started; try again"
        case .paneNotOwned(let id, let detail):
            return "the server's tab \(id) was left untouched: \(detail)"
        }
    }
}

/// `server.*` (docs/specs/2026-10-11-dev-servers-design.md).
extension RPCRouter {
    func devServerOperations() -> DevServerOperations {
        DevServerOperations(
            db: db,
            tabInspector: devServerTabInspector ?? ProductionDevServerTabInspector(
                tmux: lifecycle.tmux, holderRegistry: holderRegistry, signaller: processSignaller),
            commandRunner: devServerCommandRunner,
            stopper: devServerStopper,
            runningFiles: devServerRunningFiles,
            probe: devServerProcessProbe,
            environment: devServerEnvironment)
    }

    /// The declared command as the tab's own process (`exec`), so it leads
    /// the tab's process group and its exit status is the pane's — read back
    /// through `#{pane_dead_status}`.
    static func devServerShellCommand(_ command: String) -> String {
        "exec /bin/sh -c '" + command.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func handleServerList(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(DevServerListParams.self, from: paramsData)
        guard let worktree = try await db.worktrees.getLocal(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
        }
        let snapshot = await devServerOperations().snapshot(
            worktree: worktree, runStatusCommands: params.runStatusCommands)
        return try RPCResponse(result: snapshot.listResult)
    }

    func handleServerSummary() async throws -> RPCResponse {
        let ids = await devServerSummaryProvider?() ?? []
        return try RPCResponse(result: DevServerSummaryResult(runningWorktreeIDs: ids))
    }

    func handleServerStart(_ paramsData: Data, actor: ActuationActor? = nil) async throws -> RPCResponse {
        let params = try decoder.decode(DevServerActionParams.self, from: paramsData)
        guard let worktree = try await db.worktrees.getLocal(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
        }
        guard worktree.status == .active || worktree.status == .main else {
            return RPCResponse(error: """
                Worktree \(worktree.displayName) is \(worktree.status.rawValue); \
                servers start only in an active worktree.
                """)
        }
        let operations = devServerOperations()
        // The names come from the declarations alone, so each server can be
        // claimed before its state is read: a state read before the claim
        // could predate a concurrent start's spawn.
        let names = Self.uniqued(params.names.isEmpty
            ? DevServerDeclarationParser.load(
                worktreePath: worktree.path, repoID: worktree.repoID, environment: devServerEnvironment
            ).servers.map(\.name)
            : params.names)
        guard !names.isEmpty else {
            return try RPCResponse(result: DevServerActionResult(outcomes: []))
        }
        // One row per call naming the worktree, written before any spawn,
        // respawn or tab close.
        let actuationID = try await beginActuation(
            .serverStart, actor: actor,
            target: .local(worktree: params.worktreeID, terminal: nil),
            agent: "dev-server")
        let (claimed, busy) = await devServerClaims.claim(names, in: worktree.id, for: .start)
        let snapshot = await operations.snapshot(
            worktree: worktree, runStatusCommands: true, statusFor: Set(names))
        let repoPath = await operations.repoPath(for: worktree)
        var outcomes: [DevServerActionOutcome] = []
        for name in names {
            // Losing the claim to another start is a failure, not "already
            // running": that start may still fail, and the caller cannot
            // tell from here whether the server ever comes up.
            if let holder = busy[name] {
                outcomes.append(.init(name: name, status: .failed, message: holder == .start
                    ? "already starting; try again" : "a stop of \(name) is in progress"))
                continue
            }
            guard let server = snapshot.declared(name) else {
                outcomes.append(.init(name: name, status: .failed,
                                      message: "no declared server named \"\(name)\""))
                continue
            }
            if let info = snapshot.info(name), info.state == .running {
                outcomes.append(.init(name: name, status: .alreadyRunning,
                                      terminalID: info.terminalID, message: "already running"))
                continue
            }
            // Unknown — its tab could not be read, or its `status` command
            // timed out — means its command may still run: a second start
            // would be a duplicate server.
            if let tab = snapshot.tabs[name], case .unknown(let reason) = tab.status {
                outcomes.append(.init(name: name, status: .failed, terminalID: tab.terminal.id,
                                      message: Self.unreadableTabMessage(reason)))
                continue
            }
            if let reason = snapshot.tabsUnreadable {
                outcomes.append(.init(name: name, status: .failed, message: Self.unreadableTabMessage(reason)))
                continue
            }
            if let info = snapshot.info(name), info.state == .unknown {
                outcomes.append(.init(name: name, status: .failed, terminalID: info.terminalID,
                                      message: Self.statusTimedOutMessage))
                continue
            }
            do {
                let terminal = try await startDevServer(
                    server, worktree: worktree, reusing: snapshot.tabs[name],
                    operations: operations, repoPath: repoPath)
                outcomes.append(.init(name: name, status: .started, terminalID: terminal.id))
            } catch {
                devServerLogger.warning("""
                    server.start \(name, privacy: .public) in \(worktree.id.uuidString, privacy: .public) \
                    failed: \(String(describing: error), privacy: .public)
                    """)
                outcomes.append(.init(name: name, status: .failed, message: error.localizedDescription))
            }
        }
        await devServerClaims.release(claimed, in: worktree.id)
        await finishServerActuation(actuationID, outcomes: outcomes)
        await onDevServersChanged?()
        return try RPCResponse(result: DevServerActionResult(outcomes: outcomes))
    }

    /// Order-preserving de-duplication: a name given twice is acted on once.
    static func uniqued(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    /// Opens (or, for an exited tmux tab, respawns in place) one server's tab.
    private func startDevServer(
        _ server: DeclaredDevServer,
        worktree: LocalWorktree,
        reusing existing: DevServerTabObservation?,
        operations: DevServerOperations,
        repoPath: String?
    ) async throws -> Terminal {
        let cwd = DevServerDeclarationParser.resolvedCwd(server, worktreePath: worktree.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DevServerStartError.cwdMissing(cwd)
        }
        let command = Self.devServerShellCommand(server.command)
        let label = TerminalLabel.userSupplied(server.displayLabel) ?? server.name
        // A new run supersedes the last one's saved output: the entry stays
        // in Closed Terminals but no longer speaks for the server. Before
        // the spawn, never after: a run that dies at once has its own exit
        // recorded by then, and a detach after the spawn would erase it.
        await db.terminalHistory.detachServerOutput(worktreeID: worktree.id, serverName: server.name)

        // A server whose tab exited is started again in that same tab.
        if let existing, case .exited = existing.status {
            switch existing.terminal.transport {
            case .tmux:
                var env = operations.commandEnvironment(server: server, worktree: worktree, repoPath: repoPath)
                env["TBD_TERMINAL_ID"] = existing.terminal.id.uuidString
                try await respawnExitedServerTab(
                    existing.terminal, serverName: server.name, worktree: worktree, cwd: cwd,
                    command: command, env: env, tabInspector: operations.tabInspector)
                // The window was created with `remain-on-exit on` (that is
                // what kept its dead pane), and a respawn keeps the option.
                return existing.terminal
            case .holder:
                // A holder session cannot be respawned in place: close the
                // exited tab — its final output was saved when its child
                // exited — then open a new one. A failed close throws, which
                // fails this server only.
                let (cleanupFailure, refusal) = try await closeTerminalTab(existing.terminal, actuationID: nil)
                logTabCloseProblems(existing.terminal, cleanupFailure, refusal)
            }
        }

        let terminalID = UUID()
        var env = operations.commandEnvironment(server: server, worktree: worktree, repoPath: repoPath)
        env["TBD_TERMINAL_ID"] = terminalID.uuidString
        let config = try? await db.config.get()
        let transport = TerminalSpawnTransport.decide(config: config, registry: holderRegistry)
        let cols = TmuxManager.defaultCols
        let rows = TmuxManager.defaultRows
        let serverName = server.name
        let spawnEnv = env
        let terminal = try await tmux.withWorktreeServerLock(
            db: db, worktreeID: worktree.id, allowedStatuses: [worktree.status]
        ) { current in
            try await self.prepareTmuxServer(for: transport, worktree: current, cols: cols, rows: rows)
            return try await self.lifecycle.spawnTerminal(
                id: terminalID, worktreeID: current.id, tmuxServer: current.tmuxServer,
                workingDirectory: cwd, command: command, env: spawnEnv, sensitiveEnv: [:],
                cols: cols, rows: rows, label: label, claudeSessionID: nil, profileID: nil,
                kind: .shell, transport: transport, attachment: nil,
                modelProxySupervisor: self.modelProxySupervisor, serverName: serverName)
        }
        subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
            terminalID: terminal.id, worktreeID: terminal.worktreeID, label: terminal.label)))
        return terminal
    }

    /// `respawn-window -k` on an exited server tab, under the worktree's tmux
    /// server lock and the same guards every other window-destroying path
    /// takes: the row is read again and must still be this server's tab at
    /// the same coordinates, its pane must still be dead, and
    /// `TmuxManager.paneOwnership` must prove the pane is this terminal's —
    /// the snapshot that chose the tab can be a `status` timeout old, and `-k`
    /// kills whatever the pane runs.
    private func respawnExitedServerTab(
        _ expected: Terminal, serverName: String, worktree: LocalWorktree, cwd: String,
        command: String, env: [String: String], tabInspector: any DevServerTabInspecting
    ) async throws {
        try await tmux.withWorktreeServerLock(
            db: db, worktreeID: worktree.id, allowedStatuses: [worktree.status]
        ) { current in
            guard let row = try await self.db.terminals.get(id: expected.id),
                  row.serverName == serverName, row.transport == .tmux,
                  row.tmuxWindowID == expected.tmuxWindowID, row.tmuxPaneID == expected.tmuxPaneID
            else { throw DevServerStartError.tabChanged(expected.id) }
            guard case .exited = await tabInspector.status(of: row, tmuxServer: current.tmuxServer) else {
                throw DevServerStartError.tabChanged(expected.id)
            }
            let ownership = await self.tmux.paneOwnership(
                terminalID: row.id, server: current.tmuxServer, paneID: row.tmuxPaneID)
            guard ownership.permitsTeardown else {
                throw DevServerStartError.paneNotOwned(row.id, ownership.refusalDetail ?? "ownership unknown")
            }
            try await self.tmux.respawnWindow(
                server: current.tmuxServer, windowID: row.tmuxWindowID,
                cwd: cwd, shellCommand: command, env: env)
        }
    }

    func handleServerStop(_ paramsData: Data, actor: ActuationActor? = nil) async throws -> RPCResponse {
        let params = try decoder.decode(DevServerActionParams.self, from: paramsData)
        guard let worktree = try await db.worktrees.getLocal(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
        }
        let operations = devServerOperations()
        // Named servers are claimed before their state is read. "Stop all"
        // has to read state to know which servers run, so it claims after;
        // a start that lands in between is not stopped by this call, and
        // each stop re-reads its server's tab before it signals anything.
        let names: [String]
        let snapshot: DevServerSnapshot
        let claimed: [String]
        let busy: [String: DevServerActionClaims.Action]
        if params.names.isEmpty {
            snapshot = await operations.snapshot(worktree: worktree, runStatusCommands: true)
            names = snapshot.servers.filter { $0.state == .running || $0.state == .unknown }.map(\.name)
            guard !names.isEmpty else {
                return try RPCResponse(result: DevServerActionResult(outcomes: []))
            }
            let claim = await devServerClaims.claim(names, in: worktree.id, for: .stop)
            claimed = claim.claimed
            busy = claim.busy
        } else {
            names = Self.uniqued(params.names)
            let claim = await devServerClaims.claim(names, in: worktree.id, for: .stop)
            claimed = claim.claimed
            busy = claim.busy
            snapshot = await operations.snapshot(
                worktree: worktree, runStatusCommands: true, statusFor: Set(names))
        }
        let actuationID: String
        do {
            actuationID = try await beginActuation(
                .serverStop, actor: actor, target: .local(worktree: params.worktreeID, terminal: nil),
                agent: "dev-server")
        } catch {
            await devServerClaims.release(claimed, in: worktree.id)
            throw error
        }
        let repoPath = await operations.repoPath(for: worktree)
        var outcomes: [DevServerActionOutcome] = []
        for name in names {
            if let holder = busy[name] {
                outcomes.append(.init(name: name, status: .failed, message: holder == .stop
                    ? "already stopping" : "a start of \(name) is in progress"))
                continue
            }
            guard let info = snapshot.info(name) else {
                outcomes.append(.init(name: name, status: .failed,
                                      message: "no declared or reported server named \"\(name)\""))
                continue
            }
            let tab = snapshot.tabs[name]
            // An unreadable tab may still run its command: refuse rather
            // than report a stop that did not happen.
            if let tab, case .unknown(let reason) = tab.status {
                outcomes.append(.init(name: name, status: .failed, terminalID: tab.terminal.id,
                                      message: Self.unreadableTabMessage(reason)))
                continue
            }
            if let reason = snapshot.tabsUnreadable {
                outcomes.append(.init(name: name, status: .failed, message: Self.unreadableTabMessage(reason)))
                continue
            }
            // An exited server has nothing running, so neither a signal nor
            // its declared `stop` applies; a stopped one without a `stop`
            // has nothing to act on. Either way: report it, and clear an
            // exited server — close its tab, detach its saved last output.
            if info.state == .exited || (info.state == .stopped && !info.hasStopCommand) {
                if let tab {
                    if let problem = await closeServerTab(tab.terminal) {
                        outcomes.append(.init(name: name, status: .failed, terminalID: tab.terminal.id,
                                              message: problem))
                    } else {
                        outcomes.append(.init(name: name, status: .stopped, terminalID: tab.terminal.id))
                    }
                } else if info.state == .exited {
                    // Only a saved last output says "exited" here; clearing it is the stop.
                    outcomes.append(.init(name: name, status: .stopped))
                } else {
                    outcomes.append(.init(name: name, status: .notRunning, message: "not running"))
                }
                await db.terminalHistory.detachServerOutput(worktreeID: worktree.id, serverName: name)
                continue
            }
            let request = await operations.stopRequest(for: name, in: snapshot, repoPath: repoPath)
            let report = await operations.stopper.stop(request, allowRepoCommands: true)
            guard report.succeeded else {
                outcomes.append(.init(name: name, status: .failed, terminalID: tab?.terminal.id,
                                      message: report.message))
                continue
            }
            let closeProblem: String?
            if let tab {
                closeProblem = await closeServerTab(tab.terminal)
            } else {
                closeProblem = nil
            }
            // After the tab close, never before: the close deletes the
            // terminal row, and `recordServerExit` stamps an entry only while
            // that row exists — so the exit this stop's own kill caused cannot
            // re-attach an entry after this detach.
            await db.terminalHistory.detachServerOutput(worktreeID: worktree.id, serverName: name)
            if let closeProblem {
                outcomes.append(.init(name: name, status: .failed, terminalID: tab?.terminal.id,
                                      message: "the server stopped, but \(closeProblem)"))
            } else {
                outcomes.append(.init(name: name, status: .stopped, terminalID: tab?.terminal.id,
                                      message: report.message))
            }
        }
        await devServerClaims.release(claimed, in: worktree.id)
        await finishServerActuation(actuationID, outcomes: outcomes)
        await onDevServersChanged?()
        return try RPCResponse(result: DevServerActionResult(outcomes: outcomes))
    }

    static let statusTimedOutMessage = "state unknown (status command timed out); try again or stop it first"

    static func unreadableTabMessage(_ reason: String) -> String {
        "the state of its tab could not be read, so it may still be running; try again (\(reason))"
    }

    /// Closes a server's tab with no outcome row of its own (the call's one
    /// row covers it). A throw — the row could not be read or deleted — is
    /// returned as that server's failure rather than ending the request.
    private func closeServerTab(_ terminal: Terminal) async -> String? {
        do {
            let (cleanupFailure, refusal) = try await closeTerminalTab(terminal, actuationID: nil)
            logTabCloseProblems(terminal, cleanupFailure, refusal)
            return nil
        } catch {
            devServerLogger.warning("""
                closing dev server tab \(terminal.id.uuidString, privacy: .public) failed: \
                \(String(describing: error), privacy: .public)
                """)
            return "closing its tab failed: \(error.localizedDescription)"
        }
    }

    /// One outcome row per call: dispatched when every server succeeded,
    /// otherwise a transport failure naming each failed server.
    private func finishServerActuation(_ actuationID: String, outcomes: [DevServerActionOutcome]) async {
        let failures = outcomes.filter { $0.status == .failed }
        if failures.isEmpty {
            await finishActuation(actuationID, .dispatched)
        } else {
            await finishActuation(
                actuationID, .transportFailed,
                error: failures.map { "\($0.name): \($0.message ?? "")" }.joined(separator: "; "))
        }
    }

    /// A server tab's close still deletes the row when the transport-level
    /// teardown fails or is refused; the call's row records the server's
    /// outcome, so the teardown's own problem is logged.
    private func logTabCloseProblems(_ terminal: Terminal, _ cleanupFailure: String?, _ refusal: String?) {
        guard let problem = cleanupFailure ?? refusal else { return }
        devServerLogger.warning("""
            dev server tab \(terminal.id.uuidString, privacy: .public) closed with a teardown problem: \
            \(problem, privacy: .public)
            """)
    }
}
