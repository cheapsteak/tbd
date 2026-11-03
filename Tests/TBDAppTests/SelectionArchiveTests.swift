import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: in-process state only. Every archive call goes to a fake, through
// the bulk run's closure or `AppState`'s seams (`ArchiveRecorder`), so no test
// reaches a daemon, plays the refusal beep, or shows a modal.

// MARK: - Fixtures

/// A worktree row. `remote` makes it a lane on the `acme` provider.
private func row(_ name: String, repoID: UUID?, id: UUID = UUID(), parent: UUID? = nil,
                 order: Int = 0, status: WorktreeStatus = .active, remote: String? = nil) -> Worktree {
    let location = remote.map { WorktreeLocation.remote(provider: "acme", sessionID: $0) } ?? .local
    return Worktree(id: id, repoID: repoID, name: name, displayName: name, branch: "feature",
                    path: location.storagePath ?? "/tmp/acme-\(name)", status: status, tmuxServer: "acme",
                    sortOrder: order, parentWorktreeID: parent, location: location)
}

/// The `acme` provider, answering `describe` with no capabilities.
private func acmeProvider() -> RemoteProviderStatus {
    RemoteProviderStatus(config: .init(name: "acme", exec: "/bin/false"), describe: nil,
                         health: .ok, errorMessage: nil, remediationLabel: nil,
                         remediationCommand: nil, lastSuccessfulSnapshotAt: Date())
}

/// Whether `items` hold an Archive Selection item.
private func hasArchiveSelection(_ items: [RowActionMenu.Item]) -> Bool {
    items.contains { item in
        guard case let .action(action) = item else { return false }
        return action.kind == .archiveSelection
    }
}

/// The one Archive Selection item a menu in selection mode is: enabled when
/// a selected row is archivable, and disabled with its help otherwise.
private func archiveSelectionMenu(enabled: Bool) -> [RowActionMenu.Item] {
    [.action(.init(
        kind: .archiveSelection,
        title: RowActionMenu.archiveSelectionLabel,
        role: .destructive,
        isEnabled: enabled,
        disabledHelp: enabled ? nil : RowActionMenu.archiveSelectionNothingArchivableHelp
    ))]
}

/// Records every daemon call an archive makes through `AppState`'s seams, and
/// every refusal beep, so no test reaches a daemon or plays a sound.
@MainActor
private final class ArchiveRecorder {
    /// `worktree.archive` calls, through `worktreeArchiver`.
    var worktreeCalls: [UUID] = []
    /// `scratch.archive` calls, through `scratchArchiver`.
    var scratchCalls: [UUID] = []
    /// Archived-scratch list calls, through `archivedScratchFetcher`.
    var scratchRefreshes = 0
    var beeps = 0
    /// Rows whose `worktree.archive` fails, and with what.
    var failures: [UUID: any Error] = [:]

    func install(on state: AppState) {
        state.worktreeArchiver = { [self] id, _, _ in
            worktreeCalls.append(id)
            if let error = failures[id] { throw error }
        }
        state.scratchArchiver = { [self] id in scratchCalls.append(id) }
        state.archivedScratchFetcher = { [self] in
            scratchRefreshes += 1
            return []
        }
        state.refusalBeep = { [self] in beeps += 1 }
    }

    /// Waits until `count` `worktree.archive` calls have been made: a
    /// gesture starts its archive in a task of its own.
    func waitForWorktreeCalls(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            await MainActor.run { self.worktreeCalls.count >= count }
        }
        guard outcome == .timedOut else { return }
        Issue.record(
            BoundedWaitTimeout(
                what: "\(count) worktree.archive call(s)", observed: "\(worktreeCalls.count) made",
                deadline: TestDeadlines.saturatedPass),
            sourceLocation: sourceLocation)
    }
}

/// One entry in an `ArchiveGate`'s log.
private enum ArchiveCallEvent: Hashable {
    case start(UUID)
    case end(UUID)
}

/// A fake archive call that holds each call until the test releases it, so a
/// test sees which calls are in flight together and ends them in the order
/// it chooses. It logs each call's start and end as they happen; a released
/// call fails with its row's error in `failures`, if it has one. `open()`
/// releases every held call and lets every later one through at once, so a
/// run always finishes, whatever the test saw.
@MainActor
private final class ArchiveGate {
    private(set) var events: [ArchiveCallEvent] = []
    /// The error each row's call fails with once released.
    var failures: [UUID: any Error] = [:]
    private var held: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var isOpen = false

    /// The rows whose call has started, in the order they started.
    var started: [UUID] {
        events.compactMap { event -> UUID? in
            guard case .start(let id) = event else { return nil }
            return id
        }
    }

    /// The rows whose call has ended, in the order they ended.
    var ended: [UUID] {
        events.compactMap { event -> UUID? in
            guard case .end(let id) = event else { return nil }
            return id
        }
    }

    /// The most calls in flight at once, over the whole log.
    var peakInFlight: Int {
        var inFlight = 0
        var peak = 0
        for event in events {
            switch event {
            case .start:
                inFlight += 1
                peak = max(peak, inFlight)
            case .end:
                inFlight -= 1
            }
        }
        return peak
    }

    func archive(_ worktree: Worktree) async throws {
        let id = worktree.id
        if isOpen {
            events.append(.start(id))
        } else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                events.append(.start(id))
                held[id] = continuation
            }
        }
        events.append(.end(id))
        if let error = failures[id] { throw error }
    }

    /// Lets the held call for `id` end.
    func release(_ id: UUID, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let continuation = held.removeValue(forKey: id) else {
            Issue.record("no archive call is held for \(id)", sourceLocation: sourceLocation)
            return
        }
        continuation.resume()
    }

    func open() {
        isOpen = true
        let waiting = Array(held.values)
        held.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    /// Waits until `count` calls have started. False, with the timeout
    /// recorded, when they do not.
    func waitForStarts(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Bool {
        try await waitFor("\(count) archive call(s) to start", observed: {
            await MainActor.run { "\(self.started.count) started" }
        }, sourceLocation: sourceLocation) {
            await MainActor.run { self.started.count >= count }
        }
    }
}

// MARK: - Pure decisions

@Suite("SelectionArchive — decisions")
struct SelectionArchiveDecisionTests {
    // MARK: Selection mode

    @Test func aRowInATwoRowSelectionActsOnTheSelection() {
        let a = UUID(), b = UUID()
        let selected: Set<UUID> = [a, b]
        let acts = SelectionArchive.actsOnSelection(rowID: a, selectedIDs: selected, resolves: { _ in true })
        #expect(acts)
    }

    /// A row outside the selection is answered without resolving any ID, so
    /// the menu built on every right-click stays cheap.
    @Test func aRowOutsideTheSelectionActsOnItselfWithoutResolvingAnything() {
        let a = UUID(), b = UUID(), outside = UUID()
        let selected: Set<UUID> = [a, b]
        var resolved: [UUID] = []
        let acts = SelectionArchive.actsOnSelection(rowID: outside, selectedIDs: selected, resolves: {
            resolved.append($0)
            return true
        })
        #expect(!acts)
        #expect(resolved.isEmpty)
    }

    @Test func theOnlySelectedRowActsOnItself() {
        let a = UUID()
        let selected: Set<UUID> = [a]
        let acts = SelectionArchive.actsOnSelection(rowID: a, selectedIDs: selected, resolves: { _ in true })
        #expect(!acts)
    }

    /// Two or more selected IDs means two or more that resolve to a row: a
    /// stale ID does not make a selection of one into a selection of two.
    @Test func aStaleIDDoesNotCountTowardTwoRows() {
        let a = UUID(), b = UUID(), stale = UUID()
        let rows: Set<UUID> = [a, b]
        let withOneRow = SelectionArchive.actsOnSelection(
            rowID: a, selectedIDs: [a, stale], resolves: { rows.contains($0) })
        #expect(!withOneRow)
        let withTwoRows = SelectionArchive.actsOnSelection(
            rowID: a, selectedIDs: [a, b, stale], resolves: { rows.contains($0) })
        #expect(withTwoRows)
    }

    // MARK: Eligibility, row by row

    @Test func anActiveLocalRowCanArchiveItself() {
        let canGo = SelectionArchive.canArchiveItself(SelectionArchive.Candidate(id: UUID()))
        #expect(canGo)
    }

    /// Only these three are excluded; a failed row's own Archive is enabled,
    /// so it can go with the selection too.
    @Test func mainCreatingAndArchivedRowsCannotArchiveThemselves() {
        for status: WorktreeStatus in [.main, .creating, .archived] {
            let candidate = SelectionArchive.Candidate(id: UUID(), status: status)
            let canGo = SelectionArchive.canArchiveItself(candidate)
            #expect(!canGo)
        }
        let failed = SelectionArchive.Candidate(id: UUID(), status: .failed)
        let failedCanGo = SelectionArchive.canArchiveItself(failed)
        #expect(failedCanGo)
    }

    @Test func aRemoteLaneWhoseProviderCannotArchiveCannotArchiveItself() {
        let lane = SelectionArchive.Candidate(
            id: UUID(), location: .remote(provider: "acme", sessionID: "s1"), providerCapabilities: ["stop"])
        let canGo = SelectionArchive.canArchiveItself(lane)
        #expect(!canGo)
    }

    @Test func aRemoteLaneWhoseProviderCanArchiveCanArchiveItself() {
        let lane = SelectionArchive.Candidate(
            id: UUID(), location: .remote(provider: "acme", sessionID: "s1"), providerCapabilities: ["archive"])
        let canGo = SelectionArchive.canArchiveItself(lane)
        #expect(canGo)
    }

    /// The same exemptions the row's own Archive makes: the daemon files a
    /// gone lane, and one whose provider is retired, row-only.
    @Test func goneAndRetiredLanesAreExemptFromTheCapabilityGate() {
        let goneLane = SelectionArchive.Candidate(
            id: UUID(), location: .remote(provider: "acme", sessionID: "s1"), isGone: true)
        let retiredLane = SelectionArchive.Candidate(
            id: UUID(), location: .remote(provider: "acme", sessionID: "s2"), providerRetired: true)
        let goneCanGo = SelectionArchive.canArchiveItself(goneLane)
        let retiredCanGo = SelectionArchive.canArchiveItself(retiredLane)
        #expect(goneCanGo)
        #expect(retiredCanGo)
    }

    // MARK: Eligibility, bottom up

    @Test func aRowWithAnActiveChildOutsideTheSelectionIsNotArchivable() {
        let parent = UUID(), child = UUID(), other = UUID()
        let candidates = [
            SelectionArchive.Candidate(id: parent, activeChildIDs: [child]),
            SelectionArchive.Candidate(id: other),
        ]
        let targets = SelectionArchive.targets(candidates, runOrder: [child, parent, other])
        let expected = [other]
        #expect(targets == expected)
    }

    @Test func aParentAndItsArchivableChildrenAreAllTargetsChildrenFirst() {
        let parent = UUID(), first = UUID(), second = UUID()
        let candidates = [
            SelectionArchive.Candidate(id: parent, activeChildIDs: [first, second]),
            SelectionArchive.Candidate(id: first),
            SelectionArchive.Candidate(id: second),
        ]
        let targets = SelectionArchive.targets(candidates, runOrder: [first, second, parent])
        let expected = [first, second, parent]
        #expect(targets == expected)
    }

    /// A selected child that cannot go holds its parent back, as an
    /// unselected one does: the daemon would refuse the parent for it.
    @Test func aSelectedChildThatCannotGoHoldsBackItsParent() {
        let creatingChild = SelectionArchive.Candidate(id: UUID(), status: .creating)
        let laneChild = SelectionArchive.Candidate(
            id: UUID(), location: .remote(provider: "acme", sessionID: "s1"), providerCapabilities: [])
        for child in [creatingChild, laneChild] {
            let parent = SelectionArchive.Candidate(id: UUID(), activeChildIDs: [child.id])
            let sibling = SelectionArchive.Candidate(id: UUID())
            let targets = SelectionArchive.targets(
                [parent, child, sibling], runOrder: [child.id, parent.id, sibling.id])
            let expected = [sibling.id]
            #expect(targets == expected)
        }
    }

    @Test func aThreeLevelChainGoesWholeOrIsHeldBackFromTheBottom() {
        let grandchildID = UUID(), childID = UUID(), parentID = UUID()
        let runOrder = [grandchildID, childID, parentID]
        let child = SelectionArchive.Candidate(id: childID, activeChildIDs: [grandchildID])
        let parent = SelectionArchive.Candidate(id: parentID, activeChildIDs: [childID])

        // Every row can go: the whole chain, deepest first.
        let whole = SelectionArchive.targets(
            [parent, SelectionArchive.Candidate(id: grandchildID), child], runOrder: runOrder)
        #expect(whole == runOrder)

        // The grandchild is still creating: it holds back the child, which
        // holds back the parent.
        let creating = SelectionArchive.targets(
            [parent, SelectionArchive.Candidate(id: grandchildID, status: .creating), child], runOrder: runOrder)
        #expect(creating.isEmpty)

        // The grandchild is not selected: the same.
        let unselected = SelectionArchive.targets([parent, child], runOrder: runOrder)
        #expect(unselected.isEmpty)
    }

    @Test func aLoopingParentChainHoldsBackEveryRowInIt() {
        let a = UUID(), b = UUID(), free = UUID()
        let candidates = [
            SelectionArchive.Candidate(id: a, activeChildIDs: [b]),
            SelectionArchive.Candidate(id: b, activeChildIDs: [a]),
            SelectionArchive.Candidate(id: free),
        ]
        let targets = SelectionArchive.targets(candidates, runOrder: [a, b, free])
        let expected = [free]
        #expect(targets == expected)
    }

    // MARK: Targets

    @Test func targetsSkipRowsThatCannotGoAndFollowTheRunOrder() {
        let a = UUID(), main = UUID(), c = UUID()
        let candidates = [
            SelectionArchive.Candidate(id: a),
            SelectionArchive.Candidate(id: main, status: .main),
            SelectionArchive.Candidate(id: c),
        ]
        let targets = SelectionArchive.targets(candidates, runOrder: [c, main, a])
        let expected = [c, a]
        #expect(targets == expected)
    }

    // MARK: Routing

    /// The menu's item is disabled then, so a refusal comes from the
    /// shortcut, or from a selection that changed under an open menu.
    @Test func noTargetsAreRefused() {
        let route = SelectionArchive.route([])
        #expect(route == .refuse)
    }

    @Test func oneTargetTakesTheSingleRowArchive() {
        let id = UUID()
        let route = SelectionArchive.route([id])
        #expect(route == .single(id))
    }

    @Test func severalTargetsTakeTheBulkRun() {
        let ids = [UUID(), UUID()]
        let route = SelectionArchive.route(ids)
        #expect(route == .bulk(ids))
    }

    // MARK: The summary

    /// The first line says what is wrong; the file list after it is left
    /// out, and the colon that introduced it becomes a full stop. The text is
    /// `UncommittedArchiveRefusal.evaluate`'s for one dirty file.
    @Test func aRefusalIsTheFirstLineOfTheDaemonsSentence() {
        let refusal = """
            acme-wt has 1 uncommitted change(s) that archiving would delete:
              ?? notes.md
            Commit or remove them first.
            """
        let error = DaemonClientError.rpcError(refusal, code: RPCErrorCode.worktreeArchiveUncommitted.rawValue)
        let reason = SelectionArchive.failureReason(error)
        #expect(reason == "acme-wt has 1 uncommitted change(s) that archiving would delete.")
        #expect(!reason.hasPrefix("RPC error:"))
    }

    @Test func blankLinesBeforeTheFirstSentenceAreSkipped() {
        let error = DaemonClientError.rpcError("\n   \nCannot archive acme-lane: its agent is working.\nMore.", code: nil)
        let reason = SelectionArchive.failureReason(error)
        #expect(reason == "Cannot archive acme-lane: its agent is working.")
    }

    @Test func anotherErrorIsItsDescription() {
        let reason = SelectionArchive.failureReason(DaemonClientError.daemonNotRunning)
        #expect(reason == "TBD daemon is not running")
    }

    @Test func aReasonAtTheCharacterLimitIsKeptWhole() {
        let line = String(repeating: "x", count: SelectionArchive.reasonCharacterLimit)
        let reason = SelectionArchive.failureReason(DaemonClientError.rpcError(line, code: nil))
        #expect(reason == line)
    }

    @Test func aReasonOneCharacterOverTheLimitIsCutToEndInAnEllipsis() {
        let limit = SelectionArchive.reasonCharacterLimit
        let line = String(repeating: "x", count: limit + 1)
        let reason = SelectionArchive.failureReason(DaemonClientError.rpcError(line, code: nil))
        let expected = String(repeating: "x", count: limit - 1) + "…"
        #expect(reason == expected)
        #expect(reason.count == limit)
    }

    @Test func theSummaryCountsThenListsEachFailure() {
        let failures = [
            SelectionArchive.Failure(name: "acme-a", reason: "Its agent is still working."),
            SelectionArchive.Failure(name: "acme-b", reason: "TBD daemon is not running"),
        ]
        let text = SelectionArchive.summary(archived: 1, total: 3, failures: failures)
        #expect(text == "Archived 1 of 3 worktrees.\n\nacme-a: Its agent is still working.\nacme-b: TBD daemon is not running")
    }

    @Test func oneRowReadsInTheSingular() {
        let failures = [SelectionArchive.Failure(name: "acme-a", reason: "Refused.")]
        let text = SelectionArchive.summary(archived: 0, total: 1, failures: failures)
        #expect(text == "Archived 0 of 1 worktree.\n\nacme-a: Refused.")
    }

    private static func failures(_ count: Int) -> [SelectionArchive.Failure] {
        (1...count).map { SelectionArchive.Failure(name: "acme-\($0)", reason: "Refused.") }
    }

    @Test func aSummaryAtTheLineLimitListsEveryFailure() {
        let limit = SelectionArchive.summaryFailureLineLimit
        let text = SelectionArchive.summary(archived: 0, total: limit, failures: Self.failures(limit))
        let lines = text.components(separatedBy: "\n")
        let expected: [String] = ["Archived 0 of \(limit) worktrees.", ""] + (1...limit).map { "acme-\($0): Refused." }
        #expect(lines == expected)
    }

    @Test func aSummaryOneOverTheLineLimitCountsTheRestOnOneLine() {
        let limit = SelectionArchive.summaryFailureLineLimit
        let total = limit + 1
        let text = SelectionArchive.summary(archived: 0, total: total, failures: Self.failures(total))
        let lines = text.components(separatedBy: "\n")
        let expected: [String] = ["Archived 0 of \(total) worktrees.", ""]
            + (1...limit).map { "acme-\($0): Refused." }
            + ["…and 1 more."]
        #expect(lines == expected)
    }

    @Test func rowsNotAttemptedShareOneClosingLine() {
        let failures = [SelectionArchive.Failure(name: "acme-a", reason: "TBD daemon is not running")]
        let text = SelectionArchive.summary(archived: 1, total: 5, failures: failures, notAttempted: 3)
        let expected = """
            Archived 1 of 5 worktrees.

            acme-a: TBD daemon is not running
            3 more not attempted: lost the connection to the daemon.
            """
        #expect(text == expected)
    }

    @Test func aHeldBackRowNamesTheNestedWorktreeThatStayed() {
        let reason = SelectionArchive.nestedNotArchivedReason("acme-child")
        #expect(reason == "Not archived, because its nested worktree \"acme-child\" was not archived.")
    }
}

// MARK: - The bulk run's schedule

/// `SelectionArchive.BulkSchedule`, driven as `AppState.archiveInBulk` drives
/// it, with no app state and no calls.
@Suite("SelectionArchive — bulk schedule")
struct SelectionArchiveBulkScheduleTests {
    private typealias Schedule = SelectionArchive.BulkSchedule
    private typealias Turn = SelectionArchive.BulkSchedule.Turn

    /// A schedule over `targets`, each an ID and its parent's, in run order.
    private static func schedule(_ targets: [(id: UUID, parentID: UUID?)]) -> Schedule {
        Schedule(targets.map { Schedule.Target(id: $0.id, parentID: $0.parentID) })
    }

    /// Takes every turn `schedule` offers now, as the bulk run does: it
    /// begins each start, and records each skip as not archived under the
    /// row's name in `names`.
    private static func takeTurns(
        _ schedule: inout Schedule, names: [UUID: String] = [:],
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> [Turn] {
        var turns: [Turn] = []
        // Each row acts once, so a turn past the row count is one offered
        // again after it was answered; stop there rather than loop forever.
        for _ in 0...schedule.order.count {
            guard let turn = schedule.nextTurn() else { return turns }
            turns.append(turn)
            switch turn {
            case .start(let id):
                schedule.begin(id)
            case .skip(let id, _):
                schedule.record(id, .notArchived(name: names[id] ?? "unnamed"))
            }
        }
        Issue.record("the schedule offered more turns than it has rows: \(turns)", sourceLocation: sourceLocation)
        return turns
    }

    @Test func independentRowsStartInRunOrderFourAtATime() {
        #expect(SelectionArchive.maxConcurrentArchives == 4)
        let ids = (0..<6).map { _ in UUID() }
        var schedule = Schedule(ids.map { Schedule.Target(id: $0, parentID: nil) })
        #expect(schedule.maxConcurrent == SelectionArchive.maxConcurrentArchives)

        let opening = Self.takeTurns(&schedule)
        let firstFour = ids[0..<4].map { Turn.start($0) }
        #expect(opening == firstFour)
        #expect(schedule.inFlight == Set(ids[0..<4]))
        let waiting = Array(ids[4...])
        #expect(schedule.unstarted == waiting)

        // Whichever call ends, its slot goes to the next row in run order.
        schedule.record(ids[2], .archived)
        let afterOne = Self.takeTurns(&schedule)
        #expect(afterOne == [Turn.start(ids[4])])
        schedule.record(ids[0], .notArchived(name: "acme-0"))
        let afterTwo = Self.takeTurns(&schedule)
        #expect(afterTwo == [Turn.start(ids[5])])
        #expect(schedule.unstarted.isEmpty)

        for id in [ids[1], ids[3], ids[4], ids[5]] {
            schedule.record(id, .archived)
        }
        let afterAll = Self.takeTurns(&schedule)
        #expect(afterAll.isEmpty)
        #expect(schedule.isFinished)
    }

    @Test func aParentWaitsForEverySelectedChildBeforeIt() {
        let parent = UUID(), first = UUID(), second = UUID(), other = UUID()
        var schedule = Self.schedule([
            (id: first, parentID: parent), (id: second, parentID: parent),
            (id: parent, parentID: nil), (id: other, parentID: nil),
        ])
        let opening = Self.takeTurns(&schedule)
        let expected: [Turn] = [.start(first), .start(second), .start(other)]
        #expect(opening == expected)
        #expect(!schedule.isReady(parent))

        schedule.record(first, .archived)
        let afterFirst = Self.takeTurns(&schedule)
        #expect(afterFirst.isEmpty)
        #expect(!schedule.isReady(parent))

        schedule.record(second, .archived)
        let afterSecond = Self.takeTurns(&schedule)
        #expect(afterSecond == [Turn.start(parent)])
    }

    @Test func aRowNotArchivedHoldsBackItsParentAndTheSkipHoldsBackTheGrandparent() {
        let grandparent = UUID(), parent = UUID(), child = UUID()
        let names = [grandparent: "acme-grandparent", parent: "acme-parent", child: "acme-child"]
        var schedule = Self.schedule([
            (id: child, parentID: parent), (id: parent, parentID: grandparent),
            (id: grandparent, parentID: nil),
        ])
        let opening = Self.takeTurns(&schedule, names: names)
        #expect(opening == [Turn.start(child)])

        schedule.record(child, .notArchived(name: "acme-child"))
        let held = Self.takeTurns(&schedule, names: names)
        let expected: [Turn] = [
            .skip(parent, nestedName: "acme-child"),
            .skip(grandparent, nestedName: "acme-parent"),
        ]
        #expect(held == expected)
        #expect(schedule.isFinished)
        #expect(schedule.inFlight.isEmpty)
    }

    @Test func theHoldNamesTheFirstChildInRunOrderNotTheFirstToEnd() {
        let parent = UUID(), first = UUID(), second = UUID(), third = UUID()
        var schedule = Self.schedule([
            (id: first, parentID: parent), (id: second, parentID: parent),
            (id: third, parentID: parent), (id: parent, parentID: nil),
        ])
        let opening = Self.takeTurns(&schedule)
        #expect(opening.count == 3)

        // The calls end in reverse run order; the parent waits for all three.
        schedule.record(third, .notArchived(name: "acme-third"))
        let afterThird = Self.takeTurns(&schedule)
        #expect(afterThird.isEmpty)
        schedule.record(second, .notArchived(name: "acme-second"))
        let afterSecond = Self.takeTurns(&schedule)
        #expect(afterSecond.isEmpty)
        schedule.record(first, .archived)
        let afterFirst = Self.takeTurns(&schedule)
        #expect(afterFirst == [Turn.skip(parent, nestedName: "acme-second")])
    }

    /// A skip makes no call, so a row held back is skipped even while every
    /// slot is taken.
    @Test func aSkipTakesNoSlot() {
        let parent = UUID(), child = UUID()
        let others = (0..<4).map { _ in UUID() }
        let targets = [Schedule.Target(id: child, parentID: parent)]
            + others.map { Schedule.Target(id: $0, parentID: nil) }
            + [Schedule.Target(id: parent, parentID: nil)]
        var schedule = Schedule(targets)
        let opening = Self.takeTurns(&schedule)
        let expected = [child, others[0], others[1], others[2]].map { Turn.start($0) }
        #expect(opening == expected)

        // The child's slot goes to the last other row, and the parent is
        // skipped with all four slots taken.
        schedule.record(child, .notArchived(name: "acme-child"))
        let afterChild = Self.takeTurns(&schedule)
        let then: [Turn] = [.start(others[3]), .skip(parent, nestedName: "acme-child")]
        #expect(afterChild == then)
        #expect(schedule.inFlight == Set(others))
    }

    /// A row waits only for the children before it in run order, so a loop
    /// in the parent links leaves a row free to go first.
    @Test func aLoopInTheParentLinksStillFinishes() {
        // `first` and `second` name each other; `looped` names itself.
        let first = UUID(), second = UUID(), looped = UUID()
        var schedule = Self.schedule([
            (id: first, parentID: second), (id: second, parentID: first), (id: looped, parentID: looped),
        ])
        let opening = Self.takeTurns(&schedule)
        let expected: [Turn] = [.start(first), .start(looped)]
        #expect(opening == expected)

        schedule.record(first, .archived)
        schedule.record(looped, .archived)
        let next = Self.takeTurns(&schedule)
        #expect(next == [Turn.start(second)])
        schedule.record(second, .archived)
        let last = Self.takeTurns(&schedule)
        #expect(last.isEmpty)
        #expect(schedule.isFinished)
    }

    @Test func aRowGoneAtItsTurnHoldsBackNoParent() {
        let parent = UUID(), child = UUID()
        var schedule = Self.schedule([(id: child, parentID: parent), (id: parent, parentID: nil)])
        let turn = schedule.nextTurn()
        #expect(turn == Turn.start(child))

        // The run finds the child gone and records it so, without a call.
        schedule.record(child, .vanished)
        let next = Self.takeTurns(&schedule)
        #expect(next == [Turn.start(parent)])
    }

    @Test func anIDListedTwiceKeepsItsFirstPlace() {
        let first = UUID(), second = UUID()
        let schedule = Self.schedule([
            (id: first, parentID: nil), (id: second, parentID: nil), (id: first, parentID: second),
        ])
        let order = [first, second]
        #expect(schedule.order == order)
        // The repeat's parent link is dropped with it, so `second` waits for nothing.
        #expect(schedule.isReady(second))
    }
}

// MARK: - Both surfaces, built from live AppState

/// Through `RowActionMenuActions` with `followsSelection` on, as
/// `SidebarMenus` builds it, and through `SidebarMenus` itself for the native
/// outline and dock. The
/// selection lives in `AppState.selectedWorktreeIDs`, which both native
/// tables sync into.
@MainActor
@Suite("Archive Selection — built from live AppState")
struct ArchiveSelectionCallSiteTests {
    /// A repo with its main row, a parent and its child, a sibling, and a row
    /// still creating.
    private struct Fixture {
        let repo: Repo
        let main: Worktree
        let parent: Worktree
        let child: Worktree
        let sibling: Worktree
        let creating: Worktree
    }

    private func withState(_ body: (AppState, UserDefaults, Fixture) throws -> Void) throws {
        let suite = TestDefaultsSuite("TBDAppTests.ArchiveSelectionCallSite")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("parent", repoID: repo.id, order: 0)
        let fixture = Fixture(
            repo: repo,
            main: row("acme", repoID: repo.id, status: .main),
            parent: parent,
            child: row("child", repoID: repo.id, parent: parent.id),
            sibling: row("sibling", repoID: repo.id, order: 1),
            creating: row("creating", repoID: repo.id, order: 2, status: .creating))
        state.repos = [repo]
        state.worktrees = [repo.id: [fixture.main, fixture.parent, fixture.child, fixture.sibling, fixture.creating]]
        try body(state, suite.defaults, fixture)
    }

    /// The menu `SidebarMenus` builds for a row.
    private func rowMenu(_ state: AppState, _ worktree: Worktree) -> RowActionMenuActions {
        RowActionMenuActions(appState: state, worktree: worktree, onRename: {}, followsSelection: true)
    }

    /// The toolbar title's menu for a row, which does not follow the selection.
    private func titleMenu(_ state: AppState, _ worktree: Worktree) -> RowActionMenuActions {
        RowActionMenuActions(appState: state, worktree: worktree, onRename: {})
    }

    @Test("right-click inside a selection: Archive Selection alone, and its targets run children first")
    func insideASelection() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.parent.id, f.child.id, f.sibling.id]
            let actions = rowMenu(state, f.sibling)
            #expect(actions.actsOnSelection)
            let items = actions.items()
            let expected = archiveSelectionMenu(enabled: true)
            #expect(items == expected)
            let targets = state.selectionArchiveTargets()
            let runOrder = [f.child.id, f.parent.id, f.sibling.id]
            #expect(targets == runOrder)
        }
    }

    @Test("right-click inside a selection where nothing is archivable: the one item, disabled")
    func insideASelectionWithNothingArchivable() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.main.id, f.creating.id]
            let items = rowMenu(state, f.main).items()
            let expected = archiveSelectionMenu(enabled: false)
            #expect(items == expected)
            let targets = state.selectionArchiveTargets()
            #expect(targets.isEmpty)
        }
    }

    @Test("right-click outside the selection: the row's own menu, and the selection is untouched")
    func outsideTheSelection() throws {
        try withState { state, _, f in
            let selection: Set<UUID> = [f.parent.id, f.child.id]
            state.selectedWorktreeIDs = selection
            let actions = rowMenu(state, f.sibling)
            #expect(!actions.actsOnSelection)
            let items = actions.items()
            let ownMenu = titleMenu(state, f.sibling).items()
            #expect(items == ownMenu)
            #expect(!hasArchiveSelection(items))
            let archiveTitles = items.compactMap { item -> String? in
                guard case let .action(action) = item, action.kind == .archive else { return nil }
                return action.title
            }
            let expectedTitles = ["Archive"]
            #expect(archiveTitles == expectedTitles)
            #expect(state.selectedWorktreeIDs == selection)
        }
    }

    @Test("right-click on the only selected row: the row's own menu")
    func aSingleSelection() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.sibling.id]
            let actions = rowMenu(state, f.sibling)
            #expect(!actions.actsOnSelection)
            let items = actions.items()
            let ownMenu = titleMenu(state, f.sibling).items()
            #expect(items == ownMenu)
            #expect(!hasArchiveSelection(items))
        }
    }

    /// A stale ID, one whose row has gone, is no row: the selection holds one.
    @Test("right-click on a row selected with one stale ID: the row's own menu")
    func aRowSelectedWithAStaleID() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.sibling.id, UUID()]
            let actions = rowMenu(state, f.sibling)
            #expect(!actions.actsOnSelection)
            let items = actions.items()
            let ownMenu = titleMenu(state, f.sibling).items()
            #expect(items == ownMenu)
            #expect(!hasArchiveSelection(items))
        }
    }

    /// The gate's other branch: a menu that does not follow the selection,
    /// the toolbar title's, stays the row's own inside a selection.
    @Test("a menu that does not follow the selection keeps the row's own items inside one")
    func aMenuThatDoesNotFollowTheSelection() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.parent.id, f.child.id, f.sibling.id]
            let actions = titleMenu(state, f.sibling)
            #expect(!actions.actsOnSelection)
            let items = actions.items()
            #expect(!hasArchiveSelection(items))
            #expect(items.count > 1)
        }
    }

    @Test("a parent whose active child is not selected is skipped")
    func aParentWithAnUnselectedChildIsSkipped() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.parent.id, f.sibling.id]
            let items = rowMenu(state, f.parent).items()
            let expected = archiveSelectionMenu(enabled: true)
            #expect(items == expected)
            let targets = state.selectionArchiveTargets()
            let expectedTargets = [f.sibling.id]
            #expect(targets == expectedTargets)
        }
    }

    @Test("a remote lane whose provider cannot archive is skipped")
    func aLaneWhoseProviderCannotArchiveIsSkipped() throws {
        try withState { state, _, f in
            let lane = row("lane", repoID: f.repo.id, order: 3, remote: "s1")
            state.worktrees[f.repo.id, default: []].append(lane)
            state.remoteProviders = [acmeProvider()]
            state.selectedWorktreeIDs = [lane.id, f.sibling.id]
            let items = rowMenu(state, lane).items()
            let expected = archiveSelectionMenu(enabled: true)
            #expect(items == expected)
            let targets = state.selectionArchiveTargets()
            let expectedTargets = [f.sibling.id]
            #expect(targets == expectedTargets)
        }
    }

    @Test("a scratch row goes with the selection, first, as the Scratch section is")
    func aScratchRowIsATarget() throws {
        try withState { state, _, f in
            let scratch = row("scratch", repoID: nil)
            state.scratchWorktrees = [scratch]
            state.selectedWorktreeIDs = [f.sibling.id, scratch.id]
            let items = rowMenu(state, scratch).items()
            let expected = archiveSelectionMenu(enabled: true)
            #expect(items == expected)
            let targets = state.selectionArchiveTargets()
            let expectedTargets = [scratch.id, f.sibling.id]
            #expect(targets == expectedTargets)
        }
    }

    /// One archivable row in a larger selection takes the single-row path,
    /// prompts included, through the same decision the run makes.
    @Test("one archivable row in the selection routes to the single-row archive")
    func oneArchivableRowRoutesSingle() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.main.id, f.sibling.id]
            let items = rowMenu(state, f.main).items()
            let expected = archiveSelectionMenu(enabled: true)
            #expect(items == expected)
            let route = SelectionArchive.route(state.selectionArchiveTargets())
            #expect(route == .single(f.sibling.id))
        }
    }

    /// A menu acting on the selection derives none of the row's own facts:
    /// its context is the selection and every other field's default, even
    /// for a row whose own context would set many of them.
    @Test("inside a selection the context carries the selection alone")
    func insideASelectionTheContextIsTheSelectionAlone() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.parent.id, f.child.id, f.sibling.id]
            let context = rowMenu(state, f.parent).context()
            let expected = RowActionMenu.Context(selection: .init(hasArchivableRow: true))
            #expect(context == expected)
            // The gate's other branch: the same row outside a selection
            // derives its own facts.
            state.selectedWorktreeIDs = [f.parent.id]
            let own = rowMenu(state, f.parent).context()
            #expect(own.selection == nil)
            #expect(own.hasActiveChildren)
            #expect(own.branch == f.parent.branch)
        }
    }

    @Test("a parent whose selected child is still creating is skipped")
    func aParentWithACreatingChildIsSkipped() throws {
        try withState { state, _, f in
            let creatingChild = row("creating-child", repoID: f.repo.id, parent: f.sibling.id, status: .creating)
            state.worktrees[f.repo.id, default: []].append(creatingChild)
            state.selectedWorktreeIDs = [f.sibling.id, creatingChild.id, f.parent.id, f.child.id]
            let items = rowMenu(state, f.sibling).items()
            let expected = archiveSelectionMenu(enabled: true)
            #expect(items == expected)
            let targets = state.selectionArchiveTargets()
            let expectedTargets = [f.child.id, f.parent.id]
            #expect(targets == expectedTargets)
        }
    }

    // MARK: The run order

    /// The run order is the sidebar's own walk with each row after its
    /// nested worktrees: the same rows `allWorktreesOrdered` lists, with the
    /// Scratch section first.
    @Test("the run order is the sidebar's walk, children first, after the Scratch section")
    func theRunOrderIsTheSidebarWalkChildrenFirst() throws {
        try withState { state, _, f in
            let first = row("first", repoID: f.repo.id, parent: f.parent.id, order: 0)
            let grandchild = row("grandchild", repoID: f.repo.id, parent: first.id)
            let second = row("second", repoID: f.repo.id, parent: f.parent.id, order: 1)
            let scratch = row("scratch", repoID: nil)
            state.worktrees = [f.repo.id: [f.main, f.parent, first, grandchild, second, f.sibling]]
            state.scratchWorktrees = [scratch]

            let sidebar = state.allWorktreesOrdered.map(\.id)
            let expectedSidebar = [f.main.id, f.parent.id, first.id, grandchild.id, second.id, f.sibling.id]
            #expect(sidebar == expectedSidebar)

            let runOrder = state.selectionArchiveRunOrder
            let expectedRunOrder = [scratch.id, f.main.id, grandchild.id, first.id, second.id, f.parent.id, f.sibling.id]
            #expect(runOrder == expectedRunOrder)
        }
    }

    /// A failed row is not in the sidebar's walk, and neither is the active
    /// worktree nested under it. They still run children first, even when
    /// the child sorts after its parent.
    @Test("rows the walk does not reach still run children first")
    func rowsTheWalkMissesStillRunChildrenFirst() throws {
        try withState { state, _, f in
            let failed = row("failed", repoID: f.repo.id, order: 0, status: .failed)
            let underFailed = row("under-failed", repoID: f.repo.id, parent: failed.id, order: 9)
            state.worktrees[f.repo.id, default: []] += [failed, underFailed]
            let runOrder = state.selectionArchiveRunOrder
            let failedIndex = try #require(runOrder.firstIndex(of: failed.id))
            let childIndex = try #require(runOrder.firstIndex(of: underFailed.id))
            #expect(childIndex < failedIndex)
        }
    }

    /// Two rows whose parent links loop are reached from no row the walk
    /// starts from, and are still listed, once each.
    @Test("rows whose parent links loop are each listed once")
    func loopingParentLinksAreEachListedOnce() throws {
        try withState { state, _, f in
            let aID = UUID(), bID = UUID(), selfID = UUID()
            let a = row("loop-a", repoID: f.repo.id, id: aID, parent: bID)
            let b = row("loop-b", repoID: f.repo.id, id: bID, parent: aID)
            let selfLoop = row("loop-self", repoID: f.repo.id, id: selfID, parent: selfID)
            state.worktrees[f.repo.id, default: []] += [a, b, selfLoop]
            let runOrder = state.selectionArchiveRunOrder
            let resolvable = state.allWorktrees.map(\.id)
            #expect(runOrder.count == resolvable.count)
            let runOrderSet = Set(runOrder)
            let resolvableSet = Set(resolvable)
            #expect(runOrderSet == resolvableSet)
        }
    }

    /// Why `SelectionArchive.targets` needs no branch for a candidate the run
    /// order leaves out: the run order lists every row `findWorktree(id:)`
    /// resolves, including the ones the sidebar walk skips.
    @Test("the run order lists every row a selected ID can resolve to, once")
    func theRunOrderListsEveryResolvableRow() throws {
        try withState { state, _, f in
            let failed = row("failed", repoID: f.repo.id, order: 4, status: .failed)
            let underFailed = row("under-failed", repoID: f.repo.id, parent: failed.id)
            state.worktrees[f.repo.id, default: []] += [failed, underFailed]
            state.scratchWorktrees = [row("scratch", repoID: nil)]
            let order = state.selectionArchiveRunOrder
            let resolvable = state.allWorktrees.map(\.id)
            let orderSet = Set(order)
            let resolvableSet = Set(resolvable)
            #expect(order.count == resolvable.count)
            #expect(orderSet == resolvableSet)
            for id in resolvable {
                let found = state.findWorktree(id: id)
                #expect(found != nil)
            }
            let failedIndex = try #require(order.firstIndex(of: failed.id))
            let childIndex = try #require(order.firstIndex(of: underFailed.id))
            #expect(childIndex < failedIndex)
        }
    }

    // MARK: The archive shortcut

    /// With one row selected the shortcut keeps its old rule: the lane goes
    /// to `archiveWorktree(id:)`, and the daemon's refusal comes back as that
    /// path's alert.
    @Test("the shortcut sends one selected lane its provider cannot archive to the single-row archive")
    func theShortcutSendsOneSelectedLaneAnyway() throws {
        try withState { state, _, f in
            let lane = row("lane", repoID: f.repo.id, order: 3, remote: "s1")
            state.worktrees[f.repo.id, default: []].append(lane)
            state.remoteProviders = [acmeProvider()]
            state.selectedWorktreeIDs = [lane.id]
            #expect(state.archiveShortcutRoute() == .single(lane.id))
            // Selected with another row that cannot go, it is held to the
            // selection's rules, and nothing can go.
            state.selectedWorktreeIDs = [lane.id, f.main.id]
            #expect(state.archiveShortcutRoute() == .refuse)
        }
    }

    @Test("the shortcut refuses two or more selected rows of which none can go")
    func theShortcutRefusesWhenNothingSelectedCanGo() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.main.id, f.creating.id]
            #expect(state.archiveShortcutRoute() == .refuse)
        }
    }

    /// Stale IDs are no rows: a selection of one row and a stale ID is a
    /// selection of one row, and two stale IDs are none.
    @Test("the shortcut counts only selected IDs that resolve to a row")
    func theShortcutCountsResolvedRows() throws {
        try withState { state, _, f in
            state.selectedWorktreeIDs = [f.sibling.id, UUID()]
            #expect(state.archiveShortcutRoute() == .single(f.sibling.id))
            // The main row alone is refused in silence, as it always was.
            state.selectedWorktreeIDs = [f.main.id, UUID()]
            #expect(state.archiveShortcutRoute() == .nothing)
            state.selectedWorktreeIDs = [UUID(), UUID()]
            #expect(state.archiveShortcutRoute() == .nothing)
        }
    }

    @Test("the shortcut beeps, and archives nothing, when nothing in a selection of two or more can go")
    func theShortcutBeepsWhenNothingCanGo() {
        let suite = TestDefaultsSuite("TBDAppTests.ArchiveSelectionShortcut")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let recorder = ArchiveRecorder()
        recorder.install(on: state)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let main = row("acme", repoID: repo.id, status: .main)
        let creating = row("creating", repoID: repo.id, order: 1, status: .creating)
        state.repos = [repo]
        state.worktrees = [repo.id: [main, creating]]

        state.selectedWorktreeIDs = [main.id, creating.id]
        state.archiveSelectedWorktree()
        #expect(recorder.beeps == 1)

        // The other branches: nothing selected is no command at all.
        state.selectedWorktreeIDs = []
        state.archiveSelectedWorktree()
        #expect(recorder.beeps == 1)
        #expect(recorder.worktreeCalls.isEmpty)
    }

    @Test("the shortcut archives several rows in run order, and one row through the single-row archive")
    func theShortcutArchivesTheSelection() async {
        let suite = TestDefaultsSuite("TBDAppTests.ArchiveSelectionShortcut")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let recorder = ArchiveRecorder()
        recorder.install(on: state)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("acme-parent", repoID: repo.id, order: 0)
        let child = row("acme-child", repoID: repo.id, parent: parent.id)
        let sibling = row("acme-sibling", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [parent, child, sibling]]

        state.selectedWorktreeIDs = [parent.id, child.id]
        state.archiveSelectedWorktree()
        await recorder.waitForWorktreeCalls(2)
        let bulk = [child.id, parent.id]
        #expect(recorder.worktreeCalls == bulk)

        state.selectedWorktreeIDs = [sibling.id]
        state.archiveSelectedWorktree()
        await recorder.waitForWorktreeCalls(3)
        let all = [child.id, parent.id, sibling.id]
        #expect(recorder.worktreeCalls == all)
        #expect(recorder.beeps == 0)
        #expect(state.alertMessage == nil)
    }

    // MARK: Picking Archive Selection

    /// The menu decides only whether the item is enabled. Picking it reads
    /// the selection as it is then: a row that left the selection after the
    /// menu was built is not archived.
    @Test("picking Archive Selection archives the selection as it is when picked")
    func pickingResolvesTheLiveSelection() async {
        let suite = TestDefaultsSuite("TBDAppTests.ArchiveSelectionPick")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let recorder = ArchiveRecorder()
        recorder.install(on: state)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("acme-parent", repoID: repo.id, order: 0)
        let child = row("acme-child", repoID: repo.id, parent: parent.id)
        let sibling = row("acme-sibling", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [parent, child, sibling]]

        state.selectedWorktreeIDs = [parent.id, child.id, sibling.id]
        let actions = rowMenu(state, sibling)
        let items = actions.items()
        let expected = archiveSelectionMenu(enabled: true)
        #expect(items == expected)

        state.selectedWorktreeIDs = [child.id, sibling.id]
        actions.run(.archiveSelection)
        await recorder.waitForWorktreeCalls(2)
        // Neither waits for the other, so their calls run side by side.
        let archived: Set<UUID> = [child.id, sibling.id]
        #expect(Set(recorder.worktreeCalls) == archived)
        #expect(recorder.worktreeCalls.count == 2)
        #expect(state.findWorktree(id: parent.id) != nil)
        #expect(recorder.beeps == 0)
    }

    @Test("picking Archive Selection when nothing selected can go any more beeps and archives nothing")
    func pickingWithNothingLeftToArchiveBeeps() {
        let suite = TestDefaultsSuite("TBDAppTests.ArchiveSelectionPick")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let recorder = ArchiveRecorder()
        recorder.install(on: state)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let main = row("acme", repoID: repo.id, status: .main)
        let first = row("acme-first", repoID: repo.id, order: 0)
        let second = row("acme-second", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [main, first, second]]

        state.selectedWorktreeIDs = [first.id, second.id]
        let actions = rowMenu(state, first)
        state.selectedWorktreeIDs = [main.id, first.id]
        state.worktrees = [repo.id: [main]]
        actions.run(.archiveSelection)

        #expect(recorder.beeps == 1)
        #expect(recorder.worktreeCalls.isEmpty)
    }

    // MARK: The native sidebar and dock

    private static func titles(of menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    private static func title(of item: RowActionMenu.Item) -> String {
        switch item {
        case .action(let action): action.title
        case .divider: "—"
        case .caption(let text): text
        }
    }

    @Test("the native menu is Archive Selection alone inside a selection, with no create items")
    func nativeMenuInsideASelection() throws {
        try withState { state, defaults, f in
            state.remoteProviders = [acmeProvider()]
            state.selectedWorktreeIDs = [f.parent.id, f.child.id]
            let menus = SidebarMenus(appState: state, defaults: defaults, host: nil)
            let tree = SidebarTreeBuilder.build(
                state, options: SidebarBuildOptions(defaults: defaults), directoryExists: { _ in true })
            let node = try #require(tree.node(.worktree(f.child.id)))
            let menu = try #require(menus.menu(for: node))
            let shown = Self.titles(of: menu)
            let expected = [RowActionMenu.archiveSelectionLabel]
            #expect(shown == expected)
            let item = try #require(menu.items.first)
            #expect(item.isEnabled)
        }
    }

    @Test("the native menu outside the selection is the row's own, with its create items")
    func nativeMenuOutsideTheSelection() throws {
        try withState { state, defaults, f in
            state.remoteProviders = [acmeProvider()]
            state.selectedWorktreeIDs = [f.parent.id, f.child.id]
            let menus = SidebarMenus(appState: state, defaults: defaults, host: nil)
            let tree = SidebarTreeBuilder.build(
                state, options: SidebarBuildOptions(defaults: defaults), directoryExists: { _ in true })
            let node = try #require(tree.node(.worktree(f.sibling.id)))
            let menu = try #require(menus.menu(for: node))
            let shown = Self.titles(of: menu)
            let expected = titleMenu(state, f.sibling).items().map { Self.title(of: $0) }
                + ["—", "New Remote Session…"]
            #expect(shown == expected)
            #expect(!shown.contains(RowActionMenu.archiveSelectionLabel))
        }
    }

    @Test("the native menu is disabled when nothing selected is archivable")
    func nativeMenuWithNothingArchivable() throws {
        try withState { state, defaults, f in
            state.selectedWorktreeIDs = [f.main.id, f.creating.id]
            let menus = SidebarMenus(appState: state, defaults: defaults, host: nil)
            let tree = SidebarTreeBuilder.build(
                state, options: SidebarBuildOptions(defaults: defaults), directoryExists: { _ in true })
            let node = try #require(tree.node(.worktree(f.main.id)))
            let menu = try #require(menus.menu(for: node))
            let shown = Self.titles(of: menu)
            let expected = [RowActionMenu.archiveSelectionLabel]
            #expect(shown == expected)
            let item = try #require(menu.items.first)
            #expect(!item.isEnabled)
            #expect(item.toolTip == RowActionMenu.archiveSelectionNothingArchivableHelp)
        }
    }
}

// MARK: - The bulk run

/// `archiveInBulk` with a fake archive call. The fake is the run's only way
/// to archive, and it takes no flags, so a prompt accepted on the run's
/// behalf would show up as a second call for the same row.
///
/// `FakeArchiver` returns at once, so its calls run side by side in an order
/// no test relies on; those tests check the outcome and which calls were
/// made. `ArchiveGate` holds each call until the test releases it, so a test
/// can see which calls are in flight together and in what order they start.
@MainActor
@Suite("Archive Selection — bulk run", .fastPassBounded)
struct ArchiveSelectionBulkRunTests {
    /// Records each archive call, failing the rows it was told to.
    @MainActor
    final class FakeArchiver {
        var calls: [UUID] = []
        var failures: [UUID: any Error] = [:]
        /// `selectionArchiveInFlight` as each call saw it, for the tests
        /// that record it.
        var inFlightSeen: [Bool] = []

        func archive(_ worktree: Worktree) throws {
            calls.append(worktree.id)
            if let error = failures[worktree.id] { throw error }
        }
    }

    /// A state whose daemon calls and refusal beeps all land in the
    /// returned recorder.
    private func makeState() -> (AppState, ArchiveRecorder, () -> Void) {
        let suite = TestDefaultsSuite("TBDAppTests.ArchiveSelectionBulkRun")
        let state = AppState(userDefaults: suite.defaults)
        let recorder = ArchiveRecorder()
        recorder.install(on: state)
        return (state, recorder, { suite.tearDown() })
    }

    /// One repo with a row for each name, in sidebar order, none nested.
    private func independentRows(_ state: AppState, _ names: [String]) -> [Worktree] {
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let rows = names.enumerated().map { row($0.element, repoID: repo.id, order: $0.offset) }
        state.repos = [repo]
        state.worktrees = [repo.id: rows]
        return rows
    }

    /// Waits until the run has settled `id`: its call ended, or the run
    /// skipped it or gave up on it. False, with the timeout recorded, when it
    /// does not.
    private func waitUntilSettled(
        _ id: UUID, _ name: String, in state: AppState,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> Bool {
        try await waitFor("the run to settle \(name)", observed: {
            await MainActor.run { "\(state.selectionArchivePendingIDs.count) row(s) still pending" }
        }, sourceLocation: sourceLocation) {
            await MainActor.run { !state.selectionArchivePendingIDs.contains(id) }
        }
    }

    @Test("every row is tried children first, failures make one summary, and nothing is retried")
    func aMixOfSuccessesAndRefusals() async throws {
        let (state, _, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("acme-parent", repoID: repo.id, order: 0)
        let child = row("acme-child", repoID: repo.id, parent: parent.id)
        let guarded = row("acme-guarded", repoID: repo.id, order: 1)
        let dirty = row("acme-dirty", repoID: repo.id, order: 2)
        state.repos = [repo]
        state.worktrees = [repo.id: [parent, child, guarded, dirty]]
        state.selectedWorktreeIDs = [parent.id, child.id, guarded.id, dirty.id]

        let targets = state.selectionArchiveTargets()
        let runOrder = [child.id, parent.id, guarded.id, dirty.id]
        #expect(targets == runOrder)

        // The two refusals the single-row path answers with a prompt.
        let fake = FakeArchiver()
        fake.failures[guarded.id] = DaemonClientError.rpcError(
            "Its agent is still working.", code: RPCErrorCode.remoteLaneArchiveGuarded.rawValue)
        fake.failures[dirty.id] = DaemonClientError.rpcError(
            "acme-dirty has 1 uncommitted change(s) that archiving would delete:\n  ?? notes.md\nCommit or remove them first.",
            code: RPCErrorCode.worktreeArchiveUncommitted.rawValue)

        await state.archiveInBulk(targets) { try fake.archive($0) }

        // Every row was sent once, and the parent only after its child.
        #expect(Set(fake.calls) == Set(runOrder))
        #expect(fake.calls.count == runOrder.count)
        let childCall = try #require(fake.calls.firstIndex(of: child.id))
        let parentCall = try #require(fake.calls.firstIndex(of: parent.id))
        #expect(childCall < parentCall)
        let summary = """
            Archived 2 of 4 worktrees.

            acme-guarded: Its agent is still working.
            acme-dirty: acme-dirty has 1 uncommitted change(s) that archiving would delete.
            """
        #expect(state.alertMessage == summary)
        #expect(state.alertIsError)

        // The successes got the single-row path's settlement; the failures stay.
        let remaining = Set((state.worktrees[repo.id] ?? []).map(\.id))
        let failed: Set<UUID> = [guarded.id, dirty.id]
        #expect(remaining == failed)
        #expect(state.selectedWorktreeIDs == failed)
        #expect(state.recentlyArchivedWorktreeIDs[child.id] != nil)
        #expect(state.recentlyArchivedWorktreeIDs[parent.id] != nil)
        #expect(state.recentlyArchivedWorktreeIDs[guarded.id] == nil)
    }

    @Test("when every row goes, there is no alert")
    func allSucceed() async {
        let (state, recorder, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: repo.id, order: 0)
        let second = row("acme-second", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [first, second]]

        let fake = FakeArchiver()
        let targets = [first.id, second.id]
        #expect(!state.selectionArchiveInFlight)
        await state.archiveInBulk(targets) { worktree in
            try fake.archive(worktree)
            fake.inFlightSeen.append(state.selectionArchiveInFlight)
        }

        #expect(Set(fake.calls) == Set(targets))
        #expect(fake.calls.count == targets.count)
        #expect(state.alertMessage == nil)
        #expect(state.worktrees[repo.id]?.isEmpty == true)
        // The run held the in-flight flag throughout and let it go at the end.
        let seen = [true, true]
        #expect(fake.inFlightSeen == seen)
        #expect(!state.selectionArchiveInFlight)
        #expect(state.selectionArchivePendingIDs.isEmpty)
        #expect(recorder.beeps == 0)
    }

    @Test("a row gone before its turn is not attempted, and the summary counts only what was")
    func aRowGoneBeforeItsTurnIsNotAttempted() async {
        let (state, _, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: repo.id, order: 0)
        let second = row("acme-second", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [first, second]]

        let fake = FakeArchiver()
        fake.failures[second.id] = DaemonClientError.rpcError("Refused.", code: nil)
        let gone = UUID()
        await state.archiveInBulk([first.id, gone, second.id]) { try fake.archive($0) }

        let attempted: Set<UUID> = [first.id, second.id]
        #expect(Set(fake.calls) == attempted)
        #expect(fake.calls.count == attempted.count)
        #expect(state.alertMessage == "Archived 1 of 2 worktrees.\n\nacme-second: Refused.")
    }

    @Test("a refused child holds back its parent, which is not sent to the daemon")
    func aRefusedChildHoldsBackItsParent() async {
        let (state, _, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("acme-parent", repoID: repo.id, order: 0)
        let child = row("acme-child", repoID: repo.id, parent: parent.id)
        let sibling = row("acme-sibling", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [parent, child, sibling]]

        let fake = FakeArchiver()
        fake.failures[child.id] = DaemonClientError.rpcError("Refused.", code: nil)
        await state.archiveInBulk([child.id, parent.id, sibling.id]) { try fake.archive($0) }

        let sent: Set<UUID> = [child.id, sibling.id]
        #expect(Set(fake.calls) == sent)
        #expect(fake.calls.count == sent.count)
        let summary = """
            Archived 1 of 3 worktrees.

            acme-child: Refused.
            acme-parent: Not archived, because its nested worktree "acme-child" was not archived.
            """
        #expect(state.alertMessage == summary)
        let remaining = Set((state.worktrees[repo.id] ?? []).map(\.id))
        let kept: Set<UUID> = [parent.id, child.id]
        #expect(remaining == kept)
        #expect(state.selectionArchivePendingIDs.isEmpty)
    }

    @Test("a refused grandchild holds back the whole chain above it, each naming the row below")
    func aRefusedGrandchildHoldsBackTheChain() async {
        let (state, _, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("acme-parent", repoID: repo.id)
        let child = row("acme-child", repoID: repo.id, parent: parent.id)
        let grandchild = row("acme-grandchild", repoID: repo.id, parent: child.id)
        state.repos = [repo]
        state.worktrees = [repo.id: [parent, child, grandchild]]

        let fake = FakeArchiver()
        fake.failures[grandchild.id] = DaemonClientError.rpcError("Refused.", code: nil)
        await state.archiveInBulk([grandchild.id, child.id, parent.id]) { try fake.archive($0) }

        let sent = [grandchild.id]
        #expect(fake.calls == sent)
        let summary = """
            Archived 0 of 3 worktrees.

            acme-grandchild: Refused.
            acme-child: Not archived, because its nested worktree "acme-grandchild" was not archived.
            acme-parent: Not archived, because its nested worktree "acme-child" was not archived.
            """
        #expect(state.alertMessage == summary)
    }

    // MARK: Calls in flight together

    /// Each call holds a slot until it ends. A run that awaited each call
    /// before starting the next would show one call in flight, not four.
    @Test("six independent rows put four calls in flight before any returns, and the fifth starts when one ends")
    func fourCallsRunAtOnce() async throws {
        let (state, _, teardown) = makeState()
        defer { teardown() }
        let rows = independentRows(state, ["acme-1", "acme-2", "acme-3", "acme-4", "acme-5", "acme-6"])
        let ids = rows.map(\.id)
        let gate = ArchiveGate()
        defer { gate.open() }
        let run = Task { await state.archiveInBulk(ids) { try await gate.archive($0) } }

        guard try await gate.waitForStarts(4) else { return }
        let opening = Set(ids[0..<4])
        #expect(Set(gate.started) == opening)
        #expect(gate.started.count == 4)
        #expect(gate.ended.isEmpty)

        // A slot frees only when a call ends, and it goes to the next row in
        // run order.
        gate.release(ids[1])
        guard try await gate.waitForStarts(5) else { return }
        let afterSecond: [ArchiveCallEvent] = [.end(ids[1]), .start(ids[4])]
        #expect(Array(gate.events.dropFirst(4)) == afterSecond)

        gate.release(ids[3])
        guard try await gate.waitForStarts(6) else { return }
        let afterFourth: [ArchiveCallEvent] = [.end(ids[3]), .start(ids[5])]
        #expect(Array(gate.events.dropFirst(6)) == afterFourth)

        gate.open()
        await run.value
        #expect(gate.peakInFlight == SelectionArchive.maxConcurrentArchives)
        let remaining = rows.filter { state.findWorktree(id: $0.id) != nil }
        #expect(remaining.isEmpty)
        #expect(state.alertMessage == nil)
        #expect(state.selectionArchivePendingIDs.isEmpty)
        #expect(!state.selectionArchiveInFlight)
    }

    /// Unrelated rows behind the parent in run order take the free slots
    /// while it waits.
    @Test("a parent's call starts only once both its selected children's calls have ended")
    func aParentStartsAfterBothChildren() async throws {
        let (state, _, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("acme-parent", repoID: repo.id, order: 0)
        let first = row("acme-first-child", repoID: repo.id, parent: parent.id, order: 0)
        let second = row("acme-second-child", repoID: repo.id, parent: parent.id, order: 1)
        let others = [1, 2, 3].map { row("acme-other-\($0)", repoID: repo.id, order: $0) }
        state.repos = [repo]
        state.worktrees = [repo.id: [parent, first, second] + others]
        let gate = ArchiveGate()
        defer { gate.open() }
        let targets = [first.id, second.id, parent.id] + others.map(\.id)
        let run = Task { await state.archiveInBulk(targets) { try await gate.archive($0) } }

        guard try await gate.waitForStarts(4) else { return }
        let opening: Set<UUID> = [first.id, second.id, others[0].id, others[1].id]
        #expect(Set(gate.started) == opening)

        // One child's end frees a slot, and the parent, still waiting for
        // the other child, is passed over for the next row.
        gate.release(first.id)
        guard try await gate.waitForStarts(5) else { return }
        let afterFirst: [ArchiveCallEvent] = [.end(first.id), .start(others[2].id)]
        #expect(Array(gate.events.dropFirst(4)) == afterFirst)

        gate.release(second.id)
        guard try await gate.waitForStarts(6) else { return }
        let afterSecond: [ArchiveCallEvent] = [.end(second.id), .start(parent.id)]
        #expect(Array(gate.events.dropFirst(6)) == afterSecond)

        gate.open()
        await run.value
        #expect(state.alertMessage == nil)
        #expect(state.findWorktree(id: parent.id) == nil)
    }

    /// The parent is skipped as soon as its child fails, while an unrelated
    /// call is still in flight, and it leaves the run then.
    @Test("a failed child's parent gets no call and is listed with the nested reason")
    func aFailedChildSkipsItsParent() async throws {
        let (state, _, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let parent = row("acme-parent", repoID: repo.id, order: 0)
        let child = row("acme-child", repoID: repo.id, parent: parent.id)
        let sibling = row("acme-sibling", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [parent, child, sibling]]
        let gate = ArchiveGate()
        defer { gate.open() }
        gate.failures[child.id] = DaemonClientError.rpcError("Refused.", code: nil)
        let targets = [child.id, parent.id, sibling.id]
        let run = Task { await state.archiveInBulk(targets) { try await gate.archive($0) } }

        guard try await gate.waitForStarts(2) else { return }
        let sent: Set<UUID> = [child.id, sibling.id]
        #expect(Set(gate.started) == sent)

        gate.release(child.id)
        guard try await waitUntilSettled(parent.id, "acme-parent", in: state) else { return }
        let stillOwned: Set<UUID> = [sibling.id]
        #expect(state.selectionArchivePendingIDs == stillOwned)

        gate.release(sibling.id)
        await run.value
        #expect(Set(gate.started) == sent)
        #expect(gate.started.count == sent.count)
        let summary = """
            Archived 1 of 3 worktrees.

            acme-child: Refused.
            acme-parent: Not archived, because its nested worktree "acme-child" was not archived.
            """
        #expect(state.alertMessage == summary)
        let remaining = Set((state.worktrees[repo.id] ?? []).map(\.id))
        let kept: Set<UUID> = [parent.id, child.id]
        #expect(remaining == kept)
    }

    @Test("a lost connection starts nothing more; the calls in flight end and count, and the rows left share one line")
    func aConnectionFailureStopsTheRun() async throws {
        let (state, _, teardown) = makeState()
        defer { teardown() }
        let rows = independentRows(
            state, ["acme-first", "acme-second", "acme-third", "acme-fourth", "acme-fifth", "acme-sixth"])
        let ids = rows.map(\.id)
        state.isConnected = true
        let gate = ArchiveGate()
        defer { gate.open() }
        gate.failures[ids[1]] = DaemonClientError.daemonNotRunning
        gate.failures[ids[2]] = DaemonClientError.rpcError("Refused.", code: nil)
        // A row gone before its turn is not counted among the rows left, as
        // it is not counted when its turn comes.
        let gone = UUID()
        let targets = Array(ids[0..<5]) + [gone, ids[5]]
        let run = Task { await state.archiveInBulk(targets) { try await gate.archive($0) } }

        guard try await gate.waitForStarts(4) else { return }
        let inFlight = Set(ids[0..<4])
        #expect(Set(gate.started) == inFlight)

        gate.release(ids[1])
        guard try await waitUntilSettled(ids[1], "acme-second", in: state) else { return }
        #expect(!state.isConnected)
        // Nothing more started, and the rows never started are no longer the
        // run's; the calls still in flight are.
        #expect(gate.started.count == 4)
        let stillOwned: Set<UUID> = [ids[0], ids[2], ids[3]]
        #expect(state.selectionArchivePendingIDs == stillOwned)

        for id in [ids[0], ids[2], ids[3]] {
            gate.release(id)
        }
        await run.value
        #expect(Set(gate.started) == inFlight)
        #expect(gate.started.count == 4)
        let summary = """
            Archived 2 of 6 worktrees.

            acme-second: TBD daemon is not running
            acme-third: Refused.
            2 more not attempted: lost the connection to the daemon.
            """
        #expect(state.alertMessage == summary)
        // The calls in flight finished, and their successes left the sidebar.
        let remaining = Set((state.worktrees.values.first ?? []).map(\.id))
        let kept: Set<UUID> = [ids[1], ids[2], ids[4], ids[5]]
        #expect(remaining == kept)
        #expect(state.selectionArchivePendingIDs.isEmpty)
    }

    /// The other branch: a refusal that is not a lost connection leaves the
    /// run starting rows, and a lost connection with no row left to start
    /// leaves nothing to count.
    @Test("a refusal does not stop new starts, and a lost connection with nothing left to start adds no line")
    func aRefusalDoesNotStopTheRun() async throws {
        let (state, _, teardown) = makeState()
        defer { teardown() }
        let rows = independentRows(state, ["acme-first", "acme-second", "acme-third", "acme-fourth", "acme-fifth"])
        let ids = rows.map(\.id)
        state.isConnected = true
        let gate = ArchiveGate()
        defer { gate.open() }
        gate.failures[ids[0]] = DaemonClientError.rpcError("Refused.", code: nil)
        gate.failures[ids[4]] = DaemonClientError.connectionFailed("socket closed")
        let run = Task { await state.archiveInBulk(ids) { try await gate.archive($0) } }

        guard try await gate.waitForStarts(4) else { return }
        // The refusal's slot goes to the fifth row.
        gate.release(ids[0])
        guard try await gate.waitForStarts(5) else { return }
        #expect(gate.started.last == ids[4])

        gate.release(ids[4])
        guard try await waitUntilSettled(ids[4], "acme-fifth", in: state) else { return }
        #expect(!state.isConnected)
        for id in ids[1..<4] {
            gate.release(id)
        }
        await run.value
        let summary = """
            Archived 3 of 5 worktrees.

            acme-first: Refused.
            acme-fifth: Connection failed: socket closed
            """
        #expect(state.alertMessage == summary)
    }

    /// The calls end in reverse run order, and each is settled before the
    /// next is released.
    @Test("failures that end in reverse run order are listed in run order")
    func failuresAreListedInRunOrder() async throws {
        let (state, _, teardown) = makeState()
        defer { teardown() }
        let rows = independentRows(state, ["acme-first", "acme-second", "acme-third"])
        let ids = rows.map(\.id)
        let gate = ArchiveGate()
        defer { gate.open() }
        for (id, reason) in zip(ids, ["First refused.", "Second refused.", "Third refused."]) {
            gate.failures[id] = DaemonClientError.rpcError(reason, code: nil)
        }
        let run = Task { await state.archiveInBulk(ids) { try await gate.archive($0) } }

        guard try await gate.waitForStarts(3) else { return }
        for row in rows.reversed() {
            gate.release(row.id)
            guard try await waitUntilSettled(row.id, row.displayName, in: state) else { return }
        }
        await run.value

        let endedInReverse = [ids[2], ids[1], ids[0]]
        #expect(gate.ended == endedInReverse)
        let summary = """
            Archived 0 of 3 worktrees.

            acme-first: First refused.
            acme-second: Second refused.
            acme-third: Third refused.
            """
        #expect(state.alertMessage == summary)
    }

    /// The row menu and the shortcut, or the shortcut twice: a bulk trigger
    /// while a run is in progress archives nothing, and beeps.
    @Test("a bulk trigger during a run starts nothing, and beeps")
    func aBulkTriggerDuringARunStartsNothing() async {
        let (state, recorder, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: repo.id, order: 0)
        let second = row("acme-second", repoID: repo.id, order: 1)
        let other = row("acme-other", repoID: repo.id, order: 2)
        state.repos = [repo]
        state.worktrees = [repo.id: [first, second, other]]

        let fake = FakeArchiver()
        let nested = FakeArchiver()
        let firstID = first.id
        let otherID = other.id
        await state.archiveInBulk([first.id, second.id]) { worktree in
            try fake.archive(worktree)
            if worktree.id == firstID {
                await state.archiveInBulk([otherID]) { try nested.archive($0) }
            }
        }

        let sent: Set<UUID> = [first.id, second.id]
        #expect(Set(fake.calls) == sent)
        #expect(fake.calls.count == sent.count)
        #expect(nested.calls.isEmpty)
        #expect(recorder.beeps == 1)
        #expect(state.findWorktree(id: other.id) != nil)
        #expect(!state.selectionArchiveInFlight)
    }

    @Test("a trigger while a run holds the flag archives nothing, beeps, and leaves the flag set")
    func aTriggerWhileTheFlagIsSetArchivesNothing() async {
        let (state, recorder, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: repo.id)
        state.repos = [repo]
        state.worktrees = [repo.id: [first]]
        state.selectionArchiveInFlight = true

        let fake = FakeArchiver()
        await state.archiveInBulk([first.id]) { try fake.archive($0) }

        #expect(fake.calls.isEmpty)
        #expect(recorder.beeps == 1)
        #expect(state.selectionArchiveInFlight)
        #expect(state.selectionArchivePendingIDs.isEmpty)
        #expect(state.alertMessage == nil)
        #expect(state.findWorktree(id: first.id) != nil)
    }

    // MARK: The rows a run owns

    /// While a run goes, the rows it has yet to finish are its own. A
    /// single-row archive of one, from the row's own menu or the shortcut,
    /// is refused with a beep and sends nothing, and the run archives the row
    /// once. A row leaves the run when its own call ends, whatever the calls
    /// beside it are doing.
    @Test("the run owns each row until its own call ends, and a single-row archive of one is refused")
    func theRunOwnsEachRowUntilItsCallEnds() async throws {
        let (state, recorder, teardown) = makeState()
        defer { teardown() }
        let rows = independentRows(state, ["acme-first", "acme-second", "acme-third"])
        let ids = rows.map(\.id)
        let gate = ArchiveGate()
        defer { gate.open() }
        let run = Task { await state.archiveInBulk(ids) { try await gate.archive($0) } }

        guard try await gate.waitForStarts(3) else { return }
        #expect(state.selectionArchivePendingIDs == Set(ids))
        await state.archiveWorktree(id: ids[2])
        #expect(recorder.worktreeCalls.isEmpty)
        #expect(recorder.beeps == 1)

        gate.release(ids[0])
        guard try await waitUntilSettled(ids[0], "acme-first", in: state) else { return }
        let stillOwned: Set<UUID> = [ids[1], ids[2]]
        #expect(state.selectionArchivePendingIDs == stillOwned)
        await state.archiveWorktree(id: ids[1])
        #expect(recorder.worktreeCalls.isEmpty)
        #expect(recorder.beeps == 2)

        gate.open()
        await run.value
        #expect(Set(gate.started) == Set(ids))
        #expect(gate.started.count == ids.count)
        // The single-row archives sent nothing.
        #expect(recorder.worktreeCalls.isEmpty)
        #expect(state.selectionArchivePendingIDs.isEmpty)
        #expect(state.alertMessage == nil)
    }

    @Test("a single-row archive of a row a run owns sends nothing and beeps; of another row it runs as before")
    func aSingleRowArchiveOfAnOwnedRowIsRefused() async {
        let (state, recorder, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let owned = row("acme-owned", repoID: repo.id, order: 0)
        let free = row("acme-free", repoID: repo.id, order: 1)
        state.repos = [repo]
        state.worktrees = [repo.id: [owned, free]]
        state.selectionArchivePendingIDs = [owned.id]

        await state.archiveWorktree(id: owned.id)
        #expect(recorder.worktreeCalls.isEmpty)
        #expect(recorder.beeps == 1)
        #expect(state.findWorktree(id: owned.id) != nil)
        #expect(state.alertMessage == nil)

        await state.archiveWorktree(id: free.id)
        let sent = [free.id]
        #expect(recorder.worktreeCalls == sent)
        #expect(recorder.beeps == 1)
        #expect(state.findWorktree(id: free.id) == nil)
        #expect(state.alertMessage == nil)
    }

    @Test("a scratch archive of a row a run owns sends nothing and beeps; of another row it runs as before")
    func aScratchArchiveOfAnOwnedRowIsRefused() async {
        let (state, recorder, teardown) = makeState()
        defer { teardown() }
        let owned = row("acme-owned", repoID: nil)
        let free = row("acme-free", repoID: nil)
        state.scratchWorktrees = [owned, free]
        state.selectionArchivePendingIDs = [owned.id]

        // From the scratch row's own Archive, and through
        // `archiveWorktree(id:)`, which refuses before it hands a scratch row
        // on: one beep each.
        await state.archiveScratch(id: owned.id)
        await state.archiveWorktree(id: owned.id)
        #expect(recorder.scratchCalls.isEmpty)
        #expect(recorder.worktreeCalls.isEmpty)
        #expect(recorder.beeps == 2)
        #expect(state.findWorktree(id: owned.id) != nil)

        await state.archiveScratch(id: free.id)
        let sent = [free.id]
        #expect(recorder.scratchCalls == sent)
        #expect(recorder.scratchRefreshes == 1)
        #expect(recorder.beeps == 2)
        #expect(state.findWorktree(id: free.id) == nil)
    }

    // MARK: The Archived tab

    /// A refusal is not a lost connection: the tab is still refreshed.
    @Test("a run that archives scratch rows refreshes the Archived tab once, a refusal notwithstanding")
    func scratchRowsRefreshTheArchivedTabOnce() async {
        let (state, recorder, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let first = row("acme-first", repoID: nil)
        let second = row("acme-second", repoID: nil)
        let refused = row("acme-refused", repoID: repo.id)
        state.repos = [repo]
        state.worktrees = [repo.id: [refused]]
        state.scratchWorktrees = [first, second]

        let fake = FakeArchiver()
        fake.failures[refused.id] = DaemonClientError.rpcError("Refused.", code: nil)
        await state.archiveInBulk([first.id, second.id, refused.id]) { try fake.archive($0) }

        #expect(recorder.scratchRefreshes == 1)
        #expect(state.alertMessage == "Archived 2 of 3 worktrees.\n\nacme-refused: Refused.")
    }

    /// The refresh is a daemon call too, and after a lost connection it
    /// could only fail.
    @Test("a run stopped by a lost connection does not refresh the Archived tab")
    func aLostConnectionSkipsTheArchivedTabRefresh() async {
        let (state, recorder, teardown) = makeState()
        defer { teardown() }
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let scratch = row("acme-scratch", repoID: nil)
        let lost = row("acme-lost", repoID: repo.id)
        state.repos = [repo]
        state.worktrees = [repo.id: [lost]]
        state.scratchWorktrees = [scratch]

        let fake = FakeArchiver()
        fake.failures[lost.id] = DaemonClientError.daemonNotRunning
        await state.archiveInBulk([scratch.id, lost.id]) { try fake.archive($0) }

        let sent: Set<UUID> = [scratch.id, lost.id]
        #expect(Set(fake.calls) == sent)
        #expect(fake.calls.count == sent.count)
        #expect(recorder.scratchRefreshes == 0)
        #expect(state.findWorktree(id: scratch.id) == nil)
    }

    // MARK: Routes

    /// A refusal's beep is the gesture's (`startArchive`), played before any
    /// task starts; running the route itself archives nothing and plays
    /// nothing.
    @Test("running a route that archives nothing sends nothing and plays nothing")
    func routesThatArchiveNothingSendNothing() async {
        let (state, recorder, teardown) = makeState()
        defer { teardown() }
        await state.runArchive(.nothing)
        await state.runArchive(.refuse)
        #expect(recorder.worktreeCalls.isEmpty)
        #expect(recorder.scratchCalls.isEmpty)
        #expect(recorder.beeps == 0)
    }
}
