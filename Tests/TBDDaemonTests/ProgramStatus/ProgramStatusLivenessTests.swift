import Testing
import Foundation
import os
import TBDShared
import DaemonTestSupport
import TestSupport
@testable import TBDDaemonLib

/// Spec "Liveness": every park and wake broadcast drops the terminal's
/// Program Status entries. `broadcastHibernation` is the funnel every park and
/// wake path goes through, so it is driven directly here; the store's own
/// drop semantics are pinned in `ProgramStatusStoreTests`.
///
/// The drop is awaited inside `broadcastHibernation`, so every assertion here
/// reads the store immediately after the call returns: a park drop that ran
/// later, in a task of its own, could set its watermark after a wake and
/// refuse the woken session's first reports.
@Suite struct ProgramStatusLivenessTests {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    private func holderClaude() -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            sessionIncarnationID: UUID(), kind: .claude, transport: .holder)
    }

    /// A store that knows exactly the terminal `row` holds, whose clock reads
    /// `now`.
    private func store(
        for row: OSAllocatedUnfairLock<Terminal>, now: Date
    ) -> ProgramStatusStore {
        ProgramStatusStore(
            terminalLookup: { id in
                let terminal = row.withLock { $0 }
                return id == terminal.id ? terminal : nil
            },
            publish: { _ in },
            now: { now })
    }

    private func store(for terminal: Terminal, now: Date) -> ProgramStatusStore {
        store(for: OSAllocatedUnfairLock(initialState: terminal), now: now)
    }

    private func coordinator(programStatus: ProgramStatusStore) throws -> HibernationCoordinator {
        HibernationCoordinator(
            db: try TBDDatabase(inMemory: true), tmux: TmuxManager(dryRun: true),
            configDirManager: makeIsolatedConfigDirManager(tag: "program-status-liveness"),
            sessionTitles: ClaudeSessionTitleStore(),
            actuationLog: makeTestActuationLog(), programStatus: programStatus)
    }

    private func seed(_ store: ProgramStatusStore, _ terminal: Terminal, at date: Date) async throws {
        let outcome = await store.ingest(ProgramStatusStore.Inbound(
            terminalID: terminal.id, incarnation: .currentRow,
            payload: Array("state=working:app=claude-code".utf8), observedAt: date))
        try #require(outcome == .accepted)
    }

    @Test func parkBroadcastDropsEntries() async throws {
        let terminal = holderClaude()
        let programStatus = store(for: terminal, now: t0.addingTimeInterval(10))
        try await seed(programStatus, terminal, at: t0)
        let coord = try coordinator(programStatus: programStatus)

        await coord.broadcastHibernation(terminal: terminal, hibernated: true, keepWarm: false)
        #expect(await programStatus.snapshot(for: terminal.id) == nil)
    }

    /// A wake drops what an earlier incarnation left behind.
    @Test func wakeBroadcastDropsAnOldIncarnationsEntries() async throws {
        var terminal = holderClaude()
        let row = OSAllocatedUnfairLock(initialState: terminal)
        let programStatus = store(for: row, now: t0.addingTimeInterval(10))
        try await seed(programStatus, terminal, at: t0)
        terminal.sessionIncarnationID = UUID()
        let woken = terminal
        row.withLock { $0 = woken }
        let coord = try coordinator(programStatus: programStatus)

        await coord.broadcastHibernation(
            terminal: terminal, hibernated: false, keepWarm: false,
            tmuxWindowID: "", tmuxPaneID: "")
        #expect(await programStatus.snapshot(for: terminal.id) == nil)
    }

    /// A wake leaves the live session's current state alone: its entries are
    /// the row's current incarnation's.
    @Test func wakeBroadcastKeepsTheCurrentIncarnationsEntries() async throws {
        let terminal = holderClaude()
        let programStatus = store(for: terminal, now: t0.addingTimeInterval(10))
        try await seed(programStatus, terminal, at: t0.addingTimeInterval(20))
        let coord = try coordinator(programStatus: programStatus)

        await coord.broadcastHibernation(
            terminal: terminal, hibernated: false, keepWarm: false,
            tmuxWindowID: "", tmuxPaneID: "")
        #expect(await programStatus.snapshot(for: terminal.id)?.main?.state == .working)
    }

    /// A keep-warm toggle re-broadcasts without parking or waking, and must
    /// leave a live session's status alone — on a live row the wake branch
    /// would otherwise drop it.
    @Test func keepWarmRebroadcastKeepsEntries() async throws {
        let terminal = holderClaude()
        let programStatus = store(for: terminal, now: t0.addingTimeInterval(10))
        try await seed(programStatus, terminal, at: t0)
        let coord = try coordinator(programStatus: programStatus)

        await coord.broadcastHibernation(
            terminal: terminal, hibernated: false, keepWarm: true, isParkOrWake: false)
        #expect(await programStatus.snapshot(for: terminal.id)?.main?.state == .working)
    }
}
