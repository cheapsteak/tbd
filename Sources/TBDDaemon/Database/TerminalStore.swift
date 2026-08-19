import Foundation
import GRDB
import os
import TBDShared

private let decodeLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

/// GRDB Record type for the `terminal` table.
struct TerminalRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "terminal"

    var id: String
    var worktreeID: String
    var tmuxWindowID: String
    var tmuxPaneID: String
    var label: String?
    var createdAt: Date
    var pinnedAt: Date?
    var claudeSessionID: String?
    var suspendedAt: Date?
    var suspendedSnapshot: String?
    var profile_id: String?
    var transcriptPath: String?
    var kind: String?
    var activityState: String?
    var hibernatedAt: Date?
    var hibernateReason: String?
    var keepWarm: Bool?
    var pendingResumeAt: Date?
    var watch_desk_role: String?
    /// JSON-encoded `FactSource` — where `activityState` came from. nil on rows
    /// written before v70 and on any row stamped without provenance.
    var activityStateSource: String?
    var activityStateObservedAt: Date?
    var activityStateOrderObservedAt: Date?
    /// JSON-encoded `AwaitingInputReason`, carried verbatim from the
    /// `Notification` hook. nil when the session is not waiting, or when the
    /// wait carried no structured reason.
    var awaitingInputReason: String?
    var awaitingInputObservedAt: Date?

    init(from terminal: Terminal) {
        self.id = terminal.id.uuidString
        self.worktreeID = terminal.worktreeID.uuidString
        self.tmuxWindowID = terminal.tmuxWindowID
        self.tmuxPaneID = terminal.tmuxPaneID
        self.label = terminal.label
        self.createdAt = terminal.createdAt
        self.pinnedAt = terminal.pinnedAt
        self.claudeSessionID = terminal.claudeSessionID
        self.suspendedAt = terminal.suspendedAt
        self.suspendedSnapshot = terminal.suspendedSnapshot
        self.profile_id = terminal.profileID?.uuidString
        self.transcriptPath = terminal.transcriptPath
        self.kind = terminal.kind?.rawValue
        self.activityState = terminal.activityState.rawValue
        self.hibernatedAt = terminal.hibernatedAt
        self.hibernateReason = terminal.hibernateReason?.rawValue
        self.keepWarm = terminal.keepWarm
        self.pendingResumeAt = terminal.pendingResumeAt
        self.watch_desk_role = terminal.watchDeskRole?.rawValue
        self.activityStateSource = FactColumnJSON.encode(terminal.activityStateSource)
        self.activityStateObservedAt = terminal.activityStateObservedAt
        self.activityStateOrderObservedAt = terminal.activityStateOrderObservedAt
        self.awaitingInputReason = FactColumnJSON.encode(terminal.awaitingInputReason)
        self.awaitingInputObservedAt = terminal.awaitingInputObservedAt
    }

    /// Failable decode: skips (returns nil after a logged warning) rather than
    /// crashing when a required UUID fails to parse. Optional/enum columns
    /// (`profile_id`, `kind`, `activityState`) already decode safely.
    func toModel() -> Terminal? {
        guard let uuid = UUID(uuidString: id) else {
            decodeLogger.warning("Skipping terminal row \(id, privacy: .public): malformed id")
            return nil
        }
        guard let wtID = UUID(uuidString: worktreeID) else {
            decodeLogger.warning("Skipping terminal row \(id, privacy: .public): malformed worktreeID \(worktreeID, privacy: .public)")
            return nil
        }
        return Terminal(
            id: uuid,
            worktreeID: wtID,
            tmuxWindowID: tmuxWindowID,
            tmuxPaneID: tmuxPaneID,
            label: label,
            createdAt: createdAt,
            pinnedAt: pinnedAt,
            claudeSessionID: claudeSessionID,
            suspendedAt: suspendedAt,
            suspendedSnapshot: suspendedSnapshot,
            profileID: profile_id.flatMap(UUID.init(uuidString:)),
            transcriptPath: transcriptPath,
            kind: kind.flatMap(TerminalKind.init(rawValue:)),
            activityState: activityState.flatMap(TerminalActivityState.init(rawValue:)) ?? .unknown,
            hibernatedAt: hibernatedAt,
            hibernateReason: hibernateReason.flatMap(HibernateReason.init(rawValue:)),
            keepWarm: keepWarm ?? false,
            pendingResumeAt: pendingResumeAt,
            watchDeskRole: watch_desk_role.map {
                WatchDeskRole(rawValue: $0) ?? .readOnlyCoordinator
            },
            activityStateSource: FactColumnJSON.decode(FactSource.self, from: activityStateSource),
            activityStateObservedAt: activityStateObservedAt,
            activityStateOrderObservedAt: activityStateOrderObservedAt,
            awaitingInputReason: FactColumnJSON.decode(AwaitingInputReason.self, from: awaitingInputReason),
            awaitingInputObservedAt: awaitingInputObservedAt
        )
    }
}

/// JSON codec for the state-model blobs that ride in TEXT columns.
///
/// Failure is silent and produces nil on both sides, matching `prStatus`'s
/// existing `try?` treatment: an unreadable provenance blob must degrade to
/// "no provenance recorded" — which `Terminal.observedActivity` already reads
/// as no fact — rather than take the whole row's decode with it.
enum FactColumnJSON {
    static func encode<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

public struct AppliedTerminalActivityObservation: Sendable {
    public let activityState: TerminalActivityState
    public let source: FactSource
    public let observedAt: Date
    public let orderObservedAt: Date
}

struct AppliedTerminalSessionStart: Sendable {
    let sessionID: String
    let transcriptPath: String?
    let orderObservedAt: Date
    let activityObservation: AppliedTerminalActivityObservation?
}

private func preservesStoredActivityAtEqualOrder(
    storedState: TerminalActivityState,
    storedSource: FactSource?,
    incomingState: TerminalActivityState,
    incomingSource: FactSource
) -> Bool {
    if incomingSource == .terminalInterrupt { return false }
    if storedSource == .terminalInterrupt { return true }
    if storedState == .waitingForUser, incomingState != .waitingForUser { return true }
    return storedState != .working && incomingState == .working
}

private func clearAwaitingInputIfNotNewer(
    record: inout TerminalRecord,
    than observedAt: Date
) {
    guard record.awaitingInputObservedAt.map({ $0 >= observedAt }) != true else { return }
    record.awaitingInputReason = nil
    record.awaitingInputObservedAt = nil
}

private func applyActivityObservationToRecord(
    to record: inout TerminalRecord,
    activityState: TerminalActivityState,
    source: FactSource,
    observedAt: Date,
    replaceSameValue: Bool
) -> AppliedTerminalActivityObservation? {
    let storedOrderObservedAt = record.activityStateOrderObservedAt
        ?? record.activityStateObservedAt
    if let storedOrderObservedAt, storedOrderObservedAt > observedAt {
        return nil
    }
    let storedSource = FactColumnJSON.decode(
        FactSource.self, from: record.activityStateSource)
    let storedState = record.activityState.flatMap(TerminalActivityState.init(rawValue:))
        ?? .unknown
    if storedOrderObservedAt == observedAt,
       preservesStoredActivityAtEqualOrder(
           storedState: storedState,
           storedSource: storedSource,
           incomingState: activityState,
           incomingSource: source) {
        return nil
    }

    let sameCompleteFact = record.activityState == activityState.rawValue
        && storedSource != nil
        && record.activityStateObservedAt != nil
        && !replaceSameValue
    if sameCompleteFact,
       let storedSource,
       let storedObservedAt = record.activityStateObservedAt {
        record.activityStateOrderObservedAt = observedAt
        clearAwaitingInputIfNotNewer(record: &record, than: observedAt)
        return AppliedTerminalActivityObservation(
            activityState: activityState,
            source: storedSource,
            observedAt: storedObservedAt,
            orderObservedAt: observedAt
        )
    }

    record.activityState = activityState.rawValue
    record.activityStateSource = FactColumnJSON.encode(source)
    record.activityStateObservedAt = observedAt
    record.activityStateOrderObservedAt = observedAt
    clearAwaitingInputIfNotNewer(record: &record, than: observedAt)
    return AppliedTerminalActivityObservation(
        activityState: activityState,
        source: source,
        observedAt: observedAt,
        orderObservedAt: observedAt
    )
}

/// Provides CRUD operations for terminals.
public struct TerminalStore: Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Create a new terminal record.
    ///
    /// `id` is optional. Callers that need to know the terminal ID *before*
    /// the tmux window is spawned (so it can be injected as `TBD_TERMINAL_ID`
    /// in the spawned env, used by the SessionStart hook bridge) can pre-mint
    /// a UUID and pass it here. Defaults to a fresh UUID otherwise.
    ///
    /// Refuses (throws) when the parent worktree row is a PROMOTED scratch
    /// row (archived + `promotedToRepoID`) — re-validated inside the same
    /// write transaction as the insert, so a concurrent `scratch.promote`
    /// (which retires the row atomically with its terminal migration) can
    /// never race a new terminal row onto it. Such an orphan row would
    /// parent a live session to a retired worktree whose sessions moved —
    /// the SessionStart-hook foreign-session class. Plain archived rows are
    /// NOT rejected here: the revive flow legitimately spawns terminals
    /// while the row is still `.archived` (it flips `.active`/`.creating`
    /// only after the spawn succeeds, for crash consistency); the RPC
    /// handler rejects user-driven creates on archived rows before spawn.
    /// Promoted rows have no such flow — they are never revived.
    ///
    /// `watchDeskRole` is stamped here so that "this row was spawned as a Watch
    /// Desk session" is durable from the row's first instant rather than only
    /// from whenever a judge lease is first acquired. The wake path reads it to
    /// decide whether to reinstall the statusline tee, and a desk that has
    /// never held a lease is still a desk. The lease store keeps maintaining
    /// the column afterwards — this is the same mechanism, given a starting
    /// value, not a second one.
    public func create(
        id: UUID = UUID(),
        worktreeID: UUID,
        tmuxWindowID: String,
        tmuxPaneID: String,
        label: String? = nil,
        claudeSessionID: String? = nil,
        profileID: UUID? = nil,
        kind: TerminalKind? = nil,
        watchDeskRole: WatchDeskRole? = nil
    ) async throws -> Terminal {
        let terminal = Terminal(
            id: id,
            worktreeID: worktreeID,
            tmuxWindowID: tmuxWindowID,
            tmuxPaneID: tmuxPaneID,
            label: label,
            claudeSessionID: claudeSessionID,
            profileID: profileID,
            kind: kind,
            watchDeskRole: watchDeskRole
        )
        let record = TerminalRecord(from: terminal)
        try await writer.write { db in
            if let worktree = try WorktreeRecord.fetchOne(db, key: worktreeID.uuidString),
               worktree.status == WorktreeStatus.archived.rawValue,
               worktree.promotedToRepoID != nil {
                throw DatabaseError(message: "Worktree \(worktreeID) was promoted to a repo; create the terminal on that repo's main worktree instead")
            }
            try record.insert(db)
        }
        return terminal
    }

    /// List terminals, optionally filtered by worktree.
    public func list(worktreeID: UUID? = nil) async throws -> [Terminal] {
        try await writer.read { db in
            var request = TerminalRecord.all()
            if let worktreeID {
                request = request.filter(Column("worktreeID") == worktreeID.uuidString)
            }
            request = request.order(Column("createdAt").asc, Column("id").asc)
            return try request.fetchAll(db).compactMap { $0.toModel() }
        }
    }

    /// Get a terminal by ID.
    public func get(id: UUID) async throws -> Terminal? {
        try await writer.read { db in
            try TerminalRecord.fetchOne(db, key: id.uuidString)?.toModel()
        }
    }

    /// Delete a terminal by ID.
    public func delete(id: UUID) async throws {
        _ = try await writer.write { db in
            try TerminalRecord.deleteOne(db, key: id.uuidString)
        }
    }

    /// Delete all terminals for a worktree.
    public func deleteForWorktree(worktreeID: UUID) async throws {
        _ = try await writer.write { db in
            try TerminalRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .deleteAll(db)
        }
    }

    /// Set or clear the pinned timestamp for a terminal.
    public func setPin(id: UUID, pinned: Bool, at date: Date = Date()) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.pinnedAt = pinned ? date : nil
            try record.update(db)
        }
    }

    /// Mark a terminal as suspended, recording the session ID, snapshot, and current timestamp.
    public func setSuspended(id: UUID, sessionID: String, snapshot: String? = nil, at date: Date = Date()) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = sessionID
            record.suspendedAt = date
            record.suspendedSnapshot = snapshot
            try record.update(db)
        }
    }

    /// Clear the suspended state of a terminal. Keeps the snapshot so the
    /// app can feed it into TerminalPanelView as initial content while the
    /// tmux client connects. The snapshot is overwritten on the next suspend.
    public func clearSuspended(id: UUID) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.suspendedAt = nil
            try record.update(db)
        }
    }

    /// Update the Claude session ID for a terminal.
    public func updateSessionID(id: UUID, sessionID: String) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = sessionID
            try record.update(db)
        }
    }

    /// Update the Claude session ID and the absolute JSONL transcript path for
    /// a terminal in one write. Direct lifecycle callers use this when they do
    /// not have a SessionStart observation to order; the hook bridge uses
    /// `applySessionStart` below.
    public func updateSession(id: UUID, sessionID: String, transcriptPath: String?) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = sessionID
            // Only overwrite when the caller supplied a path. A SessionStart
            // payload that omits `transcript_path` (theoretical — Claude
            // currently always sends it) shouldn't clobber a previously
            // captured path; the existing value still points at the right
            // file as long as sessionID matches.
            if let transcriptPath = transcriptPath {
                record.transcriptPath = transcriptPath
            }
            try record.update(db)
        }
    }

    /// Apply a SessionStart as one ordered database fact. Session identity,
    /// prompt retraction, the shared event-order watermark, and Codex's idle
    /// transition either all advance together or none do.
    ///
    /// A prompt at the same timestamp wins the tie, matching
    /// `SessionStateResolver`: SessionStart cannot prove whether that more
    /// specific wait was raised before or after it. SessionStart itself is
    /// first-wins at an equal activity watermark: a differently-identified
    /// event cannot roll identity backward, while an exact retry is an
    /// idempotent no-op and therefore cannot move a transcript boundary.
    /// Claude does not assert an activity value here, but still advances the
    /// ordering watermark so an older activity or SessionStart cannot finish
    /// late and roll the row back.
    func applySessionStart(
        id: UUID,
        sessionID: String,
        transcriptPath: String?,
        observedAt: Date
    ) async throws -> AppliedTerminalSessionStart? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            if record.awaitingInputObservedAt.map({ $0 >= observedAt }) == true {
                return nil
            }
            let storedOrderObservedAt = record.activityStateOrderObservedAt
                ?? record.activityStateObservedAt
            if storedOrderObservedAt == observedAt {
                return nil
            }

            let isCodex = record.kind == TerminalKind.codex.rawValue
                || record.label == TerminalLabel.codex
            let activityObservation: AppliedTerminalActivityObservation?
            if isCodex {
                guard let applied = applyActivityObservationToRecord(
                    to: &record,
                    activityState: .idle,
                    source: .hookEvent("SessionStart"),
                    observedAt: observedAt,
                    replaceSameValue: true
                ) else { return nil }
                activityObservation = applied
            } else {
                if let storedOrderObservedAt, storedOrderObservedAt > observedAt {
                    return nil
                }
                record.activityStateOrderObservedAt = observedAt
                clearAwaitingInputIfNotNewer(record: &record, than: observedAt)
                activityObservation = nil
            }

            record.claudeSessionID = sessionID
            if let transcriptPath {
                record.transcriptPath = transcriptPath
            }
            // The activity helper already performs this for Codex. Keep the
            // call here so Claude and any future non-Codex agent share the
            // same strict-older prompt retraction rule.
            clearAwaitingInputIfNotNewer(record: &record, than: observedAt)
            try record.update(db)
            return AppliedTerminalSessionStart(
                sessionID: sessionID,
                transcriptPath: record.transcriptPath,
                orderObservedAt: observedAt,
                activityObservation: activityObservation)
        }
    }

    /// Clear Claude-specific metadata after window recreation.
    /// The recreated window runs a plain shell, not Claude.
    ///
    /// Takes `at` because it also writes an activity state, and every activity
    /// state carries provenance: this one is `.derived`, composed from TBD's
    /// own act of recreating the window, observed as that act completed.
    public func clearRecreated(id: UUID, at date: Date = Date()) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = nil
            record.transcriptPath = nil
            record.suspendedAt = nil
            record.suspendedSnapshot = nil
            record.hibernatedAt = nil
            record.hibernateReason = nil
            record.label = TerminalLabel.shell
            record.kind = TerminalKind.shell.rawValue
            record.activityState = TerminalActivityState.unknown.rawValue
            record.activityStateSource = FactColumnJSON.encode(FactSource.derived)
            record.activityStateObservedAt = date
            record.activityStateOrderObservedAt = date
            record.awaitingInputReason = nil
            record.awaitingInputObservedAt = nil
            try record.update(db)
        }
    }

    /// Set or clear the model profile ID for a terminal.
    public func setProfileID(id: UUID, profileID: UUID?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE terminal SET profile_id = ? WHERE id = ?",
                arguments: [profileID?.uuidString, id.uuidString]
            )
        }
    }

    /// Update the tmux window and pane IDs for a terminal.
    public func updateTmuxIDs(id: UUID, windowID: String, paneID: String) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.tmuxWindowID = windowID
            record.tmuxPaneID = paneID
            try record.update(db)
        }
    }

    /// Record an observation of a terminal's activity state.
    ///
    /// `source` has no default, and that is the whole point of the signature:
    /// there is no way to write an activity state without saying where it came
    /// from, so a value with no provenance cannot enter the database at all.
    /// `observedAt` follows the one-shot stamp seam (`at date: Date = Date()`
    /// in CLAUDE.md's date-seam rule) — it is *data*, the moment the machine
    /// fact was read, which callers that read earlier than they write must
    /// pass explicitly.
    ///
    /// `awaitingInputReason` rides with the observation rather than in a writer
    /// of its own, because a wait reason belongs to one state observation and
    /// is superseded by the next: passing nil (the default) clears any previous
    /// reason, so the stored reason always describes the state stored beside
    /// it, never a wait that has since ended.
    public func setActivityState(
        id: UUID,
        activityState: TerminalActivityState,
        source: FactSource,
        observedAt: Date = Date(),
        awaitingInputReason: AwaitingInputReason? = nil
    ) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.activityState = activityState.rawValue
            record.activityStateSource = FactColumnJSON.encode(source)
            record.activityStateObservedAt = observedAt
            record.activityStateOrderObservedAt = observedAt
            // Unconditional, including the nil case: this IS the superseding
            // rail. A caller that observes a new activity state without naming
            // a reason clears the old one, so a "needs your permission"
            // recorded by a `Notification` hook cannot outlive the prompt it
            // described. Making this write conditional on a non-nil reason
            // would leave stale waits pinned to the row forever.
            record.awaitingInputReason = FactColumnJSON.encode(awaitingInputReason)
            record.awaitingInputObservedAt = awaitingInputReason == nil ? nil : observedAt
            try record.update(db)
        }
    }

    /// Apply an externally observed activity fact only when it is not older
    /// than the ordering watermark already stored for the terminal.
    ///
    /// The ordering comparison and write share one database-writer
    /// transaction. Callers may therefore do
    /// arbitrary asynchronous work between observing an event and reaching
    /// this method without allowing that older event to roll back a newer one.
    ///
    /// A repeated generic value advances only the ordering watermark and clears
    /// an awaiting-input reason strictly older than itself. Its semantic transition
    /// timestamp and source remain unchanged, which both preserves
    /// hibernation's at-rest clock and prevents an idle echo from erasing an
    /// explicit interrupt.
    /// Events that establish meaningful same-value provenance (currently a user
    /// interrupt and SessionStart) opt into replacement. Exact timestamp ties
    /// cannot establish event order, so explicit interrupts and permission
    /// waits are preserved, while ambiguous working/non-working ties resolve
    /// toward non-working; the next strictly newer hook advances order.
    public func applyActivityObservation(
        id: UUID,
        activityState: TerminalActivityState,
        source: FactSource,
        observedAt: Date,
        replaceSameValue: Bool = false
    ) async throws -> AppliedTerminalActivityObservation? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard let application = applyActivityObservationToRecord(
                to: &record,
                activityState: activityState,
                source: source,
                observedAt: observedAt,
                replaceSameValue: replaceSameValue
            ) else { return nil }
            try record.update(db)
            return application
        }
    }

    /// Record a wait reason observed by a hook, WITHOUT asserting an activity
    /// state.
    ///
    /// `setActivityState` writes a reason alongside a state it is also
    /// asserting; this writer exists for the one source that can report a
    /// reason it is not entitled to turn into a state. Claude Code's
    /// `Notification` hook says a prompt was raised — it does not say the
    /// session is still sitting on it, and `activityState` is a *gating* field:
    /// `HibernationGate.blockingRail` reads it, so writing `waiting_for_user`
    /// here would change which sessions park, from a hook whose only job is to
    /// report. So the two activity columns are left exactly as they were, and
    /// the recorded reason is composed into a session state downstream instead.
    ///
    /// The superseding rail is unchanged and is what keeps this honest: the
    /// next `setActivityState` observation clears both columns (its
    /// `awaitingInputReason` defaults to nil), so a reason recorded here cannot
    /// outlive the wait it described.
    ///
    /// `observedAt` is the moment the hook reported, following the one-shot
    /// stamp seam — it is data, not behavior.
    ///
    /// **A write from a class that establishes no state cannot clear a standing
    /// `promptOnScreen`.** The hook overlay registers `Notification` with no
    /// matcher, so every type arrives here — including the ones that fire while
    /// a permission prompt is up. A subagent finishing sends `agent_completed`
    /// (`.informational`); an unconditional overwrite would replace the live
    /// prompt with it, and the session would read as un-blocked while a human is
    /// still being waited on. `.informational` and `.unrecognized` say nothing
    /// about whether a prompt went away, so they are recorded only when no
    /// `promptOnScreen` reason is standing. `.promptOnScreen` and `.doneWaiting`
    /// write unconditionally: the first is a newer prompt, the second is the
    /// agent reporting it is back at its own prompt.
    ///
    /// The *activity* rail is untouched by this and keeps superseding as it
    /// always has: `setActivityState` clears both columns, so a genuine
    /// observation of the session moving on still retracts the reason. This
    /// guard only refuses to let a report that observed nothing do it.
    public func recordAwaitingInputReason(
        id: UUID,
        reason: AwaitingInputReason,
        observedAt: Date
    ) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            let establishesNothing = reason.classification == .informational
                || reason.classification == .unrecognized
            if establishesNothing,
               let standing = FactColumnJSON.decode(
                    AwaitingInputReason.self, from: record.awaitingInputReason),
               standing.classification == .promptOnScreen {
                return
            }
            record.awaitingInputReason = FactColumnJSON.encode(reason)
            record.awaitingInputObservedAt = observedAt
            try record.update(db)
        }
    }

    /// Retract a standing wait reason WITHOUT asserting an activity state.
    ///
    /// The mirror of `recordAwaitingInputReason`, and it exists for the same
    /// reason: a caller can be entitled to say a recorded prompt is gone
    /// without being entitled to say what the session is doing instead. The two
    /// callers are both TBD's own knowledge that the process the prompt was
    /// raised on has been replaced — the in-place profile swap, which kills the
    /// pane's agent itself, and the SessionStart bridge, where Claude Code
    /// reports a new session context (a `/clear`, a resume, a hand relaunch).
    /// Neither knows what the new process is doing, so `activityState` and its
    /// provenance are left exactly as they were; writing one here would move a
    /// field `HibernationGate.blockingRail` gates on, from a step that observed
    /// no turn boundary.
    ///
    /// The activity rail is **not** a sufficient retraction on its own here,
    /// which is why this writer is not just a `setActivityState` call.
    /// `handleTerminalActivityEvent` returns early when the state is unchanged,
    /// so the SessionStart overlay's own `tbd terminal-activity idle` clears
    /// nothing when the row already reads idle — and it is a second, separate,
    /// best-effort CLI invocation that a stale `tbd` on `PATH` can lose while
    /// the first one lands.
    ///
    /// Idempotent: clearing columns that are already nil is a no-op write.
    public func clearAwaitingInputReason(id: UUID) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.awaitingInputReason = nil
            record.awaitingInputObservedAt = nil
            try record.update(db)
        }
    }

    /// Mark a terminal hibernated (claude process killed, tmux window kept
    /// alive), recording the wake session ID and timestamp. `sessionID` is the
    /// session to `claude --resume` on wake.
    ///
    /// `hibernatedAt` is the authoritative parked timestamp (post suspend/hibernate
    /// merge). The optional `snapshot` is the ANSI pane capture taken just before
    /// the kill, persisted into the legacy `suspendedSnapshot` column (reused,
    /// orthogonal to which timestamp wins) so the app can show the frozen pane as
    /// the backdrop while the session is parked / waking. Pass `nil` to leave any
    /// existing snapshot untouched.
    ///
    /// `reason` records WHO parked the session (idle sweep / manual action /
    /// crash-recovery reconcile) — see `HibernateReason`. It is stamped
    /// unconditionally (a re-park overwrites any stale reason); `nil` keeps
    /// legacy semantics (the row is still eligible for wake-on-focus).
    ///
    /// This is the choke point EVERY park site flows through
    /// (`HibernationCoordinator.performHibernate`, the reconcile recovery park,
    /// and `handleTerminalRecreateWindow`'s dead-window park), so it also
    /// cancels any scheduled auto-resume in the same write transaction: a
    /// parked session's Claude process is dead — a resume firing later would
    /// type "continue" into a bare shell — and `pendingResumeAt` must not
    /// keep advertising a resume that will never happen. Wake
    /// (`clearHibernated`) deliberately does NOT resurrect the cancelled row.
    public func setHibernated(id: UUID, sessionID: String, snapshot: String? = nil, reason: HibernateReason? = nil, at date: Date = Date()) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = sessionID
            record.hibernatedAt = date
            record.hibernateReason = reason?.rawValue
            if let snapshot {
                record.suspendedSnapshot = snapshot
            }
            record.activityState = TerminalActivityState.idle.rawValue
            // A parked session is idle because TBD's own record says it is
            // parked — `.database`, observed at the moment of the park. A
            // parked session is also waiting for nothing, so any carried
            // awaiting-input reason is cleared with it.
            record.activityStateSource = FactColumnJSON.encode(FactSource.database)
            record.activityStateObservedAt = date
            record.activityStateOrderObservedAt = date
            record.awaitingInputReason = nil
            record.awaitingInputObservedAt = nil
            try record.update(db)
            // AFTER record.update: the routine nils pendingResumeAt via raw
            // SQL, and an update of the (stale-fetched) record afterward
            // would write the old value back.
            try ScheduledResumeStore.cancelPendingInTransaction(db, terminalID: id.uuidString)
        }
    }

    /// Clear a terminal's parked state (on wake). Nils BOTH the authoritative
    /// `hibernatedAt` AND the legacy `suspendedAt` so a row parked by either the
    /// unified path or the pre-merge Suspend feature fully un-parks. Leaves
    /// `claudeSessionID` intact — the wake respawn re-captures a fresh id
    /// afterward — and keeps `suspendedSnapshot` so the app can feed it into the
    /// terminal view as initial content while the live tmux client reconnects
    /// (matches the old Suspend behavior; overwritten on the next park).
    public func clearHibernated(id: UUID) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.hibernatedAt = nil
            record.suspendedAt = nil
            record.hibernateReason = nil
            try record.update(db)
        }
    }

    /// Set or clear a terminal's keep-warm pin (exempts it from
    /// auto-hibernation).
    public func setKeepWarm(id: UUID, keepWarm: Bool) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.keepWarm = keepWarm
            try record.update(db)
        }
    }
}
