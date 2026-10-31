import Foundation
import Observation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1: in-memory AppState on an EventDrivenTestClock; no daemon, no real
// sleeps in the behavior under test.

/// `AppState`'s per-incarnation sightings behind the no-status mark: the grace
/// timer on the injected clock, the first report clearing the mark, a new
/// incarnation restarting it, and shells and parked or removed rows never
/// holding one.
/// Design: `docs/specs/2026-10-30-osc-only-agent-status-design.md`, "Sessions
/// that cannot report".
@MainActor
@Suite("NoStatusSighting", .clockDriven)
struct NoStatusSightingTests {
    /// The grace timer arms from a `Task { @MainActor }` and its fire needs the
    /// main actor again, so every wait gets the saturated-pass budget.
    private static let mainActorHop = TestDeadlines.saturatedPass

    private func withAppState(
        _ body: (AppState, EventDrivenTestClock) async throws -> Void
    ) async rethrows {
        let suite = TestDefaultsSuite("tbd-no-status-sighting")
        defer { suite.tearDown() }
        let state = AppState(userDefaults: suite.defaults)
        let clock = EventDrivenTestClock()
        state.noStatusClock = clock
        // Emptying `terminals` cancels any timer still parked on the clock.
        defer { state.terminals = [:] }
        try await body(state, clock)
    }

    private func agentRow(
        kind: TerminalKind = .claude,
        incarnation: UUID? = UUID()
    ) -> TBDShared.Terminal {
        TBDShared.Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            sessionIncarnationID: incarnation, kind: kind,
            activityState: .unknown, transport: .tmux)
    }

    private func current(_ state: AppState, _ row: TBDShared.Terminal) -> TBDShared.Terminal? {
        state.terminals[row.worktreeID]?.first { $0.id == row.id }
    }

    private func help(_ state: AppState, _ row: TBDShared.Terminal) -> String? {
        guard let terminal = current(state, row) else { return nil }
        return NoStatusMark.help(for: terminal, sighting: state.noStatusSightings[row.id])
    }

    private func awaitGraceElapsed(_ state: AppState, _ terminalID: UUID) async -> PollOutcome {
        await pollUntilTrue(timeout: Self.mainActorHop) { @Sendable in
            await MainActor.run { state.noStatusSightings[terminalID]?.graceElapsed == true }
        }
    }

    @Test func theMarkShowsAfterTheGraceAndTheFirstReportClearsIt() async throws {
        try await withAppState { state, clock in
            let row = agentRow()
            state.terminals[row.worktreeID] = [row]
            #expect(state.noStatusSightings[row.id]
                == NoStatusSighting(incarnationID: row.sessionIncarnationID, graceElapsed: false))

            try await clock.requireSleeperArmed(timeout: Self.mainActorHop)
            #expect(help(state, row) == nil)

            // A second short of the grace, the timer is still waiting.
            await clock.advance(by: NoStatusMark.grace - .seconds(1))
            #expect(clock.hasSleeper, "the grace ran out before 15 seconds")
            #expect(help(state, row) == nil)

            try await clock.requireAdvanceWhenArmed(by: .seconds(1), timeout: Self.mainActorHop)
            let elapsed = await awaitGraceElapsed(state, row.id)
            #expect(elapsed == .satisfied, "the grace never marked the sighting elapsed")
            #expect(help(state, row) == NoStatusMark.tmuxHelp)

            state.handleDelta(.terminalActivityUpdated(TerminalActivityDelta(
                terminalID: row.id, worktreeID: row.worktreeID, activityState: .idle)))
            #expect(state.noStatusSightings[row.id] == nil)
            #expect(help(state, row) == nil)
            let rowHelp = NoStatusMark.rowHelp(
                terminals: state.terminals[row.worktreeID] ?? [], sightings: state.noStatusSightings)
            #expect(rowHelp == nil)
        }
    }

    @Test func aNewIncarnationRestartsTheGrace() async throws {
        try await withAppState { state, clock in
            let row = agentRow()
            state.terminals[row.worktreeID] = [row]
            try await clock.requireAdvanceWhenArmed(by: NoStatusMark.grace, timeout: Self.mainActorHop)
            let elapsed = await awaitGraceElapsed(state, row.id)
            #expect(elapsed == .satisfied, "the grace never marked the sighting elapsed")
            #expect(help(state, row) == NoStatusMark.tmuxHelp)

            // The row is relaunched and is still at `.unknown`.
            var relaunched = row
            let next = UUID()
            relaunched.sessionIncarnationID = next
            state.terminals[row.worktreeID] = [relaunched]
            #expect(state.noStatusSightings[row.id]
                == NoStatusSighting(incarnationID: next, graceElapsed: false))
            #expect(help(state, row) == nil)
            try await clock.requireSleeperArmed(timeout: Self.mainActorHop)
        }
    }

    @Test func aShellArmsNoTimerAndAnAgentBesideItDoes() async throws {
        try await withAppState { state, clock in
            let shell = agentRow(kind: .shell)
            state.terminals[shell.worktreeID] = [shell]
            #expect(state.noStatusSightings.isEmpty)
            let armed = await watchForSleeper(on: clock)
            #expect(!armed, "a shell terminal armed a no-status timer")

            var agent = agentRow(kind: .codex)
            agent.worktreeID = shell.worktreeID
            state.terminals[shell.worktreeID] = [shell, agent]
            #expect(state.noStatusSightings[agent.id] != nil)
            #expect(state.noStatusSightings[shell.id] == nil)
            try await clock.requireSleeperArmed(timeout: Self.mainActorHop)
        }
    }

    @Test func aParkedOrRemovedRowLosesItsSighting() async throws {
        try await withAppState { state, clock in
            let row = agentRow()
            state.terminals[row.worktreeID] = [row]
            #expect(state.noStatusSightings[row.id] != nil)
            try await clock.requireSleeperArmed(timeout: Self.mainActorHop)

            state.terminals[row.worktreeID]?[0].hibernatedAt = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(state.noStatusSightings[row.id] == nil)

            state.terminals[row.worktreeID]?[0].hibernatedAt = nil
            #expect(state.noStatusSightings[row.id] != nil)

            state.terminals[row.worktreeID] = nil
            #expect(state.noStatusSightings[row.id] == nil)
        }
    }

    /// One delta can write a row several times — a wake's delta un-parks it,
    /// then gives it its new incarnation — and the sightings are reconciled
    /// once, against the row the delta leaves. Reconciled after each write,
    /// the un-parked row still carrying its parked incarnation would get a
    /// sighting and a grace timer, both thrown away a write later for the
    /// woken incarnation's: three writes to the sightings and two timers
    /// where one of each is right.
    @Test func aDeltaThatWritesARowSeveralTimesStartsOneSighting() async throws {
        try await withAppState { state, clock in
            let woken = UUID()
            var row = agentRow()
            row.hibernatedAt = Date(timeIntervalSince1970: 1_800_000_000)
            state.terminals[row.worktreeID] = [row]
            #expect(state.noStatusSightings.isEmpty)

            let writes = SightingWriteCounter(state)
            state.handleDelta(.terminalHibernationChanged(TerminalHibernationDelta(
                terminalID: row.id, worktreeID: row.worktreeID,
                hibernated: false, keepWarm: false, sessionIncarnationID: woken)))
            writes.stop()

            #expect(writes.count == 1)
            #expect(state.noStatusSightings[row.id]
                == NoStatusSighting(incarnationID: woken, graceElapsed: false))
            try await clock.requireSleeperArmed(timeout: Self.mainActorHop)
        }
    }
}

/// Counts writes to `AppState.noStatusSightings`. Observation's `onChange` is
/// one-shot, so it re-arms inside the callback, synchronously, to hear every
/// write of a burst made within one synchronous call.
@MainActor
private final class SightingWriteCounter {
    private let state: AppState
    private var isLive = true
    private(set) var count = 0

    init(_ state: AppState) {
        self.state = state
        arm()
    }

    func stop() {
        isLive = false
    }

    private func arm() {
        withObservationTracking {
            _ = state.noStatusSightings
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isLive else { return }
                self.count += 1
                self.arm()
            }
        }
    }
}
