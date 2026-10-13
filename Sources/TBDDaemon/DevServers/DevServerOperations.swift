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
    /// Why the worktree's tab rows could not be read; nil when they were.
    /// Every server not shown running by a live file or `status` then reads
    /// *Unknown*, and a start or stop refuses as for an unreadable tab.
    let tabsUnreadable: String?
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

    /// `statusFor` limits the `status` commands run to those servers (nil:
    /// every declared one); the others read as if no command ran.
    func snapshot(
        worktree: LocalWorktree, runStatusCommands: Bool, statusFor names: Set<String>? = nil
    ) async -> DevServerSnapshot {
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
        let terminals: [Terminal]
        var tabsUnreadable: String?
        do {
            terminals = try await db.terminals.list(worktreeID: worktree.id)
        } catch {
            terminals = []
            tabsUnreadable = "the worktree's terminals could not be read: \(error)"
        }
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
                    guard let status = server.status, names?.contains(server.name) ?? true else { return nil }
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
            lastOutputs: lastOutputs, tabsUnreadable: tabsUnreadable != nil))
        return DevServerSnapshot(
            worktree: worktree, declarations: declarations, liveFiles: liveFiles,
            diagnostics: scan.diagnostics, tabs: tabs, tabsUnreadable: tabsUnreadable, servers: servers)
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

    /// Kill targets are the server's running TBD tab and, when
    /// `signalRunningFiles` is true, the pid of every live running file for
    /// it. The tab is read again here rather than trusted from the snapshot,
    /// which can be a `status` timeout old: a first-hand pid (a live tmux
    /// pane) is then anchored by the start time the kill reads at once, a
    /// holder job by the start time its row recorded, and a tab whose pid
    /// cannot be tied to it — or whose state cannot be read at all — is
    /// reported, never signalled. Running files are anchored by the start
    /// time they recorded.
    ///
    /// Archive passes `signalRunningFiles: false`: anything can write a
    /// running file, so only a user gesture may signal the pid one names.
    /// The files are still listed, so a stop that ends the tab's job deletes
    /// a file naming it.
    func stopRequest(
        for name: String, in snapshot: DevServerSnapshot, repoPath: String?, signalRunningFiles: Bool = true
    ) async -> DevServerStopRequest {
        let declared = snapshot.declared(name)
        var targets: [DevServerKillTarget] = []
        var unverifiable: [String] = []
        var tabWasRunning = false
        if let reason = snapshot.tabsUnreadable {
            // A tab may still run the command; it is not signalled, and the
            // stop is not reported as done.
            tabWasRunning = true
            unverifiable.append("the server's tab could not be looked up (\(reason))")
        }
        if let tab = snapshot.tabs[name], tab.status.runningPID != nil || tab.status.isUnknown {
            tabWasRunning = true
            switch await tabInspector.status(of: tab.terminal, tmuxServer: snapshot.worktree.tmuxServer) {
            case .running(let pid, let expected?):
                targets.append(DevServerKillTarget(
                    pid: pid, expectedStart: expected, tolerance: AgentReaper.defaultHolderIdentityWindow))
            case .running(let pid, nil):
                targets.append(.firstHand(pid: pid))
            case .runningUnverifiable(let pid):
                unverifiable.append("""
                    pid \(pid) in the server's tab has no recorded start time, so it cannot be told \
                    apart from a reused pid and was not signalled; closing the tab ends it
                    """)
            case .unknown(let reason):
                // Its command may still run: neither signalled nor taken
                // for stopped.
                unverifiable.append("the state of the server's tab could not be read (\(reason))")
            case .exited, .gone:
                break
            }
        }
        let files = snapshot.liveFiles.filter { $0.file.server == name }
        for entry in files where signalRunningFiles {
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
            killTargets: targets, unverifiable: unverifiable,
            runningOnlyByStatus: !tabWasRunning && files.isEmpty,
            runningFiles: files.map {
                DevServerStopRunningFile(
                    path: $0.path, pid: $0.file.pid, startTime: Date(timeIntervalSince1970: $0.file.startTime))
            })
    }

    /// Archive's half: stop the servers TBD started in its own tabs, in
    /// parallel, and nothing else. Archive can run with no user gesture
    /// (auto-archive on merge), so it never runs a declared `status` or
    /// `stop` command, and it never signals a pid just because a running
    /// file names it: any same-user process can write one, naming any
    /// process. A server is stopped only when its TBD tab still runs the
    /// command or cannot be read (the tab's process group, SIGTERM then
    /// SIGKILL); a server known only through a running file or its `status`
    /// command is reported left running, its running file kept for
    /// OrphanGC once the process ends. Teardown for those belongs in the
    /// repo's archive hook. Tabs are left for archive's own teardown, which
    /// captures their scrollback.
    func stopAllForArchive(worktree: LocalWorktree) async -> [DevServerStopReport] {
        let snapshot = await snapshot(worktree: worktree, runStatusCommands: false)
        let repoPath = await repoPath(for: worktree)
        var requests: [DevServerStopRequest] = []
        var leftRunning: [DevServerStopReport] = []
        for server in snapshot.servers where server.state == .running || server.state == .unknown {
            let tabMayRun = snapshot.tabsUnreadable != nil
                || snapshot.tabs[server.name].map { $0.status.runningPID != nil || $0.status.isUnknown } == true
            if tabMayRun {
                requests.append(await stopRequest(
                    for: server.name, in: snapshot, repoPath: repoPath, signalRunningFiles: false))
            } else {
                leftRunning.append(DevServerStopReport(name: server.name, succeeded: false, message: """
                    left running: no TBD tab is running \(server.name), and archive stops only servers \
                    running in TBD's tabs; stop it from the repo's archive hook
                    """))
            }
        }
        let stopper = self.stopper
        return await withTaskGroup(of: DevServerStopReport.self) { group in
            for request in requests { group.addTask { await stopper.stop(request, allowRepoCommands: false) } }
            var reports = leftRunning
            for await report in group { reports.append(report) }
            return reports.sorted { $0.name < $1.name }
        }
    }
}
