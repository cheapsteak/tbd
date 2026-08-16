import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// The stale-snapshot watermark, from the gesture side
/// (`docs/specs/2026-08-16-remote-lane-archive-design.md` §"Stale snapshots").
///
/// Tier 1: in-memory GRDB, a scripted fake provider, a real actuation log in a
/// temp directory, and every timestamp passed in explicitly. Nothing sleeps —
/// the rule under test is an ordering between `Date`s, and wall time would
/// only make it slower and flakier.
///
/// The property these tests exist for: **a gesture's watermark must cover the
/// moment its row was written, not the moment the gesture began.** A verb takes
/// real time, and a poll launched during it carries the provider's pre-gesture
/// word; a watermark stamped only at the start lets that response through the
/// gate and reverses the row the user just filed.
@Suite("Remote lane filing watermark")
struct RemoteLaneWatermarkTests {

    /// A `now` seam that hands out the given instants in order, then repeats
    /// the last one. Deliberately explicit rather than a monotonic `Date()`:
    /// the assertion is *which* instant was recorded, and a real clock cannot
    /// tell the pre-verb stamp from the post-write one.
    private final class Instants: @unchecked Sendable {
        private let values: [Date]
        private var index = 0
        private let lock = NSLock()
        init(_ values: [Date]) { self.values = values }
        var next: @Sendable () -> Date {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                let value = values[min(index, values.count - 1)]
                index += 1
                return value
            }
        }
    }

    private static func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + seconds)
    }

    private static let archived = providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#)
    private static let unarchived = providerOK(#"{"id": "sess-1", "state": "running", "archived": false}"#)
    private static let unreachable = ProviderResult(
        exitCode: 1,
        stdout: Data(#"{"error": {"code": "unreachable", "message": "host is down"}}"#.utf8),
        stderr: "")

    // MARK: - The gesture paths re-stamp after the row write

    @Test("archive stamps the watermark again once the row is written")
    func archiveRestampsAfterTheRowWrite() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"], verbs: [Self.archived], tag: "watermark-archive-restamp")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        // Gesture at T0; the verb runs; the row lands at T10.
        let clock = Instants([Self.at(0), Self.at(10), Self.at(11)])

        let failure = try await fixture.lanes().performArchive(
            .invokeVerb(provider: "fake", sessionID: "sess-1"), worktree: lane, now: clock.next)

        #expect(failure == nil)
        #expect(try await fixture.status(of: lane) == .archived)
        let recorded = try #require(await fixture.manager.filingDecision(for: lane.id))
        #expect(
            recorded == Self.at(10),
            "the watermark stopped at the gesture's start, so a poll launched during the verb still passes the gate")
    }

    @Test("revive stamps the watermark again once the row is written")
    func reviveRestampsAfterTheRowWrite() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive", "unarchive"], verbs: [Self.unarchived],
            tag: "watermark-revive-restamp")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: true)
        let clock = Instants([Self.at(0), Self.at(10), Self.at(11)])

        let failure = try await fixture.lanes().performRevive(
            .invokeUnarchive(provider: "fake", sessionID: "sess-1"), worktree: lane, now: clock.next)

        #expect(failure == nil)
        #expect(try await fixture.status(of: lane) == .active)
        let recorded = try #require(await fixture.manager.filingDecision(for: lane.id))
        #expect(recorded == Self.at(10))
    }

    /// The scenario in full, with the sync driven for real: the user archives
    /// at T0, a poll launched at T5 (while the verb was still running) returns
    /// the provider's pre-archive `archived: false`, and lands at T20. Only a
    /// watermark covering the row write at T10 refuses it.
    @Test("a poll launched during the archive verb cannot un-file the row")
    func pollLaunchedDuringTheVerbDoesNotUnfileTheRow() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"], verbs: [Self.archived], tag: "watermark-archive-race")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        let clock = Instants([Self.at(0), Self.at(10), Self.at(11)])

        _ = try await fixture.lanes().performArchive(
            .invokeVerb(provider: "fake", sessionID: "sess-1"), worktree: lane, now: clock.next)
        #expect(try await fixture.status(of: lane) == .archived)

        try await fixture.manager.apply(
            snapshot: [RemoteSessionPayload(id: "sess-1", state: .running, archived: false)],
            provider: "fake", now: Self.at(20), requestStartedAt: Self.at(5))

        #expect(
            try await fixture.status(of: lane) == .archived,
            "the stale poll returned the row the user just archived")
    }

    /// The mirror image: revive at T0, a poll launched at T5 carrying the
    /// provider's pre-revive `archived: true`, arriving at T20.
    @Test("a poll launched during the unarchive verb cannot re-file the row")
    func pollLaunchedDuringTheVerbDoesNotRefileTheRow() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive", "unarchive"], verbs: [Self.unarchived],
            tag: "watermark-revive-race")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: true)
        let clock = Instants([Self.at(0), Self.at(10), Self.at(11)])

        _ = try await fixture.lanes().performRevive(
            .invokeUnarchive(provider: "fake", sessionID: "sess-1"), worktree: lane, now: clock.next)
        #expect(try await fixture.status(of: lane) == .active)

        try await fixture.manager.apply(
            snapshot: [RemoteSessionPayload(id: "sess-1", state: .running, archived: true)],
            provider: "fake", now: Self.at(20), requestStartedAt: Self.at(5))

        #expect(
            try await fixture.status(of: lane) == .active,
            "the stale poll re-filed the row the user just revived")
    }

    // MARK: - The map is monotonic

    @Test("an older instant never displaces a newer watermark")
    func noteIsMonotonic() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: [], tag: "watermark-monotonic")
        defer { fixture.cleanup() }
        let id = UUID()

        await fixture.manager.noteFilingDecision(worktreeID: id, at: Self.at(20))
        await fixture.manager.noteFilingDecision(worktreeID: id, at: Self.at(5))

        #expect(
            await fixture.manager.filingDecision(for: id) == Self.at(20),
            "a late-arriving older stamp moved the watermark backwards")
    }

    @Test("a newer instant still advances the watermark")
    func noteAdvances() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: [], tag: "watermark-advance")
        defer { fixture.cleanup() }
        let id = UUID()

        await fixture.manager.noteFilingDecision(worktreeID: id, at: Self.at(5))
        await fixture.manager.noteFilingDecision(worktreeID: id, at: Self.at(20))

        #expect(await fixture.manager.filingDecision(for: id) == Self.at(20))
    }

    // MARK: - Withdrawal restores rather than deletes

    @Test("withdrawing a failed decision puts the prior watermark back")
    func withdrawRestoresThePrior() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: [], tag: "watermark-withdraw")
        defer { fixture.cleanup() }
        let id = UUID()

        await fixture.manager.noteFilingDecision(worktreeID: id, at: Self.at(5))
        let prior = await fixture.manager.noteFilingDecision(worktreeID: id, at: Self.at(20))
        #expect(prior == Self.at(5))
        await fixture.manager.withdrawFilingDecision(
            worktreeID: id, restoring: prior, ifStillAt: Self.at(20))

        #expect(
            await fixture.manager.filingDecision(for: id) == Self.at(5),
            "a later failed verb destroyed an earlier legitimate filing decision")
    }

    @Test("withdrawal leaves a decision another path made in the meantime alone")
    func withdrawDefersToANewerDecision() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: [], tag: "watermark-withdraw-newer")
        defer { fixture.cleanup() }
        let id = UUID()

        let prior = await fixture.manager.noteFilingDecision(worktreeID: id, at: Self.at(5))
        // Another path files this row while the verb is out.
        await fixture.manager.noteFilingDecision(worktreeID: id, at: Self.at(30))
        await fixture.manager.withdrawFilingDecision(
            worktreeID: id, restoring: prior, ifStillAt: Self.at(5))

        #expect(await fixture.manager.filingDecision(for: id) == Self.at(30))
    }

    /// End to end through `performArchive`: a lane that already carries a
    /// legitimate watermark from an earlier decision, whose verb then fails,
    /// must keep it.
    @Test("a failing archive verb does not destroy an earlier watermark")
    func failingVerbKeepsTheEarlierWatermark() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"], verbs: [Self.unreachable], tag: "watermark-verb-failure")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        await fixture.manager.noteFilingDecision(worktreeID: lane.id, at: Self.at(1))

        let failure = try await fixture.lanes().performArchive(
            .invokeVerb(provider: "fake", sessionID: "sess-1"), worktree: lane,
            now: Instants([Self.at(5), Self.at(10), Self.at(11)]).next)

        #expect(failure == "host is down")
        #expect(try await fixture.status(of: lane) == .active)
        #expect(
            await fixture.manager.filingDecision(for: lane.id) == Self.at(1),
            "the failed verb dropped a watermark an earlier decision had legitimately left")
    }

    // MARK: - The row write can fail too

    /// The verb succeeds and the DB write throws. The watermark was recorded
    /// for a filing that never happened, so it has to come back off — the same
    /// treatment the verb-failure path gets, on the path that was left out.
    @Test("a failing row write withdraws the watermark it recorded")
    func failingRowWriteWithdrawsTheWatermark() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"], verbs: [Self.archived], tag: "watermark-db-failure")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        // Deleting the row makes `db.worktrees.archive` throw "Worktree not
        // found" — a DB failure arriving after the verb already succeeded.
        try await fixture.db.worktrees.delete(id: lane.id)

        await #expect(throws: (any Error).self) {
            _ = try await fixture.lanes().performArchive(
                .invokeVerb(provider: "fake", sessionID: "sess-1"), worktree: lane,
                now: Instants([Self.at(5), Self.at(10), Self.at(11)]).next)
        }

        #expect(
            await fixture.manager.filingDecision(for: lane.id) == nil,
            "a watermark survives for a filing that never happened, suppressing real snapshots for two poll intervals")
    }

    @Test("a failing revive row write withdraws the watermark it recorded")
    func failingReviveRowWriteWithdrawsTheWatermark() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive", "unarchive"], verbs: [Self.unarchived],
            tag: "watermark-db-failure-revive")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: true)
        try await fixture.db.worktrees.delete(id: lane.id)

        await #expect(throws: (any Error).self) {
            _ = try await fixture.lanes().performRevive(
                .invokeUnarchive(provider: "fake", sessionID: "sess-1"), worktree: lane,
                now: Instants([Self.at(5), Self.at(10), Self.at(11)]).next)
        }

        #expect(await fixture.manager.filingDecision(for: lane.id) == nil)
    }
}
