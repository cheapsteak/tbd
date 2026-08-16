import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

// DEFECT UNDER TEST: "the forge answered, and this branch has no pull request"
// and "nobody could get an answer" used to be the same absence — a worktree
// missing from the fetch results, indistinguishable either way. A night spent
// treating an outage as a fleet with nothing open looks exactly like a calm
// night, and the old `PRRefreshResult` doc comment ("nil means no PR found")
// asserted the collapsed reading outright.
//
// Every test here therefore asserts the two are DIFFERENT, not merely that each
// is producible: an implementation that recorded `.none` for both would satisfy
// "records an observation" and still be the bug.

/// A `gh` stand-in whose viewer batch and by-number lookups can each be told to
/// succeed with given nodes, return no output at all, or return garbage.
/// `acme/acme-prod` is a placeholder, as everywhere in this suite.
private actor ScriptedGH {
    enum Answer: Sendable {
        /// Parsed successfully, with these PR nodes (possibly none).
        case nodes([String])
        /// gh produced nothing usable — the "could not ask" shape.
        case noOutput
        /// gh answered with something unparseable.
        case garbage
    }

    private var viewer: Answer
    private let byNumber: [Int: String]
    private let byNumberAnswer: Answer
    private let checkSignals: Answer

    init(viewer: Answer = .nodes([]),
         byNumber: [Int: String] = [:],
         byNumberAnswer: Answer = .nodes([]),
         checkSignals: Answer = .nodes([])) {
        self.viewer = viewer
        self.byNumber = byNumber
        self.byNumberAnswer = byNumberAnswer
        self.checkSignals = checkSignals
    }

    /// Change what the viewer batch answers, so one manager can see a pull
    /// request change between two polls.
    func replaceViewer(_ answer: Answer) { viewer = answer }

    func run(args: [String], repoPath: String) -> GHCommandResult? {
        if args.first == "repo" { return GHCommandResult(stdout: "acme/acme-prod\n") }
        guard let query = args.first(where: { $0.hasPrefix("query=") }) else { return nil }
        if query.contains("viewer {") {
            switch viewer {
            case .nodes(let nodes):
                return GHCommandResult(
                    stdout: #"{"data":{"viewer":{"pullRequests":{"nodes":[\#(nodes.joined(separator: ","))]}}}}"#)
            case .noOutput: return nil
            case .garbage: return GHCommandResult(stdout: "{\"nope\":true}")
            }
        }
        if query.contains("statusCheckRollup { state contexts") {
            switch checkSignals {
            case .nodes:
                return GHCommandResult(stdout: #"{"data":{"repository":{"pullRequest":{"commits":{"nodes":[]}}}}}"#)
            case .noOutput: return nil
            case .garbage: return GHCommandResult(stdout: "{\"nope\":true}")
            }
        }
        if query.contains("pullRequest(number:") {
            switch byNumberAnswer {
            case .nodes:
                let fields = Self.aliasedNumbers(inQuery: query).map { alias, number in
                    "\"\(alias)\": \(byNumber[number] ?? "null")"
                }
                return GHCommandResult(stdout: #"{"data":{"repository":{\#(fields.joined(separator: ","))}}}"#)
            case .noOutput: return nil
            case .garbage: return GHCommandResult(stdout: "{\"nope\":true}")
            }
        }
        return nil
    }

    private static func aliasedNumbers(inQuery query: String) -> [(alias: String, number: Int)] {
        query.split(separator: "\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":"),
                  let open = line.range(of: "pullRequest(number: "),
                  let close = line[open.upperBound...].firstIndex(of: ")"),
                  let number = Int(line[open.upperBound..<close]) else { return nil }
            return (String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces), number)
        }
    }
}

@Suite("PR observation recording")
struct PRObservationRecordingTests {

    private static let stamp = Date(timeIntervalSince1970: 1_760_000_000)

    private static func nodeJSON(
        number: Int, head: String, state: String = "OPEN", rollup: String = "SUCCESS"
    ) -> String {
        """
        {"number": \(number), "url": "https://github.com/acme/acme-prod/pull/\(number)",
         "state": "\(state)", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
         "headRefName": "\(head)", "createdAt": "2026-07-01T00:00:00Z", "isDraft": false,
         "statusCheckRollup": {"state": "\(rollup)"}}
        """
    }

    private static func worktree(
        _ id: UUID, branch: String = "tbd/w", prNumber: Int? = nil
    ) -> PRStatusManager.PollWorktree {
        (id: id, branch: branch, upstreamBranch: "main", defaultBranch: "main",
         pushBranch: .noPushDestination, worktreePath: "/wt/acme-prod", prNumber: prNumber)
    }

    private static func makeManager(_ gh: ScriptedGH) -> PRStatusManager {
        PRStatusManager(ghRunner: { args, path in await gh.run(args: args, repoPath: path) },
                        now: { Self.stamp })
    }

    // MARK: - `.none` and `.undetermined` are different answers

    @Test("a branch the forge answered about with no PR records .none, not .undetermined")
    func answeredWithNoPRRecordsNone() async {
        // An empty node list from a query that PARSED is the forge saying "no
        // pull request here" — settled knowledge a program can act on.
        let wt = UUID()
        let manager = Self.makeManager(ScriptedGH(viewer: .nodes([])))

        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        let observation = await manager.observation(for: wt)
        #expect(observation?.outcome == PRObservation.Outcome.none)
        #expect(observation?.observedAt == Self.stamp)
        #expect(await manager.allStatuses()[wt] == nil)
    }

    @Test("a failed batch records .undetermined with a cause, never .none")
    func failedBatchRecordsUndetermined() async {
        let wt = UUID()
        let manager = Self.makeManager(ScriptedGH(viewer: .noOutput))

        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        let outcome = await manager.observation(for: wt)?.outcome
        guard case .undetermined(let cause) = outcome else {
            Issue.record("expected .undetermined, observed \(String(describing: outcome))")
            return
        }
        #expect(!cause.isEmpty)
        #expect(outcome != PRObservation.Outcome.none, "an outage must never read as 'no pull request'")
    }

    @Test("an unparseable response is undetermined and names the parse failure")
    func unparseableResponseNamesItsCause() async {
        let wt = UUID()
        let manager = Self.makeManager(ScriptedGH(viewer: .garbage))

        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        #expect(await manager.observation(for: wt)?.outcome
                == .undetermined(cause: PRUndeterminedCause.unparseableResponse))
    }

    @Test(".none and .undetermined are not equal and neither folds into the other")
    func noneAndUndeterminedAreDistinct() async {
        // Two worktrees, one poll each, same manager shape — composed side by
        // side so the assertion is about the pair, not about either alone.
        let answered = UUID()
        let unreachable = UUID()
        let answeredManager = Self.makeManager(ScriptedGH(viewer: .nodes([])))
        let unreachableManager = Self.makeManager(ScriptedGH(viewer: .noOutput))

        await answeredManager.fetchAll(worktrees: [Self.worktree(answered)])
        await unreachableManager.fetchAll(worktrees: [Self.worktree(unreachable)])

        let noneOutcome = await answeredManager.observation(for: answered)?.outcome
        let undetermined = await unreachableManager.observation(for: unreachable)?.outcome
        #expect(noneOutcome == PRObservation.Outcome.none)
        #expect(noneOutcome != undetermined)
        if case .undetermined = noneOutcome {
            Issue.record("the settled 'no pull request' answer was folded into .undetermined")
        }
        if case PRObservation.Outcome.none = undetermined ?? .observed {
            Issue.record("an unreachable forge was folded into 'no pull request'")
        }
    }

    // MARK: - A failed fetch keeps the value AND admits it is unconfirmed

    @Test("a failed check query keeps the prior status and records .undetermined — both")
    func failedCheckQueryKeepsValueAndRecordsUndetermined() async {
        // The combination is the point: a value from before, honestly labeled
        // as not reconfirmed. Asserting either half alone would pass an
        // implementation that dropped the other.
        let wt = UUID()
        let gh = ScriptedGH(
            viewer: .nodes([Self.nodeJSON(number: 12, head: "tbd/w", rollup: "FAILURE")]),
            checkSignals: .noOutput)
        let manager = Self.makeManager(gh)
        let cached = PRStatus(number: 12, url: "https://github.com/acme/acme-prod/pull/12",
                              state: .mergeable, reason: "Ready to merge")
        await manager.seedForTesting(worktreeID: wt, status: cached)

        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        #expect(await manager.allStatuses()[wt] == cached, "the previous value must survive a transient failure")
        #expect(await manager.observation(for: wt)?.outcome
                == .undetermined(cause: PRUndeterminedCause.checkQueryFailed))
    }

    @Test("a failed fetch with no prior status does not invent .none")
    func failedFetchWithNoCacheDoesNotInventNone() async {
        let wt = UUID()
        let manager = Self.makeManager(ScriptedGH(viewer: .noOutput))

        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        #expect(await manager.allStatuses()[wt] == nil)
        let outcome = await manager.observation(for: wt)?.outcome
        #expect(outcome != PRObservation.Outcome.none,
                "with nothing cached and nothing learned, the honest answer is ignorance")
        if case .undetermined = outcome {} else {
            Issue.record("expected .undetermined, observed \(String(describing: outcome))")
        }
    }

    @Test("a numbered worktree that will not resolve is undetermined, never .none")
    func unresolvableNumberIsUndetermined() async {
        // It demonstrably HAS a pull request — it carries the number — so "no
        // pull request" is a conclusion the evidence cannot support.
        let wt = UUID()
        let manager = Self.makeManager(ScriptedGH(byNumberAnswer: .noOutput))

        await manager.fetchAll(worktrees: [Self.worktree(wt, prNumber: 404)])

        let outcome = await manager.observation(for: wt)?.outcome
        #expect(outcome != PRObservation.Outcome.none)
        #expect(outcome == .undetermined(cause: PRUndeterminedCause.queryFailed))
    }

    // MARK: - observedAt is stamped on every write

    @Test("a resolved PR is .observed and its status carries the observed-at stamp")
    func resolvedPRStampsObservedAt() async {
        let wt = UUID()
        let manager = Self.makeManager(
            ScriptedGH(viewer: .nodes([Self.nodeJSON(number: 12, head: "tbd/w")])))

        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        #expect(await manager.observation(for: wt)?.outcome == .observed)
        #expect(await manager.allStatuses()[wt]?.observedAt == Self.stamp,
                "a cache that cannot say when it was read is the cache that was measured lying")
    }

    @Test("a re-read of an unchanged PR keeps the stamp current without rewriting the row")
    func reReadAdvancesTheStampWithoutRePersisting() async {
        // Two rules meet here, and both are load-bearing.
        //
        // The cache's stamp MUST advance: it is what `pr.list` hands a surface,
        // and a stamp that only moved when the pull request itself changed
        // would make a value confirmed a minute ago read as days old.
        //
        // The DB write MUST NOT happen: `observedAt` advances every poll, so
        // deciding "has it changed" on an equality that includes it writes one
        // SQLite transaction per worktree per cadence, forever, on a fleet
        // whose steady state was zero. Change detection is `sameValue(as:)`.
        let wt = UUID()
        let gh = ScriptedGH(viewer: .nodes([Self.nodeJSON(number: 12, head: "tbd/w")]))
        let later = Self.stamp.addingTimeInterval(600)
        let clock = MutableStamp(Self.stamp)
        let manager = PRStatusManager(
            ghRunner: { args, path in await gh.run(args: args, repoPath: path) },
            now: { clock.value })
        let persisted = StatusPersistRecorder()
        await manager.setOnStatusPersist { id, status in await persisted.record(id, status) }

        await manager.fetchAll(worktrees: [Self.worktree(wt)])
        clock.value = later
        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        #expect(await manager.allStatuses()[wt]?.observedAt == later,
                "the in-memory stamp must follow the newest read")
        let stamps = await persisted.observedAts
        #expect(stamps == [Self.stamp],
                "an unchanged pull request must not rewrite its row, observed \(stamps)")
    }

    // MARK: - An attempt is an attempt whether or not it resolved

    @Test("a batch cannot stamp its older outcome over a refresh that failed mid-batch")
    func aFailedRefreshMidBatchKeepsItsNewerOutcome() async {
        // The scenario, in one call: a batch starts at T0; the user hits refresh
        // at T1 while it is parked in `gh`; the forge is not answering, so the
        // refresh records `.undetermined @ T1` and — having landed no value —
        // writes no `lastDirectUpdate`. The batch then finishes and records its
        // own `.none @ T0` for the same worktree.
        //
        // Only the SUCCESS path stamps `lastDirectUpdate`, so `directRefreshLanded`
        // does not cover this: `observedAt` moved backwards, the "the last check
        // did not resolve" clause vanished from the tooltip, and the freshness
        // label reported an age older than the most recent attempt.
        let wt = UUID()
        let batchStartedAt = Self.stamp
        let refreshedAt = Self.stamp.addingTimeInterval(30)
        let clock = MutableStamp(batchStartedAt)
        let box = ManagerBox()
        let interrupt = OneShot()
        let manager = PRStatusManager(
            ghRunner: { args, _ in
                if args.first == "repo" { return GHCommandResult(stdout: "acme/acme-prod\n") }
                guard let query = args.first(where: { $0.hasPrefix("query=") }) else { return nil }
                // Everything except the viewer batch fails: that outage is what
                // the user's refresh runs into.
                guard query.contains("viewer {") else { return nil }
                if interrupt.claim() {
                    clock.value = refreshedAt
                    _ = await box.value?.refresh(
                        worktreeID: wt, branch: "tbd/w", upstreamBranch: "main",
                        defaultBranch: "main", pushBranch: .noPushDestination,
                        repoPath: "/wt/acme-prod")
                }
                return GHCommandResult(
                    stdout: #"{"data":{"viewer":{"pullRequests":{"nodes":[]}}}}"#)
            },
            now: { clock.value })
        box.set(manager)

        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        let observation = await manager.observation(for: wt)
        #expect(observation?.observedAt == refreshedAt,
                "the recorded attempt moved backwards in time, to \(String(describing: observation?.observedAt))")
        guard case .undetermined = observation?.outcome else {
            Issue.record("the failed refresh's outcome was overwritten by the batch: \(String(describing: observation?.outcome))")
            return
        }
    }

    // MARK: - The in-memory facts are bounded to the fleet that exists

    @Test("retain drops the outcomes of worktrees that left the fleet, and keeps the values")
    func retainBoundsTheOutcomeMapToTheActiveFleet() async {
        let alive = UUID(), archived = UUID()
        let manager = Self.makeManager(ScriptedGH(viewer: .nodes([])))
        await manager.seedForTesting(
            worktreeID: archived,
            status: PRStatus(number: 5, url: "https://github.com/acme/acme-prod/pull/5",
                             state: .merged, reason: "Merged"))

        await manager.fetchAll(worktrees: [Self.worktree(alive), Self.worktree(archived)])
        #expect(await manager.allObservations().count == 2,
                "both worktrees must be on record first, or the prune below proves nothing")

        await manager.retain(active: [alive])

        #expect(Set(await manager.allObservations().keys) == [alive],
                "an outcome recorded for a worktree that has left the fleet outlived it")
        // The cached VALUE is deliberately kept: `.merged` is never persisted,
        // so this in-memory entry is the only record that the merged edge has
        // already been consumed for this worktree.
        #expect(await manager.allStatuses()[archived]?.state == .merged)
    }

    @Test("a pull request whose value changed is persisted")
    func aChangedValueStillPersists() async {
        let wt = UUID()
        let gh = ScriptedGH(viewer: .nodes([Self.nodeJSON(number: 12, head: "tbd/w")]))
        let clock = MutableStamp(Self.stamp)
        let manager = PRStatusManager(
            ghRunner: { args, path in await gh.run(args: args, repoPath: path) },
            now: { clock.value })
        let persisted = StatusPersistRecorder()
        await manager.setOnStatusPersist { id, status in await persisted.record(id, status) }

        await manager.fetchAll(worktrees: [Self.worktree(wt)])
        await gh.replaceViewer(.nodes([Self.nodeJSON(number: 12, head: "tbd/w", state: "CLOSED")]))
        clock.value = Self.stamp.addingTimeInterval(600)
        await manager.fetchAll(worktrees: [Self.worktree(wt)])

        let states = await persisted.states
        #expect(states == [.mergeable, .closed],
                "a real state change must still reach the DB, observed \(states)")
    }
}

/// A mutable stamp for the date seam. A class rather than an actor so the
/// `@Sendable () -> Date` closure can read it synchronously; the tests that use
/// it drive it from one task.
private final class MutableStamp: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

/// Holds the manager under test so a scripted `gh` call can reach back into it,
/// which is how a user gesture is interleaved with a batch: the runner is
/// invoked from inside the actor's own `await`, so the reentrant call lands
/// exactly where a real mid-batch `pr.refresh` would.
private final class ManagerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var manager: PRStatusManager?
    func set(_ manager: PRStatusManager) {
        lock.lock(); self.manager = manager; lock.unlock()
    }
    var value: PRStatusManager? {
        lock.lock(); defer { lock.unlock() }; return manager
    }
}

/// One-shot latch, so an interruption injected into a query cannot re-enter
/// through the queries it makes itself.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

private actor StatusPersistRecorder {
    private(set) var persisted: [(id: UUID, status: PRStatus?)] = []
    func record(_ id: UUID, _ status: PRStatus?) { persisted.append((id, status)) }
    var observedAts: [Date?] { persisted.map { $0.status?.observedAt } }
    var states: [PRMergeableState?] { persisted.map { $0.status?.state } }
}
