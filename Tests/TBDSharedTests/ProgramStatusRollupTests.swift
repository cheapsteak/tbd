import Testing
import Foundation
@testable import TBDShared

@Suite("ProgramStatusRollup")
struct ProgramStatusRollupTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func entry(
        _ state: ProgramStatusState, kind: ProgramStatusBlockKind? = nil,
        title: String? = nil, msg: String? = nil, at seconds: TimeInterval = 0
    ) -> ProgramStatusEntry {
        ProgramStatusEntry(state: state, kind: kind, title: title, msg: msg, observedAt: at(seconds))
    }

    private func snapshot(
        main: ProgramStatusEntry?, tasks: [ProgramStatusTaskEntry] = []
    ) -> ProgramStatusSnapshot {
        ProgramStatusSnapshot(
            terminalID: UUID(), incarnationID: nil, main: main, tasks: tasks, revision: 1)
    }

    private func task(_ id: String, _ e: ProgramStatusEntry) -> ProgramStatusTaskEntry {
        ProgramStatusTaskEntry(id: id, entry: e)
    }

    // MARK: - mainValue

    @Test func workingMapsToWorking() {
        #expect(ProgramStatusRollup.mainValue(entry(.working)) == .working)
    }

    @Test func blockedAuthMapsToNeedsAuth() {
        #expect(ProgramStatusRollup.mainValue(entry(.blocked, kind: .auth)) == .needsAuth)
    }

    @Test func blockedPermissionMapsToAwaitingInputCarryingKind() {
        let value = ProgramStatusRollup.mainValue(entry(.blocked, kind: .permission, msg: "Run ls?"))
        guard case .awaitingInput(let reason?) = value else {
            Issue.record("expected awaitingInput, got \(value)")
            return
        }
        #expect(reason.message == "Run ls?")
        #expect(reason.programStatusBlock == ProgramStatusBlock(kind: .permission, taskID: nil))
        #expect(reason.classification == .promptOnScreen)
    }

    @Test func blockedWithoutKindFallsBackToTitleThenEmpty() {
        let titled = ProgramStatusRollup.mainValue(entry(.blocked, title: "Dialog"))
        guard case .awaitingInput(let reason?) = titled else {
            Issue.record("expected awaitingInput, got \(titled)")
            return
        }
        #expect(reason.message == "Dialog")
        #expect(reason.programStatusBlock == ProgramStatusBlock(kind: nil, taskID: nil))

        let bare = ProgramStatusRollup.mainValue(entry(.blocked))
        guard case .awaitingInput(let bareReason?) = bare else {
            Issue.record("expected awaitingInput, got \(bare)")
            return
        }
        #expect(bareReason.message == "")
    }

    @Test func blockedUnrecognizedKindIsCarriedAsIs() {
        let value = ProgramStatusRollup.mainValue(entry(.blocked, kind: .unrecognized("future")))
        guard case .awaitingInput(let reason?) = value else {
            Issue.record("expected awaitingInput, got \(value)")
            return
        }
        #expect(reason.programStatusBlock?.kind == .unrecognized("future"))
    }

    @Test func terminalStatesMap() {
        #expect(ProgramStatusRollup.mainValue(entry(.error)) == .error)
        #expect(ProgramStatusRollup.mainValue(entry(.done)) == .done)
        #expect(ProgramStatusRollup.mainValue(entry(.idle)) == .idle)
    }

    @Test func clearAndUnrecognizedMapToUnknown() {
        #expect(ProgramStatusRollup.mainValue(entry(.clear)) == .unknown(why: "program status cleared"))
        #expect(ProgramStatusRollup.mainValue(entry(.unrecognized("paused")))
                == .unknown(why: "unrecognized program status state 'paused'"))
    }

    // MARK: - resolve

    @Test func noMainResolvesToNil() {
        let snap = snapshot(main: nil, tasks: [task("a", entry(.working))])
        #expect(ProgramStatusRollup.resolve(snap) == nil)
    }

    @Test func rule1MainBlockBeatsBlockedTask() throws {
        let snap = snapshot(
            main: entry(.blocked, kind: .question, msg: "main asks", at: 1),
            tasks: [task("a", entry(.blocked, kind: .permission, title: "task asks", at: 5)),
                    task("b", entry(.working, at: 6))])
        let resolution = try #require(ProgramStatusRollup.resolve(snap))
        guard case .awaitingInput(let reason?) = resolution.value else {
            Issue.record("expected awaitingInput, got \(resolution.value)")
            return
        }
        #expect(reason.programStatusBlock == ProgramStatusBlock(kind: .question, taskID: nil))
        #expect(resolution.observedAt == at(1))
        #expect(resolution.workingTaskCount == 1)
    }

    @Test func rule1ErrorAndNeedsAuthBeatTasks() throws {
        let tasks = [task("a", entry(.blocked, at: 5))]
        let err = try #require(ProgramStatusRollup.resolve(snapshot(main: entry(.error, at: 2), tasks: tasks)))
        #expect(err.value == .error)
        #expect(err.observedAt == at(2))
        let auth = try #require(ProgramStatusRollup.resolve(
            snapshot(main: entry(.blocked, kind: .auth, at: 3), tasks: tasks)))
        #expect(auth.value == .needsAuth)
    }

    @Test func rule2BlockedTaskBeatsWorkingMain() throws {
        let snap = snapshot(
            main: entry(.working, at: 1),
            tasks: [task("a", entry(.working, at: 2)),
                    task("b", entry(.blocked, kind: .permission, title: "Subagent B", msg: "m", at: 3)),
                    task("c", entry(.blocked, title: "Subagent C", at: 4))])
        let resolution = try #require(ProgramStatusRollup.resolve(snap))
        guard case .awaitingInput(let reason?) = resolution.value else {
            Issue.record("expected awaitingInput, got \(resolution.value)")
            return
        }
        // First blocked task in insertion order, labelled with its title.
        #expect(reason.message == "Subagent B")
        #expect(reason.programStatusBlock == ProgramStatusBlock(kind: .permission, taskID: "b"))
        #expect(resolution.observedAt == at(3))
        #expect(resolution.workingTaskCount == 1)
    }

    @Test func rule2FallsBackToMsgWhenTaskHasNoTitle() throws {
        let snap = snapshot(main: entry(.done), tasks: [task("a", entry(.blocked, msg: "waiting", at: 1))])
        let resolution = try #require(ProgramStatusRollup.resolve(snap))
        guard case .awaitingInput(let reason?) = resolution.value else {
            Issue.record("expected awaitingInput, got \(resolution.value)")
            return
        }
        #expect(reason.message == "waiting")
    }

    @Test func rule3WorkingMainCountsWorkingTasks() throws {
        let snap = snapshot(
            main: entry(.working, at: 1),
            tasks: [task("a", entry(.working, at: 4)), task("b", entry(.working, at: 2))])
        let resolution = try #require(ProgramStatusRollup.resolve(snap))
        #expect(resolution.value == .working)
        #expect(resolution.workingTaskCount == 2)
        #expect(resolution.observedAt == at(4))
    }

    @Test func rule3TasksWorkingUnderDoneMainIsWorking() throws {
        // The delegation case: the parent turn ended, its subagents run on.
        let snap = snapshot(
            main: entry(.done, at: 10),
            tasks: [task("a", entry(.working, at: 3))])
        let resolution = try #require(ProgramStatusRollup.resolve(snap))
        #expect(resolution.value == .working)
        #expect(resolution.workingTaskCount == 1)
        #expect(resolution.observedAt == at(3))
    }

    @Test func rule4DoneAndIdle() throws {
        let done = try #require(ProgramStatusRollup.resolve(snapshot(main: entry(.done, at: 7))))
        #expect(done.value == .done)
        #expect(done.workingTaskCount == 0)
        #expect(done.observedAt == at(7))
        let idle = try #require(ProgramStatusRollup.resolve(snapshot(main: entry(.idle))))
        #expect(idle.value == .idle)
    }

    // MARK: - Wire

    @Test func snapshotRoundTrips() throws {
        let original = ProgramStatusSnapshot(
            terminalID: UUID(), incarnationID: UUID(),
            main: ProgramStatusEntry(state: .blocked, kind: .permission, title: "T", msg: "M",
                                     progress: 40, observedAt: at(1)),
            tasks: [task("bg-1", entry(.working, title: "sub", at: 2))],
            revision: 9)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProgramStatusSnapshot.self, from: data)
        #expect(decoded == original)
        #expect(decoded.isAuthoritative)
        #expect(!decoded.isEmpty)
    }

    @Test func emptySnapshotIsNotAuthoritative() {
        let empty = snapshot(main: nil)
        #expect(empty.isEmpty)
        #expect(!empty.isAuthoritative)
    }

    @Test func programStatusDeltaRoundTrips() throws {
        let snap = ProgramStatusSnapshot(
            terminalID: UUID(), incarnationID: nil, main: entry(.working),
            tasks: [], revision: 3)
        let data = try JSONEncoder().encode(StateDelta.terminalProgramStatusChanged(snap))
        let decoded = try JSONDecoder().decode(StateDelta.self, from: data)
        guard case .terminalProgramStatusChanged(let roundTripped) = decoded else {
            Issue.record("expected terminalProgramStatusChanged, got \(decoded)")
            return
        }
        #expect(roundTripped == snap)
    }
}
