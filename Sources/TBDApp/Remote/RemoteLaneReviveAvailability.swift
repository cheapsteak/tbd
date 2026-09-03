import Foundation
import TBDShared

/// Whether an archived remote lane can still be revived, and what to say when
/// it cannot
/// (`docs/specs/2026-09-02-remote-session-delete-and-transcript-exchange-design.md`,
/// "A deleted lane keeps its place").
///
/// A lane whose remote session was destroyed keeps its row, and Revive on that
/// row means creating a new session seeded from the transcript the delete
/// retained. Past the provider's stated expiry there is nothing to seed from,
/// so Revive is disabled and names the date — and the row stays, because a lane
/// whose conversation lapsed is still a record of work that happened.
///
/// Pure, with no AppKit or SwiftUI and no `AppState`, so every branch is
/// testable directly — the same split `RemoteSessionActionMenu` and
/// `RemoteDeleteConfirmation` use. The daemon makes the same decision
/// authoritatively in `RemoteLaneLifecycle.reseedPlan`; this exists so the
/// button is disabled before it is pressed rather than only refused after.
enum RemoteLaneReviveAvailability {
    enum Decision: Equatable {
        case enabled
        /// Disabled, with the sentence to show as help text.
        case expired(String)
    }

    /// - Parameters:
    ///   - worktree: the archived row the Revive button belongs to.
    ///   - receipts: every receipt the daemon holds (`AppState.retainedTranscripts`).
    ///   - now: the date seam. `expiresAt` is a persisted timestamp compared
    ///     against the present, never a duration.
    ///
    /// A local lane, a remote lane with no receipt, and a remote lane whose
    /// receipt states no expiry are all `.enabled`. **An absent `expiresAt` is
    /// never read as permanence** — the contract makes that a MUST NOT for
    /// callers — but it is equally not a reason to disable anything: the
    /// provider has made no claim, and the provider is the last word on whether
    /// the seed still works.
    static func decide(
        worktree: Worktree, receipts: [RetainedTranscript], now: Date
    ) -> Decision {
        guard !worktree.location.isLocal else { return .enabled }
        // Newest first, matching the daemon's own choice: a lane retained more
        // than once wants the last word on its conversation.
        let receipt = receipts
            .filter { $0.originWorktreeID == worktree.id }
            .max { $0.createdAt < $1.createdAt }
        guard let receipt, receipt.hasExpired(asOf: now), let expiresAt = receipt.expiresAt else {
            return .enabled
        }
        return .expired(
            "The transcript retained from this lane's session expired on " +
            "\(RetainReceipt.formatTimestamp(expiresAt)), so there is nothing left to " +
            "recreate the conversation from. The row stays as a record of the work.")
    }
}
