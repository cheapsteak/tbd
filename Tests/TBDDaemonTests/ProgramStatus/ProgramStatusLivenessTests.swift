import Testing
import Foundation
import TBDShared
import TestSupport
@testable import TBDDaemonLib

/// Spec "Liveness": every park and wake broadcast drops the terminal's
/// Program Status entries. `broadcastHibernation` is the funnel every park and
/// wake path goes through, so it is driven directly here; the store's own
/// drop semantics are pinned in `ProgramStatusStoreTests`.
@Suite struct ProgramStatusLivenessTests {
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    private struct DropNotObserved: Error, CustomStringConvertible {
        let what: String
        var description: String { "Program Status entries were not dropped after \(what)" }
    }

    private func holderClaude() -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "",
            kind: .claude, transport: .holder)
    }

    /// A store that knows exactly one terminal and whose clock reads `now`.
    private func store(for terminal: Terminal, now: Date) -> ProgramStatusStore {
        ProgramStatusStore(
            enabled: true,
            terminalLookup: { id in id == terminal.id ? terminal : nil },
            publish: { _ in },
            now: { now })
    }

    private func coordinator(programStatus: ProgramStatusStore) throws -> HibernationCoordinator {
        HibernationCoordinator(
            db: try TBDDatabase(inMemory: true), tmux: TmuxManager(dryRun: true),
            configDirManager: makeIsolatedConfigDirManager(tag: "program-status-liveness"),
            actuationLog: makeTestActuationLog(), programStatus: programStatus)
    }

    private func seed(_ store: ProgramStatusStore, _ terminal: Terminal, at date: Date) async throws {
        let outcome = await store.ingest(ProgramStatusStore.Inbound(
            terminalID: terminal.id, incarnation: .currentRow,
            payload: Array("state=working:app=claude-code".utf8), observedAt: date))
        try #require(outcome == .accepted)
    }

    private func awaitDropped(_ store: ProgramStatusStore, _ terminal: Terminal, after what: String) async {
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            await store.snapshot(for: terminal.id) == nil
        }
        if outcome == .timedOut {
            Issue.record(DropNotObserved(what: what))
        }
    }

    @Test func parkBroadcastDropsEntries() async throws {
        let terminal = holderClaude()
        let programStatus = store(for: terminal, now: t0.addingTimeInterval(10))
        try await seed(programStatus, terminal, at: t0)
        let coord = try coordinator(programStatus: programStatus)

        await coord.broadcastHibernation(terminal: terminal, hibernated: true, keepWarm: false)
        await awaitDropped(programStatus, terminal, after: "a park broadcast")
    }

    @Test func wakeBroadcastDropsEntriesObservedBeforeIt() async throws {
        let terminal = holderClaude()
        let programStatus = store(for: terminal, now: t0.addingTimeInterval(10))
        try await seed(programStatus, terminal, at: t0)
        let coord = try coordinator(programStatus: programStatus)

        await coord.broadcastHibernation(
            terminal: terminal, hibernated: false, keepWarm: false,
            tmuxWindowID: "", tmuxPaneID: "")
        await awaitDropped(programStatus, terminal, after: "a wake broadcast")
    }

    /// A keep-warm toggle re-broadcasts without parking or waking, and must
    /// leave a live session's status alone — on a live row the wake branch
    /// would otherwise drop it. One-sided: a regressed drop would run in a
    /// task and could land after this read.
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
