import Foundation
import TBDShared

extension StateSubscriptionManager {
    /// Publish a terminal's current pending set: the legacy `AskUserQuestion`
    /// captures and the open prompts, in one `.terminalPendingPromptsChanged`.
    /// The daemon no longer sends `.terminalPendingQuestionsChanged`; the
    /// case stays decodable for an app paired with an older daemon.
    ///
    /// Every site that mutates `PendingPromptStore` owes the app one of
    /// these. The app mirrors the record rather than deriving it, so a set
    /// cleared without a retraction leaves an answered question rendering
    /// forever — the same failure `broadcastAwaitingInputRetraction` exists to
    /// avoid. It lives on the subscription manager rather than on one owner
    /// because the mutating sites are split between `RPCRouter` and
    /// `WorktreeLifecycle`, and both hold this.
    ///
    /// The set is read together with its revision in one actor call, and the
    /// revision rides the delta. Reading them separately would let a
    /// suspension between the two publish a set under someone else's stamp;
    /// carrying the stamp is what lets the app drop a delta that lost the race
    /// between the mutation and the send — the mutation and the send are two
    /// hops, and the actor orders only the first.
    func broadcastPendingPrompts(
        terminalID: UUID,
        from store: PendingPromptStore
    ) async {
        let delta = await Self.pendingPromptsDelta(terminalID: terminalID, from: store)
        broadcast(delta: delta)
    }

    /// Send a new subscriber the pending set of every terminal that holds a
    /// capture or an open prompt, one delta per terminal, to that subscriber
    /// only. Without it a freshly connected app shows no cards until the next
    /// change to each terminal's set
    /// (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`,
    /// "Snapshot"). Each delta carries its revision, so one that races a
    /// concurrent broadcast is ordered by the app like any other.
    func replayPendingPrompts(
        to subscriber: SubscriberID,
        from store: PendingPromptStore
    ) async {
        for terminalID in await store.terminalsWithPendingState() {
            let delta = await Self.pendingPromptsDelta(terminalID: terminalID, from: store)
            send(delta: delta, to: subscriber)
        }
    }

    private static func pendingPromptsDelta(
        terminalID: UUID,
        from store: PendingPromptStore
    ) async -> StateDelta {
        let snapshot = await store.snapshot(forTerminal: terminalID)
        return .terminalPendingPromptsChanged(
            TerminalPendingPromptsDelta(
                terminalID: terminalID,
                captures: snapshot.entries.map {
                    PendingQuestionPayload(
                        toolUseID: $0.toolUseID,
                        inputJSON: $0.inputJSON,
                        timestamp: $0.timestamp)
                },
                prompts: snapshot.prompts,
                revision: snapshot.revision))
    }
}
