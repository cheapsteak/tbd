import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// `RemoteLaneLifecycle.reseedPlan` — what Revive means for an archived remote
/// lane
/// (`docs/specs/2026-09-02-remote-session-delete-and-transcript-exchange-design.md`,
/// "A deleted lane keeps its place").
///
/// Tier 1: a pure function over a receipt, a boolean, a capability set and a
/// date. No provider, no database, no clock — expiry is a persisted timestamp
/// compared against a `Date` that is passed in, which is the date seam.
@Suite("RemoteLaneLifecycle reseed")
struct RemoteLaneReseedTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func receipt(
        key: String = "opaque-key", expiresAt: Date? = nil, lane: UUID? = nil
    ) -> RetainedTranscript {
        RetainedTranscript(
            provider: "agentbox", key: key, expiresAt: expiresAt, bytes: 42,
            originWorktreeID: lane)
    }

    // MARK: - A receipt and no session: reseed

    @Test("a receipt and no listed session reseeds from its key")
    func receiptWithNoListedSessionReseeds() {
        let plan = RemoteLaneLifecycle.reseedPlan(
            receipt: receipt(), sessionStillListed: false,
            capabilities: ["seed"], now: now)
        #expect(plan == .reseed(key: "opaque-key"))
    }

    /// An absent `expires_at` is the provider declining to say, never a promise
    /// of permanence — but it is equally not a reason to refuse. The provider
    /// is the last word on whether the seed still works.
    @Test("an unstated expiry does not stand in the way of a reseed")
    func unstatedExpiryStillReseeds() {
        let plan = RemoteLaneLifecycle.reseedPlan(
            receipt: receipt(expiresAt: nil), sessionStillListed: false,
            capabilities: ["seed"], now: now)
        #expect(plan == .reseed(key: "opaque-key"))
    }

    @Test("an expiry still in the future reseeds")
    func futureExpiryReseeds() {
        let plan = RemoteLaneLifecycle.reseedPlan(
            receipt: receipt(expiresAt: now.addingTimeInterval(3600)),
            sessionStillListed: false, capabilities: ["seed"], now: now)
        #expect(plan == .reseed(key: "opaque-key"))
    }

    // MARK: - Past the expiry: refused, naming the date

    @Test("a lapsed receipt refuses and names the date")
    func lapsedReceiptRefusesNamingTheDate() throws {
        let expiresAt = now.addingTimeInterval(-3600)
        let plan = RemoteLaneLifecycle.reseedPlan(
            receipt: receipt(expiresAt: expiresAt), sessionStillListed: false,
            capabilities: ["seed"], now: now)
        guard case .expired(let message) = plan else {
            Issue.record("expected .expired, got \(plan)")
            return
        }
        // Asserted on the composed sentence rather than on the case alone: the
        // date IS the finding, and a refusal that omitted it would leave the
        // user with no way to tell a lapsed record from a broken one.
        #expect(message.contains(RetainReceipt.formatTimestamp(expiresAt)))
    }

    /// The boundary is inclusive — a receipt expiring exactly now has expired,
    /// matching `RetainedTranscript.hasExpired(asOf:)` and the store's own
    /// `expires_at <= ?` sweep, so the three cannot disagree about one instant.
    @Test("an expiry exactly at now has lapsed")
    func expiryAtNowHasLapsed() {
        let plan = RemoteLaneLifecycle.reseedPlan(
            receipt: receipt(expiresAt: now), sessionStillListed: false,
            capabilities: ["seed"], now: now)
        #expect(plan != .reseed(key: "opaque-key"))
    }

    // MARK: - No seed capability

    /// Refused by name rather than attempted: the contract has providers ignore
    /// stdin fields they do not recognize, so an unchecked reseed would return
    /// an empty session wearing a revived lane's name.
    @Test("a provider that does not declare seed refuses, naming the capability")
    func undeclaredSeedRefusesNamingIt() {
        let plan = RemoteLaneLifecycle.reseedPlan(
            receipt: receipt(), sessionStillListed: false,
            capabilities: ["unarchive", "archive"], now: now)
        guard case .refusedNoSeed(let message) = plan else {
            Issue.record("expected .refusedNoSeed, got \(plan)")
            return
        }
        #expect(message.contains("seed"))
    }

    /// Expiry is checked before the capability, so a lane whose transcript
    /// lapsed is told the transcript lapsed — the fact that actually explains
    /// why nothing can be done — rather than being sent to ask its provider for
    /// a capability that would not help.
    @Test("a lapsed receipt reports the expiry rather than the missing capability")
    func lapsedReceiptBeatsMissingCapability() {
        let plan = RemoteLaneLifecycle.reseedPlan(
            receipt: receipt(expiresAt: now.addingTimeInterval(-1)),
            sessionStillListed: false, capabilities: [], now: now)
        guard case .expired = plan else {
            Issue.record("expected .expired to win over .refusedNoSeed, got \(plan)")
            return
        }
    }

    // MARK: - Everything else keeps today's behavior

    @Test("no receipt keeps the ordinary unarchive path")
    func noReceiptKeepsUnarchive() {
        let plan = RemoteLaneLifecycle.reseedPlan(
            receipt: nil, sessionStillListed: false, capabilities: ["seed"], now: now)
        #expect(plan == .unarchive)
    }

    /// The discriminating case, and the reason `sessionStillListed` exists.
    /// `tbd remote retain` on a healthy session leaves a receipt behind, and
    /// reviving *that* lane must still be an `unarchive` — a receipt alone
    /// never means the session was destroyed.
    @Test("a receipt on a session the provider still lists keeps unarchive")
    func receiptOnALiveSessionKeepsUnarchive() {
        let plan = RemoteLaneLifecycle.reseedPlan(
            receipt: receipt(), sessionStillListed: true,
            capabilities: ["seed"], now: now)
        #expect(plan == .unarchive)
    }

    /// And a lapsed receipt on a live session is still just an unarchive: the
    /// session is right there, so no transcript is needed to reach it.
    @Test("a lapsed receipt on a listed session keeps unarchive")
    func lapsedReceiptOnALiveSessionKeepsUnarchive() {
        let plan = RemoteLaneLifecycle.reseedPlan(
            receipt: receipt(expiresAt: now.addingTimeInterval(-3600)),
            sessionStillListed: true, capabilities: ["seed"], now: now)
        #expect(plan == .unarchive)
    }
}

/// `RetainedTranscriptStore.latest(originWorktreeID:)` — the lookup Revive uses
/// to find the transcript a deleted lane left behind.
///
/// Tier 2: in-memory GRDB, no provider.
@Suite("RetainedTranscriptStore origin lookup")
struct RetainedTranscriptOriginLookupTests {
    @Test func findsTheNewestReceiptForALane() async throws {
        let db = try TBDDatabase(inMemory: true)
        let lane = UUID()
        let other = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.retainedTranscripts.insert(RetainedTranscript(
            provider: "agentbox", key: "older", bytes: 1,
            originWorktreeID: lane, createdAt: base))
        try await db.retainedTranscripts.insert(RetainedTranscript(
            provider: "agentbox", key: "newer", bytes: 2,
            originWorktreeID: lane, createdAt: base.addingTimeInterval(60)))
        try await db.retainedTranscripts.insert(RetainedTranscript(
            provider: "agentbox", key: "someone-elses", bytes: 3,
            originWorktreeID: other, createdAt: base.addingTimeInterval(120)))

        let found = try await db.retainedTranscripts.latest(originWorktreeID: lane)
        #expect(found?.key == "newer")
    }

    @Test func findsNothingForALaneWithNoReceipt() async throws {
        let db = try TBDDatabase(inMemory: true)
        try await db.retainedTranscripts.insert(RetainedTranscript(
            provider: "agentbox", key: "unattached", bytes: 1))
        let found = try await db.retainedTranscripts.latest(originWorktreeID: UUID())
        #expect(found == nil)
    }
}
