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
        #expect(TransportMigrationMenu.isOffered(for: Self.row(transport: .tmux)))
        #expect(!TransportMigrationMenu.isOffered(for: Self.row(transport: .holder)))
        #expect(!TransportMigrationMenu.isOffered(for: nil))
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
            #expect(state.alertMessage?.contains("mid-turn") == true)
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
        #expect(report.headline == "Moved 1 · 2 already on the holder · 1 not moved · 1 can't be moved")
        #expect(report.skipped == [.init(label: "one", reason: "busy")])
        #expect(report.refused == [.init(label: "two", reason: "no holder")])
    }
}
