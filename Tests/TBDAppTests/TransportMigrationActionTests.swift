import Clocks
import Foundation
import Testing
@testable import TBDApp
import TBDShared

@MainActor
@Suite("TransportMigrationAction")
struct TransportMigrationActionTests {
    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-transport-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    private static func row(
        transport: TerminalTransport, parked: Bool = false, worktreeID: UUID = UUID()
    ) -> Terminal {
        Terminal(
            id: UUID(), worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            hibernatedAt: parked ? Date() : nil, transport: transport)
    }

    @Test func theMenuItemIsOfferedOnlyForARowNotOnTheHolder() {
        #expect(TransportMigrationMenu.isOffered(for: Self.row(transport: .tmux), holderSupported: true))
        #expect(!TransportMigrationMenu.isOffered(for: Self.row(transport: .holder), holderSupported: true))
        #expect(!TransportMigrationMenu.isOffered(for: nil, holderSupported: true))
        #expect(!TransportMigrationMenu.isOffered(for: Self.row(transport: .tmux), holderSupported: false))
    }

    @Test func theActionSendsTheTerminalIDAndVeilsTheRowDuringTheCall() async {
        await withAppState { state in
            let row = Self.row(transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            var sent: [UUID?] = []
            var veil: SwitchingAccount?
            state.terminalTransportMigrator = { @MainActor id in
                sent.append(id)
                veil = state.switchingAccountTerminals[row.id]
                return TerminalMigrateTransportResult(migrated: [row.id], skipped: [], refused: [])
            }
            state.transportMoveClock = CountingImmediateClock(counter: SleepCounter())
            await state.migrateTerminalToHolder(terminalID: row.id)
            #expect(sent == [row.id])
            #expect(veil == .transportMove)
            #expect(veil?.caption == "Moving session off tmux…")
            #expect(state.switchingAccountTerminals[row.id] == nil)
            #expect(state.alertMessage == nil)
        }
    }

    @Test func aHolderRowGetsNoVeil() async {
        await withAppState { state in
            let row = Self.row(transport: .holder)
            state.terminals[row.worktreeID] = [row]
            var veil: SwitchingAccount?
            state.terminalTransportMigrator = { @MainActor _ in
                veil = state.switchingAccountTerminals[row.id]
                return TerminalMigrateTransportResult(
                    migrated: [], skipped: [], refused: [], alreadyHolder: [row.id])
            }
            await state.migrateTerminalToHolder(terminalID: row.id)
            #expect(veil == nil)
        }
    }

    @Test func aSkippedSessionSaysWhyAndTheVeilClears() async {
        await withAppState { state in
            let row = Self.row(transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            state.terminalTransportMigrator = { @MainActor _ in
                TerminalMigrateTransportResult(
                    migrated: [], skipped: [TerminalMigrationSkip(terminalID: row.id, reason: "mid-turn")],
                    refused: [])
            }
            await state.migrateTerminalToHolder(terminalID: row.id)
            #expect(state.alertMessage?.contains(TransportMigrationMenu.skippedAlertPrefix + "mid-turn") == true)
            #expect(state.switchingAccountTerminals[row.id] == nil)
        }
    }

    @Test func aFailedCallClearsTheVeilAndAlerts() async {
        struct Boom: Error {}
        await withAppState { state in
            let row = Self.row(transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            state.terminalTransportMigrator = { @MainActor _ in throw Boom() }
            await state.migrateTerminalToHolder(terminalID: row.id)
            #expect(state.switchingAccountTerminals[row.id] == nil)
            #expect(state.alertMessage != nil)
        }
    }

    @Test func theFleetActionSendsNilAndVeilsOnlyAwakeTmuxRows() async {
        await withAppState { state in
            let wt = UUID()
            let tmux = Self.row(transport: .tmux, worktreeID: wt)
            let parked = Self.row(transport: .tmux, parked: true, worktreeID: wt)
            let holder = Self.row(transport: .holder, worktreeID: wt)
            state.terminals[wt] = [tmux, parked, holder]
            var sent: [UUID?] = []
            var veiled: Set<UUID> = []
            state.terminalTransportMigrator = { @MainActor id in
                sent.append(id)
                veiled = Set(state.switchingAccountTerminals.keys)
                return TerminalMigrateTransportResult(migrated: [tmux.id], skipped: [], refused: [])
            }
            let result = await state.migrateAllTerminalsToHolder()
            #expect(sent.count == 1 && sent[0] == nil)
            #expect(veiled == [tmux.id])
            #expect(state.switchingAccountTerminals.isEmpty)
            #expect(result?.migrated == [tmux.id])
        }
    }

    @Test func theFleetActionClearsTheVeilAndAlertsWhenTheCallFails() async {
        struct Boom: Error {}
        await withAppState { state in
            let row = Self.row(transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            state.terminalTransportMigrator = { @MainActor _ in throw Boom() }
            let result = await state.migrateAllTerminalsToHolder()
            #expect(result == nil)
            #expect(state.switchingAccountTerminals.isEmpty)
            #expect(state.alertMessage != nil)
        }
    }

    // MARK: - The veil's lifetime is adoption, not the reply

    private static func movedRow(like row: Terminal) -> Terminal {
        Terminal(
            id: row.id, worktreeID: row.worktreeID, tmuxWindowID: "", tmuxPaneID: "",
            transport: .holder)
    }

    @Test func theIntermediateWakeDoesNotBumpTheEpochAndAdoptionEndsTheVeil() async {
        await withAppState { state in
            let row = Self.row(transport: .tmux, parked: true)
            state.terminals[row.worktreeID] = [row]
            state.switchingAccountTerminals[row.id] = .transportMove
            let before = state.terminalAttachEpochs[row.id] ?? 0
            state.applyTerminalHibernationDelta(TerminalHibernationDelta(
                terminalID: row.id, worktreeID: row.worktreeID, hibernated: false, keepWarm: false))
            #expect((state.terminalAttachEpochs[row.id] ?? 0) == before,
                    "the wake rebuilt the pane against the window the move retires")
            #expect(state.switchingAccountTerminals[row.id] == .transportMove,
                    "the veil ended before the row was adopted")
            state.adoptRecreatedTerminal(Self.movedRow(like: row))
            #expect(state.switchingAccountTerminals[row.id] == nil)
        }
    }

    @Test func aReplyBeforeAdoptionKeepsTheVeilUpUntilTheBound() async {
        await withAppState { state in
            let row = Self.row(transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            let counter = SleepCounter()
            state.transportMoveClock = CountingImmediateClock(counter: counter)
            state.terminalTransportMigrator = { @MainActor _ in
                TerminalMigrateTransportResult(migrated: [row.id], skipped: [], refused: [])
            }
            await state.migrateTerminalToHolder(terminalID: row.id)
            #expect(counter.count > 0, "the veil cleared on the reply, before adoption")
            #expect(state.switchingAccountTerminals[row.id] == nil, "a lost delta stranded the veil")
        }
    }

    @Test func adoptionBeforeTheReplyEndsTheVeilWithoutWaiting() async {
        await withAppState { state in
            let row = Self.row(transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            let counter = SleepCounter()
            state.transportMoveClock = CountingImmediateClock(counter: counter)
            state.terminalTransportMigrator = { @MainActor _ in
                state.adoptRecreatedTerminal(Self.movedRow(like: row))
                return TerminalMigrateTransportResult(migrated: [row.id], skipped: [], refused: [])
            }
            await state.migrateTerminalToHolder(terminalID: row.id)
            #expect(counter.count == 0)
            #expect(state.switchingAccountTerminals[row.id] == nil)
        }
    }

    @Test func aPaneFailingToAttachMidMoveIsNotAutoRecreated() async {
        await withAppState { state in
            let row = Self.row(transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            state.switchingAccountTerminals[row.id] = .transportMove
            #expect(state.claimAutomaticTerminalRecreation(terminalID: row.id) == .alreadyInFlight)
            state.switchingAccountTerminals[row.id] = nil
            #expect(state.claimAutomaticTerminalRecreation(terminalID: row.id) == .claimed(attempt: 1))
        }
    }

    @Test func theManualRecreationClaimIsAlsoRefusedMidMove() async {
        await withAppState { state in
            let row = Self.row(transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            state.switchingAccountTerminals[row.id] = .transportMove
            #expect(state.claimManualTerminalRecreation(terminalID: row.id) == .alreadyInFlight)
            state.switchingAccountTerminals[row.id] = nil
            #expect(state.claimManualTerminalRecreation(terminalID: row.id) == .claimed)
        }
    }

    @Test func aCaptionOverrideAloneIsNotATransportMove() {
        #expect(!SwitchingAccount(profileName: nil, captionOverride: "x").isTransportMove)
        #expect(SwitchingAccount.transportMove.isTransportMove)
    }

    @Test func theAccountSwitchCaptionIsUnchanged() {
        #expect(SwitchingAccount(profileName: "Acme").caption == "Switching account to Acme…")
        #expect(SwitchingAccount(profileName: nil).caption == "Switching account…")
    }

    @Test func theReportKeepsSkipsAndRefusalsApart() {
        let a = UUID(), b = UUID()
        let result = TerminalMigrateTransportResult(
            migrated: [UUID()], skipped: [TerminalMigrationSkip(terminalID: a, reason: "busy")],
            refused: [TerminalMigrationSkip(terminalID: b, reason: "no holder")],
            alreadyHolder: [UUID(), UUID()])
        let report = TransportMigrationMenu.report(result, label: { $0 == a ? "one" : "two" })
        #expect(report.headline == "Moved 1 · 2 already on the holder · 1 skipped · 1 refused")
        #expect(report.skipped == [.init(label: "one", reason: "busy")])
        #expect(report.refused == [.init(label: "two", reason: "no holder")])
    }
}

/// Counts sleeps without waiting, so a bounded wait is observable and instant.
final class SleepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

struct CountingImmediateClock: Clock {
    typealias Instant = ImmediateClock<Duration>.Instant
    let counter: SleepCounter
    private let base = ImmediateClock<Duration>()
    init(counter: SleepCounter) { self.counter = counter }
    var now: Instant { base.now }
    var minimumResolution: Duration { base.minimumResolution }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        counter.bump()
        try await base.sleep(until: deadline, tolerance: tolerance)
    }
}

/// The reply-races-the-deltas path, on a `TestClock` and through the
/// production delta entry point (`handleDelta`).
@MainActor
@Suite("TransportMigrationRace", .clockDriven, .serialized)
struct TransportMigrationRaceTests {
    private func withAppState(_ body: (AppState) async -> Void) async {
        let name = "tbd-transport-race-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        await body(AppState(userDefaults: defaults))
        defaults.removePersistentDomain(forName: name)
    }

    private func setUp(
        _ state: AppState, clock: TestClock<Duration>
    ) -> Terminal {
        let row = Terminal(
            id: UUID(), worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            transport: .tmux)
        state.terminals[row.worktreeID] = [row]
        state.transportMoveClock = clock
        state.terminalTransportMigrator = { @MainActor _ in
            TerminalMigrateTransportResult(migrated: [row.id], skipped: [], refused: [])
        }
        return row
    }

    private func identity(_ state: AppState, _ row: Terminal) -> String {
        let current = state.terminals[row.worktreeID]!.first { $0.id == row.id }!
        return TerminalPanePresentation.identity(
            for: current, switching: state.switchingAccountTerminals[row.id],
            attachEpoch: state.terminalAttachEpochs[row.id] ?? 0)
    }

    @Test func theDeltasLandingAfterTheReplyCauseOneRebuildAndEndTheVeil() async {
        await withAppState { state in
            let clock = TestClock<Duration>()
            let row = setUp(state, clock: clock)
            let task = Task { @MainActor in await state.migrateTerminalToHolder(terminalID: row.id) }
            // The migrator parks the row before the reply.
            await clock.waitForSuspension()
            state.handleDelta(.terminalHibernationChanged(TerminalHibernationDelta(
                terminalID: row.id, worktreeID: row.worktreeID, hibernated: true, keepWarm: false)))
            var identities = [identity(state, row)]
            await clock.advanceWhenSuspended(by: .milliseconds(300))
            #expect(state.switchingAccountTerminals[row.id] == .transportMove,
                    "the veil cleared on the reply, before the deltas")
            #expect((state.terminalAttachEpochs[row.id] ?? 0) == 0)

            state.handleDelta(.terminalHibernationChanged(TerminalHibernationDelta(
                terminalID: row.id, worktreeID: row.worktreeID, hibernated: false, keepWarm: false)))
            identities.append(identity(state, row))
            var moved = row
            moved.tmuxWindowID = ""
            moved.tmuxPaneID = ""
            moved.transport = .holder
            state.handleDelta(.terminalReplaced(moved))
            await clock.advanceWhenSuspended(by: .milliseconds(100))
            await task.value

            #expect(state.switchingAccountTerminals[row.id] == nil)
            #expect((state.terminalAttachEpochs[row.id] ?? 0) == 0)
            #expect(state.terminals[row.worktreeID]?.first?.tmuxWindowID == "")
            identities.append(identity(state, row))
            let rebuilds = zip(identities, identities.dropFirst()).filter { $0 != $1 }.count
            #expect(rebuilds == 1, "the pane rebuilt \(rebuilds) times; identities: \(identities)")
        }
    }

    @Test func noDeltaMeansTheBoundClearsTheVeil() async {
        await withAppState { state in
            let clock = TestClock<Duration>()
            let row = setUp(state, clock: clock)
            let task = Task { @MainActor in await state.migrateTerminalToHolder(terminalID: row.id) }
            await clock.waitForSuspension()
            #expect(state.switchingAccountTerminals[row.id] == .transportMove)
            await clock.advanceWhenSuspended(by: .seconds(5))
            await task.value
            #expect(state.switchingAccountTerminals[row.id] == nil)
        }
    }
}
