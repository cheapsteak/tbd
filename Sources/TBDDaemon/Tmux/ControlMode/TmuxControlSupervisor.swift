import Foundation
import os

/// Tracks at most one `TmuxControlConnection` per tmux server and drains its
/// events into the log. Phase 1's control-mode path is observation-only:
/// nothing is rendered and no FDs are vended.
actor TmuxControlSupervisor {
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")
    private var connections: [String: TmuxControlConnection] = [:]
    /// One FIFO command correlator per connection, keyed by server. Fed the
    /// connection's `.commandSucceeded`/`.commandFailed` events by `drain`.
    private var commandClients: [String: TmuxControlCommandClient] = [:]
    /// Shared per-daemon fanout. Reader threads call `route` directly; the
    /// actor only mediates attach/ready/detach.
    private let fanout = PaneFanout()

    /// Idempotently ensure a control connection exists for `serverName`.
    /// A no-op if one is already running.
    func ensureConnection(serverName: String) {
        guard connections[serverName] == nil else { return }
        let connection = TmuxControlConnection(serverName: serverName)
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
        commandClients[serverName] = TmuxControlCommandClient(
            writeLine: { [connection] line in connection.sendCommand(line) },
            onFatalError: { [weak self] in
                Task { await self?.teardownConnection(serverName: serverName, connection: connection) }
            })
        Task { [weak self] in
            await self?.drain(serverName: serverName, connection: connection)
        }
    }

    /// Stop every connection. Call on daemon shutdown.
    func stopAll() {
        for connection in connections.values { connection.stop() }
        connections.removeAll()
        let clients = commandClients
        commandClients.removeAll()
        for client in clients.values {
            Task { await client.connectionClosed() }  // fail any pending sends
        }
        fanout.closeAll()
    }

    /// The FIFO command correlator for `server`, if a connection is up. Used by
    /// the RPC layer / attach orchestrator to issue commands over the stream.
    func command(server: String) -> TmuxControlCommandClient? {
        commandClients[server]
    }

    /// Tear a connection down after a fatal correlator violation. Guarded on
    /// identity so a stale callback from a superseded connection is a no-op.
    /// `stop()` ends the event stream, so `drain` performs the client cleanup.
    private func teardownConnection(serverName: String, connection: TmuxControlConnection) {
        guard connections[serverName] === connection else { return }
        logger.error("tearing down tmux -CC connection for \(serverName, privacy: .public) after correlator fault")
        connection.stop()
    }

    /// Allocate a per-pane pipe in the fanout and return the read end for the
    /// RPC layer to vend, plus the attach's generation (for the ready-timeout
    /// cancel). The sink starts NOT ready — writes stay gated until the app
    /// acks with `attach.ready`.
    func attach(server: String, paneID: String) throws -> (readFD: Int32, generation: UInt64) {
        try fanout.attach(key: PaneKey(server: server, paneID: paneID))
    }

    func markReady(server: String, paneID: String) {
        fanout.markReady(key: PaneKey(server: server, paneID: paneID))
    }

    func isReady(server: String, paneID: String) -> Bool {
        fanout.isReady(key: PaneKey(server: server, paneID: paneID))
    }

    func detach(server: String, paneID: String) {
        fanout.detach(key: PaneKey(server: server, paneID: paneID))
    }

    /// Cancel an attach the app never acked (spec: 5 s ready timeout).
    /// Generation-scoped: a stale timer from a superseded attach is a no-op.
    func detachIfNotReady(server: String, paneID: String, generation: UInt64) {
        fanout.detachIfNotReady(key: PaneKey(server: server, paneID: paneID), generation: generation)
    }

    private func drain(serverName: String, connection: TmuxControlConnection) async {
        let client = commandClients[serverName]
        for await event in connection.events {
            // Command reply blocks stop at the correlator; keep the one-line
            // summary log for diagnostics. Everything else logs as before.
            log(event, serverName: serverName)
            switch event {
            case .commandSucceeded, .commandFailed:
                await client?.handle(event)
            default:
                break
            }
        }
        connections[serverName] = nil
        commandClients[serverName] = nil
        await client?.connectionClosed()  // fail any pending sends
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
