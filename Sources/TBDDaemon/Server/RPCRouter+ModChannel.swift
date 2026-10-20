import Foundation
import TBDShared

/// The session-mod channel's ties to the router's state
/// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`, "The
/// channel"). The daemon builds its routes and disconnect sweep here so they
/// share the router's prompt store and publish through the same broadcast as
/// every other mutation of it.
extension RPCRouter {
    /// The channel's routes over this router's prompt store:
    /// - `incarnationOf` reads the terminal row's `sessionIncarnationID`, the
    ///   incarnation a fresh spawn's token is minted for, so a process that
    ///   outlived its row is refused;
    /// - `promptAnswerEnabled` reads `config.transcriptPromptAnswerEnabled`
    ///   per request, so a toggle takes effect without a restart (a failed
    ///   read counts as off);
    /// - `broadcast` publishes each changed terminal's pending set.
    func makeModChannelRoutes(channel: ModChannel, token: ModChannelToken) -> ModChannelRoutes {
        let db = self.db
        return ModChannelRoutes(
            channel: channel,
            store: pendingQuestions,
            token: token,
            incarnationOf: { terminalID in
                (try? await db.terminals.get(id: terminalID))?.sessionIncarnationID
            },
            promptAnswerEnabled: {
                (try? await db.config.get().transcriptPromptAnswerEnabled) ?? false
            },
            broadcast: { [weak self] terminals in
                await self?.broadcastPendingPrompts(terminals: terminals)
            })
    }

    /// The disconnect sweep over this router's prompt store, publishing each
    /// terminal it clears.
    func makeModDisconnectSweep(channel: ModChannel) -> ModDisconnectSweep {
        ModDisconnectSweep(
            channel: channel,
            store: pendingQuestions,
            broadcast: { [weak self] terminals in
                await self?.broadcastPendingPrompts(terminals: terminals)
            })
    }
}
