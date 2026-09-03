import Testing
import Foundation
@testable import TBDApp
@testable import TBDShared

/// `RemoteLaneReviveAvailability` — whether the archived list's Revive button
/// is still good for a remote lane whose session was destroyed.
///
/// Tier 1: a pure function over a worktree, a receipt list and a `Date`. The
/// daemon decides the same thing authoritatively
/// (`RemoteLaneLifecycle.reseedPlan`); this is what disables the button before
/// it is pressed rather than only refusing afterwards.
@Suite("RemoteLaneReviveAvailability")
struct RemoteLaneReviveAvailabilityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let laneID = UUID()

    private func lane(location: WorktreeLocation) -> Worktree {
        Worktree(
            id: laneID, repoID: UUID(), name: "agentbox-probe",
            displayName: "probe", branch: "acme-branch", path: "",
            status: .archived, tmuxServer: "", location: location)
    }

    private var remoteLane: Worktree {
        lane(location: .remote(provider: "agentbox", sessionID: "probe"))
    }

    private func receipt(
        expiresAt: Date?, lane: UUID?, createdAt: Date = Date(timeIntervalSince1970: 1)
    ) -> RetainedTranscript {
        RetainedTranscript(
            provider: "agentbox", key: "opaque-key", expiresAt: expiresAt, bytes: 7,
            originWorktreeID: lane, createdAt: createdAt)
    }

    @Test func aLaneWithNoReceiptStaysRevivable() {
        let decision = RemoteLaneReviveAvailability.decide(
            worktree: remoteLane, receipts: [], now: now)
        #expect(decision == .enabled)
    }

    /// An absent `expires_at` is the provider declining to say. It is never
    /// rendered as permanence, and it is never a reason to disable anything.
    @Test func anUnstatedExpiryStaysRevivable() {
        let decision = RemoteLaneReviveAvailability.decide(
            worktree: remoteLane, receipts: [receipt(expiresAt: nil, lane: laneID)], now: now)
        #expect(decision == .enabled)
    }

    @Test func anUnexpiredReceiptStaysRevivable() {
        let decision = RemoteLaneReviveAvailability.decide(
            worktree: remoteLane,
            receipts: [receipt(expiresAt: now.addingTimeInterval(60), lane: laneID)],
            now: now)
        #expect(decision == .enabled)
    }

    @Test func aLapsedReceiptDisablesReviveAndNamesTheDate() {
        let expiresAt = now.addingTimeInterval(-60)
        let decision = RemoteLaneReviveAvailability.decide(
            worktree: remoteLane, receipts: [receipt(expiresAt: expiresAt, lane: laneID)],
            now: now)
        guard case .expired(let reason) = decision else {
            Issue.record("expected .expired, got \(decision)")
            return
        }
        #expect(reason.contains(RetainReceipt.formatTimestamp(expiresAt)))
    }

    /// Another lane's lapsed receipt must not disable this one — the receipts
    /// arrive as one flat list across every provider and every lane.
    @Test func someoneElsesLapsedReceiptDoesNotDisableThisLane() {
        let decision = RemoteLaneReviveAvailability.decide(
            worktree: remoteLane,
            receipts: [receipt(expiresAt: now.addingTimeInterval(-60), lane: UUID())],
            now: now)
        #expect(decision == .enabled)
    }

    /// A lane retained twice takes the newest word: an early receipt that has
    /// since lapsed must not disable a lane whose later retention is still good.
    @Test func theNewestReceiptWins() {
        let receipts = [
            receipt(expiresAt: now.addingTimeInterval(-600), lane: laneID,
                    createdAt: Date(timeIntervalSince1970: 1)),
            receipt(expiresAt: now.addingTimeInterval(600), lane: laneID,
                    createdAt: Date(timeIntervalSince1970: 100)),
        ]
        #expect(RemoteLaneReviveAvailability.decide(
            worktree: remoteLane, receipts: receipts, now: now) == .enabled)
    }

    /// A local worktree never consults a receipt at all — its revive is a git
    /// worktree being recreated, and nothing about a transcript bears on it.
    @Test func aLocalWorktreeIsNeverGatedByAReceipt() {
        let decision = RemoteLaneReviveAvailability.decide(
            worktree: lane(location: .local),
            receipts: [receipt(expiresAt: now.addingTimeInterval(-60), lane: laneID)],
            now: now)
        #expect(decision == .enabled)
    }
}
