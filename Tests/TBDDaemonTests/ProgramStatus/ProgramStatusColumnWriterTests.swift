import Testing
import Foundation
import os
import TBDShared
import TestSupport
@testable import TBDDaemonLib

/// The production store end to end: `ProgramStatusStore.live` over an
/// in-memory database, with every delta it broadcasts recorded and an enabled
/// PR-poll ledger. Reports in, columns, banners and ledger stamps out.
@Suite struct ProgramStatusColumnWriterTests {
    private static let t0 = Date(timeIntervalSince1970: 6_000_000)

    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Every drop is stamped well after every report a test sends.
    private static let dropInstant = at(1000)

    private static let secret = "acme secret"
    private static let encodedSecret = Data(secret.utf8).base64EncodedString()

    private final class Harness: Sendable {
        let db: TBDDatabase
        let subscriptions: StateSubscriptionManager
        let ledger: WorktreeActivityLedger
        let store: ProgramStatusStore
        let worktreeID: UUID
        private let deltas: OSAllocatedUnfairLock<[StateDelta]>

        private init(
            db: TBDDatabase, subscriptions: StateSubscriptionManager,
            ledger: WorktreeActivityLedger, worktreeID: UUID,
            deltas: OSAllocatedUnfairLock<[StateDelta]>
        ) {
            self.db = db
            self.subscriptions = subscriptions
            self.ledger = ledger
            self.worktreeID = worktreeID
            self.deltas = deltas
            self.store = ProgramStatusStore.live(
                db: db, subscriptions: subscriptions, ledger: ledger,
                now: { ProgramStatusColumnWriterTests.dropInstant })
        }

        static func make() async throws -> Harness {
            let db = try TBDDatabase(inMemory: true)
            let deltas = OSAllocatedUnfairLock<[StateDelta]>(initialState: [])
            let subscriptions = StateSubscriptionManager()
            subscriptions.addSubscriber { data in
                if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                    deltas.withLock { $0.append(delta) }
                }
                return true
            }
            let ledger = WorktreeActivityLedger()
            await ledger.setEnabled(true)
            let repo = try await db.repos.create(
                path: "/tmp/pscw-repo-\(UUID().uuidString)", displayName: "acme",
                defaultBranch: "main")
            let worktree = try await db.worktrees.create(
                repoID: repo.id, name: "wt", branch: "main",
                path: "/tmp/pscw-wt-\(UUID().uuidString)", tmuxServer: "tbd-pscw")
            return Harness(
                db: db, subscriptions: subscriptions, ledger: ledger,
                worktreeID: worktree.id, deltas: deltas)
        }

        func terminal(kind: TerminalKind = .claude) async throws -> Terminal {
            try await db.terminals.create(
                worktreeID: worktreeID, tmuxWindowID: "", tmuxPaneID: "",
                kind: kind, transport: .holder, sessionIncarnationID: UUID())
        }

        func row(_ terminal: Terminal) async throws -> Terminal {
            try #require(try await db.terminals.get(id: terminal.id))
        }

        func activityDeltas(_ terminal: Terminal) -> [TerminalActivityDelta] {
            deltas.withLock { $0 }.compactMap {
                if case .terminalActivityUpdated(let delta) = $0, delta.terminalID == terminal.id {
                    return delta
                }
                return nil
            }
        }

        func awaitingInputDeltas(_ terminal: Terminal) -> [TerminalAwaitingInputDelta] {
            deltas.withLock { $0 }.compactMap {
                if case .terminalAwaitingInputChanged(let delta) = $0, delta.terminalID == terminal.id {
                    return delta
                }
                return nil
            }
        }

        func attentionNotifications() async throws -> [TBDNotification] {
            try await db.notifications.unread(worktreeID: worktreeID)
                .filter { $0.type == .attentionNeeded }
        }
    }

    private static func inbound(
        _ terminal: Terminal, _ text: String, at seconds: TimeInterval,
        incarnation: ProgramStatusStore.Incarnation = .currentRow
    ) -> ProgramStatusStore.Inbound {
        ProgramStatusStore.Inbound(
            terminalID: terminal.id, incarnation: incarnation,
            payload: Array(text.utf8), observedAt: at(seconds))
    }

    @discardableResult
    private func ingest(
        _ h: Harness, _ terminal: Terminal, _ text: String, at seconds: TimeInterval,
        incarnation: ProgramStatusStore.Incarnation = .currentRow
    ) async -> ProgramStatusStore.Outcome {
        await h.store.ingest(Self.inbound(terminal, text, at: seconds, incarnation: incarnation))
    }

    // MARK: - The mapping, through the store

    @Test func workingWritesWorking() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        #expect(await ingest(h, terminal, "state=working:app=claude-code", at: 1) == .accepted)
        let row = try await h.row(terminal)
        #expect(row.activityState == .working)
        #expect(row.activityStateSource == .programStatus)
        #expect(row.activityStateObservedAt == Self.at(1))
    }

    @Test func blockedPermissionWritesWaitingWithTheKindOnly() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(
            h, terminal,
            "state=blocked:app=claude-code:kind=permission:msg=\(Self.encodedSecret)", at: 1)
        let row = try await h.row(terminal)
        #expect(row.activityState == .waitingForUser)
        let reason = try #require(row.awaitingInputReason)
        #expect(reason.programStatusBlock?.kind == .permission)
        #expect(reason.message == "")
        #expect(row.awaitingInputObservedAt == Self.at(1))
        #expect(!(FactColumnJSON.encode(reason) ?? "").contains(Self.secret))
    }

    @Test func blockedQuestionAndBareBlockedWriteWaiting() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=blocked:app=claude-code:kind=question", at: 1)
        var row = try await h.row(terminal)
        #expect(row.activityState == .waitingForUser)
        #expect(row.awaitingInputReason?.programStatusBlock?.kind == .question)

        await ingest(h, terminal, "state=working:app=claude-code", at: 2)
        await ingest(h, terminal, "state=blocked:app=claude-code", at: 3)
        row = try await h.row(terminal)
        #expect(row.activityState == .waitingForUser)
        #expect(row.awaitingInputReason?.programStatusBlock == ProgramStatusBlock(kind: nil, taskID: nil))
    }

    @Test func doneIdleErrorAndAuthWriteIdle() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()
        let endings = [
            "state=done:app=claude-code",
            "state=idle:app=claude-code",
            "state=error:app=claude-code",
            "state=blocked:app=claude-code:kind=auth",
        ]
        var seconds: TimeInterval = 0
        for ending in endings {
            seconds += 1
            await ingest(h, terminal, "state=working:app=claude-code", at: seconds)
            #expect(try await h.row(terminal).activityState == .working)
            seconds += 1
            await ingest(h, terminal, ending, at: seconds)
            let row = try await h.row(terminal)
            #expect(row.activityState == .idle, "\(ending)")
            #expect(row.awaitingInputReason == nil, "\(ending)")
        }
    }

    @Test func aWorkingTaskUnderAnIdleMainWritesWorking() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=idle:app=claude-code", at: 1)
        #expect(try await h.row(terminal).activityState == .idle)
        await ingest(h, terminal, "state=working:app=claude-code:id=t1", at: 2)
        #expect(try await h.row(terminal).activityState == .working)
    }

    @Test func aBlockedTaskUnderAnIdleMainWritesWaiting() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=idle:app=claude-code", at: 1)
        await ingest(h, terminal, "state=blocked:app=claude-code:id=t1:kind=question", at: 2)
        let row = try await h.row(terminal)
        #expect(row.activityState == .waitingForUser)
        #expect(row.awaitingInputReason?.programStatusBlock?.taskID == "t1")
    }

    @Test func anUnchangedValueWritesNothing() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=working:app=claude-code", at: 1)
        await ingest(h, terminal, "state=working:app=claude-code", at: 2)
        #expect(try await h.row(terminal).activityStateObservedAt == Self.at(1))
        #expect(h.activityDeltas(terminal).count == 1)
    }

    // MARK: - Unknown: clear, child exit, incarnation change

    @Test func aBareClearWritesUnknown() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=working:app=claude-code", at: 1)
        #expect(try await h.row(terminal).activityState == .working)
        await ingest(h, terminal, "state=clear", at: 2)
        let row = try await h.row(terminal)
        #expect(row.activityState == .unknown)
        #expect(row.activityStateSource == .programStatus)
    }

    @Test func childExitWritesUnknown() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=blocked:app=claude-code:kind=permission", at: 1)
        #expect(try await h.row(terminal).activityState == .waitingForUser)
        await h.store.drop(terminalID: terminal.id, reason: .childExited)
        let row = try await h.row(terminal)
        #expect(row.activityState == .unknown)
        #expect(row.awaitingInputReason == nil)
        #expect(row.activityStateObservedAt == Self.dropInstant)
    }

    @Test func anIncarnationChangeResetsTheColumnAndTheMemo() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()
        let incarnationA = try #require(terminal.sessionIncarnationID)

        await ingest(h, terminal, "state=working:app=claude-code", at: 1)
        #expect(try await h.row(terminal).activityState == .working)

        // An in-place replacement starts incarnation B on the live row.
        let beforeReplacement = try await h.row(terminal)
        let incarnationB = try #require(try await h.db.terminals.prepareProfileAgentRespawn(
            id: terminal.id,
            expectedState: TerminalReplacementSnapshot(terminal: beforeReplacement),
            sessionID: "acme-session-b", transcriptPath: nil, profileID: nil,
            at: Self.at(2)))
        #expect(try await h.row(terminal).activityState == .unknown)

        // A late report from A is refused and changes nothing.
        let late = await ingest(
            h, terminal, "state=idle:app=claude-code", at: 3, incarnation: .claimed(incarnationA))
        #expect(late != .accepted)
        #expect(try await h.row(terminal).activityState == .unknown)

        // B's first `working` is written although A's was the last value
        // written: the memo is per incarnation.
        await ingest(
            h, terminal, "state=working:app=claude-code", at: 4, incarnation: .claimed(incarnationB))
        #expect(try await h.row(terminal).activityState == .working)
    }

    // MARK: - Parks

    @Test func aParkStillWritesIdle() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=working:app=claude-code", at: 1)
        #expect(try await h.row(terminal).activityState == .working)
        try await h.db.terminals.setHibernated(
            id: terminal.id, sessionID: "acme-session", at: Self.at(2))
        await h.store.drop(terminalID: terminal.id, reason: .parked)
        let row = try await h.row(terminal)
        #expect(row.activityState == .idle)
        #expect(row.activityStateSource == .database)
    }

    /// Holder park SIGTERMs the child, so the child-exit drop can land after
    /// the park's `.idle`; it must not overwrite it.
    @Test func childExitAfterParkLeavesIdle() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=working:app=claude-code", at: 1)
        #expect(try await h.row(terminal).activityState == .working)
        try await h.db.terminals.setHibernated(
            id: terminal.id, sessionID: "acme-session", at: Self.at(2))
        await h.store.drop(terminalID: terminal.id, reason: .parked)
        await h.store.drop(terminalID: terminal.id, reason: .childExited)
        let row = try await h.row(terminal)
        #expect(row.activityState == .idle)
        #expect(row.activityStateSource == .database)
    }

    // MARK: - Across a wake and a rolled-back park

    /// A wake starts the replacement process while the row still reads parked,
    /// and un-parks it only once the launch is recorded. Codex draws its first
    /// `idle` at once and never repeats it, so a report refused in that window
    /// must still speak once the wake completes.
    @Test func aReportMadeWhileTheWakeStillReadsParkedSpeaksAfterTheWake() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal(kind: .codex)

        await ingest(h, terminal, "state=working:app=codex", at: 1)
        try await h.db.terminals.setHibernated(
            id: terminal.id, sessionID: "acme-thread", at: Self.at(2))
        await h.store.drop(terminalID: terminal.id, reason: .parked)

        // The wake: a fresh incarnation on the still-parked row, then the
        // replacement's first report, then the un-park and its broadcast.
        let parked = try await h.row(terminal)
        let incarnationB = try #require(try await h.db.terminals.prepareHibernatedAgentRespawn(
            id: terminal.id, expectedState: TerminalReplacementSnapshot(terminal: parked),
            at: Self.at(1001)))
        #expect(await ingest(h, terminal, "state=idle:app=codex", at: 1002)
            == .rejected("terminal is parked"))
        #expect(try await h.row(terminal).activityState == .unknown)
        try await h.db.terminals.clearHibernated(id: terminal.id)
        await h.store.dropIfIncarnationChanged(terminalID: terminal.id, reason: .woke)

        let row = try await h.row(terminal)
        #expect(row.activityState == .idle)
        #expect(row.activityStateSource == .programStatus)
        #expect(row.activityStateObservedAt == Self.at(1002))
        #expect(await h.store.snapshot(for: terminal.id)?.incarnationID == incarnationB)
    }

    /// What the ending session reported while its park was under way belongs
    /// to that session, and the wake replays none of it.
    @Test func aReportFromTheSessionAParkEndedIsNotReplayed() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=working:app=claude-code", at: 1)
        try await h.db.terminals.setHibernated(
            id: terminal.id, sessionID: "acme-session", at: Self.at(2))
        #expect(await ingest(h, terminal, "state=idle:app=claude-code", at: 3)
            == .rejected("terminal is parked"))
        await h.store.drop(terminalID: terminal.id, reason: .parked)

        let parked = try await h.row(terminal)
        _ = try #require(try await h.db.terminals.prepareHibernatedAgentRespawn(
            id: terminal.id, expectedState: TerminalReplacementSnapshot(terminal: parked),
            at: Self.at(1001)))
        try await h.db.terminals.clearHibernated(id: terminal.id)
        await h.store.dropIfIncarnationChanged(terminalID: terminal.id, reason: .woke)
        #expect(try await h.row(terminal).activityStateSource == .derived)

        // The woken session's own report still lands.
        await ingest(h, terminal, "state=working:app=claude-code", at: 1005)
        #expect(try await h.row(terminal).activityState == .working)
    }

    /// The app labels what it reads with its cached row, which learns a wake's
    /// incarnation only from the wake's broadcast. A report it forwards in
    /// between still claims the incarnation the park ended; observed after
    /// the park's drop, it can only be the woken process's, and it speaks.
    /// The previous process's late report, observed before the drop, is still
    /// refused, and so is a claim of an incarnation no drop ended.
    @Test func aWokenSessionsReportClaimingTheIncarnationTheParkEndedSpeaks() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()
        let incarnationA = try #require(terminal.sessionIncarnationID)

        #expect(await ingest(
            h, terminal, "state=working:app=claude-code", at: 1,
            incarnation: .claimed(incarnationA)) == .accepted)
        try await h.db.terminals.setHibernated(
            id: terminal.id, sessionID: "acme-session", at: Self.at(2))
        await h.store.drop(terminalID: terminal.id, reason: .parked)

        let parked = try await h.row(terminal)
        let incarnationB = try #require(try await h.db.terminals.prepareHibernatedAgentRespawn(
            id: terminal.id, expectedState: TerminalReplacementSnapshot(terminal: parked),
            at: Self.at(1001)))
        try await h.db.terminals.clearHibernated(id: terminal.id)
        await h.store.dropIfIncarnationChanged(terminalID: terminal.id, reason: .woke)

        #expect(await ingest(
            h, terminal, "state=idle:app=claude-code", at: 999,
            incarnation: .claimed(incarnationA)) == .rejected("observed before drop"))
        #expect(await ingest(
            h, terminal, "state=idle:app=claude-code", at: 1002,
            incarnation: .claimed(UUID())) == .rejected("incarnation mismatch"))
        #expect(try await h.row(terminal).activityState == .unknown)

        #expect(await ingest(
            h, terminal, "state=working:app=claude-code", at: 1003,
            incarnation: .claimed(incarnationA)) == .accepted)
        let row = try await h.row(terminal)
        #expect(row.activityState == .working)
        #expect(row.activityStateObservedAt == Self.at(1003))
        #expect(await h.store.snapshot(for: terminal.id)?.incarnationID == incarnationB)
    }

    /// The same stale claim on a report the app forwarded while the wake
    /// still read parked: the wake replays it as the woken process's.
    @Test func aBackloggedReportClaimingAStaleIncarnationSpeaksAfterTheWake() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal(kind: .codex)
        let incarnationA = try #require(terminal.sessionIncarnationID)

        await ingest(h, terminal, "state=working:app=codex", at: 1, incarnation: .claimed(incarnationA))
        try await h.db.terminals.setHibernated(
            id: terminal.id, sessionID: "acme-thread", at: Self.at(2))
        await h.store.drop(terminalID: terminal.id, reason: .parked)

        let parked = try await h.row(terminal)
        let incarnationB = try #require(try await h.db.terminals.prepareHibernatedAgentRespawn(
            id: terminal.id, expectedState: TerminalReplacementSnapshot(terminal: parked),
            at: Self.at(1001)))
        #expect(await ingest(
            h, terminal, "state=idle:app=codex", at: 1002,
            incarnation: .claimed(incarnationA)) == .rejected("terminal is parked"))
        try await h.db.terminals.clearHibernated(id: terminal.id)
        await h.store.dropIfIncarnationChanged(terminalID: terminal.id, reason: .woke)

        let row = try await h.row(terminal)
        #expect(row.activityState == .idle)
        #expect(row.activityStateSource == .programStatus)
        #expect(row.activityStateObservedAt == Self.at(1002))
        #expect(await h.store.snapshot(for: terminal.id)?.incarnationID == incarnationB)
    }

    /// A park that cannot confirm its child gone rolls back, leaving the
    /// park's `.idle` under a live agent the store last saw working. The
    /// agent's next report that maps to the same value must still be written.
    @Test func aRolledBackParkDoesNotSilenceTheNextReport() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=working:app=claude-code", at: 1)
        let live = try await h.row(terminal)
        _ = try #require(try await h.db.terminals.beginHibernatedShellRespawn(
            id: terminal.id, expectedState: TerminalHibernationSnapshot(terminal: live),
            at: Self.at(2)))
        try await h.db.terminals.clearHibernated(id: terminal.id)
        #expect(try await h.row(terminal).activityState == .idle)

        await ingest(h, terminal, "state=working:app=claude-code:id=t1", at: 3)
        let row = try await h.row(terminal)
        #expect(row.activityState == .working)
        #expect(row.activityStateSource == .programStatus)
    }

    /// A rolled-back park un-parks the row without a wake, so what the agent
    /// reported while the park's intent read parked is discarded: a later
    /// un-park must not replay it for whatever session is then running.
    @Test func aRolledBackParkReplaysNothingAtTheNextWake() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=working:app=claude-code", at: 1)
        let live = try await h.row(terminal)
        _ = try #require(try await h.db.terminals.beginHibernatedShellRespawn(
            id: terminal.id, expectedState: TerminalHibernationSnapshot(terminal: live),
            at: Self.at(2)))
        #expect(await ingest(h, terminal, "state=blocked:app=claude-code:kind=permission", at: 3)
            == .rejected("terminal is parked"))
        try await h.db.terminals.clearHibernated(id: terminal.id)
        await h.store.discardParkedBacklog(terminalID: terminal.id)

        await h.store.dropIfIncarnationChanged(terminalID: terminal.id, reason: .woke)
        let row = try await h.row(terminal)
        #expect(row.activityState == .idle)
        #expect(row.activityStateSource == .database)
        #expect(try await h.attentionNotifications().isEmpty)
    }

    // MARK: - Deletion

    /// The production store forgets a terminal when its row is deleted, by
    /// either deletion path, and keeps what it holds for the others.
    @Test func deletingARowForgetsItsTerminal() async throws {
        let h = try await Harness.make()
        let closed = try await h.terminal()
        let archived = try await h.terminal()
        let repo = try await h.db.repos.create(
            path: "/tmp/pscw-repo-\(UUID().uuidString)", displayName: "acme",
            defaultBranch: "main")
        let otherWorktree = try await h.db.worktrees.create(
            repoID: repo.id, name: "wt2", branch: "main",
            path: "/tmp/pscw-wt-\(UUID().uuidString)", tmuxServer: "tbd-pscw")
        let kept = try await h.db.terminals.create(
            worktreeID: otherWorktree.id, tmuxWindowID: "", tmuxPaneID: "",
            kind: .claude, transport: .holder, sessionIncarnationID: UUID())
        for terminal in [closed, archived] {
            #expect(await ingest(h, terminal, "state=working:app=claude-code", at: 1) == .accepted)
            await h.store.drop(terminalID: terminal.id, reason: .childExited)
        }
        #expect(await ingest(h, kept, "state=working:app=claude-code", at: 1) == .accepted)
        #expect(await h.store.keepsState(for: closed.id))
        #expect(await h.store.keepsState(for: archived.id))

        try await h.db.terminals.delete(id: closed.id)
        #expect(await h.store.keepsState(for: closed.id) == false)
        #expect(await h.store.keepsState(for: archived.id))

        try await h.db.terminals.deleteForWorktree(worktreeID: h.worktreeID)
        #expect(await h.store.keepsState(for: archived.id) == false)
        #expect(await h.store.snapshot(for: kept.id)?.main?.state == .working)
    }

    // MARK: - Reentrancy

    /// Suspends the first caller until `release()`; every later caller passes.
    private final class FirstCallGate: Sendable {
        private struct State: Sendable {
            var calls = 0
            var arrived = false
            var released = false
            var waiting: CheckedContinuation<Void, Never>?
        }

        private let state = OSAllocatedUnfairLock<State>(initialState: State())

        var hasArrived: Bool { state.withLock { $0.arrived } }

        func pass() async {
            let isFirst: Bool = state.withLock { current in
                current.calls += 1
                return current.calls == 1
            }
            guard isFirst else { return }
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

    /// The store suspends on the column write, so a second ingest can run to
    /// completion while the first is still on its way to the database. The
    /// older report must not land last.
    @Test func interleavedIngestsLeaveTheNewerValue() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()
        let real = ProgramStatusEffects.live(
            db: h.db, subscriptions: h.subscriptions, ledger: h.ledger)
        let gate = FirstCallGate()
        let gated = ProgramStatusEffects(
            writeColumns: { write in
                await gate.pass()
                return await real.writeColumns(write)
            },
            raiseAttention: real.raiseAttention,
            recordAgentEvent: real.recordAgentEvent)
        let db = h.db
        let store = ProgramStatusStore(
            terminalLookup: { id in try? await db.terminals.get(id: id) },
            publish: { _ in },
            effects: gated)

        let older = Self.inbound(terminal, "state=working:app=claude-code", at: 1)
        let first = Task { await store.ingest(older) }
        let reached = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in
            gate.hasArrived
        }
        if reached == .timedOut {
            Issue.record("the first ingest never reached its column write")
        }
        #expect(await store.ingest(
            Self.inbound(terminal, "state=idle:app=claude-code", at: 2)) == .accepted)
        gate.release()
        #expect(await first.value == .accepted)

        let row = try await h.row(terminal)
        #expect(row.activityState == .idle)
        #expect(row.activityStateObservedAt == Self.at(2))
    }

    // MARK: - Deltas

    @Test func deltasCarryProgramStatusProvenance() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(h, terminal, "state=working:app=claude-code", at: 1)
        let activity = try #require(h.activityDeltas(terminal).last)
        #expect(activity.activityState == .working)
        #expect(activity.worktreeID == h.worktreeID)
        #expect(activity.activityStateSource == .programStatus)
        #expect(activity.activityStateObservedAt == Self.at(1))
        #expect(activity.activityStateOrderObservedAt == Self.at(1))
        #expect(h.awaitingInputDeltas(terminal).isEmpty)

        await ingest(h, terminal, "state=blocked:app=claude-code:kind=permission", at: 2)
        let raised = try #require(h.awaitingInputDeltas(terminal).last)
        #expect(raised.reason?.programStatusBlock?.kind == .permission)
        #expect(raised.observedAt == Self.at(2))

        await ingest(h, terminal, "state=working:app=claude-code", at: 3)
        let deltas = h.awaitingInputDeltas(terminal)
        #expect(deltas.count == 2)
        let retracted = try #require(deltas.last)
        #expect(retracted.reason == nil)
        #expect(retracted.observedAt == nil)
    }

    // MARK: - Banner

    @Test func bannerOnEnteringBlockedOnlyOnce() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(
            h, terminal,
            "state=blocked:app=claude-code:kind=permission:msg=\(Self.encodedSecret)", at: 1)
        await ingest(
            h, terminal,
            "state=blocked:app=claude-code:kind=permission:msg=\(Self.encodedSecret)", at: 2)
        await ingest(
            h, terminal,
            "state=blocked:app=claude-code:kind=question:msg=\(Self.encodedSecret)", at: 3)

        let notifications = try await h.attentionNotifications()
        #expect(notifications.count == 1)
        #expect(notifications.first?.message == "Claude needs your permission")
        let message = notifications.first?.message ?? ""
        #expect(!message.contains(Self.secret))
    }

    @Test func bannerTextFollowsTheAgent() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal(kind: .codex)

        #expect(await ingest(h, terminal, "state=blocked:app=codex:kind=question", at: 1) == .accepted)
        let notifications = try await h.attentionNotifications()
        #expect(notifications.count == 1)
        #expect(notifications.first?.message == "Codex has a question")
        let message = notifications.first?.message ?? ""
        #expect(!message.contains(Self.secret))
    }

    /// A sign-in block maps to idle and raises nothing. A blocked task entry
    /// still does once the main entry moves on (a main-entry auth block
    /// outranks every task entry in the roll-up).
    @Test func authRaisesNoBanner() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()

        await ingest(
            h, terminal, "state=blocked:app=claude-code:kind=auth:msg=\(Self.encodedSecret)", at: 1)
        #expect(try await h.attentionNotifications().isEmpty)

        await ingest(h, terminal, "state=idle:app=claude-code", at: 2)
        await ingest(
            h, terminal,
            "state=blocked:app=claude-code:id=t1:kind=permission:msg=\(Self.encodedSecret)", at: 3)
        let notifications = try await h.attentionNotifications()
        #expect(notifications.count == 1)
        #expect(notifications.first?.message == "Claude needs your input")
        let message = notifications.first?.message ?? ""
        #expect(!message.contains(Self.secret))
    }

    /// After a daemon restart the store's memory is empty, but the row still
    /// says the session is waiting: the banner it raised before must not be
    /// raised again.
    @Test func aFreshStoreOnAnAlreadyWaitingRowRaisesNoBanner() async throws {
        let h = try await Harness.make()
        let terminal = try await h.terminal()
        let block = ProgramStatusBlock(kind: .permission, taskID: nil)
        _ = try await h.db.terminals.applyProgramStatusActivity(
            id: terminal.id, scope: .incarnation(terminal.sessionIncarnationID),
            activityState: .waitingForUser,
            awaitingInputReason: AwaitingInputReason(message: "", programStatusBlock: block),
            observedAt: Self.at(1))

        #expect(await ingest(
            h, terminal, "state=blocked:app=claude-code:kind=permission", at: 2) == .accepted)
        #expect(try await h.row(terminal).activityState == .waitingForUser)
        #expect(try await h.attentionNotifications().isEmpty)
    }

    // MARK: - Ledger

    @Test func anAcceptedReportStampsTheLedger() async throws {
        let h = try await Harness.make()
        let shell = try await h.terminal(kind: .shell)
        let claude = try await h.terminal()

        #expect(await ingest(h, shell, "state=working:app=claude-code", at: 2) != .accepted)
        #expect(await ingest(h, claude, "state=working:app=claude-code", at: 1) == .accepted)
        #expect(await h.ledger.snapshot().hooks == [claude.id: Self.at(1)])
    }
}
