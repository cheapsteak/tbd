import Foundation
import os
import TBDShared

private let modChannelLog = Logger(subsystem: "com.tbd.daemon", category: "modChannel")

extension Daemon {
    /// Starts the session-mod channel: the listener on
    /// `TBDConstants.modSocketPath` and the disconnect sweep beside it
    /// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`, "The
    /// channel").
    ///
    /// Never throws. A key that cannot be loaded or a socket that cannot be
    /// bound logs at `.error` and leaves both unset: the daemon keeps running,
    /// and dialogs are answered in the terminal as with the feature off.
    func startModChannel(router: RPCRouter) async {
        // The same token spawns mint their sessions' credentials from, so the
        // two always agree on the key.
        guard let token = ModChannelToken.shared else {
            modChannelLog.error(
                "mod channel not started: the channel key could not be loaded")
            return
        }
        let channel = ModChannel()
        let socketPath = TBDConstants.modSocketPath
        let server = ModChannelServer(
            socketPath: socketPath,
            routes: router.makeModChannelRoutes(channel: channel, token: token))
        do {
            try await server.start()
        } catch {
            modChannelLog.error("""
                mod channel not started: binding \(socketPath, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """)
            // Releases the server's event loop group.
            await server.stop()
            return
        }
        modChannelServer = server

        let sweep = router.makeModDisconnectSweep()
        modDisconnectSweep = sweep
        await sweep.start()
    }
}
