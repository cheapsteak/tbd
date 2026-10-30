import Foundation
import os
import TBDShared

private let programStatusLog = Logger(subsystem: "com.tbd.daemon", category: "programStatus")

/// Owns every Program Status Protocol (OSC 7501) report the daemon accepts:
/// per terminal, the main entry and up to 32 task entries.
///
/// The entries are memory only — `title` and `msg` can carry content from the
/// user's work — and a daemon restart starts empty. What reaches `state.db` is
/// the rolled-up state mapped onto the activity columns every consumer reads
/// (`ProgramStatusColumnValue`), written through `effects` when the mapped
/// value changes. It also raises the attention banner when a session becomes
/// blocked, and stamps the PR-poll activity ledger for every accepted report.
///
/// Design: docs/specs/2026-10-10-program-status-protocol-design.md ("Trust",
/// "Liveness", "Rolling up task entries");
/// docs/specs/2026-10-30-osc-only-agent-status-design.md ("The store writes
/// the activity columns", "Attention banner", "PR poll pacing").
public actor ProgramStatusStore {
    /// Which incarnation a report belongs to.
    public enum Incarnation: Sendable, Equatable {
        /// The daemon's own reader: it reads the current holder process, so the
        /// row's current incarnation is the report's.
        case currentRow
        /// Forwarded by the app, which names the incarnation it was attached to.
        case claimed(UUID?)
    }

    /// One report on its way into the store.
    public struct Inbound: Sendable {
        public let terminalID: UUID
        public let incarnation: Incarnation
        /// The raw OSC data after `7501;`.
        public let payload: [UInt8]
        public let observedAt: Date

        public init(terminalID: UUID, incarnation: Incarnation, payload: [UInt8], observedAt: Date) {
            self.terminalID = terminalID
            self.incarnation = incarnation
            self.payload = payload
            self.observedAt = observedAt
        }
    }

    public enum Outcome: Sendable, Equatable {
        case accepted
        case ignoredProbe
        case rejected(String)
    }

    /// Why a terminal's entries were dropped wholesale (spec "Liveness").
    public enum DropReason: String, Sendable {
        case childExited
        case parked
        case woke
        case incarnationChanged
    }

    public nonisolated let now: @Sendable () -> Date
    private let terminalLookup: @Sendable (UUID) async -> Terminal?
    private let publish: @Sendable (ProgramStatusSnapshot) -> Void
    private let effects: ProgramStatusEffects
    private let inbox: AsyncStream<Inbound>
    private nonisolated let inboxContinuation: AsyncStream<Inbound>.Continuation

    private struct Held {
        var incarnationID: UUID?
        var main: ProgramStatusEntry?
        var tasks: [ProgramStatusTaskEntry]
        var lastObservedAt: Date
    }

    private var held: [UUID: Held] = [:]
    /// Per-terminal mutation counter, never reset — see
    /// `ProgramStatusSnapshot.revision`.
    private var revisions: [UUID: UInt64] = [:]
    /// Per-terminal count of unconditional drops, never reset. `ingest`
    /// captures it before its terminal lookup suspends and refuses to apply
    /// if it moved: a drop that ran during the lookup found nothing to drop,
    /// and the report it raced belongs to the session that drop ended.
    private var dropGenerations: [UUID: UInt64] = [:]
    /// Per-terminal instant (from `now`) of the latest unconditional drop. A
    /// report observed at or before it belongs to the session that drop
    /// ended — a backlog the daemon's inbox or the app's forwarder delivers
    /// late — and is refused.
    private var droppedAt: [UUID: Date] = [:]

    /// The column value the row is known to hold for one incarnation.
    private struct WrittenColumn {
        var incarnationID: UUID?
        var value: ProgramStatusColumnValue
    }

    /// Per terminal, the column value the last write found or left standing,
    /// so a report that maps to the same value writes nothing. Set only from a
    /// write's outcome; cleared by every drop and while a write is in flight.
    private var written: [UUID: WrittenColumn] = [:]
    /// Per-terminal count of column writes started and memo resets, never
    /// reset. A write records its outcome in `written` only if this did not
    /// move while it was suspended: a later write, or a drop, then describes
    /// the row better than it does.
    private var columnGenerations: [UUID: UInt64] = [:]

    /// `effects` defaults to `.inert`: entries are held and published, and
    /// nothing is written, raised or stamped.
    public init(
        terminalLookup: @escaping @Sendable (UUID) async -> Terminal?,
        publish: @escaping @Sendable (ProgramStatusSnapshot) -> Void,
        effects: ProgramStatusEffects = .inert,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.terminalLookup = terminalLookup
        self.publish = publish
        self.effects = effects
        let made = AsyncStream.makeStream(
            of: Inbound.self, bufferingPolicy: .bufferingNewest(4096))
        self.inbox = made.stream
        self.inboxContinuation = made.continuation
    }

    /// The production store: terminals from `db`, snapshots broadcast as
    /// `.terminalProgramStatusChanged`, and `ProgramStatusEffects.live` for
    /// the columns, the banner and `ledger`.
    public static func live(
        db: TBDDatabase,
        subscriptions: StateSubscriptionManager,
        ledger: WorktreeActivityLedger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ProgramStatusStore {
        ProgramStatusStore(
            terminalLookup: { id in
                do {
                    return try await db.terminals.get(id: id)
                } catch {
                    return nil
                }
            },
            publish: { snapshot in
                subscriptions.broadcast(delta: .terminalProgramStatusChanged(snapshot))
            },
            effects: .live(db: db, subscriptions: subscriptions, ledger: ledger),
            now: now)
    }

    /// Thread-safe and non-blocking: the daemon reader's path. Reports are
    /// ingested in enqueue order by `run()`.
    public nonisolated func enqueue(_ inbound: Inbound) {
        inboxContinuation.yield(inbound)
    }

    /// Consumes the inbox in order. Started once by the daemon.
    public func run() async {
        for await inbound in inbox {
            _ = await ingest(inbound)
        }
    }

    /// Validate and apply one report.
    @discardableResult
    public func ingest(_ inbound: Inbound) async -> Outcome {
        let terminalID = inbound.terminalID

        // 1. Parse.
        guard let payload = ProgramStatusParser.parse(inbound.payload) else {
            return reject(terminalID, "unparseable payload")
        }
        let report: ProgramStatusReport
        switch payload {
        case .probe:
            return .ignoredProbe
        case .report(let parsed):
            report = parsed
        }

        // 2. App. Each agent stamps its own `app` on every state report —
        // `claude-code` or `codex` — but writes its clears without one: Claude
        // Code both the bare `state=clear` and `state=clear:id=X` (read from
        // the v2.1.301 bundle), Codex its bare `state=clear`. So a clear with
        // no `app` is accepted; one naming an app TBD does not know is still
        // refused. Refusing app-less clears left a finished task entry
        // standing, and with it a session stuck reading as working. Whether
        // the app is the terminal's own agent is checked after the lookup.
        guard report.app != nil || report.state == .clear else {
            return reject(terminalID, "missing app")
        }
        if let app = report.app, !ProgramStatusProtocol.knownApps.contains(app) {
            return reject(terminalID, "unknown app")
        }

        // A report observed at or before the terminal's latest drop belongs
        // to the session that drop ended.
        if let watermark = droppedAt[terminalID], inbound.observedAt <= watermark {
            return reject(terminalID, "observed before drop")
        }

        // 3. A live holder session running an agent that reports, and a
        // report from that agent: `app` must be the terminal's own, so a
        // Claude report on a Codex terminal (or the reverse) is refused. An
        // app-less clear is either agent's.
        let generationBeforeLookup = dropGenerations[terminalID] ?? 0
        guard let terminal = await terminalLookup(terminalID) else {
            return reject(terminalID, "unknown terminal")
        }
        guard terminal.transport == .holder else { return reject(terminalID, "not a holder session") }
        guard !terminal.isParked else { return reject(terminalID, "terminal is parked") }
        guard let expectedApp = ProgramStatusProtocol.expectedApp(for: terminal) else {
            return reject(terminalID, "not an agent session")
        }
        if let app = report.app, app != expectedApp {
            return reject(terminalID, "app does not match the terminal's agent")
        }

        // 4. Incarnation.
        let incarnationID: UUID?
        switch inbound.incarnation {
        case .currentRow:
            incarnationID = terminal.sessionIncarnationID
        case .claimed(let claimed):
            guard claimed == terminal.sessionIncarnationID else {
                return reject(terminalID, "incarnation mismatch")
            }
            incarnationID = claimed
        }

        // A drop that ran while the lookup was suspended found nothing to
        // drop; applying now would hold an entry nothing ever clears.
        guard (dropGenerations[terminalID] ?? 0) == generationBeforeLookup else {
            return reject(terminalID, "dropped during lookup")
        }

        // 5. Re-read state after the await (actor reentrancy).
        var current: Held
        if let existing = held[terminalID], existing.incarnationID == incarnationID {
            if inbound.observedAt < existing.lastObservedAt {
                return reject(terminalID, "stale")
            }
            current = existing
        } else {
            if held[terminalID] != nil {
                programStatusLog.debug(
                    "drop terminal=\(terminalID.uuidString, privacy: .public) reason=\(DropReason.incarnationChanged.rawValue, privacy: .public)")
            }
            current = Held(
                incarnationID: incarnationID, main: nil, tasks: [],
                lastObservedAt: inbound.observedAt)
        }

        // 6. Apply.
        let entry = ProgramStatusEntry(report: report, observedAt: inbound.observedAt)
        if let taskID = report.id {
            if report.state == .clear {
                current.tasks.removeAll { $0.id == taskID }
            } else if let index = current.tasks.firstIndex(where: { $0.id == taskID }) {
                current.tasks[index].entry = entry
            } else {
                if current.tasks.count >= ProgramStatusProtocol.maxTaskEntries {
                    Self.evictOldestTask(&current.tasks)
                }
                current.tasks.append(ProgramStatusTaskEntry(id: taskID, entry: entry))
            }
        } else if report.state == .clear {
            // Bare `state=clear`: the program exited or restored terminal
            // modes. Main and tasks both go.
            current.main = nil
            current.tasks = []
        } else {
            current.main = entry
        }
        current.lastObservedAt = inbound.observedAt

        if current.main == nil && current.tasks.isEmpty {
            held.removeValue(forKey: terminalID)
            publishEmpty(terminalID: terminalID, incarnationID: incarnationID)
        } else {
            held[terminalID] = current
            publishCurrent(terminalID: terminalID)
        }

        // 7. The activity columns. A bare `clear` ends the agent's reporting:
        // `.unknown`. Otherwise the roll-up's mapped value; nil (task entries
        // with no main entry, as after a restart, or a main entry this build
        // does not recognize) writes nothing.
        let columnValue: ProgramStatusColumnValue?
        if report.id == nil && report.state == .clear {
            columnValue = .unknown
        } else {
            columnValue = snapshot(for: terminalID)
                .flatMap { ProgramStatusRollup.resolve($0) }
                .flatMap { ProgramStatusColumnValue.mapping($0.value) }
        }
        if let columnValue {
            let alreadyStanding = written[terminalID].map {
                $0.incarnationID == incarnationID && $0.value == columnValue
            } ?? false
            if !alreadyStanding {
                let outcome = await writeColumn(ProgramStatusColumnWrite(
                    terminalID: terminalID, value: columnValue,
                    scope: .incarnation(incarnationID), observedAt: inbound.observedAt))
                // The banner keys on the committed transition into a wait,
                // not on this store's memory, so a store that restarted empty
                // never raises one for a session already waiting.
                if case .written(let previous) = outcome,
                   previous != .waitingForUser,
                   let block = columnValue.block {
                    await effects.raiseAttention(
                        terminal.worktreeID,
                        ProgramStatusAttention.message(app: expectedApp, block: block))
                }
            }
        }

        // 8. Every accepted report marks the worktree active for the PR poll
        // schedule, whether or not it moved the column.
        await effects.recordAgentEvent(terminalID, terminal.worktreeID, inbound.observedAt)
        return .accepted
    }

    /// The terminal's current snapshot, or nil when nothing is held for it.
    public func snapshot(for terminalID: UUID) -> ProgramStatusSnapshot? {
        guard let entry = held[terminalID] else { return nil }
        return ProgramStatusSnapshot(
            terminalID: terminalID,
            incarnationID: entry.incarnationID,
            main: entry.main,
            tasks: entry.tasks,
            revision: revisions[terminalID] ?? 0)
    }

    /// `snapshot(for:)` for each of `terminalIDs`, in one actor hop, keyed by
    /// terminal ID. A terminal the store holds nothing for is absent.
    public func snapshots(for terminalIDs: [UUID]) -> [UUID: ProgramStatusSnapshot] {
        var out: [UUID: ProgramStatusSnapshot] = [:]
        for terminalID in terminalIDs {
            if let snapshot = snapshot(for: terminalID) {
                out[terminalID] = snapshot
            }
        }
        return out
    }

    /// Every terminal that holds a main entry or task entries.
    public func allSnapshots() -> [ProgramStatusSnapshot] {
        var out: [ProgramStatusSnapshot] = []
        for terminalID in held.keys {
            if let snapshot = snapshot(for: terminalID), !snapshot.isEmpty {
                out.append(snapshot)
            }
        }
        return out
    }

    /// Drop every entry for a terminal (spec "Liveness"), and refuse every
    /// report for it observed up to now — including one whose ingest is
    /// suspended on its terminal lookup right now. Publishes a retraction
    /// when anything was held.
    ///
    /// For an end that is unconditional: the child exited or the row parked.
    ///
    /// A child exit also writes `.unknown` to the columns, for whichever
    /// incarnation is live, whatever this store holds: the column may carry a
    /// value written before a daemon restart that the store never saw. A park
    /// writes nothing here — the park itself wrote `.idle`, and the writer
    /// refuses a parked row — and neither does a wake: its lifecycle reset
    /// already wrote `.unknown` for the new incarnation, which the woken agent
    /// may have overwritten by now.
    public func drop(terminalID: UUID, reason: DropReason) async {
        let droppedNow = now()
        dropGenerations[terminalID] = (dropGenerations[terminalID] ?? 0) + 1
        droppedAt[terminalID] = droppedNow
        removeHeld(terminalID: terminalID, reason: reason)
        guard reason == .childExited else { return }
        _ = await writeColumn(ProgramStatusColumnWrite(
            terminalID: terminalID, value: .unknown,
            scope: .anyLiveIncarnation, observedAt: droppedNow))
    }

    /// Drop the terminal's entries only if they belong to an incarnation other
    /// than the row's current one (or the row is gone). A wake's drop: by the
    /// time it runs, the replacement session is live and its reports may
    /// already be held, and those are its current state. Sets no watermark,
    /// so the live session's reports keep flowing.
    public func dropIfIncarnationChanged(terminalID: UUID, reason: DropReason) async {
        guard held[terminalID] != nil else { return }
        let terminal = await terminalLookup(terminalID)
        // Re-read after the await (actor reentrancy).
        guard let current = held[terminalID] else { return }
        if let terminal, current.incarnationID == terminal.sessionIncarnationID { return }
        removeHeld(terminalID: terminalID, reason: reason)
    }

    // MARK: - Private

    /// Also forgets the terminal's column memo, whether or not anything was
    /// held: every drop ends what the memo described.
    private func removeHeld(terminalID: UUID, reason: DropReason) {
        forgetColumn(terminalID)
        guard let removed = held.removeValue(forKey: terminalID) else { return }
        programStatusLog.debug(
            "drop terminal=\(terminalID.uuidString, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        publishEmpty(terminalID: terminalID, incarnationID: removed.incarnationID)
    }

    /// Write the columns through `effects`, and remember what the row holds
    /// afterwards when nothing raced the write.
    ///
    /// While the write is suspended the memo says nothing: a report arriving
    /// meanwhile must reach the writer, whose order guard decides between the
    /// two. A write scoped to any live incarnation (a child exit) leaves no
    /// memo, since it cannot name the incarnation it landed on.
    private func writeColumn(_ write: ProgramStatusColumnWrite) async -> ProgramStatusColumnOutcome {
        let generation = forgetColumn(write.terminalID)
        let outcome = await effects.writeColumns(write)
        // Re-read after the await (actor reentrancy).
        guard columnGenerations[write.terminalID] == generation,
              case .incarnation(let incarnationID) = write.scope else { return outcome }
        switch outcome {
        case .unchanged, .written:
            written[write.terminalID] = WrittenColumn(incarnationID: incarnationID, value: write.value)
        case .refused:
            break
        }
        return outcome
    }

    /// Clear the terminal's memo and bump its column generation, so a write
    /// in flight records nothing when it resumes. Returns the new generation.
    @discardableResult
    private func forgetColumn(_ terminalID: UUID) -> UInt64 {
        written.removeValue(forKey: terminalID)
        let next = (columnGenerations[terminalID] ?? 0) + 1
        columnGenerations[terminalID] = next
        return next
    }

    private func reject(_ terminalID: UUID, _ reason: String) -> Outcome {
        programStatusLog.debug(
            "rejected report terminal=\(terminalID.uuidString, privacy: .public) reason=\(reason, privacy: .public)")
        return .rejected(reason)
    }

    private func bumpRevision(_ terminalID: UUID) -> UInt64 {
        let next = (revisions[terminalID] ?? 0) + 1
        revisions[terminalID] = next
        return next
    }

    /// Published synchronously inside the actor, so publish order equals
    /// mutation order.
    private func publishCurrent(terminalID: UUID) {
        guard let entry = held[terminalID] else { return }
        let revision = bumpRevision(terminalID)
        publish(ProgramStatusSnapshot(
            terminalID: terminalID,
            incarnationID: entry.incarnationID,
            main: entry.main,
            tasks: entry.tasks,
            revision: revision))
    }

    private func publishEmpty(terminalID: UUID, incarnationID: UUID?) {
        let revision = bumpRevision(terminalID)
        publish(ProgramStatusSnapshot(
            terminalID: terminalID,
            incarnationID: incarnationID,
            main: nil,
            tasks: [],
            revision: revision))
    }

    /// Remove the task whose entry was observed longest ago.
    private static func evictOldestTask(_ tasks: inout [ProgramStatusTaskEntry]) {
        guard !tasks.isEmpty else { return }
        var oldestIndex = 0
        for index in tasks.indices where tasks[index].entry.observedAt < tasks[oldestIndex].entry.observedAt {
            oldestIndex = index
        }
        tasks.remove(at: oldestIndex)
    }
}

extension ProgramStatusEffects {
    /// The production effects.
    ///
    /// - `writeColumns` writes through `TerminalStore.applyProgramStatusActivity`
    ///   (a failed write is a refusal) and broadcasts the
    ///   `terminalActivityUpdated` and `terminalAwaitingInputChanged` deltas the
    ///   app reads, each only when its half changed. A cancelled scheduled
    ///   resume needs no wake of the resume scheduler: its loop re-reads
    ///   pending rows, and its eligibility check refuses a cancelled one.
    /// - `raiseAttention` creates an `.attentionNeeded` notification and
    ///   broadcasts it; a failed insert is logged and dropped.
    /// - `recordAgentEvent` stamps `ledger`.
    public static func live(
        db: TBDDatabase,
        subscriptions: StateSubscriptionManager,
        ledger: WorktreeActivityLedger
    ) -> ProgramStatusEffects {
        ProgramStatusEffects(
            writeColumns: { write in
                let applied: ProgramStatusActivityWrite?
                do {
                    applied = try await db.terminals.applyProgramStatusActivity(
                        id: write.terminalID, scope: write.scope,
                        activityState: write.value.activityState,
                        awaitingInputReason: write.value.awaitingInputReason,
                        observedAt: write.observedAt)
                } catch {
                    programStatusLog.debug(
                        "column write failed terminal=\(write.terminalID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    return .refused
                }
                guard let applied else { return .refused }
                if applied.stateChanged {
                    subscriptions.broadcast(delta: .terminalActivityUpdated(TerminalActivityDelta(
                        terminalID: write.terminalID,
                        worktreeID: applied.worktreeID,
                        activityState: write.value.activityState,
                        activityStateSource: .programStatus,
                        activityStateObservedAt: write.observedAt,
                        activityStateOrderObservedAt: write.observedAt)))
                }
                if applied.reasonChanged {
                    let reason = write.value.awaitingInputReason
                    subscriptions.broadcast(delta: .terminalAwaitingInputChanged(
                        TerminalAwaitingInputDelta(
                            terminalID: write.terminalID,
                            worktreeID: applied.worktreeID,
                            reason: reason,
                            observedAt: reason == nil ? nil : write.observedAt)))
                }
                guard applied.stateChanged || applied.reasonChanged else { return .unchanged }
                return .written(previous: applied.previousActivityState)
            },
            raiseAttention: { worktreeID, message in
                do {
                    let notification = try await db.notifications.create(
                        worktreeID: worktreeID, type: .attentionNeeded, message: message)
                    subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
                        notificationID: notification.id,
                        worktreeID: notification.worktreeID,
                        type: notification.type,
                        message: notification.message)))
                } catch {
                    programStatusLog.debug(
                        "attention notification failed worktree=\(worktreeID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                }
            },
            recordAgentEvent: { terminalID, worktreeID, date in
                await ledger.recordAgentEvent(terminalID: terminalID, worktreeID: worktreeID, at: date)
            })
    }
}
