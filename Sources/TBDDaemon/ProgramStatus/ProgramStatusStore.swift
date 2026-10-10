import Foundation
import os
import TBDShared

private let programStatusLog = Logger(subsystem: "com.tbd.daemon", category: "programStatus")

/// Owns every Program Status Protocol (OSC 7501) report the daemon accepts:
/// per terminal, the main entry and up to 32 task entries.
///
/// Memory only. Nothing here is written to `state.db` — `title` and `msg` can
/// carry content from the user's work — and a daemon restart starts empty.
/// Reports drive display and resolution only; nothing here acts on a session.
///
/// Design: docs/specs/2026-10-10-program-status-protocol-design.md ("Trust",
/// "Liveness", "Rolling up task entries").
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
        case flagOff
        case incarnationChanged
    }

    /// Readable synchronously from the readers' parse threads.
    public nonisolated let gate: ProgramStatusGate
    public nonisolated let now: @Sendable () -> Date
    private let terminalLookup: @Sendable (UUID) async -> Terminal?
    private let publish: @Sendable (ProgramStatusSnapshot) -> Void
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

    public init(
        enabled: Bool,
        terminalLookup: @escaping @Sendable (UUID) async -> Terminal?,
        publish: @escaping @Sendable (ProgramStatusSnapshot) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gate = ProgramStatusGate(enabled: enabled)
        self.now = now
        self.terminalLookup = terminalLookup
        self.publish = publish
        let made = AsyncStream.makeStream(
            of: Inbound.self, bufferingPolicy: .bufferingNewest(4096))
        self.inbox = made.stream
        self.inboxContinuation = made.continuation
    }

    /// The production store: terminals from `db`, snapshots broadcast as
    /// `.terminalProgramStatusChanged`.
    public static func live(
        db: TBDDatabase,
        subscriptions: StateSubscriptionManager,
        enabled: Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> ProgramStatusStore {
        ProgramStatusStore(
            enabled: enabled,
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

        // 1. Flag.
        guard gate.isEnabled else { return reject(terminalID, "flag off") }

        // 2. Parse.
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

        // 3. App.
        guard report.app == ProgramStatusProtocol.expectedApp else {
            return reject(terminalID, "app is not \(ProgramStatusProtocol.expectedApp)")
        }

        // A report observed at or before the terminal's latest drop belongs
        // to the session that drop ended.
        if let watermark = droppedAt[terminalID], inbound.observedAt <= watermark {
            return reject(terminalID, "observed before drop")
        }

        // 4. A live holder session whose recorded agent is Claude.
        let generationBeforeLookup = dropGenerations[terminalID] ?? 0
        guard let terminal = await terminalLookup(terminalID) else {
            return reject(terminalID, "unknown terminal")
        }
        guard terminal.transport == .holder else { return reject(terminalID, "not a holder session") }
        guard !terminal.isParked else { return reject(terminalID, "terminal is parked") }
        let isClaude = terminal.kind == .claude || (terminal.kind == nil && !terminal.isCodexTerminal)
        guard isClaude else { return reject(terminalID, "not a Claude session") }

        // 5. Incarnation.
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

        // The flag may have been turned off while the lookup was suspended.
        guard gate.isEnabled else { return reject(terminalID, "flag off") }
        // A drop that ran while the lookup was suspended found nothing to
        // drop; applying now would hold an entry nothing ever clears.
        guard (dropGenerations[terminalID] ?? 0) == generationBeforeLookup else {
            return reject(terminalID, "dropped during lookup")
        }

        // 6. Re-read state after the await (actor reentrancy).
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

        // 7. Apply.
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
    /// For an end that is unconditional: the child exited, the row parked, or
    /// the flag went off.
    public func drop(terminalID: UUID, reason: DropReason) {
        dropGenerations[terminalID] = (dropGenerations[terminalID] ?? 0) + 1
        droppedAt[terminalID] = now()
        removeHeld(terminalID: terminalID, reason: reason)
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

    /// Set the gate. Turning it off drops every terminal's entries.
    public func setEnabled(_ enabled: Bool) {
        gate.set(enabled)
        guard !enabled else { return }
        let terminalIDs: [UUID] = Array(held.keys)
        for terminalID in terminalIDs {
            drop(terminalID: terminalID, reason: .flagOff)
        }
    }

    // MARK: - Private

    private func removeHeld(terminalID: UUID, reason: DropReason) {
        guard let removed = held.removeValue(forKey: terminalID) else { return }
        programStatusLog.debug(
            "drop terminal=\(terminalID.uuidString, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        publishEmpty(terminalID: terminalID, incarnationID: removed.incarnationID)
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
