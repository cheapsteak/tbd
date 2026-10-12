import Foundation
import TBDShared

/// One worktree's dev servers, read once: declarations, the live running
/// files attributed to it, its server tabs, and the derived states.
struct DevServerSnapshot: Sendable {
    let worktree: LocalWorktree
    let declarations: DevServerDeclarations
    let liveFiles: [DevServerRunningFileEntry]
    let diagnostics: [DevServerRunningFileDiagnostic]
    /// The newest non-gone server tab per server name.
    let tabs: [String: DevServerTabObservation]
    let servers: [DevServerInfo]

    func declared(_ name: String) -> DeclaredDevServer? { declarations.servers.first { $0.name == name } }
    func info(_ name: String) -> DevServerInfo? { servers.first { $0.name == name } }

    var listResult: DevServerListResult {
        DevServerListResult(
            worktreeID: worktree.id, servers: servers,
            parseErrors: declarations.errors, runningFileDiagnostics: diagnostics)
    }
}

/// The reads and stops both `server.*` and archive need. Value type; the
/// router builds one per call from its wired collaborators, and the daemon
/// builds one for the lifecycle.
struct DevServerOperations: Sendable {
    /// The spec's bound on a declared `status` command; a timeout reads as
    /// *unknown*.
    static let statusTimeout: Duration = .seconds(5)

    let db: TBDDatabase
    let tabInspector: any DevServerTabInspecting
    let commandRunner: any DevServerCommandRunning
    let stopper: DevServerStopper
    let runningFiles: DevServerRunningFileStore
    let probe: DevServerProcessProbe
    /// Resolves the user's `servers.toml` (via `TBD_HOME`).
    let environment: [String: String]

    func repoPath(for worktree: LocalWorktree) async -> String? {
        guard let repoID = worktree.repoID else { return nil }
        // `try?` flattens `Repo?` (SE-0230): one binding covers both a failed
        // read and a missing row.
        guard let repo = try? await db.repos.get(id: repoID) else { return nil }
        return repo.path
    }

    func snapshot(worktree: LocalWorktree, runStatusCommands: Bool) async -> DevServerSnapshot {
        let declarations = DevServerDeclarationParser.load(
            worktreePath: worktree.path, repoID: worktree.repoID, environment: environment)
        let scan = runningFiles.scan()
        let attributed = DevServerRunningFileStore.attribute(
            scan.entries, worktreePaths: [worktree.id: worktree.path])[worktree.id] ?? []
        let liveFiles = attributed.filter {
            DevServerRunningFileStore.liveness(of: $0.file, probe: probe) == .live
        }
        // `list(worktreeID:)` orders by createdAt ascending, so the newest
        // non-gone tab for a name wins — what the deriver expects.
        let terminals = (try? await db.terminals.list(worktreeID: worktree.id)) ?? []
        var tabs: [String: DevServerTabObservation] = [:]
        for terminal in terminals {
            guard let name = terminal.serverName else { continue }
            let status = await tabInspector.status(of: terminal, tmuxServer: worktree.tmuxServer)
            guard status != .gone else { continue }
            tabs[name] = DevServerTabObservation(terminal: terminal, status: status)
        }
        // Saved last outputs: what makes an ended holder server read *Exited*
        // once its tab is gone. A read failure reads as none.
        let lastOutputs = (try? await db.terminalHistory.latestServerOutputs(worktreeID: worktree.id)) ?? [:]
        var checks: [String: DevServerStatusCheck] = [:]
        if runStatusCommands {
            let repoPath = await repoPath(for: worktree)
            let runner = commandRunner
            let jobs: [(name: String, command: String, cwd: String, env: [String: String])] =
                declarations.servers.compactMap { server in
                    guard let status = server.status else { return nil }
                    return (server.name, status,
                            DevServerDeclarationParser.resolvedCwd(server, worktreePath: worktree.path),
                            commandEnvironment(server: server, worktree: worktree, repoPath: repoPath))
                }
            checks = await withTaskGroup(of: (String, DevServerStatusCheck).self) { group in
                for job in jobs {
                    group.addTask {
                        switch await runner.run(
                            job.command, cwd: job.cwd, environment: job.env, timeout: Self.statusTimeout)
                        {
                        case .exited(0): return (job.name, .running)
                        case .exited, .failedToLaunch: return (job.name, .notRunning)
                        case .timedOut: return (job.name, .timedOut)
                        }
                    }
                }
                var collected: [String: DevServerStatusCheck] = [:]
                for await (name, check) in group { collected[name] = check }
                return collected
            }
        }
        let servers = DevServerStateDeriver.derive(DevServerDerivationInput(
            declared: declarations.servers, liveFiles: liveFiles, tabs: tabs, statusChecks: checks,
            lastOutputs: lastOutputs))
        return DevServerSnapshot(
            worktree: worktree, declarations: declarations, liveFiles: liveFiles,
            diagnostics: scan.diagnostics, tabs: tabs, servers: servers)
    }

    /// The environment a server's tab, `stop` and `status` commands run with:
    /// its declared `env`, then the TBD and dev-server variables (which win).
    func commandEnvironment(server: DeclaredDevServer, worktree: LocalWorktree, repoPath: String?) -> [String: String] {
        var env = server.env
        env["TBD_WORKTREE_ID"] = worktree.id.uuidString
        env["TBD_WORKTREE_NAME"] = worktree.name
        env["TBD_WORKTREE_PATH"] = worktree.path
        if let repoPath { env["TBD_REPO_PATH"] = repoPath }
        env["DEV_SERVER_NAME"] = server.name
        env[TBDConstants.devServersDirEnvironmentKey] = runningFiles.directory.path
        return env
    }

    /// Kill targets are the server's running TBD tab (pid read live) and the
    /// pid of every live running file for it, each re-verified against its
    /// recorded start time before the kill signals anything.
    func stopRequest(for name: String, in snapshot: DevServerSnapshot, repoPath: String?) -> DevServerStopRequest {
        let declared = snapshot.declared(name)
        var targets: [DevServerKillTarget] = []
        if case .running(let pid, let expected)? = snapshot.tabs[name]?.status {
            targets.append(DevServerKillTarget(
                pid: pid, expectedStart: expected,
                tolerance: expected == nil ? 0 : AgentReaper.defaultHolderIdentityWindow))
        }
        let files = snapshot.liveFiles.filter { $0.file.server == name }
        for entry in files {
            targets.append(DevServerKillTarget(
                pid: entry.file.pid, expectedStart: Date(timeIntervalSince1970: entry.file.startTime),
                tolerance: DevServerRunningFileStore.startTimeTolerance))
        }
        let worktree = snapshot.worktree
        return DevServerStopRequest(
            name: name, declared: declared,
            cwd: declared.map { DevServerDeclarationParser.resolvedCwd($0, worktreePath: worktree.path) }
                ?? worktree.path,
            commandEnvironment: declared.map {
                commandEnvironment(server: $0, worktree: worktree, repoPath: repoPath)
            } ?? [:],
            killTargets: targets, runningFilePaths: files.map(\.path))
    }

    /// Archive's half: stop every server TBD started (a running server tab)
    /// or that a live running file reports, in parallel. Tabs are left for
    /// archive's own teardown, which captures their scrollback.
    func stopAllForArchive(worktree: LocalWorktree) async -> [DevServerStopReport] {
        let snapshot = await snapshot(worktree: worktree, runStatusCommands: false)
        let repoPath = await repoPath(for: worktree)
        let requests = snapshot.servers.filter { $0.state == .running }
            .map { stopRequest(for: $0.name, in: snapshot, repoPath: repoPath) }
        let stopper = self.stopper
        return await withTaskGroup(of: DevServerStopReport.self) { group in
            for request in requests { group.addTask { await stopper.stop(request) } }
            var reports: [DevServerStopReport] = []
            for await report in group { reports.append(report) }
            return reports.sorted { $0.name < $1.name }
        }
    }
}
