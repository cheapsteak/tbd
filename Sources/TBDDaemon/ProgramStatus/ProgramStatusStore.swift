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
    /// Per terminal, the incarnations unconditional drops ended — the one
    /// whose entries a drop removed, and the row's own at the drop — newest
    /// last, at most `maxEndedIncarnations`. A report observed after a drop
    /// can only come from the process that replaced the one it ended, so a
    /// report claiming one of these is filed under the row's current
    /// incarnation: the app labels what it reads with its cached row, which
    /// catches up with a wake only when the wake's broadcast arrives.
    private var endedIncarnations: [UUID: [UUID?]] = [:]
    private static let maxEndedIncarnations = 8

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
    /// Per terminal, the reports refused only because the row was parked, in
    /// arrival order and at most `maxParkedBacklog` of them. A wake starts its
    /// replacement process while the row still reads parked and un-parks it
    /// only once the launch is recorded, so whatever that process reports in
    /// between is refused — and an agent reports on change only, so it never
    /// says it again. The wake's drop (`dropIfIncarnationChanged`) replays
    /// these through `ingest`; every unconditional drop discards them, since a
    /// report from before a park's drop belongs to the session the park ended,
    /// and so does a park that rolls back (`discardParkedBacklog`), whose
    /// un-park is no wake.
    private var parkedBacklog: [UUID: [Inbound]] = [:]
    private static let maxParkedBacklog = ProgramStatusProtocol.maxTaskEntries + 1
    /// Terminals whose rows were deleted (`forget`), newest last, at most
    /// `maxForgotten`: the tombstone an `ingest` or a `drop` suspended on its
    /// terminal lookup across the `forget` checks when it resumes. Its lookup
    /// may have read the row before the delete committed, and applying would
    /// re-create what `forget` removed, for a row nothing will ever delete
    /// again. Bounded, because a terminal's ID is never reused, so only work
    /// already under way when its row was deleted, or an exit reported just
    /// after, can still name it.
    private var forgotten: Set<UUID> = []
    private var forgottenOrder: [UUID] = []
    private static let maxForgotten = 512

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
    /// `.terminalProgramStatusChanged`, `ProgramStatusEffects.live` for the
    /// columns, the banner and `ledger`, and what it keeps for a terminal
    /// forgotten when `db` deletes the terminal's row.
    public static func live(
        db: TBDDatabase,
        subscriptions: StateSubscriptionManager,
        ledger: WorktreeActivityLedger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ProgramStatusStore {
        let store = ProgramStatusStore(
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
        db.terminals.deletions.onTerminalsDeleted { [weak store] terminalIDs in
            await store?.forget(terminalIDs: terminalIDs)
        }
        return store
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
        let observedAfterADrop = droppedAt[terminalID] != nil

        // 3. A live holder session running an agent that reports, and a
        // report from that agent: `app` must be the terminal's own, so a
        // Claude report on a Codex terminal (or the reverse) is refused. An
        // app-less clear is either agent's.
        let generationBeforeLookup = dropGenerations[terminalID] ?? 0
        guard let terminal = await terminalLookup(terminalID) else {
            return reject(terminalID, "unknown terminal")
        }
        // A row deleted while the lookup was suspended: what this report
        // would hold has already been forgotten.
        guard !forgotten.contains(terminalID) else {
            return reject(terminalID, "terminal deleted")
        }
        guard terminal.transport == .holder else { return reject(terminalID, "not a holder session") }
        if terminal.isParked {
            // Refused now, and kept for the wake's replay when the report is
            // the row's own agent's and no drop ran during the lookup.
            if (dropGenerations[terminalID] ?? 0) == generationBeforeLookup,
               let expectedApp = ProgramStatusProtocol.expectedApp(for: terminal),
               report.app.map({ $0 == expectedApp }) ?? true {
                holdUntilWake(inbound)
            }
            return reject(terminalID, "terminal is parked")
        }
        guard let expectedApp = ProgramStatusProtocol.expectedApp(for: terminal) else {
            return reject(terminalID, "not an agent session")
        }
        if let app = report.app, app != expectedApp {
            return reject(terminalID, "app does not match the terminal's agent")
        }

        // 4. Incarnation. A claim of an incarnation a drop ended, observed
        // after that drop, names a process that is gone: the bytes came from
        // its replacement, so the report is the row's current incarnation's.
        let incarnationID: UUID?
        switch inbound.incarnation {
        case .currentRow:
            incarnationID = terminal.sessionIncarnationID
        case .claimed(let claimed):
            if claimed == terminal.sessionIncarnationID {
                incarnationID = claimed
            } else if observedAfterADrop,
                      endedIncarnations[terminalID]?.contains(claimed) == true {
                incarnationID = terminal.sessionIncarnationID
            } else {
                return reject(terminalID, "incarnation mismatch")
            }
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
            // Nothing held for this incarnation, as after a daemon restart or
            // a bare `clear`, so there is no held report to be stale against.
            // A column this store wrote (`.programStatus`) speaks for the
            // row's current incarnation and outlives the store's memory: a
            // report observed at or before its stamp — one the app re-sends
            // from before the restart — would install and publish a main
            // entry older than the column, which a later task-entry report
            // would then roll up and write.
            if terminal.activityStateSource == .programStatus,
               let columnOrder = terminal.activityStateOrderObservedAt
                   ?? terminal.activityStateObservedAt,
               inbound.observedAt <= columnOrder {
                return reject(terminalID, "observed before the column")
            }
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
            // Skipped only when this store's last write left the value AND the
            // row read above still holds it, source included: a park that
            // rolled back writes the columns without this store seeing it.
            let memoMatches = written[terminalID].map {
                $0.incarnationID == incarnationID && $0.value == columnValue
            } ?? false
            let rowMatches = terminal.activityState == columnValue.activityState
                && terminal.awaitingInputReason == columnValue.awaitingInputReason
                && terminal.activityStateSource == .programStatus
            if !(memoMatches && rowMatches) {
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

    /// Whether the store holds a report from `incarnationID` of `terminalID` —
    /// whether that process is reporting its state. The caller passes the
    /// incarnation it read off the row. False after a bare `clear` or a drop,
    /// and for an agent that never reported.
    public func holdsReport(terminalID: UUID, incarnationID: UUID?) -> Bool {
        guard let entry = held[terminalID] else { return false }
        return entry.incarnationID == incarnationID
    }

    /// Whether `terminal`'s current incarnation is a reporting one: the store
    /// holds a report from it, or the row's activity column holds a value
    /// this store wrote (`.programStatus`). The column is the half that
    /// survives a daemon restart, which starts the store empty. It speaks
    /// only for the current incarnation, because every write that mints an
    /// incarnation — a wake, a respawn, a park — rewrites the source, and the
    /// store writes `.programStatus` only for the incarnation the row names.
    public func isReporting(_ terminal: Terminal) -> Bool {
        terminal.activityStateSource == .programStatus
            || holdsReport(terminalID: terminal.id, incarnationID: terminal.sessionIncarnationID)
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
    /// Records the incarnations the drop ended — the held entries' and the
    /// row's at the drop — so a later report that still claims one of them,
    /// from a forwarder whose cached row has not caught up, is filed under
    /// the replacement's (see `endedIncarnations`).
    ///
    /// A child exit also writes `.unknown` to the columns, for whichever
    /// incarnation is live, whatever this store holds: the column may carry a
    /// value written before a daemon restart that the store never saw. It is
    /// stamped `.processLiveness`, the fact it comes from, so the app does not
    /// read a session whose agent died as one that never reported. A park
    /// writes nothing here — the park itself wrote `.idle`, and the writer
    /// refuses a parked row — and neither does a wake: its lifecycle reset
    /// already wrote `.unknown` for the new incarnation, which the woken agent
    /// may have overwritten by now.
    public func drop(terminalID: UUID, reason: DropReason) async {
        // A deleted row's exit or park, reported after its `forget`: there is
        // nothing to drop, and the watermarks would outlive the row.
        guard !forgotten.contains(terminalID) else { return }
        let droppedNow = now()
        dropGenerations[terminalID] = (dropGenerations[terminalID] ?? 0) + 1
        droppedAt[terminalID] = droppedNow
        parkedBacklog.removeValue(forKey: terminalID)
        if let ended = held[terminalID] {
            recordEnded(ended.incarnationID, terminalID: terminalID)
        }
        removeHeld(terminalID: terminalID, reason: reason)
        // After the watermark is set, so no report this drop ended can slip
        // in while the lookup is suspended.
        let row = await terminalLookup(terminalID)
        // Re-read after the await (actor reentrancy): a `forget` that ran
        // meanwhile removed what this drop recorded, and the row is gone.
        guard !forgotten.contains(terminalID) else { return }
        if let row {
            recordEnded(row.sessionIncarnationID, terminalID: terminalID)
        }
        guard reason == .childExited else { return }
        _ = await writeColumn(ProgramStatusColumnWrite(
            terminalID: terminalID, value: .unknown,
            scope: .anyLiveIncarnation, observedAt: droppedNow,
            source: .processLiveness))
    }

    /// Drop the terminal's entries only if they belong to an incarnation other
    /// than the row's current one (or the row is gone). A wake's drop: by the
    /// time it runs, the replacement session is live and its reports may
    /// already be held, and those are its current state. Sets no watermark,
    /// so the live session's reports keep flowing.
    ///
    /// Then replays, through `ingest`, every report refused while the row
    /// still read parked (`parkedBacklog`): the replacement process's first
    /// reports, made before the wake un-parked the row. Each is validated
    /// again against the row as it stands now, under the row's current
    /// incarnation whatever incarnation it claimed: every unconditional drop
    /// empties the backlog and refuses what was observed before it, so what
    /// is left was observed after the process the park ended was gone, and
    /// can only be its replacement's — a forwarder labels it with a cached
    /// row that has not caught up with the wake.
    public func dropIfIncarnationChanged(terminalID: UUID, reason: DropReason) async {
        if held[terminalID] != nil {
            let terminal = await terminalLookup(terminalID)
            // Re-read after the await (actor reentrancy).
            if let current = held[terminalID],
               terminal.map({ current.incarnationID != $0.sessionIncarnationID }) ?? true {
                removeHeld(terminalID: terminalID, reason: reason)
            }
        }
        for inbound in parkedBacklog.removeValue(forKey: terminalID) ?? [] {
            _ = await ingest(Inbound(
                terminalID: inbound.terminalID, incarnation: .currentRow,
                payload: inbound.payload, observedAt: inbound.observedAt))
        }
    }

    /// Discard the reports kept while the row read parked, because something
    /// other than the wake that replays them un-parked it: a park that rolled
    /// back. What they report belongs to the session that park was ending, and
    /// replayed at a later wake they would speak for its replacement.
    public func discardParkedBacklog(terminalID: UUID) {
        parkedBacklog.removeValue(forKey: terminalID)
    }

    /// Forget everything kept for terminals whose rows were deleted: entries,
    /// counters, watermarks, the parked backlog and the column memo. A deleted
    /// row takes no further report — its lookup finds nothing — so none of it
    /// would ever be read again. `live` calls this for every row
    /// `TerminalStore` deletes, the rows a worktree or repo delete cascades to
    /// among them.
    ///
    /// Leaves only a tombstone, in the bounded `forgotten`: an ingest or a
    /// drop already suspended on its terminal lookup may have read the row
    /// before the delete, and it refuses when it resumes instead of
    /// re-creating what this removed.
    public func forget(terminalIDs: [UUID]) {
        for terminalID in terminalIDs {
            if forgotten.insert(terminalID).inserted {
                forgottenOrder.append(terminalID)
            }
            held.removeValue(forKey: terminalID)
            revisions.removeValue(forKey: terminalID)
            dropGenerations.removeValue(forKey: terminalID)
            droppedAt.removeValue(forKey: terminalID)
            endedIncarnations.removeValue(forKey: terminalID)
            written.removeValue(forKey: terminalID)
            columnGenerations.removeValue(forKey: terminalID)
            parkedBacklog.removeValue(forKey: terminalID)
        }
        if forgottenOrder.count > Self.maxForgotten {
            let evicted = forgottenOrder.prefix(forgottenOrder.count - Self.maxForgotten)
            forgotten.subtract(evicted)
            forgottenOrder.removeFirst(evicted.count)
        }
    }

    /// Whether the store keeps anything for `terminalID` beyond `forget`'s
    /// tombstone. Tests only.
    func keepsState(for terminalID: UUID) -> Bool {
        held[terminalID] != nil
            || revisions[terminalID] != nil
            || dropGenerations[terminalID] != nil
            || droppedAt[terminalID] != nil
            || endedIncarnations[terminalID] != nil
            || written[terminalID] != nil
            || columnGenerations[terminalID] != nil
            || parkedBacklog[terminalID] != nil
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

    private func recordEnded(_ incarnationID: UUID?, terminalID: UUID) {
        var ended = endedIncarnations[terminalID] ?? []
        ended.removeAll { $0 == incarnationID }
        ended.append(incarnationID)
        if ended.count > Self.maxEndedIncarnations {
            ended.removeFirst(ended.count - Self.maxEndedIncarnations)
        }
        endedIncarnations[terminalID] = ended
    }

    private func holdUntilWake(_ inbound: Inbound) {
        var backlog = parkedBacklog[inbound.terminalID] ?? []
        backlog.append(inbound)
        if backlog.count > Self.maxParkedBacklog {
            backlog.removeFirst(backlog.count - Self.maxParkedBacklog)
        }
        parkedBacklog[inbound.terminalID] = backlog
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
    ///   (a failed write is a refusal) and broadcasts the deltas the app
    ///   reads: `terminalActivityUpdated` when the state or its source changed,
    ///   `terminalAwaitingInputChanged` when the reason did. A cancelled scheduled
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
                        observedAt: write.observedAt, source: write.source)
                } catch {
                    programStatusLog.debug(
                        "column write failed terminal=\(write.terminalID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    return .refused
                }
                guard let applied else { return .refused }
                // The source is announced with the state: a write can change
                // only the source, and the app's no-status mark reads it.
                if applied.stateChanged || applied.sourceChanged {
                    subscriptions.broadcast(delta: .terminalActivityUpdated(TerminalActivityDelta(
                        terminalID: write.terminalID,
                        worktreeID: applied.worktreeID,
                        activityState: write.value.activityState,
                        activityStateSource: write.source,
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
                guard applied.changed else { return .unchanged }
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
