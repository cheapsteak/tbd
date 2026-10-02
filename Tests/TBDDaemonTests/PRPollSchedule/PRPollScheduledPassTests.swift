import Foundation
import os
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// `RPCRouter.runScheduledPass` end to end over `PRPollLegsHarness`: what a
/// due set asks `gh`, what it writes back, and what the next reconcile makes
/// of it. Spec: docs/specs/2026-10-01-pr-polling-schedule-design.md.
@Suite("PRPollScheduledPass", .serialized)
struct PRPollScheduledPassTests {
    /// "Two worktrees on one PR produce one query and two updates."
    @Test func twoOwnersOneQueryTwoUpdates() async throws {
        let h = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .pending), (wt: 1, number: 7, state: .pending)],
            responses: [7: "MERGEABLE_CLEAN"])
        await h.router.runScheduledPass(PRPollDue(discover: [], track: [h.key(7)]))
        #expect(await h.gh.numberedQueries().count == 1)
        #expect(await h.gh.branchQueries().isEmpty)
        #expect(try await h.bindingState(wt: 0, number: 7) == .mergeable)
        #expect(try await h.bindingState(wt: 1, number: 7) == .mergeable)
    }

    /// "Coincident items in one repo go out as one query."
    @Test func coincidentKeysInOneRepoAreOneQuery() async throws {
        let h = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .pending), (wt: 1, number: 8, state: .blocked)],
            responses: [7: "MERGEABLE_CLEAN", 8: "MERGEABLE_CLEAN"])
        await h.router.runScheduledPass(PRPollDue(discover: [], track: [h.key(7), h.key(8)]))
        let queries = await h.gh.numberedQueries()
        #expect(queries.count == 1)
        #expect(queries.first.map {
            $0.contains("pullRequest(number: 7)") && $0.contains("pullRequest(number: 8)")
        } == true)
    }

    /// A key that is not due is neither asked nor written.
    @Test func aKeyNotDueIsNotAsked() async throws {
        let h = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .pending), (wt: 1, number: 8, state: .blocked)],
            responses: [7: "MERGEABLE_CLEAN", 8: "MERGEABLE_CLEAN"])
        await h.router.runScheduledPass(PRPollDue(discover: [], track: [h.key(7)]))
        let queries = await h.gh.numberedQueries()
        #expect(queries.count == 1)
        #expect(queries.first?.contains("pullRequest(number: 8)") == false)
        #expect(try await h.bindingState(wt: 1, number: 8) == .blocked)
    }

    @Test func mergedResultLeavesTheSchedule() async throws {
        let h = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .pending)], responses: [7: "MERGED"])
        await h.router.runScheduledPass(PRPollDue(discover: [], track: [h.key(7)]))
        #expect(try await h.bindingState(wt: 0, number: 7) == .merged)
        var schedule = PRPollSchedule()
        schedule.reconcile(try #require(await h.router.pollScheduleFacts()), now: Date())
        #expect(schedule.tier(of: .track(h.key(7))) == nil)
        #expect(schedule.tier(of: .discover(h.worktreeID(0))) == nil)
    }

    /// Spec, "Closed": the same PR, open again — the same pass refreshes it by
    /// number, and from then on it is tracked on its tier.
    @Test func aClosedPRFoundOpenAgainReturnsToTracking() async throws {
        // The branch query returns PR 7 OPEN for the worktree whose binding says closed.
        let h = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .closed)], responses: [7: "MERGEABLE_CLEAN"],
            branchNodes: [7: "OPEN"])
        // Before the pass the active worktree's closed binding is in closed discovery.
        var before = PRPollSchedule()
        before.reconcile(try #require(await h.router.pollScheduleFacts()), now: Date())
        #expect(before.tier(of: .discover(h.worktreeID(0))) == .closedDiscovery)

        await h.router.runScheduledPass(PRPollDue(discover: [h.worktreeID(0)], track: []))
        #expect(await h.gh.branchQueries().count == 1)
        #expect(await h.gh.numberedQueries().count == 1)
        #expect(try await h.bindingState(wt: 0, number: 7) == .mergeable)
        var schedule = PRPollSchedule()
        schedule.reconcile(try #require(await h.router.pollScheduleFacts()), now: Date())
        #expect(schedule.tier(of: .track(h.key(7))) == .waiting)
        #expect(schedule.tier(of: .discover(h.worktreeID(0))) == nil)
    }

    /// Spec, "Closed": the same PR, still closed — the binding stays as it is
    /// and the branch stays in closed discovery.
    @Test func aClosedPRStillClosedStaysOnClosedDiscovery() async throws {
        let h = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .closed)], responses: [:], branchNodes: [7: "CLOSED"])
        await h.router.runScheduledPass(PRPollDue(discover: [h.worktreeID(0)], track: []))
        #expect(await h.gh.branchQueries().count == 1)
        #expect(await h.gh.numberedQueries().isEmpty)
        #expect(try await h.bindingState(wt: 0, number: 7) == .closed)
        var schedule = PRPollSchedule()
        schedule.reconcile(try #require(await h.router.pollScheduleFacts()), now: Date())
        #expect(schedule.tier(of: .discover(h.worktreeID(0))) == .closedDiscovery)
        #expect(schedule.tier(of: .track(h.key(7))) == nil)
    }

    /// A closed PR's branch is discovered by branch, never by its stored
    /// number: only the branch query names the newest PR for the branch.
    @Test func closedPRDiscoveryUsesTheBranchQuery() async throws {
        let h = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .closed)], responses: [:], provenanceNumbers: [0: 7])
        await h.router.runScheduledPass(PRPollDue(discover: [h.worktreeID(0)], track: []))
        #expect(await h.gh.branchQueries().count == 1)
        #expect(await h.gh.numberedQueries().allSatisfy { !$0.contains("pullRequest(number: 7)") })
    }

    /// The branch-facts cache is pruned against the whole fleet at most once
    /// an hour: the first pass prunes and stamps, the next one inside the hour
    /// leaves the stamp alone.
    @Test func theFullPruneRunsAtMostHourly() async throws {
        let h = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .pending)], responses: [7: "MERGEABLE_CLEAN"])
        #expect(h.router.lastFullPrune.withLock { $0 } == nil)
        await h.router.runScheduledPass(PRPollDue(discover: [], track: [h.key(7)]))
        let first = h.router.lastFullPrune.withLock { $0 }
        #expect(first != nil)
        await h.router.runScheduledPass(PRPollDue(discover: [], track: [h.key(7)]))
        #expect(h.router.lastFullPrune.withLock { $0 } == first)
    }

    /// The old loop is untouched: `runPollPass` still refreshes every binding.
    @Test func theLegacyPassStillRuns() async throws {
        let h = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .pending)], responses: [7: "MERGEABLE_CLEAN"])
        try await h.router.runPollPass()
        #expect(try await h.bindingState(wt: 0, number: 7) == .mergeable)
        #expect(h.router.lastFullPrune.withLock { $0 } == nil)
    }
}
