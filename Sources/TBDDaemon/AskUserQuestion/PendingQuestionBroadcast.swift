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
    func broadcastPendingQuestions(
        terminalID: UUID,
        from store: PendingQuestionStore
    ) async {
        let entries = await store.entries(forTerminal: terminalID)
        broadcast(delta: .terminalPendingQuestionsChanged(
            TerminalPendingQuestionsDelta(
                terminalID: terminalID,
                pending: entries.map {
                    PendingQuestionPayload(
                        toolUseID: $0.toolUseID,
                        inputJSON: $0.inputJSON,
                        timestamp: $0.timestamp)
                })))
    }
}
