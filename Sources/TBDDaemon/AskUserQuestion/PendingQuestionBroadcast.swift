import Foundation
import TBDShared

extension StateSubscriptionManager {
    /// Publish a terminal's current pending-question set.
    ///
    /// Every site that mutates `PendingQuestionStore` owes the app one of
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
    func broadcastPendingQuestions(
        terminalID: UUID,
        from store: PendingQuestionStore
    ) async {
        let snapshot = await store.snapshot(forTerminal: terminalID)
        broadcast(delta: .terminalPendingQuestionsChanged(
            TerminalPendingQuestionsDelta(
                terminalID: terminalID,
                pending: snapshot.entries.map {
                    PendingQuestionPayload(
                        toolUseID: $0.toolUseID,
                        inputJSON: $0.inputJSON,
                        timestamp: $0.timestamp)
                },
                revision: snapshot.revision)))
    }
}
