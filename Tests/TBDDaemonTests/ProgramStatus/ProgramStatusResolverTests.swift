import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1. The resolver's program-status rung (3½): OSC precedence over the
/// hook rail, and the states TBD owns outranking it.
@Suite("SessionStateResolver program status")
struct ProgramStatusResolverTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let resolveNow = Date(timeIntervalSince1970: 1_700_010_000)

    private func resolver() -> SessionStateResolver {
        let pinned = resolveNow
        return SessionStateResolver(now: { pinned })
    }

    private func terminal(
        incarnation: UUID?,
        hookState: TerminalActivityState = .idle,
        hookAt: Date? = nil,
        hibernatedAt: Date? = nil,
        pendingResumeAt: Date? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(),
            tmuxWindowID: "",
            tmuxPaneID: "",
            sessionIncarnationID: incarnation,
            kind: .claude,
            activityState: hookState,
            hibernatedAt: hibernatedAt,
            hibernateReason: hibernatedAt == nil ? nil : .manual,
            pendingResumeAt: pendingResumeAt,
            activityStateSource: .hookEvent("Stop"),
            activityStateObservedAt: hookAt ?? t0.addingTimeInterval(1_000),
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

    @Test func oscWorkingBeatsANewerHookIdle() {
        let incarnation = UUID()
        // The hook says idle, a thousand seconds after the OSC report.
        let row = terminal(incarnation: incarnation, hookState: .idle, hookAt: t0.addingTimeInterval(1_000))
        let snap = snapshot(for: row, incarnation: incarnation, main: entry(.working, at: 10))
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: snap))
        #expect(state.value == .working)
        #expect(state.source == .programStatus)
        #expect(state.observedAt == t0.addingTimeInterval(10))
    }

    @Test func oscDoneIsReportedAsDone() {
        let incarnation = UUID()
        let row = terminal(incarnation: incarnation, hookState: .working)
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
        let row = terminal(incarnation: UUID(), hookState: .idle)
        let snap = snapshot(for: row, incarnation: UUID(), main: entry(.working, at: 10))
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: snap))
        #expect(state.value == .idle)
        #expect(state.source == .hookEvent("Stop"))
    }

    @Test func snapshotWithoutMainFallsBackToTheHookRail() {
        // After a main `clear`, task entries alone do not make the terminal
        // OSC-authoritative.
        let incarnation = UUID()
        let row = terminal(incarnation: incarnation, hookState: .idle)
        let snap = snapshot(
            for: row, incarnation: incarnation, main: nil,
            tasks: [ProgramStatusTaskEntry(id: "a", entry: entry(.working, at: 10))])
        let state = resolver().resolve(SessionStateFacts(terminal: row, programStatus: snap))
        #expect(state.value == .idle)
        #expect(state.source == .hookEvent("Stop"))
    }

    @Test func noSnapshotLeavesTheHookRailUntouched() {
        let row = terminal(incarnation: nil, hookState: .idle)
        let state = resolver().resolve(SessionStateFacts(terminal: row))
        #expect(state.value == .idle)
        #expect(state.source == .hookEvent("Stop"))
    }
}
