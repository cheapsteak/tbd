import Foundation
import TBDShared

/// Relays "this pending `AskUserQuestion` is now in the JSONL" from the app's
/// own transcript reader back to the daemon, at most once per capture.
///
/// `AskUserQuestionMerger.merge` reports satisfied ids on *every* publish, and
/// with `appSideTranscriptRead` on that is roughly once per poll tick for as
/// long as the pane is open. The daemon's clear is idempotent, but the RPC and
/// the `terminalPendingQuestionsChanged` delta it broadcasts are not free, so
/// an id already reported is dropped here rather than re-sent.
///
/// The `send` closure is the seam: production wires it to
/// `DaemonClient.terminalAskUserQuestionSatisfied`, tests substitute a
/// recorder and assert on what a merge result actually asked for.
actor AskUserQuestionSatisfactionReporter {
    /// Ids already reported, per terminal. Bounded by the caller's pending set
    /// on every call — see `report(terminalID:pendingToolUseIDs:...)` — so it
    /// cannot outgrow the daemon's own store.
    private var reported: [UUID: Set<String>] = [:]
    private let send: @Sendable (UUID, [String]) async -> Void

    init(send: @escaping @Sendable (UUID, [String]) async -> Void) {
        self.send = send
    }

    /// Reports whichever of `satisfiedToolUseIDs` has not been reported yet.
    ///
    /// `pendingToolUseIDs` is the capture set the merge ran against. Memory of
    /// anything outside it is dropped first: an id the daemon no longer holds
    /// can never be reported again, and keeping it would leave this actor
    /// growing for the life of the app. It also means a capture the daemon
    /// re-raised under the same id — a fresh question after an expiry reap —
    /// is reportable again.
    func report(
        terminalID: UUID,
        pendingToolUseIDs: Set<String>,
        satisfiedToolUseIDs: [String]
    ) async {
        var already = (reported[terminalID] ?? []).intersection(pendingToolUseIDs)
        let fresh = satisfiedToolUseIDs.filter { !already.contains($0) }
        guard !fresh.isEmpty else {
            if already.isEmpty {
                reported.removeValue(forKey: terminalID)
            } else {
                reported[terminalID] = already
            }
            return
        }
        already.formUnion(fresh)
        reported[terminalID] = already
        await send(terminalID, fresh)
    }
}
