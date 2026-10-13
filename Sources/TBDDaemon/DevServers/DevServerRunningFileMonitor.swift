import Darwin
import Foundation
import os
import TBDShared

private let monitorLogger = Logger(subsystem: "com.tbd.daemon", category: "dev-servers")

/// Keeps "which worktrees have a dev server running" current for the sidebar
/// dot (docs/specs/2026-10-11-dev-servers-design.md, "Sidebar dot"): a watch
/// on the running-file directory for prompt updates, and a recheck every
/// `recheckInterval` (spec: 10 s) so a server that died without cleaning up —
/// or a server tab whose command exited, which produces no file event — drops
/// out. Reads only: never signals a process, never runs a `status` command.
actor DevServerRunningFileMonitor {
    private let db: TBDDatabase
    private let runningFiles: DevServerRunningFileStore
    private let probe: DevServerProcessProbe
    private let tabInspector: any DevServerTabInspecting
    private let broadcast: @Sendable (StateDelta) -> Void
    private let recheckInterval: Duration
    private let clock: any Clock<Duration>

    private var running: Set<UUID> = []
    /// Per worktree, a sorted description of its live running files and its
    /// server tabs' states: the facts a server list renders.
    private var fingerprints: [UUID: [String]] = [:]
    /// Bumped by every `refresh()`; only the newest one may commit, so two
    /// refreshes interleaving across their awaits cannot leave the older
    /// reading in place.
    private var generation = 0
    private var source: DispatchSourceFileSystemObject?
    private var recheckTask: Task<Void, Never>?
    private let watchQueue = DispatchQueue(label: "com.tbd.daemon.dev-servers.watch")

    init(
        db: TBDDatabase,
        runningFiles: DevServerRunningFileStore,
        probe: DevServerProcessProbe = .live,
        tabInspector: any DevServerTabInspecting,
        broadcast: @escaping @Sendable (StateDelta) -> Void,
        recheckInterval: Duration = .seconds(10),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.db = db
        self.runningFiles = runningFiles
        self.probe = probe
        self.tabInspector = tabInspector
        self.broadcast = broadcast
        self.recheckInterval = recheckInterval
        self.clock = clock
    }

    /// The current summary, in a stable order.
    func runningWorktreeIDs() -> [UUID] {
        running.sorted { $0.uuidString < $1.uuidString }
    }

    /// Initial read, then the directory watch and the recheck loop.
    func start() async {
        await refresh()
        ensureWatcher()
        guard recheckTask == nil else { return }
        let clock = self.clock
        let interval = recheckInterval
        recheckTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self else { return }
                await self.recheck()
            }
        }
    }

    func stop() {
        recheckTask?.cancel()
        recheckTask = nil
        source?.cancel()
        source = nil
    }

    private func recheck() async {
        ensureWatcher()
        await refresh()
    }

    /// Recomputes the summary and each worktree's fingerprint; broadcasts
    /// `.devServersChanged` when either moved, so a quiet machine stays
    /// silent while anything a server list shows — a running file's
    /// endpoints or pid, a server tab's running or exited state — reaches the
    /// app even when the set of running worktrees did not change.
    func refresh() async {
        generation += 1
        let mine = generation
        let worktrees: [LocalWorktree]
        do {
            worktrees = try await db.worktrees.listLocal(excludeArchived: true)
        } catch {
            monitorLogger.debug("dev-servers: listing worktrees failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        var paths: [UUID: String] = [:]
        var tmuxServers: [UUID: String] = [:]
        for worktree in worktrees {
            paths[worktree.id] = worktree.path
            tmuxServers[worktree.id] = worktree.tmuxServer
        }

        var next = Set<UUID>()
        var nextFingerprints: [UUID: [String]] = [:]
        let attributed = DevServerRunningFileStore.attribute(runningFiles.scan().entries, worktreePaths: paths)
        for (id, entries) in attributed {
            for entry in entries {
                switch DevServerRunningFileStore.liveness(of: entry.file, probe: probe) {
                case .live:
                    next.insert(id)
                    nextFingerprints[id, default: []].append(Self.fingerprint(of: entry.file))
                case .unknown:
                    // A process that could not be read has not stopped: a
                    // worktree the dot already shows keeps it, as for a tab
                    // that could not be read.
                    if running.contains(id) { next.insert(id) }
                    nextFingerprints[id, default: []].append("unknown " + Self.fingerprint(of: entry.file))
                case .stale:
                    break
                }
            }
        }

        // Plan decision D9: a TBD-started server tab counts while its command
        // runs, and the recheck is what notices it exiting. Every server tab
        // is read — not only those in worktrees no file marks — because a
        // tab's exit changes what the server list shows either way.
        let serverTabs = ((try? await db.terminals.list()) ?? []).filter { $0.serverName != nil }
        for tab in serverTabs {
            guard let tmuxServer = tmuxServers[tab.worktreeID], let name = tab.serverName else { continue }
            let state: String
            switch await tabInspector.status(of: tab, tmuxServer: tmuxServer) {
            case .running(let pid, _), .runningUnverifiable(let pid):
                next.insert(tab.worktreeID)
                state = "running \(pid)"
            case .exited(let code, _):
                state = "exited \(code.map(String.init) ?? "?")"
            case .unknown:
                // No answer is not an exit: a worktree the dot already shows
                // keeps it until a read says otherwise.
                if running.contains(tab.worktreeID) { next.insert(tab.worktreeID) }
                state = "unknown"
            case .gone:
                continue
            }
            nextFingerprints[tab.worktreeID, default: []].append("tab \(tab.id.uuidString) \(name) \(state)")
        }
        nextFingerprints = nextFingerprints.mapValues { $0.sorted() }

        guard mine == generation, next != running || nextFingerprints != fingerprints else { return }
        running = next
        fingerprints = nextFingerprints
        broadcast(.devServersChanged)
    }

    /// What the app shows for one live running file.
    private static func fingerprint(of file: DevServerRunningFile) -> String {
        let endpoints = file.endpoints.map { "\($0.name)=\($0.url)" }.joined(separator: ",")
        return "file \(file.server) \(file.pid) \(file.startTime) \(endpoints)"
    }

    /// Watches the directory itself: an entry added, removed or renamed in it
    /// (an atomic writer's rename lands here) is a `.write` on the directory.
    /// `.delete` / `.rename` mean the directory itself went away or moved;
    /// the watch is then re-armed on whatever now sits at the path. When the
    /// directory cannot be opened at all, the recheck retries.
    private func ensureWatcher() {
        guard source == nil else { return }
        let path = runningFiles.directory.path
        // The watch needs the directory; the spec names it as the shared
        // location, so creating it is intended.
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        source = Self.makeWatcher(path: path, queue: watchQueue) { [weak self] replaced in
            guard let self else { return }
            Task { await self.handleEvent(replaced: replaced) }
        }
        if source == nil {
            monitorLogger.debug("dev-servers: cannot watch \(path, privacy: .public); relying on the recheck")
        }
    }

    /// Nonisolated so the dispatch handlers are not inferred actor-isolated:
    /// they run on `queue`, and hop to the actor through `onEvent` only.
    private nonisolated static func makeWatcher(
        path: String, queue: DispatchQueue, onEvent: @escaping @Sendable (_ replaced: Bool) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        // The mask is read here, on the source's queue, where it belongs to
        // this event and no later one.
        source.setEventHandler { [weak source] in
            guard let source else { return }
            onEvent(!source.data.isDisjoint(with: [.delete, .rename]))
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func handleEvent(replaced: Bool) async {
        if replaced {
            source?.cancel()
            source = nil
            // Only re-arm while running: an event delivered after `stop()`
            // must not resurrect the watch.
            if recheckTask != nil { ensureWatcher() }
        }
        await refresh()
    }
}
