import Foundation
import os

/// Tracks at most one `TmuxControlConnection` per tmux server and drains its
/// events into the log. Phase 1's control-mode path is observation-only:
/// nothing is rendered and no FDs are vended.
actor TmuxControlSupervisor {
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")
    private var connections: [String: TmuxControlConnection] = [:]
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
        Task { [weak self] in
            await self?.drain(serverName: serverName, connection: connection)
        }
    }

    /// Stop every connection. Call on daemon shutdown.
    func stopAll() {
        for connection in connections.values { connection.stop() }
        connections.removeAll()
        fanout.closeAll()
    }

    /// Allocate a per-pane pipe in the fanout and return the read end for the
    /// RPC layer to vend. The sink starts NOT ready — writes stay gated until
    /// the app acks with `attach.ready`.
    func attach(server: String, paneID: String) throws -> Int32 {
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
    func detachIfNotReady(server: String, paneID: String) {
        let key = PaneKey(server: server, paneID: paneID)
        if !fanout.isReady(key: key) { fanout.detach(key: key) }
    }

    private func drain(serverName: String, connection: TmuxControlConnection) async {
        for await event in connection.events {
            log(event, serverName: serverName)
        }
        connections[serverName] = nil
        logger.info("tmux -CC event stream ended for \(serverName, privacy: .public)")
    }

    private func log(_ event: TmuxControlEvent, serverName: String) {
        let tag = "[\(serverName)]"
        switch event {
        case .output(let pane, let bytes):
            logger.debug("\(tag, privacy: .public) %output \(pane, privacy: .public) \(bytes.count) bytes")
        case .extendedOutput(let pane, let age, let bytes):
            logger.debug("\(tag, privacy: .public) %extended-output \(pane, privacy: .public) age=\(age)ms \(bytes.count) bytes")
        case .commandSucceeded(let number, let lines):
            logger.debug("\(tag, privacy: .public) %end #\(number) \(lines.count) lines")
        case .commandFailed(let number, let lines):
            logger.error("\(tag, privacy: .public) %error #\(number) \(lines.count) lines")
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
