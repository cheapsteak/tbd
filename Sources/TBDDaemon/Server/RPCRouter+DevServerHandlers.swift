import Foundation
import os
import TBDShared

private let devServerLogger = Logger(subsystem: "com.tbd.daemon", category: "dev-servers")

enum DevServerStartError: LocalizedError {
    case cwdMissing(String)
    var errorDescription: String? {
        switch self {
        case .cwdMissing(let path): return "working directory does not exist: \(path)"
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
        let snapshot = await operations.snapshot(worktree: worktree, runStatusCommands: true)
        let names = params.names.isEmpty ? snapshot.declarations.servers.map(\.name) : params.names
        guard !names.isEmpty else {
            return try RPCResponse(result: DevServerActionResult(outcomes: []))
        }
        // One row per call naming the worktree, written before any spawn,
        // respawn or tab close.
        let actuationID = try await beginActuation(
            .serverStart, actor: actor,
            target: .local(worktree: params.worktreeID, terminal: nil),
            agent: "dev-server")
        let repoPath = await operations.repoPath(for: worktree)
        var outcomes: [DevServerActionOutcome] = []
        for name in names {
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
            do {
                let terminal = try await startDevServer(
                    server, worktree: worktree, reusing: snapshot.tabs[name],
                    operations: operations, repoPath: repoPath, actuationID: actuationID)
                outcomes.append(.init(name: name, status: .started, terminalID: terminal.id))
                // A new run supersedes the last one's saved output: the entry
                // stays in Closed Terminals but no longer speaks for the server.
                await db.terminalHistory.detachServerOutput(worktreeID: worktree.id, serverName: name)
            } catch {
                devServerLogger.warning("""
                    server.start \(name, privacy: .public) in \(worktree.id.uuidString, privacy: .public) \
                    failed: \(String(describing: error), privacy: .public)
                    """)
                outcomes.append(.init(name: name, status: .failed, message: error.localizedDescription))
            }
        }
        await finishServerActuation(actuationID, outcomes: outcomes)
        await onDevServersChanged?()
        return try RPCResponse(result: DevServerActionResult(outcomes: outcomes))
    }

    /// Opens (or, for an exited tmux tab, respawns in place) one server's tab.
    private func startDevServer(
        _ server: DeclaredDevServer,
        worktree: LocalWorktree,
        reusing existing: DevServerTabObservation?,
        operations: DevServerOperations,
        repoPath: String?,
        actuationID: String
    ) async throws -> Terminal {
        let cwd = DevServerDeclarationParser.resolvedCwd(server, worktreePath: worktree.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DevServerStartError.cwdMissing(cwd)
        }
        let command = Self.devServerShellCommand(server.command)
        let label = TerminalLabel.userSupplied(server.displayLabel) ?? server.name

        // A server whose tab exited is started again in that same tab.
        if let existing, case .exited = existing.status {
            switch existing.terminal.transport {
            case .tmux:
                var env = operations.commandEnvironment(server: server, worktree: worktree, repoPath: repoPath)
                env["TBD_TERMINAL_ID"] = existing.terminal.id.uuidString
                try await lifecycle.tmux.respawnWindow(
                    server: worktree.tmuxServer, windowID: existing.terminal.tmuxWindowID,
                    cwd: cwd, shellCommand: command, env: env)
                await keepFinalScreen(tmuxServer: worktree.tmuxServer, windowID: existing.terminal.tmuxWindowID)
                return existing.terminal
            case .holder:
                // A holder session cannot be respawned in place: close the
                // exited tab — its final output was saved when its child
                // exited — then open a new one.
                let (cleanupFailure, refusal) = try await closeTerminalTab(
                    existing.terminal, actuationID: actuationID)
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
        if terminal.transport == .tmux {
            await keepFinalScreen(tmuxServer: worktree.tmuxServer, windowID: terminal.tmuxWindowID)
        }
        subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
            terminalID: terminal.id, worktreeID: terminal.worktreeID, label: terminal.label)))
        return terminal
    }

    /// `remain-on-exit on`, so a crashed server's output stays readable and
    /// its exit status stays queryable (`#{pane_dead_status}`).
    private func keepFinalScreen(tmuxServer: String, windowID: String) async {
        do {
            try await lifecycle.tmux.setRemainOnExit(server: tmuxServer, windowID: windowID)
        } catch {
            devServerLogger.warning("""
                server.start: remain-on-exit failed for \(windowID, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
        }
    }

    func handleServerStop(_ paramsData: Data, actor: ActuationActor? = nil) async throws -> RPCResponse {
        let params = try decoder.decode(DevServerActionParams.self, from: paramsData)
        guard let worktree = try await db.worktrees.getLocal(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found: \(params.worktreeID)")
        }
        let operations = devServerOperations()
        let snapshot = await operations.snapshot(worktree: worktree, runStatusCommands: true)
        let names = params.names.isEmpty
            ? snapshot.servers.filter { $0.state == .running || $0.state == .unknown }.map(\.name)
            : params.names
        guard !names.isEmpty else {
            return try RPCResponse(result: DevServerActionResult(outcomes: []))
        }
        let actuationID = try await beginActuation(
            .serverStop, actor: actor, target: .local(worktree: params.worktreeID, terminal: nil),
            agent: "dev-server")
        let repoPath = await operations.repoPath(for: worktree)
        var outcomes: [DevServerActionOutcome] = []
        for name in names {
            guard let info = snapshot.info(name) else {
                outcomes.append(.init(name: name, status: .failed,
                                      message: "no declared or reported server named \"\(name)\""))
                continue
            }
            let tab = snapshot.tabs[name]
            // Nothing to signal and no stop command to run: report it, but
            // still clear an exited server — close its tab, detach its saved
            // last output.
            if info.state != .running && info.state != .unknown && !info.hasStopCommand {
                if let tab {
                    let (cleanupFailure, refusal) = try await closeTerminalTab(
                        tab.terminal, actuationID: actuationID)
                    logTabCloseProblems(tab.terminal, cleanupFailure, refusal)
                    outcomes.append(.init(name: name, status: .stopped, terminalID: tab.terminal.id))
                } else if info.state == .exited {
                    // Only a saved last output says "exited" here; clearing it is the stop.
                    outcomes.append(.init(name: name, status: .stopped))
                } else {
                    outcomes.append(.init(name: name, status: .notRunning, message: "not running"))
                }
                await db.terminalHistory.detachServerOutput(worktreeID: worktree.id, serverName: name)
                continue
            }
            let report = await operations.stopper.stop(
                operations.stopRequest(for: name, in: snapshot, repoPath: repoPath))
            guard report.succeeded else {
                outcomes.append(.init(name: name, status: .failed, terminalID: tab?.terminal.id,
                                      message: report.message))
                continue
            }
            if let tab {
                let (cleanupFailure, refusal) = try await closeTerminalTab(
                    tab.terminal, actuationID: actuationID)
                logTabCloseProblems(tab.terminal, cleanupFailure, refusal)
            }
            // After the tab close, never before: the close deletes the
            // terminal row, and `recordServerExit` stamps an entry only while
            // that row exists — so the exit this stop's own kill caused cannot
            // re-attach an entry after this detach.
            await db.terminalHistory.detachServerOutput(worktreeID: worktree.id, serverName: name)
            outcomes.append(.init(name: name, status: .stopped, terminalID: tab?.terminal.id))
        }
        await finishServerActuation(actuationID, outcomes: outcomes)
        await onDevServersChanged?()
        return try RPCResponse(result: DevServerActionResult(outcomes: outcomes))
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
