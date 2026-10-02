import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("WorktreeActivity")
struct WorktreeActivityTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let a = UUID(), b = UUID()

    @Test func workingSessionIsActive() {
        let s = [SessionActivityFact(terminalID: a, isWorking: true, isHibernated: false)]
        #expect(WorktreeActivity.isActive(sessions: s, lastHookAt: [:], lastSelectedAt: nil, now: t0))
    }

    @Test func hibernatedSessionIsIdleEvenIfWorkingOrRecentlyHooked() {
        let s = [SessionActivityFact(terminalID: a, isWorking: true, isHibernated: true)]
        #expect(!WorktreeActivity.isActive(sessions: s, lastHookAt: [a: t0], lastSelectedAt: nil, now: t0))
    }

    @Test func hookWithinThirtyMinutesIsActive() {
        let s = [SessionActivityFact(terminalID: a, isWorking: false, isHibernated: false)]
        #expect(WorktreeActivity.isActive(sessions: s, lastHookAt: [a: t0], lastSelectedAt: nil, now: t0.addingTimeInterval(1799)))
        #expect(!WorktreeActivity.isActive(sessions: s, lastHookAt: [a: t0], lastSelectedAt: nil, now: t0.addingTimeInterval(1801)))
    }

    @Test func selectionWithinThirtyMinutesIsActiveWithNoSessions() {
        #expect(WorktreeActivity.isActive(sessions: [], lastHookAt: [:], lastSelectedAt: t0, now: t0.addingTimeInterval(1000)))
        #expect(!WorktreeActivity.isActive(sessions: [], lastHookAt: [:], lastSelectedAt: t0, now: t0.addingTimeInterval(1801)))
    }

    @Test func hookFromAnotherWorktreesTerminalDoesNotCount() {
        let s = [SessionActivityFact(terminalID: a, isWorking: false, isHibernated: false)]
        #expect(!WorktreeActivity.isActive(sessions: s, lastHookAt: [b: t0], lastSelectedAt: nil, now: t0))
    }

    @Test func ledgerSignalsOnlyOnAPossibleActivation() async {
        let ledger = WorktreeActivityLedger()
        let box = UUIDBox()
        await ledger.setOnPossibleActivation { await box.add($0) }
        let wt = UUID()
        await ledger.recordHookEvent(terminalID: a, worktreeID: wt, at: t0)
        await ledger.recordHookEvent(terminalID: a, worktreeID: wt, at: t0.addingTimeInterval(60))   // still inside window
        await ledger.recordHookEvent(terminalID: a, worktreeID: wt, at: t0.addingTimeInterval(1900)) // window lapsed
        await ledger.recordSelection(worktreeID: wt, at: t0.addingTimeInterval(1910))                 // inside again
        #expect(await box.items == [wt, wt])
    }

    @Test func retainDropsUnknownIDs() async {
        let ledger = WorktreeActivityLedger()
        let wt = UUID()
        await ledger.recordHookEvent(terminalID: a, worktreeID: wt, at: t0)
        await ledger.recordSelection(worktreeID: wt, at: t0)
        await ledger.retain(terminalIDs: [], worktreeIDs: [])
        let snap = await ledger.snapshot()
        #expect(snap.hooks.isEmpty && snap.selections.isEmpty)
    }
}

private actor UUIDBox {
    var items: [UUID] = []
    func add(_ id: UUID) { items.append(id) }
}
