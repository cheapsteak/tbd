import Testing
import Foundation
import os
import TBDShared
import TestSupport
@testable import TBDDaemonLib

/// Tier 1: an injected terminal lookup, a captured publish, injected dates.
@Suite struct ProgramStatusStoreTests {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    /// Everything a test needs around one store.
    private final class Harness: Sendable {
        let terminals: OSAllocatedUnfairLock<[UUID: Terminal]>
        let published: OSAllocatedUnfairLock<[ProgramStatusSnapshot]>
        let store: ProgramStatusStore

        init(
            enabled: Bool = true,
            lookupGate: LookupGate? = nil,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            let terminals = OSAllocatedUnfairLock<[UUID: Terminal]>(initialState: [:])
            let published = OSAllocatedUnfairLock<[ProgramStatusSnapshot]>(initialState: [])
            self.terminals = terminals
            self.published = published
            self.store = ProgramStatusStore(
                enabled: enabled,
                terminalLookup: { id in
                    if let lookupGate {
                        await lookupGate.wait()
                    }
                    return terminals.withLock { $0[id] }
                },
                publish: { snapshot in published.withLock { $0.append(snapshot) } },
                now: now)
        }

        func remove(_ terminalID: UUID) {
            terminals.withLock { $0[terminalID] = nil }
        }

        func add(_ terminal: Terminal) {
            terminals.withLock { $0[terminal.id] = terminal }
        }

        var publishedSnapshots: [ProgramStatusSnapshot] {
            published.withLock { $0 }
        }
    }

    /// Holds every terminal lookup suspended until `release()`, so a test can
    /// run a drop while an ingest is parked on its lookup. Lookups after the
    /// release pass straight through.
    fileprivate final class LookupGate: Sendable {
        private struct State: Sendable {
            var arrived = false
            var released = false
            var waiting: CheckedContinuation<Void, Never>?
        }

        private let state = OSAllocatedUnfairLock<State>(initialState: State())

        var hasArrived: Bool { state.withLock { $0.arrived } }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = state.withLock { current in
                    current.arrived = true
                    if current.released { return true }
                    current.waiting = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func release() {
            let waiting: CheckedContinuation<Void, Never>? = state.withLock { current in
                current.released = true
                let held = current.waiting
                current.waiting = nil
                return held
            }
            waiting?.resume()
        }
    }

    private struct LookupNotReached: Error, CustomStringConvertible {
        var description: String { "the ingest never reached its terminal lookup" }
    }

    private func holderClaude(
        incarnation: UUID? = nil, kind: TerminalKind? = .claude,
        transport: TerminalTransport = .holder, hibernatedAt: Date? = nil, label: String? = nil
    ) -> Terminal {
        Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", label: label,
            sessionIncarnationID: incarnation, kind: kind,
            hibernatedAt: hibernatedAt, transport: transport)
    }

    private func inbound(
        _ terminal: Terminal, _ text: String, at seconds: TimeInterval = 0,
        incarnation: ProgramStatusStore.Incarnation = .currentRow
    ) -> ProgramStatusStore.Inbound {
        ProgramStatusStore.Inbound(
            terminalID: terminal.id, incarnation: incarnation,
            payload: Array(text.utf8), observedAt: t0.addingTimeInterval(seconds))
    }

    private func isRejected(_ outcome: ProgramStatusStore.Outcome) -> Bool {
        if case .rejected = outcome { return true }
        return false
    }

    // MARK: - Trust

    @Test func flagOffRejects() async {
        let h = Harness(enabled: false)
        let terminal = holderClaude()
        h.add(terminal)
        let outcome = await h.store.ingest(inbound(terminal, "state=working:app=claude-code"))
        #expect(outcome == .rejected("flag off"))
        #expect(await h.store.snapshot(for: terminal.id) == nil)
        #expect(h.publishedSnapshots.isEmpty)
    }

    @Test func nonClaudeOrNonHolderOrParkedTerminalsReject() async {
        let h = Harness()
        let codex = holderClaude(kind: .codex)
        let codexByLabel = holderClaude(kind: nil, label: TerminalLabel.codex)
        let shell = holderClaude(kind: .shell)
        let tmux = holderClaude(transport: .tmux)
        let hibernated = holderClaude(hibernatedAt: t0)
        for terminal in [codex, codexByLabel, shell, tmux, hibernated] {
            h.add(terminal)
            let outcome = await h.store.ingest(inbound(terminal, "state=working:app=claude-code"))
            #expect(isRejected(outcome))
        }
        #expect(h.publishedSnapshots.isEmpty)
    }

    @Test func legacyNilKindClaudeAccepts() async {
        let h = Harness()
        let terminal = holderClaude(kind: nil)
        h.add(terminal)
        #expect(await h.store.ingest(inbound(terminal, "state=working:app=claude-code")) == .accepted)
    }

    @Test func unknownTerminalRejects() async {
        let h = Harness()
        let outcome = await h.store.ingest(inbound(holderClaude(), "state=working:app=claude-code"))
        #expect(isRejected(outcome))
    }

    @Test func wrongOrMissingAppRejects() async {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        #expect(isRejected(await h.store.ingest(inbound(terminal, "state=working:app=other"))))
        #expect(isRejected(await h.store.ingest(inbound(terminal, "state=working"))))
        #expect(h.publishedSnapshots.isEmpty)
    }

    @Test func unparseablePayloadRejects() async {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        #expect(isRejected(await h.store.ingest(inbound(terminal, "app=claude-code"))))
        #expect(isRejected(await h.store.ingest(inbound(terminal, ""))))
    }

    @Test func claimedIncarnationMustMatchRow() async {
        let h = Harness()
        let current = UUID()
        let terminal = holderClaude(incarnation: current)
        h.add(terminal)
        let mismatch = await h.store.ingest(inbound(
            terminal, "state=working:app=claude-code", incarnation: .claimed(UUID())))
        #expect(mismatch == .rejected("incarnation mismatch"))
        let nilClaim = await h.store.ingest(inbound(
            terminal, "state=working:app=claude-code", incarnation: .claimed(nil)))
        #expect(isRejected(nilClaim))
        let match = await h.store.ingest(inbound(
            terminal, "state=working:app=claude-code", incarnation: .claimed(current)))
        #expect(match == .accepted)
        #expect(await h.store.snapshot(for: terminal.id)?.incarnationID == current)
    }

    @Test func claimedNilMatchesFreshRowWithNilIncarnation() async {
        let h = Harness()
        let terminal = holderClaude(incarnation: nil)
        h.add(terminal)
        let outcome = await h.store.ingest(inbound(
            terminal, "state=working:app=claude-code", incarnation: .claimed(nil)))
        #expect(outcome == .accepted)
    }

    @Test func currentRowTakesTheRowsIncarnation() async {
        let h = Harness()
        let current = UUID()
        let terminal = holderClaude(incarnation: current)
        h.add(terminal)
        #expect(await h.store.ingest(inbound(terminal, "state=working:app=claude-code")) == .accepted)
        #expect(await h.store.snapshot(for: terminal.id)?.incarnationID == current)
    }

    @Test func staleObservedAtRejects() async {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        #expect(await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 10)) == .accepted)
        let stale = await h.store.ingest(inbound(terminal, "state=done:app=claude-code", at: 5))
        #expect(stale == .rejected("stale"))
        #expect(await h.store.snapshot(for: terminal.id)?.main?.state == .working)
    }

    @Test func probeIsIgnoredAndPublishesNothing() async {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        #expect(await h.store.ingest(inbound(terminal, "?")) == .ignoredProbe)
        #expect(h.publishedSnapshots.isEmpty)
    }

    // MARK: - Entries

    @Test func mainReportIsStoredWholesaleAndPublished() async throws {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        let title = Data("Fixing tests".utf8).base64EncodedString()
        #expect(await h.store.ingest(inbound(
            terminal, "state=working:app=claude-code:progress=40:title=\(title)", at: 1)) == .accepted)
        let first = try #require(await h.store.snapshot(for: terminal.id))
        #expect(first.main?.title == "Fixing tests")
        #expect(first.main?.progress == 40)
        // A later report replaces the entry wholesale.
        #expect(await h.store.ingest(inbound(terminal, "state=done:app=claude-code", at: 2)) == .accepted)
        let second = try #require(await h.store.snapshot(for: terminal.id))
        #expect(second.main?.state == .done)
        #expect(second.main?.title == nil)
        #expect(h.publishedSnapshots.count == 2)
        #expect(h.publishedSnapshots.last == second)
    }

    @Test func taskAddReplaceAndClear() async throws {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 1))
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code:id=a", at: 2))
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code:id=b", at: 3))
        _ = await h.store.ingest(inbound(terminal, "state=blocked:app=claude-code:id=a", at: 4))
        let afterReplace = try #require(await h.store.snapshot(for: terminal.id))
        #expect(afterReplace.tasks.map(\.id) == ["a", "b"])
        #expect(afterReplace.tasks.first?.entry.state == .blocked)

        _ = await h.store.ingest(inbound(terminal, "state=clear:app=claude-code:id=a", at: 5))
        let afterClear = try #require(await h.store.snapshot(for: terminal.id))
        #expect(afterClear.tasks.map(\.id) == ["b"])
        #expect(afterClear.main?.state == .working)
    }

    @Test func thirtyThirdTaskEvictsTheOldest() async throws {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        // Insert in order; then refresh t0 so t1 becomes the oldest-observed.
        for index in 0..<32 {
            _ = await h.store.ingest(inbound(
                terminal, "state=working:app=claude-code:id=t\(index)", at: TimeInterval(index)))
        }
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code:id=t0", at: 100))
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code:id=new", at: 101))
        let snapshot = try #require(await h.store.snapshot(for: terminal.id))
        let ids = snapshot.tasks.map(\.id)
        #expect(ids.count == ProgramStatusProtocol.maxTaskEntries)
        #expect(!ids.contains("t1"))
        #expect(ids.contains("t0"))
        #expect(ids.last == "new")
    }

    @Test func tasksWithoutMainAreHeldButNotAuthoritative() async throws {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code:id=a", at: 1))
        let snapshot = try #require(await h.store.snapshot(for: terminal.id))
        #expect(!snapshot.isAuthoritative)
        #expect(await h.store.allSnapshots().count == 1)
    }

    @Test func bareClearEmptiesAndPublishesRetraction() async throws {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 1))
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code:id=a", at: 2))
        #expect(await h.store.ingest(inbound(terminal, "state=clear:app=claude-code", at: 3)) == .accepted)
        #expect(await h.store.snapshot(for: terminal.id) == nil)
        #expect(await h.store.allSnapshots().isEmpty)
        let last = try #require(h.publishedSnapshots.last)
        #expect(last.isEmpty)
        #expect(last.terminalID == terminal.id)
    }

    @Test func incarnationChangeDiscardsOldEntries() async throws {
        let h = Harness()
        let first = UUID()
        var terminal = holderClaude(incarnation: first)
        h.add(terminal)
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 1))
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code:id=a", at: 2))

        let second = UUID()
        terminal.sessionIncarnationID = second
        h.add(terminal)
        // Older than the discarded entries, yet accepted: it is a new process.
        #expect(await h.store.ingest(inbound(terminal, "state=idle:app=claude-code", at: 0)) == .accepted)
        let snapshot = try #require(await h.store.snapshot(for: terminal.id))
        #expect(snapshot.incarnationID == second)
        #expect(snapshot.tasks.isEmpty)
        #expect(snapshot.main?.state == .idle)
    }

    // MARK: - Drops and revisions

    @Test func dropRetractsAndBumpsRevision() async throws {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 1))
        let before = try #require(await h.store.snapshot(for: terminal.id)).revision
        await h.store.drop(terminalID: terminal.id, reason: .parked)
        #expect(await h.store.snapshot(for: terminal.id) == nil)
        let last = try #require(h.publishedSnapshots.last)
        #expect(last.isEmpty)
        #expect(last.revision > before)

        // Dropping what is not held publishes nothing.
        let count = h.publishedSnapshots.count
        await h.store.drop(terminalID: terminal.id, reason: .childExited)
        #expect(h.publishedSnapshots.count == count)
    }

    /// A drop that runs while an ingest is suspended on its terminal lookup
    /// finds nothing to drop; the ingest must not then store the report it
    /// was validating. Observed after the watermark, so only the generation
    /// check can reject it.
    @Test func dropDuringSuspendedIngestRejectsTheReport() async {
        let gate = LookupGate()
        let dropInstant = t0.addingTimeInterval(100)
        let h = Harness(lookupGate: gate, now: { dropInstant })
        let terminal = holderClaude()
        h.add(terminal)
        let store = h.store
        let report = inbound(terminal, "state=working:app=claude-code", at: 200)
        let ingest = Task { await store.ingest(report) }

        let reached = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            gate.hasArrived
        }
        if reached == .timedOut {
            Issue.record(LookupNotReached())
        }
        await store.drop(terminalID: terminal.id, reason: .childExited)
        gate.release()

        #expect(await ingest.value == .rejected("dropped during lookup"))
        #expect(await store.snapshot(for: terminal.id) == nil)
        #expect(h.publishedSnapshots.isEmpty)
    }

    /// A report observed at or before a drop belongs to the session that drop
    /// ended — a backlog delivered late — and is refused; one observed after
    /// it is accepted.
    @Test func dropWatermarkRejectsReportsObservedAtOrBeforeIt() async {
        let dropInstant = t0.addingTimeInterval(10)
        let h = Harness(now: { dropInstant })
        let terminal = holderClaude()
        h.add(terminal)
        await h.store.drop(terminalID: terminal.id, reason: .childExited)

        let before = await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 5))
        #expect(before == .rejected("observed before drop"))
        let at = await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 10))
        #expect(at == .rejected("observed before drop"))
        #expect(await h.store.snapshot(for: terminal.id) == nil)

        let after = await h.store.ingest(inbound(terminal, "state=done:app=claude-code", at: 11))
        #expect(after == .accepted)
        #expect(await h.store.snapshot(for: terminal.id)?.main?.state == .done)
    }

    /// A wake keeps what the live session has reported: entries of the row's
    /// current incarnation stay, and nothing is published.
    @Test func wakeDropKeepsTheCurrentIncarnationsEntries() async {
        let h = Harness()
        let terminal = holderClaude(incarnation: UUID())
        h.add(terminal)
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 5))

        let count = h.publishedSnapshots.count
        await h.store.dropIfIncarnationChanged(terminalID: terminal.id, reason: .woke)
        #expect(await h.store.snapshot(for: terminal.id)?.main?.state == .working)
        #expect(h.publishedSnapshots.count == count)
    }

    /// A wake drops entries from an incarnation the row no longer runs, and
    /// sets no watermark: the new session's next report is accepted.
    @Test func wakeDropDiscardsAnOldIncarnationsEntries() async throws {
        let h = Harness()
        var terminal = holderClaude(incarnation: UUID())
        h.add(terminal)
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 5))

        terminal.sessionIncarnationID = UUID()
        h.add(terminal)
        await h.store.dropIfIncarnationChanged(terminalID: terminal.id, reason: .woke)
        #expect(await h.store.snapshot(for: terminal.id) == nil)
        let last = try #require(h.publishedSnapshots.last)
        #expect(last.isEmpty)

        let next = await h.store.ingest(inbound(terminal, "state=idle:app=claude-code", at: 1))
        #expect(next == .accepted)
    }

    @Test func wakeDropDiscardsEntriesForAVanishedRow() async {
        let h = Harness()
        let terminal = holderClaude(incarnation: UUID())
        h.add(terminal)
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 5))
        h.remove(terminal.id)
        await h.store.dropIfIncarnationChanged(terminalID: terminal.id, reason: .woke)
        #expect(await h.store.snapshot(for: terminal.id) == nil)
    }

    @Test func setEnabledFalseRetractsEveryTerminal() async {
        let h = Harness()
        let a = holderClaude()
        let b = holderClaude()
        h.add(a)
        h.add(b)
        _ = await h.store.ingest(inbound(a, "state=working:app=claude-code", at: 1))
        _ = await h.store.ingest(inbound(b, "state=done:app=claude-code", at: 1))
        await h.store.setEnabled(false)
        #expect(!h.store.gate.isEnabled)
        #expect(await h.store.allSnapshots().isEmpty)
        let retracted = Set(h.publishedSnapshots.filter(\.isEmpty).map(\.terminalID))
        #expect(retracted == [a.id, b.id])
        // Reports are rejected from here on.
        #expect(await h.store.ingest(inbound(a, "state=working:app=claude-code", at: 2)) == .rejected("flag off"))
    }

    @Test func revisionIsMonotonicAcrossClears() async {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 1))
        _ = await h.store.ingest(inbound(terminal, "state=clear:app=claude-code", at: 2))
        _ = await h.store.ingest(inbound(terminal, "state=working:app=claude-code", at: 3))
        await h.store.drop(terminalID: terminal.id, reason: .childExited)
        let revisions = h.publishedSnapshots.map(\.revision)
        #expect(revisions == [1, 2, 3, 4])
    }

    @Test func enqueuedReportsAreIngestedInOrderByRun() async {
        let h = Harness()
        let terminal = holderClaude()
        h.add(terminal)
        let runner = Task { await h.store.run() }
        defer { runner.cancel() }
        h.store.enqueue(inbound(terminal, "state=working:app=claude-code", at: 1))
        h.store.enqueue(inbound(terminal, "state=done:app=claude-code", at: 2))
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) {
            h.published.withLock { $0.count } == 2
        }
        if outcome == .timedOut {
            Issue.record("run() did not publish both enqueued reports; published \(h.publishedSnapshots.count)")
        }
        #expect(h.publishedSnapshots.map { $0.main?.state } == [.working, .done])
    }
}
