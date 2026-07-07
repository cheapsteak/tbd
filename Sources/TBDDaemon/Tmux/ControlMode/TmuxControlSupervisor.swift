import Foundation
import os

/// Lock-protected box for the layout-change echo filter. Lets the bridge's
/// synchronous `struct` init install the filter BEFORE any connection starts,
/// without hopping onto the actor (which the sync init cannot `await`). The
/// drain task (actor-isolated) reads it via the nonisolated getter.
private final class LayoutChangeFilterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var filter: (@Sendable (String, String) -> Bool)?
    func set(_ filter: @escaping @Sendable (String, String) -> Bool) {
        lock.lock(); self.filter = filter; lock.unlock()
    }
    func get() -> (@Sendable (String, String) -> Bool)? {
        lock.lock(); defer { lock.unlock() }; return filter
    }
}

/// Tracks at most one `TmuxControlConnection` per tmux server and drains its
/// events into the log. Phase 1's control-mode path is observation-only:
/// nothing is rendered and no FDs are vended.
actor TmuxControlSupervisor {
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")
    private var connections: [String: TmuxControlConnection] = [:]
    /// Echo-suppression predicate `(server, windowID) -> shouldApply`, wired to
    /// `ControlModeResizeCoordinator.shouldApplyLayoutChange` by the bridge. A
    /// `%layout-change` for which this returns `false` is one of our own resize
    /// echoes and is suppressed in `drain`. MUST be installed (via
    /// `setLayoutChangeFilter`) before `ensureConnection` so the drain loop
    /// consults it from the first event; nil (default) applies every change,
    /// which is the correct pre-resize-feature behavior.
    private let layoutFilterBox = LayoutChangeFilterBox()
    /// One FIFO command correlator per connection, keyed by server. Fed the
    /// connection's `.commandSucceeded`/`.commandFailed` events by `drain`.
    private var commandClients: [String: TmuxControlCommandClient] = [:]
    /// Servers whose faulted connection is still inside its (off-actor,
    /// blocking) `stop()` (R6-M4). `evictForTeardown` inserts the name before
    /// handing ownership to the nonisolated teardown; `finishTeardown` removes
    /// it AFTER `stop()` returns. `ensureConnection` suspends while its server
    /// is here: eviction-before-stop (R5-M1) empties the maps while the old
    /// tmux client process is still dying, and `PaneFanout.route` keys by
    /// (server, paneID) only — a successor started in that window would leave
    /// TWO live `-CC` connections routing duplicate `%output` into the same
    /// pane pipes.
    private var stoppingServers: Set<String> = []
    /// Continuations parked by `ensureConnection` on a stopping server,
    /// resumed (and re-checked) by `finishTeardown` once the stop returns.
    private var stopWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Shared per-daemon fanout. Reader threads call `route` directly (it is
    /// internally locked), so this is honestly `nonisolated`; the actor only
    /// mediates attach/ready/detach. Test-visible so orchestration tests can
    /// fabricate `%output` events against the same fanout the supervisor owns.
    nonisolated let fanout = PaneFanout()
    /// Connection factory seam. Production builds a real `tmux -CC` connection;
    /// tests substitute one backed by a stub binary so teardown paths can run
    /// without a live tmux.
    private let makeConnection: @Sendable (String) -> TmuxControlConnection
    /// How a fatally-faulted connection is stopped (see `teardownConnection`).
    /// `TmuxControlConnection.stop()` blocks up to ~2 s (SIGTERM → SIGKILL
    /// escalation), so this MUST only ever run off the actor. Injectable so
    /// tests can hold a stop mid-flight deterministically.
    private let stopConnection: @Sendable (TmuxControlConnection) -> Void

    init(makeConnection: @escaping @Sendable (String) -> TmuxControlConnection
            = { TmuxControlConnection(serverName: $0) },
         stopConnection: @escaping @Sendable (TmuxControlConnection) -> Void = { $0.stop() }) {
        self.makeConnection = makeConnection
        self.stopConnection = stopConnection
    }

    /// Idempotently ensure a control connection exists for `serverName`.
    /// A no-op if one is already running. If the server's previous connection
    /// is mid-teardown (evicted from the maps but its blocking `stop()` still
    /// running), this SUSPENDS until the stop completes rather than starting
    /// a successor early (R6-M4) — suspension, not blocking: the actor stays
    /// free, and every caller already awaits this actor method.
    func ensureConnection(serverName: String) async {
        // Loop, not `if`: a fresh teardown can begin between a waiter's
        // resume and this task re-entering the actor.
        while stoppingServers.contains(serverName) {
            await withCheckedContinuation { continuation in
                stopWaiters[serverName, default: []].append(continuation)
            }
        }
        guard connections[serverName] == nil else { return }
        let connection = makeConnection(serverName)
        let fanout = self.fanout
        connection.outputSink = { [fanout] event in
            fanout.route(server: serverName, event: event)
        }
        do {
            try connection.start()
        } catch {
            logger.error("failed to start tmux -CC connection for \(serverName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        connections[serverName] = connection
        // Commands for this connection are correlated FIFO through the client.
        // `writeLine` funnels to the connection's stdin writer (which appends
        // the newline); `onFatalError` tears the connection down on a protocol
        // violation — hopped onto this actor because `stop()` must run here.
        let client = TmuxControlCommandClient(
            writeLine: { [connection] line in connection.sendCommand(line) },
            onFatalError: { [weak self] in
                Task { await self?.teardownConnection(serverName: serverName, connection: connection) }
            })
        commandClients[serverName] = client
        // Bind the client to THIS connection so its drain closes its own client,
        // not whatever a later `ensureConnection` installed in the map. A map
        // re-lookup inside `drain` would race the successor's install.
        Task { [weak self] in
            await self?.drain(serverName: serverName, connection: connection, client: client)
        }
    }

    /// Stop every connection. Call on daemon shutdown. Two halves, same rule
    /// as `teardownConnection` (`stop()` blocks up to ~2 s per connection —
    /// never on this actor): the actor-isolated half (`beginStopAll`) empties
    /// the maps — failing each client's pending sends immediately, in the
    /// same bookkeeping order as `evictForTeardown` — and marks every server
    /// `stopping` (R6-M4 consistency: an `ensureConnection` racing the
    /// shutdown parks instead of starting a successor beside a still-dying
    /// tmux client process, which would double-route `%output`). The blocking
    /// `stop()`s then run OFF the actor — and OFF the cooperative pool: a
    /// task-group closure runs on Swift concurrency's fixed-width executor,
    /// so N connections blocking in `stop()` would starve every task in the
    /// daemon (observed as a full test-runner wedge). GCD threads absorb the
    /// blocking instead, concurrently (independent processes), the same
    /// discipline as the codebase's dedicated-Thread rule for blocking
    /// syscalls. The `stopping` marks are cleared once the stops return
    /// rather than left forever: production's only caller is daemon shutdown
    /// (the process exits right after, so a late successor is moot), and
    /// tests rely on the supervisor staying usable after `stopAll` (the
    /// reconnect-after-stopAll contract in
    /// `TmuxControlCommandClientIntegrationTests`).
    nonisolated func stopAll() async {
        let evicted = await beginStopAll()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                DispatchQueue.concurrentPerform(iterations: evicted.count) { index in
                    self.stopConnection(evicted[index].1)
                }
                continuation.resume()
            }
        }
        await finishStopAll(serverNames: evicted.map(\.0))
    }

    /// Actor-isolated half of `stopAll`: evict every connection from the maps
    /// (failing pending sends, marking each server `stopping`) and close the
    /// fanout. Returns the evicted connections for the off-actor stops.
    private func beginStopAll() async -> [(String, TmuxControlConnection)] {
        var evicted: [(String, TmuxControlConnection)] = []
        for serverName in Array(connections.keys) {
            // Re-lookup per iteration: `connectionClosed()` inside the shared
            // eviction suspends, and a concurrent drain cleanup may mutate
            // the map between iterations.
            if let connection = await evictForStop(serverName: serverName) {
                evicted.append((serverName, connection))
            }
        }
        fanout.closeAll()
        return evicted
    }

    /// Post-stop half of `stopAll`: clear every `stopping` mark and resume
    /// the `ensureConnection` calls parked on them.
    private func finishStopAll(serverNames: [String]) {
        for serverName in serverNames {
            finishTeardown(serverName: serverName)
        }
    }

    /// The FIFO command correlator for `server`, if a connection is up. Used by
    /// the RPC layer / attach orchestrator to issue commands over the stream.
    func command(server: String) -> TmuxControlCommandClient? {
        commandClients[server]
    }

    /// Install the layout-change echo filter (see `layoutFilterBox`). Nonisolated
    /// so the bridge's synchronous init can call it before `ensureConnection`.
    nonisolated func setLayoutChangeFilter(_ filter: @escaping @Sendable (String, String) -> Bool) {
        layoutFilterBox.set(filter)
    }

    /// Tear a connection down after a fatal correlator violation. `nonisolated`
    /// on purpose (same rule as `writeReplay`): `stop()` blocks up to ~2 s on
    /// the SIGTERM → SIGKILL escalation, and that wait must run on the caller's
    /// task — never on this actor, where it would stall every supervisor call
    /// for every worktree. The actor-isolated half (`evictForTeardown`) is
    /// bookkeeping only and runs first: state leaves the maps BEFORE `stop()`
    /// so pending sends fail immediately — but the server is marked
    /// `stopping` for the same window, so a concurrent `ensureConnection`
    /// waits for `stop()` to return instead of racing a successor into a
    /// second live `-CC` connection (R6-M4). No fd-reuse hazard either way:
    /// the successor opens its own fresh pty, and the old connection's
    /// primary fd is owned by (and closed only inside) its own `stop()`.
    private nonisolated func teardownConnection(
        serverName: String, connection: TmuxControlConnection
    ) async {
        guard await evictForTeardown(serverName: serverName, connection: connection) else { return }
        await stopOffPool(connection)
        await finishTeardown(serverName: serverName)
    }

    /// Run one connection's blocking `stop()` on a GCD thread — NEVER on the
    /// caller's task, which for `onFatalError`'s bare `Task {}` is a
    /// cooperative-pool thread (R9-H1: the same fixed-width-executor hazard
    /// R8-M2 fixed in `stopAll`, reachable here from any protocol violation).
    private nonisolated func stopOffPool(_ connection: TmuxControlConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                self.stopConnection(connection)
                continuation.resume()
            }
        }
    }

    /// Post-`stop()` half of the teardown: the old tmux client process is
    /// gone, so a successor may now go live. Clears the `stopping` mark and
    /// resumes every `ensureConnection` parked on it (each re-checks the set).
    private func finishTeardown(serverName: String) {
        stoppingServers.remove(serverName)
        for waiter in stopWaiters.removeValue(forKey: serverName) ?? [] {
            waiter.resume()
        }
    }

    /// Bookkeeping half of the fatal-error teardown. Guarded on identity so a
    /// stale callback from a superseded connection is a no-op (the M1-era
    /// stale-drain rule: never evict a successor's entries). Removes the maps'
    /// state and fails the client's pending sends NOW — waiting for `stop()`
    /// to end the stream (and `drain` to observe it) could take the whole
    /// SIGKILL escalation. `drain`'s own end-of-stream cleanup then no-ops on
    /// the maps (identity guard) and re-calls `connectionClosed` (idempotent).
    /// Returns whether this call still owned the connection — only the owner
    /// proceeds to `stop()`.
    private func evictForTeardown(
        serverName: String, connection: TmuxControlConnection
    ) async -> Bool {
        guard connections[serverName] === connection else { return false }
        logger.error("tearing down tmux -CC connection for \(serverName, privacy: .public) after correlator fault")
        _ = await evictForStop(serverName: serverName)
        return true
    }

    /// Shared eviction bookkeeping for `evictForTeardown` and `stopAll` — the
    /// order is load-bearing: remove the connection from the map and mark the
    /// server stopping BEFORE ownership leaves the actor (from here until
    /// `finishTeardown`, `ensureConnection` must wait — R6-M4), then fail the
    /// client's pending sends NOW rather than after the blocking `stop()`.
    private func evictForStop(serverName: String) async -> TmuxControlConnection? {
        guard let connection = connections.removeValue(forKey: serverName) else { return nil }
        stoppingServers.insert(serverName)
        let client = commandClients.removeValue(forKey: serverName)
        await client?.connectionClosed()  // fail pending sends without waiting for stop()
        return connection
    }

    /// Allocate a per-pane pipe in the fanout and return the read end for the
    /// RPC layer to vend, plus the attach's generation (for the ready-timeout
    /// cancel). The sink starts NOT ready — writes stay gated until the app
    /// acks with `attach.ready`.
    func attach(server: String, paneID: String) throws -> (readFD: Int32, generation: UInt64) {
        try fanout.attach(key: PaneKey(server: server, paneID: paneID))
    }

    /// Open the pane's write gate — generation-checked (R6-H1): a stale
    /// sequence's markReady, superseded between its replay write and this
    /// call, must not open a successor's un-replayed gate. Returns whether
    /// the gate actually opened (`false` → the caller's attach was replaced).
    @discardableResult
    func markReady(server: String, paneID: String, generation: UInt64) -> Bool {
        fanout.markReady(key: PaneKey(server: server, paneID: paneID), generation: generation)
    }

    /// Record the app's `attach.ready` ack and return the attach's CURRENT
    /// generation (M4.3) — the whole replay sequence is tagged with it.
    /// Generation-checked when the app echoed one (`expectedGeneration`): a
    /// stale ready for a superseded attach returns `.superseded` without
    /// touching the successor's sink. Once acknowledged, the ready-timeout no
    /// longer threatens this attach.
    func acknowledgeAttach(
        server: String, paneID: String, expectedGeneration: UInt64? = nil
    ) -> PaneAcknowledgeResult {
        fanout.acknowledge(
            key: PaneKey(server: server, paneID: paneID), expectedGeneration: expectedGeneration)
    }

    func isReady(server: String, paneID: String) -> Bool {
        fanout.isReady(key: PaneKey(server: server, paneID: paneID))
    }

    /// Read-only generation lookup (R10-3) — see `PaneFanout.currentGeneration`.
    func currentGeneration(server: String, paneID: String) -> UInt64? {
        fanout.currentGeneration(key: PaneKey(server: server, paneID: paneID))
    }

    func detach(server: String, paneID: String) {
        fanout.detach(key: PaneKey(server: server, paneID: paneID))
    }

    /// Generation-checked detach for failure cleanup: removes + closes the
    /// pane's sink ONLY if it still belongs to `generation`, so a stale
    /// attach's failure (or a stale `pane.detach`) can never EOF a newer
    /// attach's healthy pipe. Returns whether a sink was actually detached.
    @discardableResult
    func detachIfGeneration(server: String, paneID: String, generation: UInt64) -> Bool {
        fanout.detachIfGeneration(
            key: PaneKey(server: server, paneID: paneID), generation: generation)
    }

    /// Pre-ready, generation-checked replay write (M4.2), delegated to the
    /// fanout. `nonisolated` on purpose: `writeReplay` may block up to its
    /// deadline waiting for the app to drain the pipe — that wait must run on
    /// the caller's task (the attach orchestrator), never on this actor,
    /// where it would stall every attach/detach in the daemon.
    nonisolated func writeReplay(
        server: String, paneID: String, generation: UInt64, bytes: Data,
        deadline: TimeInterval = 5.0
    ) throws {
        try fanout.writeReplay(
            key: PaneKey(server: server, paneID: paneID),
            generation: generation, bytes: bytes, deadline: deadline)
    }

    /// Cancel an attach the app never acked (spec: 5 s ready timeout).
    /// Generation-scoped: a stale timer from a superseded attach is a no-op.
    func detachIfNotReady(server: String, paneID: String, generation: UInt64) {
        fanout.detachIfNotReady(key: PaneKey(server: server, paneID: paneID), generation: generation)
    }

    private func drain(serverName: String, connection: TmuxControlConnection,
                       client: TmuxControlCommandClient) async {
        for await event in connection.events {
            // Command reply blocks stop at the correlator; keep the one-line
            // summary log for diagnostics. A `%layout-change` that the filter
            // rejects is one of our own resize echoes (addendum §4) — suppress
            // the info log so external changes stay legible; everything else
            // logs as before. (No functional layout consumer exists in Phase A;
            // suppression is observable via logs and the unit tests.)
            if case .layoutChange(let windowID, _) = event,
               let filter = layoutFilterBox.get(),
               !filter(serverName, windowID) {
                logger.debug("[\(serverName, privacy: .public)] suppressed resize echo \(windowID, privacy: .public)")
            } else {
                log(event, serverName: serverName)
            }
            switch event {
            case .commandSucceeded, .commandFailed:
                await client.handle(event)
            default:
                break
            }
        }
        // A stale drain from a superseded connection must not evict its
        // successor's entries — only clear the maps if we still own them.
        // Ownership also decides who stops the connection (R9-M1): on a
        // NATURAL stream end (tmux server exited on its own) nothing else
        // ever calls `stop()`, and the pty master fd is closed only inside
        // it — every natural server death used to leak one fd for the life
        // of the daemon. When we DON'T own the entry, a teardown/stopAll
        // already evicted it and owns the stop (both paths and this cleanup
        // run on this actor, so the handoff cannot race; `stop()` is
        // idempotent regardless). No `stopping` mark needed here: the tmux
        // process is already dead, so a racing successor cannot double-route
        // output the way R6-M4's mid-SIGTERM window could.
        let ownedAtStreamEnd = connections[serverName] === connection
        if ownedAtStreamEnd {
            connections[serverName] = nil
            commandClients[serverName] = nil
        }
        await client.connectionClosed()  // fail any pending sends (this drain's client regardless of map ownership)
        if ownedAtStreamEnd {
            await stopOffPool(connection)  // release the pty fd (off-pool; blocking escalation)
        }
        logger.info("tmux -CC event stream ended for \(serverName, privacy: .public)")
    }

    private func log(_ event: TmuxControlEvent, serverName: String) {
        let tag = "[\(serverName)]"
        switch event {
        case .output(let pane, let bytes):
            logger.debug("\(tag, privacy: .public) %output \(pane, privacy: .public) \(bytes.count) bytes")
        case .extendedOutput(let pane, let age, let bytes):
            logger.debug("\(tag, privacy: .public) %extended-output \(pane, privacy: .public) age=\(age)ms \(bytes.count) bytes")
        case .commandSucceeded(let number, let fromClient, let lines):
            logger.debug("\(tag, privacy: .public) %end #\(number) fromClient=\(fromClient, privacy: .public) \(lines.count) lines")
        case .commandFailed(let number, let fromClient, let lines):
            logger.error("\(tag, privacy: .public) %error #\(number) fromClient=\(fromClient, privacy: .public) \(lines.count) lines")
        case .windowAdd(let window):
            logger.info("\(tag, privacy: .public) %window-add \(window, privacy: .public)")
        case .windowClose(let window):
            logger.info("\(tag, privacy: .public) %window-close \(window, privacy: .public)")
        case .layoutChange(let window, _):
            logger.info("\(tag, privacy: .public) %layout-change \(window, privacy: .public)")
        case .pause(let pane):
            logger.info("\(tag, privacy: .public) %pause \(pane, privacy: .public)")
        case .continue(let pane):
            logger.info("\(tag, privacy: .public) %continue \(pane, privacy: .public)")
        case .exit(let reason):
            logger.info("\(tag, privacy: .public) %exit \(reason ?? "", privacy: .public)")
        case .unhandled(let line):
            logger.debug("\(tag, privacy: .public) unhandled: \(line, privacy: .public)")
        }
    }
}
