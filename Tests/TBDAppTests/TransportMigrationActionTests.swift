import Clocks
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

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
        func offered(_ terminal: Terminal?, holderSupported: Bool = true) -> Bool {
            TransportMigrationMenu.isOffered(
                for: terminal, holderSupported: holderSupported, watchMode: .off)
        }
        #expect(offered(Self.row(transport: .tmux)))
        #expect(!offered(Self.row(transport: .holder)))
        #expect(!offered(nil))
        #expect(!offered(Self.row(transport: .tmux), holderSupported: false))
    }

    /// The app half of the Nightwatch/holder gate: nobody is offered a gesture
    /// the daemon refuses. Both branches, because the offer is a conditional.
    @Test func theMenuItemIsNotOfferedWhileAWatchModeIsLive() {
        let row = Self.row(transport: .tmux)
        #expect(TransportMigrationMenu.isOffered(
            for: row, holderSupported: true, watchMode: .off))
        for mode in [NightwatchMode.daywatch, .nightwatch] {
            #expect(!TransportMigrationMenu.isOffered(
                for: row, holderSupported: true, watchMode: mode),
                    "the move was offered with \(mode) active")
            #expect(TransportMigrationMenu.isBlockedByWatchMode(mode))
        }
        #expect(!TransportMigrationMenu.isBlockedByWatchMode(.off))
    }

    @Test func theActionSendsTheTerminalIDAndVeilsTheRowDuringTheCall() async {
        await withAppState { state in
            let row = Self.row(transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            var sent: [UUID] = []
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

    /// The fleet run is composed from the per-session move: one single-id RPC
    /// per non-holder row, never the daemon's `--all`. A sequential
    /// park-and-respawn of a real fleet outruns the app's 300 s receive
    /// deadline, and when it does the whole report is lost.
    @Test func theFleetActionSendsOneIDPerNonHolderRow() async {
        await withAppState { state in
            let wt = UUID()
            let tmux = Self.row(transport: .tmux, worktreeID: wt)
            let parked = Self.row(transport: .tmux, parked: true, worktreeID: wt)
            let holder = Self.row(transport: .holder, worktreeID: wt)
            state.terminals[wt] = [tmux, parked, holder]
            var sent: [UUID] = []
            var veiledPerCall: [UUID: Set<UUID>] = [:]
            state.transportMoveClock = CountingImmediateClock(counter: SleepCounter())
            state.terminalTransportMigrator = { @MainActor id in
                sent.append(id)
                veiledPerCall[id] = Set(state.switchingAccountTerminals.keys)
                return TerminalMigrateTransportResult(
                    migrated: [id], skipped: [], refused: [])
            }
            let result = await state.migrateAllTerminalsToHolder()
            // A parked row has no live pane, so it is moved without a veil.
            #expect(Set(sent) == [tmux.id, parked.id],
                    "the run did not cover every non-holder row: \(sent)")
            #expect(veiledPerCall[tmux.id] == [tmux.id],
                    "the awake row was not veiled for its own call")
            #expect(veiledPerCall[parked.id]?.isEmpty == true,
                    "a parked row was veiled")
            #expect(state.switchingAccountTerminals.isEmpty)
            #expect(Set(result.migrated) == [tmux.id, parked.id])
            // The holder row is answered from the cache rather than by a no-op
            // round trip of its own.
            #expect(result.alreadyHolder == [holder.id])
        }
    }

    /// A throw stops the run: the thrown row is named with an unknown outcome
    /// (not "still on tmux"), every later row is named as untried, and the rows
    /// that moved before it stay in the report.
    @Test func theFleetActionKeepsTheReportWhenACallFails() async {
        struct Boom: LocalizedError {
            var errorDescription: String? { "daemon went away" }
        }
        await withAppState { state in
            let wt = UUID()
            let rows = (0..<5).map { _ in
                Self.row(transport: .tmux, parked: true, worktreeID: wt)
            }
            state.terminals[wt] = rows
            let order = state.terminals[wt]!.map(\.id)
            state.terminalTransportMigrator = { @MainActor id in
                if order.firstIndex(of: id)! < 2 {
                    return TerminalMigrateTransportResult(
                        migrated: [id], skipped: [], refused: [])
                }
                throw Boom()
            }
            let result = await state.migrateAllTerminalsToHolder()
            #expect(result.migrated == Array(order[0..<2]),
                    "the finished sessions vanished from the report")
            #expect(result.refused.isEmpty)
            let reasons = Dictionary(
                uniqueKeysWithValues: result.skipped.map { ($0.terminalID, $0.reason) })
            #expect(reasons[order[2]] == TransportMigrationMenu.outcomeUnknownReason)
            #expect(reasons[order[3]] == TransportMigrationMenu.runStoppedReason)
            #expect(reasons[order[4]] == TransportMigrationMenu.runStoppedReason)
            #expect(reasons.count == 3)
            #expect(state.switchingAccountTerminals.isEmpty)
            #expect(state.alertMessage != nil)
        }
    }

    /// A row another operation has veiled gets no RPC, but is still named.
    @Test func theFleetActionNamesARowAnotherOperationHasVeiled() async {
        await withAppState { state in
            let wt = UUID()
            let veiled = Self.row(transport: .tmux, worktreeID: wt)
            let plain = Self.row(transport: .tmux, parked: true, worktreeID: wt)
            state.terminals[wt] = [veiled, plain]
            state.switchingAccountTerminals[veiled.id] = .transportMove
            var sent: [UUID] = []
            state.terminalTransportMigrator = { @MainActor id in
                sent.append(id)
                return TerminalMigrateTransportResult(
                    migrated: [id], skipped: [], refused: [])
            }
            let result = await state.migrateAllTerminalsToHolder()
            #expect(sent == [plain.id], "the veiled row was sent: \(sent)")
            #expect(result.skipped.map(\.terminalID) == [veiled.id])
            #expect(result.skipped.first?.reason == TransportMigrationMenu.paneBusyReason)
            #expect(result.migrated == [plain.id])
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
        #expect(report.movedNotResumed.isEmpty)
    }

    /// A row that moved and did not restart is neither a skip nor a refusal:
    /// "can't be moved" would be false about it, and leaving it out of the
    /// headline undercounts what the run did.
    @Test func theReportCountsAndHeadsAMoveThatDidNotRestart() {
        let a = UUID()
        let result = TerminalMigrateTransportResult(
            migrated: [UUID()],
            movedNotResumed: [TerminalMigrationSkip(terminalID: a, reason: "focus the tab")],
            skipped: [], refused: [])
        let report = TransportMigrationMenu.report(result, label: { _ in "one" })
        #expect(report.headline == "Moved 1 · 1 moved but not restarted")
        #expect(report.movedNotResumed == [.init(label: "one", reason: "focus the tab")])
        #expect(report.refused.isEmpty, "a session that moved was grouped with the refusals")
        #expect(report.movedNotResumedHeading.contains("Moved to the holder"))
        #expect(report.skippedHeading == "Check these and try again")
        #expect(report.refusedHeading == "Can't be moved until this changes")
    }

    /// The single-session alert, same distinction. And the veil still waits for
    /// the adoption of a row that moved without restarting — it has moved, so
    /// its pane must not stay attached to the retired window.
    @Test func aMoveThatDidNotRestartAlertsAndStillWaitsForAdoption() async {
        await withAppState { state in
            let row = Self.row(transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            let counter = SleepCounter()
            state.transportMoveClock = CountingImmediateClock(counter: counter)
            state.terminalTransportMigrator = { @MainActor id in
                TerminalMigrateTransportResult(
                    migrated: [],
                    movedNotResumed: [TerminalMigrationSkip(
                        terminalID: id, reason: "focus the tab to start it there")],
                    skipped: [], refused: [])
            }
            await state.migrateTerminalToHolder(terminalID: row.id)
            #expect(state.alertMessage?.contains(
                TransportMigrationMenu.movedNotResumedAlertPrefix
                    + "focus the tab to start it there") == true)
            #expect(counter.count > 0, "the veil ended on the reply for a row that moved")
            #expect(state.switchingAccountTerminals[row.id] == nil)
        }
    }

    /// A parked holder row ends the veil too: a move whose wake failed lands
    /// one, and holding the veil over it until the bound expires would stall
    /// the tab for nothing.
    @Test func adoptingAParkedHolderRowAlsoEndsTheVeil() async {
        await withAppState { state in
            let row = Self.row(transport: .tmux)
            state.terminals[row.worktreeID] = [row]
            state.switchingAccountTerminals[row.id] = .transportMove
            var moved = Self.movedRow(like: row)
            moved.hibernatedAt = Date()
            state.adoptRecreatedTerminal(moved)
            #expect(state.switchingAccountTerminals[row.id] == nil)
        }
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

/// The reply-races-the-deltas path, on an `EventDrivenTestClock` and through
/// the production delta entry point (`handleDelta`).
///
/// The adoption wait is a poll loop on `transportMoveClock`, so its progress is
/// observed through the clock's ledger rather than by reading state right after
/// an advance: `advance` only resumes the sleeper, and the loop's post-sleep
/// check runs on the main actor some turns later. A re-arm is the proof that
/// the loop ran that check, saw the veil still up, and went back to waiting.
@MainActor
@Suite("TransportMigrationRace", .clockDriven, .serialized)
struct TransportMigrationRaceTests {
    /// Reaching the adoption wait's sleep takes main-actor turns (the migrate
    /// task, then the loop after each tick), so every arming wait gets the
    /// saturated-pass budget rather than the 45 s default.
    private static let mainActorHop = TestDeadlines.saturatedPass

    private func withAppState(_ body: (AppState) async throws -> Void) async rethrows {
        let name = "tbd-transport-race-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(AppState(userDefaults: defaults))
    }

    private func setUp(
        _ state: AppState, clock: EventDrivenTestClock
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

    @Test func theDeltasLandingAfterTheReplyCauseOneRebuildAndEndTheVeil() async throws {
        try await withAppState { state in
            let clock = EventDrivenTestClock()
            let row = setUp(state, clock: clock)
            // DELIBERATE BREAK (reverted next commit): the veil ends on the reply.
            state.terminalTransportMigrator = { @MainActor _ in
                state.switchingAccountTerminals[row.id] = nil
                return TerminalMigrateTransportResult(migrated: [row.id], skipped: [], refused: [])
            }
            let task = Task { @MainActor in await state.migrateTerminalToHolder(terminalID: row.id) }
            // The reply has landed and the veil is waiting on adoption. A reply
            // that ended the veil would never reach this sleep.
            try await clock.requireSleeperArmed(timeout: Self.mainActorHop)
            // The migrator parked the row; that delta arrives after the reply.
            state.handleDelta(.terminalHibernationChanged(TerminalHibernationDelta(
                terminalID: row.id, worktreeID: row.worktreeID, hibernated: true, keepWarm: false)))
            var identities = [identity(state, row)]
            // Three ticks of the wait with no adoption, then the fourth re-arm:
            // the loop has read the veil after every tick and kept waiting.
            for _ in 0..<3 {
                try await clock.requireAdvanceWhenArmed(
                    by: AppState.transportMovePollInterval, timeout: Self.mainActorHop)
            }
            try await clock.requireSleeperArmed(timeout: Self.mainActorHop)
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
            // The loop is parked on its re-armed tick; one tick lets it see the
            // adoption and end, which the join then observes.
            try await clock.requireAdvanceWhenArmed(
                by: AppState.transportMovePollInterval, timeout: Self.mainActorHop)
            await task.value

            #expect(state.switchingAccountTerminals[row.id] == nil)
            #expect((state.terminalAttachEpochs[row.id] ?? 0) == 0)
            #expect(state.terminals[row.worktreeID]?.first?.tmuxWindowID == "")
            identities.append(identity(state, row))
            let rebuilds = zip(identities, identities.dropFirst()).filter { $0 != $1 }.count
            #expect(rebuilds == 1, "the pane rebuilt \(rebuilds) times; identities: \(identities)")
        }
    }

    @Test func noDeltaMeansTheBoundClearsTheVeil() async throws {
        try await withAppState { state in
            let clock = EventDrivenTestClock()
            let row = setUp(state, clock: clock)
            let task = Task { @MainActor in await state.migrateTerminalToHolder(terminalID: row.id) }
            try await clock.requireSleeperArmed(timeout: Self.mainActorHop)
            #expect(state.switchingAccountTerminals[row.id] == .transportMove)
            // The wait re-arms every poll interval, so step it one armed tick at
            // a time until the bound clears the veil.
            let start = clock.now
            let id = row.id
            let cleared = try await clock.advanceUntil(
                "the bound clears the veil", by: AppState.transportMovePollInterval,
                timeout: Self.mainActorHop, maxSteps: 100
            ) {
                await MainActor.run { state.switchingAccountTerminals[id] == nil }
            }
            await task.value
            #expect(cleared)
            #expect(state.switchingAccountTerminals[row.id] == nil)
            // The bound, not some earlier exit, is what ended the wait.
            #expect(start.duration(to: clock.now) == AppState.transportMoveAdoptionBound,
                    "the veil cleared after \(start.duration(to: clock.now)) of virtual time")
        }
    }
}
