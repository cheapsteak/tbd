import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1. The resolver's program-status rung (4): the snapshot's precedence
/// over the activity columns, the columns speaking when the store holds
/// nothing, and the states TBD owns outranking both.
@Suite("SessionStateResolver program status")
struct ProgramStatusResolverTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let resolveNow = Date(timeIntervalSince1970: 1_700_010_000)

    private func resolver() -> SessionStateResolver {
        let pinned = resolveNow
        return SessionStateResolver(now: { pinned })
    }

    /// A holder Claude row whose columns the program status store wrote.
    private func terminal(
        incarnation: UUID?,
        columnState: TerminalActivityState = .idle,
        columnAt: Date? = nil,
        reason: AwaitingInputReason? = nil,
        hibernatedAt: Date? = nil,
        pendingResumeAt: Date? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "",
            tmuxPaneID: "",
            sessionIncarnationID: incarnation,
            kind: .claude,
            activityState: columnState,
            hibernatedAt: hibernatedAt,
            hibernateReason: hibernatedAt == nil ? nil : .manual,
            pendingResumeAt: pendingResumeAt,
            activityStateSource: .programStatus,
            activityStateObservedAt: columnAt ?? t0.addingTimeInterval(1_000),
            awaitingInputReason: reason,
            awaitingInputObservedAt: reason == nil ? nil : (columnAt ?? t0.addingTimeInterval(1_000)),
            transport: .holder)
    }

    private func snapshot(
        for terminal: Terminal, incarnation: UUID?,
        main: ProgramStatusEntry?, tasks: [ProgramStatusTaskEntry] = []
    ) -> ProgramStatusSnapshot {
        ProgramStatusSnapshot(
            terminalID: terminal.id, incarnationID: incarnation,
            main: main, tasks: tasks, revision: 1)
    }

    private func entry(_ state: ProgramStatusState, at seconds: TimeInterval) -> ProgramStatusEntry {
        ProgramStatusEntry(state: state, observedAt: t0.addingTimeInterval(seconds))
    }

    @Test func theSnapshotOutranksTheColumn() {
        let incarnation = UUID()
        // The column says idle, stamped a thousand seconds after the snapshot's
        // report.
        let row = terminal(
            incarnation: incarnation, columnState: .idle, columnAt: t0.addingTimeInterval(1_000))
        let snap = snapshot(for: row, incarnation: incarnation, main: entry(.working, at: 10))
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: snap))
        #expect(state.value == .working)
        #expect(state.source == .programStatus)
        #expect(state.observedAt == t0.addingTimeInterval(10))
    }

    @Test func oscDoneIsReportedAsDone() {
        let incarnation = UUID()
        let row = terminal(incarnation: incarnation, columnState: .working)
        let snap = snapshot(for: row, incarnation: incarnation, main: entry(.done, at: 10))
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: snap))
        #expect(state.value == .done)
        #expect(state.source == .programStatus)
    }

    @Test func parkedOutranksOSC() {
        let incarnation = UUID()
        let parkedAt = t0.addingTimeInterval(50)
        let row = terminal(incarnation: incarnation, hibernatedAt: parkedAt)
        let snap = snapshot(for: row, incarnation: incarnation, main: entry(.working, at: 10))
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: snap))
        #expect(state.value == .parked(reason: "manual"))
        #expect(state.source == .database)
    }

    @Test func goneOutranksOSC() {
        let incarnation = UUID()
        let row = terminal(incarnation: incarnation)
        let snap = snapshot(for: row, incarnation: incarnation, main: entry(.working, at: 10))
        let state = resolver().resolve(SessionStateFacts(
            terminal: row,
            liveness: ObservedFact(value: false, source: .processLiveness, observedAt: t0),
            programStatus: snap))
        #expect(state.value == .gone)
    }

    @Test func rateLimitedOutranksOSC() {
        let incarnation = UUID()
        let until = t0.addingTimeInterval(3_600)
        let row = terminal(incarnation: incarnation, pendingResumeAt: until)
        let snap = snapshot(for: row, incarnation: incarnation, main: entry(.working, at: 10))
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: snap))
        #expect(state.value == .rateLimited(until: until))
        #expect(state.source == .database)
    }

    @Test func snapshotForAnotherIncarnationIsIgnored() {
        let row = terminal(incarnation: UUID(), columnState: .idle)
        let snap = snapshot(for: row, incarnation: UUID(), main: entry(.working, at: 10))
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: snap))
        #expect(state.value == .idle)
        #expect(state.observedAt == t0.addingTimeInterval(1_000))
    }

    @Test func snapshotWithoutMainFallsBackToTheColumn() {
        // After a main `clear`, task entries alone do not make the terminal
        // OSC-authoritative.
        let incarnation = UUID()
        let row = terminal(incarnation: incarnation, columnState: .idle)
        let snap = snapshot(
            for: row, incarnation: incarnation, main: nil,
            tasks: [ProgramStatusTaskEntry(id: "a", entry: entry(.working, at: 10))])
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: snap))
        #expect(state.value == .idle)
        #expect(state.observedAt == t0.addingTimeInterval(1_000))
    }

    @Test func unrecognizedMainStateFallsBackToTheColumn() {
        let incarnation = UUID()
        let row = terminal(incarnation: incarnation, columnState: .idle)
        let snap = snapshot(
            for: row, incarnation: incarnation, main: entry(.unrecognized("paused"), at: 10))
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: snap))
        #expect(state.value == .idle)
        #expect(state.observedAt == t0.addingTimeInterval(1_000))
    }

    @Test func unrecognizedMainStillHonoursABlockedTask() {
        let incarnation = UUID()
        let row = terminal(incarnation: incarnation, columnState: .idle)
        let snap = snapshot(
            for: row, incarnation: incarnation, main: entry(.unrecognized("paused"), at: 10),
            tasks: [ProgramStatusTaskEntry(id: "a", entry: entry(.blocked, at: 11))])
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: snap))
        guard case .awaitingInput = state.value else {
            Issue.record("expected awaitingInput, got \(state.value)")
            return
        }
        #expect(state.source == .programStatus)
    }

    @Test func noSnapshotLeavesTheColumnSpeaking() {
        let row = terminal(incarnation: nil, columnState: .idle)
        let state = resolver().resolve(SessionStateFacts(terminal: row))
        #expect(state.value == .idle)
        #expect(state.source == .programStatus)
        #expect(state.observedAt == t0.addingTimeInterval(1_000))
    }

    /// After a daemon restart the store holds nothing, and the column the
    /// store wrote before it is what speaks: a wait, with its block.
    @Test func theColumnSpeaksWhenTheStoreIsEmpty() throws {
        let block = ProgramStatusBlock(kind: .question, taskID: nil)
        let row = terminal(
            incarnation: UUID(), columnState: .waitingForUser,
            columnAt: t0.addingTimeInterval(30),
            reason: AwaitingInputReason(message: "", programStatusBlock: block))
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: nil))
        guard case .awaitingInput(let reason) = state.value else {
            Issue.record("expected awaitingInput, got \(state.value)")
            return
        }
        #expect(try #require(reason).programStatusBlock == block)
        #expect(state.source == .programStatus)
        #expect(state.observedAt == t0.addingTimeInterval(30))
    }
}
