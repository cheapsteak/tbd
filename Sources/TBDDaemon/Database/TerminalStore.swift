import Foundation
import GRDB
import os
import TBDShared

private let decodeLogger = Logger(subsystem: "com.tbd.daemon", category: "database.decode")

/// GRDB Record type for the `terminal` table. The unused
/// `transcript_stream_path` column is not named here; GRDB ignores it.
struct TerminalRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "terminal"

    static func databaseDateEncodingStrategy(
        for column: String
    ) -> DatabaseDateEncodingStrategy {
        if column == "sessionOrderObservedAt" {
            // Numeric epoch storage preserves distinct starts within one
            // millisecond. GRDB's default decoder accepts both this numeric
            // representation and legacy datetime text rows.
            return .timeIntervalSince1970
        }
        return .deferredToDate
    }

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
    var sessionOrderObservedAt: Date?
    var codexTranscriptBoundaryOffset: Int64?
    var sessionIncarnationID: String?
    var pendingSessionIncarnationID: String?
    var kind: String?
    var activityState: String?
    var hibernatedAt: Date?
    var hibernateReason: String?
    var keepWarm: Bool?
    var pendingResumeAt: Date?
    /// JSON-encoded `FactSource` — where `activityState` came from. nil on rows
    /// written before v70 and on any row stamped without provenance.
    var activityStateSource: String?
    var activityStateObservedAt: Date?
    var activityStateOrderObservedAt: Date?
    /// JSON-encoded `AwaitingInputReason`: the block the agent reported over
    /// OSC 7501, written by `applyProgramStatusActivity` with no message text.
    /// nil when the session is not waiting.
    var awaitingInputReason: String?
    var awaitingInputObservedAt: Date?
    /// `TerminalTransport` raw value. NULL on every row written before
    /// `20260831055719_terminal_transport`, which is what `.tmux` means; an
    /// unrecognized value from a newer daemon degrades the same way rather than
    /// failing the decode.
    var transport: String?
    /// PID of the `TBDHolder` process, for holder-transport rows only.
    var holder_pid: Int32?
    /// PID of the job the holder `forkpty()`d, for holder-transport rows only.
    var child_pid: Int32?
    /// When the job named by `child_pid` was started. NULL on a row that has
    /// never been through a park/wake cycle, where `createdAt` is still the
    /// right identity anchor — see `Terminal.holderChildStartedAt`.
    var holder_child_started_at: Date?

    /// The declared dev server this tab runs — see `Terminal.serverName`.
    var server_name: String?

    /// Why the last automatic wake was held, and when — see
    /// `Terminal.startHeldReason`. Both NULL on a row no hold has touched.
    var start_held_reason: String?
    var start_held_at: Date?

    /// JSON-encoded `ClaudeSpawnExtras` — see `Terminal.claudeSpawnExtras`.
    /// NULL when nothing was passed and on rows written before the column.
    var claude_spawn_extras: String?

    /// JSON-encoded `CodexLaunchOptions` — see `Terminal.codexLaunchOptions`.
    var codex_launch_options: String?

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
        self.sessionOrderObservedAt = terminal.sessionOrderObservedAt
        self.codexTranscriptBoundaryOffset = terminal.codexTranscriptBoundaryOffset
        self.sessionIncarnationID = terminal.sessionIncarnationID?.uuidString
        self.pendingSessionIncarnationID = terminal.pendingSessionIncarnationID?.uuidString
        self.kind = terminal.kind?.rawValue
        self.activityState = terminal.activityState.rawValue
        self.hibernatedAt = terminal.hibernatedAt
        self.hibernateReason = terminal.hibernateReason?.rawValue
        self.keepWarm = terminal.keepWarm
        self.pendingResumeAt = terminal.pendingResumeAt
        self.activityStateSource = FactColumnJSON.encode(terminal.activityStateSource)
        self.activityStateObservedAt = terminal.activityStateObservedAt
        self.activityStateOrderObservedAt = terminal.activityStateOrderObservedAt
        self.awaitingInputReason = FactColumnJSON.encode(terminal.awaitingInputReason)
        self.awaitingInputObservedAt = terminal.awaitingInputObservedAt
        self.transport = terminal.transport.rawValue
        self.holder_pid = terminal.holderPID
        self.child_pid = terminal.childPID
        self.holder_child_started_at = terminal.holderChildStartedAt
        self.server_name = terminal.serverName
        self.start_held_reason = terminal.startHeldReason
        self.start_held_at = terminal.startHeldAt
        self.claude_spawn_extras = ClaudeSpawnExtrasColumn.encode(terminal.claudeSpawnExtras)
        self.codex_launch_options = FactColumnJSON.encode(terminal.codexLaunchOptions)
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
        var model = Terminal(
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
            sessionOrderObservedAt: sessionOrderObservedAt,
            codexTranscriptBoundaryOffset: codexTranscriptBoundaryOffset,
            sessionIncarnationID: sessionIncarnationID.flatMap(UUID.init(uuidString:)),
            pendingSessionIncarnationID: pendingSessionIncarnationID.flatMap(UUID.init(uuidString:)),
            kind: kind.flatMap(TerminalKind.init(rawValue:)),
            activityState: activityState.flatMap(TerminalActivityState.init(rawValue:)) ?? .unknown,
            hibernatedAt: hibernatedAt,
            hibernateReason: hibernateReason.flatMap(HibernateReason.init(rawValue:)),
            keepWarm: keepWarm ?? false,
            pendingResumeAt: pendingResumeAt,
            activityStateSource: FactColumnJSON.decode(FactSource.self, from: activityStateSource),
            activityStateObservedAt: activityStateObservedAt,
            activityStateOrderObservedAt: activityStateOrderObservedAt,
            awaitingInputReason: FactColumnJSON.decode(AwaitingInputReason.self, from: awaitingInputReason),
            awaitingInputObservedAt: awaitingInputObservedAt,
            // NULL (a row older than the column) and an unrecognized value from
            // a newer daemon both degrade to tmux rather than throwing.
            transport: transport.flatMap(TerminalTransport.init(rawValue:)) ?? .tmux,
            holderPID: holder_pid,
            childPID: child_pid,
            holderChildStartedAt: holder_child_started_at
        )
        model.serverName = server_name
        model.startHeldReason = start_held_reason
        model.startHeldAt = start_held_at
        model.claudeSpawnExtras = ClaudeSpawnExtrasColumn.decode(
            claude_spawn_extras, table: Self.databaseTableName, rowID: id)
        // An unreadable blob degrades to "no options recorded", so a relaunch
        // falls back to the default command rather than failing the row.
        model.codexLaunchOptions = FactColumnJSON.decode(
            CodexLaunchOptions.self, from: codex_launch_options)
        return model
    }
}

/// JSON codec for the state-model blobs that ride in TEXT columns.
///
/// Failure is silent and produces nil on both sides, matching `prStatus`'s
/// existing `try?` treatment: an unreadable provenance blob must degrade to
/// "no provenance recorded" — which `Terminal.observedActivity` already reads
/// as no fact — rather than take the whole row's decode with it.
/// A recorded `codex_launch_options` value that no longer decodes. A relaunch
/// refuses on it rather than guess whether it named a dedicated Codex home.
public struct UnreadableCodexLaunchOptions: Error, LocalizedError, CustomStringConvertible {
    public let terminalID: UUID
    public var description: String {
        "Terminal \(terminalID)'s recorded Codex launch options cannot be read, so Codex is not relaunched in it: they may name a dedicated Codex home."
    }
    public var errorDescription: String? { description }
}

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

    /// Compare a decoded fact with its persisted JSON representation. JSON
    /// object key order is not identity, while a malformed non-NULL value must
    /// not collapse into the same state as an absent fact.
    static func matches<T: Decodable & Equatable>(_ expected: T?, encoded json: String?) -> Bool {
        guard let json else { return expected == nil }
        guard let expected else { return false }
        return decode(T.self, from: json) == expected
    }
}

/// JSON codec for the three columns that hold `ClaudeSpawnExtras`:
/// `terminal.claude_spawn_extras`, `terminal_history.claudeSpawnExtras` (one
/// object each) and `worktree.archivedClaudeSpawnExtras` (a map from Claude
/// session id to an object).
///
/// NULL means nothing stored. A value that does not decode also reads as
/// nothing stored — a bad value must never block a start or drop the row —
/// but unlike `FactColumnJSON` it says so: a warning naming the table and row,
/// since losing these silently would quietly start a session without the
/// plugin folders its starter asked for.
enum ClaudeSpawnExtrasColumn {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "claude-overlay")

    static func encode(_ extras: ClaudeSpawnExtras?) -> String? {
        guard let extras else { return nil }
        return encodeJSON(extras)
    }

    /// An empty map stores NULL, so "no archived session carried any values"
    /// has the one spelling a pre-column row already has.
    static func encodeMap(_ map: [String: ClaudeSpawnExtras]?) -> String? {
        guard let map, !map.isEmpty else { return nil }
        return encodeJSON(map)
    }

    static func decode(_ json: String?, table: String, rowID: String) -> ClaudeSpawnExtras? {
        decodeJSON(ClaudeSpawnExtras.self, from: json, table: table, rowID: rowID)
    }

    static func decodeMap(_ json: String?, table: String, rowID: String) -> [String: ClaudeSpawnExtras]? {
        decodeJSON([String: ClaudeSpawnExtras].self, from: json, table: table, rowID: rowID)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return String(data: try encoder.encode(value), encoding: .utf8)
        } catch {
            logger.warning("Could not encode Claude spawn extras: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func decodeJSON<T: Decodable>(
        _ type: T.Type, from json: String?, table: String, rowID: String
    ) -> T? {
        guard let json else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            logger.warning("\(table, privacy: .public) row \(rowID, privacy: .public): stored Claude spawn extras do not decode, reading as none: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// What `applyProgramStatusActivity` did to an accepted row.
public struct ProgramStatusActivityWrite: Sendable, Equatable {
    /// The row's worktree, for the deltas and the banner.
    public let worktreeID: UUID
    /// The `activityState` the row held before this write.
    public let previousActivityState: TerminalActivityState
    /// Whether `activityState` took a new value.
    public let stateChanged: Bool
    /// Whether the stored wait reason took a new value (including a
    /// retraction to none).
    public let reasonChanged: Bool
    /// Whether `activityStateSource` took a new value. A write can change only
    /// this — a child exit's `.unknown` over a never-reported `.unknown` — and
    /// the app reads the source, so it is announced like a state change.
    public let sourceChanged: Bool
    /// Whether a `.working` write cancelled a pending scheduled resume.
    public let cancelledPendingResume: Bool

    /// Whether the write changed anything a reader of the columns sees.
    public var changed: Bool {
        Self.changesValue(
            stateChanged: stateChanged, reasonChanged: reasonChanged, sourceChanged: sourceChanged)
    }

    /// The one rule for what changes the columns' value: the state, the wait
    /// reason or the source. `applyProgramStatusActivity` decides by it whether
    /// to write, and `changed` reports it.
    static func changesValue(stateChanged: Bool, reasonChanged: Bool, sourceChanged: Bool) -> Bool {
        stateChanged || reasonChanged || sourceChanged
    }
}

struct AppliedTerminalSessionStart: Sendable {
    let sessionID: String
    let transcriptPath: String?
    let orderObservedAt: Date?
    let transcriptBoundaryOffset: Int64?
    let isInitialAttachment: Bool
}

struct ObservedTranscriptBoundary: Sendable {
    let path: String
    let eof: Int64
}

/// The durable process incarnation and launch-owned coordinates observed
/// before a SessionStart handler suspends. The nonce is authoritative across
/// tmux ABA reuse; coordinates and label remain additional rejection rails.
struct TerminalSessionIncarnation: Sendable {
    let tmuxWindowID: String
    let tmuxPaneID: String
    let label: String?
    let sessionIncarnationID: UUID?
    let pendingSessionIncarnationID: UUID?

    init(terminal: Terminal) {
        self.tmuxWindowID = terminal.tmuxWindowID
        self.tmuxPaneID = terminal.tmuxPaneID
        self.label = terminal.label
        self.sessionIncarnationID = terminal.sessionIncarnationID
        self.pendingSessionIncarnationID = terminal.pendingSessionIncarnationID
    }

    fileprivate init(record: TerminalRecord) {
        self.tmuxWindowID = record.tmuxWindowID
        self.tmuxPaneID = record.tmuxPaneID
        self.label = record.label
        self.sessionIncarnationID = record.sessionIncarnationID.flatMap(UUID.init(uuidString:))
        self.pendingSessionIncarnationID = record.pendingSessionIncarnationID.flatMap(
            UUID.init(uuidString:))
    }

    fileprivate func matches(_ record: TerminalRecord) -> Bool {
        record.tmuxWindowID == tmuxWindowID
            && record.tmuxPaneID == tmuxPaneID
            && record.label == label
            && record.sessionIncarnationID == sessionIncarnationID?.uuidString
            && record.pendingSessionIncarnationID == pendingSessionIncarnationID?.uuidString
    }

    func matches(_ terminal: Terminal) -> Bool {
        terminal.tmuxWindowID == tmuxWindowID
            && terminal.tmuxPaneID == tmuxPaneID
            && terminal.label == label
            && terminal.sessionIncarnationID == sessionIncarnationID
            && terminal.pendingSessionIncarnationID == pendingSessionIncarnationID
    }
}

/// The launch-relevant terminal state observed before an operation suspends.
/// Process replacement callers compare this inside the writer transaction so
/// a command prepared for one session/profile/park state cannot commit against
/// another. Activity facts are deliberately excluded: hooks from the same
/// process may advance them without changing which process a replacement owns.
struct TerminalReplacementSnapshot: Sendable {
    let incarnation: TerminalSessionIncarnation
    let worktreeID: UUID
    let kind: TerminalKind?
    let claudeSessionID: String?
    let transcriptPath: String?
    let profileID: UUID?
    let suspendedAt: Date?
    let hibernatedAt: Date?

    init(terminal: Terminal) {
        incarnation = TerminalSessionIncarnation(terminal: terminal)
        worktreeID = terminal.worktreeID
        kind = terminal.kind
        claudeSessionID = terminal.claudeSessionID
        transcriptPath = terminal.transcriptPath
        profileID = terminal.profileID
        suspendedAt = terminal.suspendedAt
        hibernatedAt = terminal.hibernatedAt
    }

    fileprivate func matches(_ record: TerminalRecord) -> Bool {
        incarnation.matches(record)
            && record.worktreeID == worktreeID.uuidString
            && record.kind == kind?.rawValue
            && record.claudeSessionID == claudeSessionID
            && record.transcriptPath == transcriptPath
            && record.profile_id == profileID?.uuidString
            && record.suspendedAt == suspendedAt
            && record.hibernatedAt == hibernatedAt
    }

    func matches(_ terminal: Terminal) -> Bool {
        incarnation.matches(terminal)
            && terminal.worktreeID == worktreeID
            && terminal.kind == kind
            && terminal.claudeSessionID == claudeSessionID
            && terminal.transcriptPath == transcriptPath
            && terminal.profileID == profileID
            && terminal.suspendedAt == suspendedAt
            && terminal.hibernatedAt == hibernatedAt
    }
}

/// The complete durable fact set that authorizes a Codex-to-Claude provider
/// replacement. General replacement snapshots deliberately ignore activity;
/// Continue proceeds only after its rollout read showed Codex idle, so its
/// CAS also includes the activity value, provenance, and both observation
/// watermarks: a change to any of them after that read rejects the replacement.
struct TerminalContinueInClaudeSnapshot: Sendable {
    let replacement: TerminalReplacementSnapshot
    let activityState: TerminalActivityState
    let activityStateSource: FactSource?
    let activityStateObservedAt: Date?
    let activityStateOrderObservedAt: Date?
    let awaitingInputReason: AwaitingInputReason?
    let awaitingInputObservedAt: Date?

    init(terminal: Terminal) {
        replacement = TerminalReplacementSnapshot(terminal: terminal)
        activityState = terminal.activityState
        activityStateSource = terminal.activityStateSource
        activityStateObservedAt = terminal.activityStateObservedAt
        activityStateOrderObservedAt = terminal.activityStateOrderObservedAt
        awaitingInputReason = terminal.awaitingInputReason
        awaitingInputObservedAt = terminal.awaitingInputObservedAt
    }

    fileprivate func matches(_ record: TerminalRecord) -> Bool {
        replacement.matches(record)
            && record.activityState == activityState.rawValue
            && FactColumnJSON.matches(
                activityStateSource, encoded: record.activityStateSource)
            && record.activityStateObservedAt == activityStateObservedAt
            && record.activityStateOrderObservedAt == activityStateOrderObservedAt
            && FactColumnJSON.matches(
                awaitingInputReason, encoded: record.awaitingInputReason)
            && record.awaitingInputObservedAt == awaitingInputObservedAt
    }

    func matches(_ terminal: Terminal) -> Bool {
        replacement.matches(terminal)
            && terminal.activityState == activityState
            && terminal.activityStateSource == activityStateSource
            && terminal.activityStateObservedAt == activityStateObservedAt
            && terminal.activityStateOrderObservedAt == activityStateOrderObservedAt
            && terminal.awaitingInputReason == awaitingInputReason
            && terminal.awaitingInputObservedAt == awaitingInputObservedAt
    }
}

/// The complete safety state that authorizes hibernating a live process.
/// Unlike general replacement snapshots, this includes the activity and
/// keep-warm rails so a hook or preference change between the final read and
/// the park transaction rejects without writing.
struct TerminalHibernationSnapshot: Sendable {
    let replacement: TerminalReplacementSnapshot
    let keepWarm: Bool
    let activityState: TerminalActivityState
    let activityStateSource: FactSource?
    let activityStateObservedAt: Date?
    let activityStateOrderObservedAt: Date?
    let awaitingInputReason: AwaitingInputReason?
    let awaitingInputObservedAt: Date?

    init(terminal: Terminal) {
        replacement = TerminalReplacementSnapshot(terminal: terminal)
        keepWarm = terminal.keepWarm
        activityState = terminal.activityState
        activityStateSource = terminal.activityStateSource
        activityStateObservedAt = terminal.activityStateObservedAt
        activityStateOrderObservedAt = terminal.activityStateOrderObservedAt
        awaitingInputReason = terminal.awaitingInputReason
        awaitingInputObservedAt = terminal.awaitingInputObservedAt
    }

    fileprivate func matches(_ record: TerminalRecord) -> Bool {
        replacement.matches(record)
            && (record.keepWarm ?? false) == keepWarm
            && record.activityState == activityState.rawValue
            && FactColumnJSON.matches(
                activityStateSource, encoded: record.activityStateSource)
            && record.activityStateObservedAt == activityStateObservedAt
            && record.activityStateOrderObservedAt == activityStateOrderObservedAt
            && FactColumnJSON.matches(
                awaitingInputReason, encoded: record.awaitingInputReason)
            && record.awaitingInputObservedAt == awaitingInputObservedAt
    }

    func matchesActivity(_ terminal: Terminal) -> Bool {
        terminal.activityState == activityState
            && terminal.activityStateSource == activityStateSource
            && terminal.activityStateObservedAt == activityStateObservedAt
            && terminal.activityStateOrderObservedAt == activityStateOrderObservedAt
            && terminal.awaitingInputReason == awaitingInputReason
            && terminal.awaitingInputObservedAt == awaitingInputObservedAt
    }
}

private enum HibernatedTranscriptPathUpdate {
    case preserve
    case replace(String?)
}

@discardableResult
private func resetAgentProcessLifecycle(
    record: inout TerminalRecord,
    sessionID: String?,
    transcriptPath: String?,
    at date: Date
) -> UUID {
    let incarnationID = UUID()
    record.claudeSessionID = sessionID
    record.transcriptPath = transcriptPath
    record.sessionOrderObservedAt = nil
    record.codexTranscriptBoundaryOffset = nil
    record.sessionIncarnationID = incarnationID.uuidString
    record.pendingSessionIncarnationID = nil
    resetActivityColumns(record: &record, at: date)
    return incarnationID
}

/// The activity reset a wake makes: `.unknown`, stamped `.derived` at `date`,
/// with no wait reason. What a process TBD has not heard from is doing is
/// unknown, and `.unknown` is the value the idle sweep and merge-park refuse.
/// Shared by every write that leaves a row awake over a process whose state
/// no agent report has given yet — a wake, a recreated window, and an
/// un-park that replaced nothing (`clearHibernated`,
/// `clearSessionExitStamp`).
private func resetActivityColumns(record: inout TerminalRecord, at date: Date) {
    record.activityState = TerminalActivityState.unknown.rawValue
    record.activityStateSource = FactColumnJSON.encode(FactSource.derived)
    record.activityStateObservedAt = date
    record.activityStateOrderObservedAt = date
    record.awaitingInputReason = nil
    record.awaitingInputObservedAt = nil
}

private func resetRecreatedShellLifecycle(
    record: inout TerminalRecord,
    at date: Date
) -> UUID {
    let incarnationID = resetAgentProcessLifecycle(
        record: &record,
        sessionID: nil,
        transcriptPath: nil,
        at: date)
    record.suspendedAt = nil
    record.suspendedSnapshot = nil
    record.hibernatedAt = nil
    record.hibernateReason = nil
    record.start_held_reason = nil
    record.start_held_at = nil
    record.label = TerminalLabel.shell
    record.kind = TerminalKind.shell.rawValue
    // A shell launches no Codex, so the tab no longer has Codex options.
    record.codex_launch_options = nil
    return incarnationID
}

/// One transaction's worth of activity-write result: what to hand the caller,
/// and whether the write crossed the `working -> idle` edge (and for which
/// profile), so the notification can be fired AFTER the transaction commits
/// rather than from inside it.
private struct ActivityWriteOutcome<Result: Sendable>: Sendable {
    var result: Result
    var becameIdleProfileID: UUID?
}

/// Spelled out so every `return` in `applyProgramStatusActivity` states the
/// generic argument instead of leaning on inference through an optional.
private typealias ProgramStatusWriteOutcome = ActivityWriteOutcome<ProgramStatusActivityWrite?>

/// Fan-out for `working -> idle` activity transitions.
///
/// A reference type because `TerminalStore` is a value type constructed inside
/// `TBDDatabase.init`, long before the usage poller that consumes these edges
/// exists. The daemon installs the observer once, afterwards.
///
/// Deliberately narrow: it carries a profile id and nothing else. It is not a
/// general event bus, and a second kind of transition should get its own
/// reason for existing rather than a second case here.
public final class TerminalActivityTransitionNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var becameIdle: (@Sendable (UUID) -> Void)?

    public init() {}

    /// Install (or replace) the observer. The daemon wires exactly one.
    public func onSessionBecameIdle(_ observer: @escaping @Sendable (UUID) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        becameIdle = observer
    }

    /// Called by the store after an activity write commits. Never called from
    /// inside a database transaction: the observer is free to do real work.
    func notifySessionBecameIdle(profileID: UUID) {
        lock.lock()
        let observer = becameIdle
        lock.unlock()
        observer?(profileID)
    }
}

/// Fan-out for terminal-row deletions, so memory a daemon component keys by
/// terminal ID is released on every path that deletes a row — a closed tab, a
/// hook tab, an archived, forgotten or recovered worktree — without each of
/// those paths having to know who keeps what. That includes the rows the
/// foreign keys delete: a worktree's terminals go with the worktree, and a
/// repo's with its worktrees, so `WorktreeStore` and `RepoStore` report them
/// too (`terminalIDs`).
///
/// A reference type for the reason `TerminalActivityTransitionNotifier` is
/// one: `TerminalStore` is a value type built inside `TBDDatabase.init`,
/// before any component that keeps per-terminal memory exists. Unlike that
/// notifier it takes several observers, each installed once by its owner.
public final class TerminalDeletionNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [@Sendable ([UUID]) async -> Void] = []

    public init() {}

    /// Add an observer, called with the IDs of every batch of deleted rows.
    public func onTerminalsDeleted(_ observer: @escaping @Sendable ([UUID]) async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        observers.append(observer)
    }

    /// Called by the store after a deletion commits, never from inside its
    /// transaction.
    func notifyDeleted(_ terminalIDs: [UUID]) async {
        guard !terminalIDs.isEmpty else { return }
        for observer in currentObservers() {
            await observer(terminalIDs)
        }
    }

    private func currentObservers() -> [@Sendable ([UUID]) async -> Void] {
        lock.lock()
        defer { lock.unlock() }
        return observers
    }

    /// The terminal rows of worktree `worktreeID`: the rows a delete of the
    /// worktree takes with it through the foreign-key cascade. Read inside the
    /// deleting transaction, before the delete, so the notification after it
    /// commits names exactly the rows that went.
    static func terminalIDs(_ db: Database, worktreeID: UUID) throws -> [UUID] {
        try String.fetchAll(
            db, sql: "SELECT id FROM terminal WHERE worktreeID = ?",
            arguments: [worktreeID.uuidString]
        ).compactMap(UUID.init(uuidString:))
    }

    /// The terminal rows of every worktree of repo `repoID`: the rows a delete
    /// of those worktrees, or of the repo row, takes with it through the
    /// cascade. Read as `terminalIDs(_:worktreeID:)` is.
    static func terminalIDs(_ db: Database, repoID: UUID) throws -> [UUID] {
        try String.fetchAll(
            db, sql: """
                SELECT terminal.id FROM terminal
                JOIN worktree ON terminal.worktreeID = worktree.id
                WHERE worktree.repoID = ?
                """,
            arguments: [repoID.uuidString]
        ).compactMap(UUID.init(uuidString:))
    }
}

/// Provides CRUD operations for terminals.
public struct TerminalStore: Sendable {
    let writer: any DatabaseWriter

    /// `working -> idle` transitions reported by an OBSERVER of the session.
    ///
    /// Its one consumer today is the token-profile usage probe, a billed
    /// request that runs on completed turns and, while account balancing is
    /// on, on a five-minute timer too
    /// (`docs/specs/2026-09-01-token-based-claude-profiles-design.md`).
    /// That consumer defines what the edge means: *a turn finished, so this
    /// profile's utilization moved*. It is not "the `activity_state` column
    /// changed value".
    ///
    /// **Two writers fire it**, and they are the ones that carry an outside
    /// observation of what the agent did: `applyProgramStatusActivity` (the
    /// agent's own OSC 7501 report) and `setActivityState`. The edge is
    /// detected inside the store rather than at their call sites because a
    /// caller-side check would have to be written twice, kept in sync, and
    /// would still miss the next call site.
    ///
    /// **Three other writers set `activityState = .idle` and deliberately do
    /// not fire it**, because none of them observed a turn finishing:
    ///
    /// - `beginHibernatedShellRespawn`, `finalizeHibernatedShellRespawn`,
    ///   `persistHibernatedState` — a park writes `.idle` with
    ///   `FactSource.database`: TBD's own bookkeeping that it stopped the
    ///   session, not evidence from the session that it stopped working. Most
    ///   parks are of sessions that were already idle, and the sweep that
    ///   issues them is a background timer — wiring a billed probe to it would
    ///   add a second, unbounded timer beside the poller's own.
    ///
    /// The one case that genuinely loses information is a session parked
    /// **mid-turn**: utilization moved and no probe fires. It is accepted.
    /// Those numbers are not lost, only late — the next turn on that profile
    /// probes, or the poller's five-minute probe while balancing is on, the
    /// profile row renders its staleness note meanwhile, and the profile's
    /// `⋯` menu offers a manual refresh. Paying a billed request per park to
    /// shave that latency is the wrong trade.
    public let activityTransitions = TerminalActivityTransitionNotifier()

    /// Every row this store deletes, reported after the deletion commits.
    public let deletions = TerminalDeletionNotifier()

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
    /// `transport` is stamped here and never changed afterwards — the
    /// `pty_holder_enabled` gate is read at spawn time, so a session created on
    /// one transport keeps it for life. It defaults to `.tmux` so every existing
    /// call site keeps creating tmux-backed sessions untouched.
    ///
    /// `sessionIncarnationID` is the incarnation a fresh Claude spawn exports
    /// as `TBD_TERMINAL_INCARNATION_ID` when a session-mod feature is on
    /// (`SessionModSpawn.prepare`). It lands in the insert because
    /// `applySessionStart` accepts only a hook whose reported incarnation
    /// equals the row's: a row written without it would drop every hook its
    /// own process sends. Nil, the default, is the row every other spawn has
    /// always written.
    ///
    /// `claudeSpawnExtras` is the plugin folders and settings overlay the
    /// starter passed for a Claude terminal, stored as given so later starts
    /// of its session can reapply them. Callers pass it through
    /// `ClaudeSpawnExtras.nonEmpty`; nil, the default, stores nothing.
    public func create(
        id: UUID = UUID(),
        worktreeID: UUID,
        tmuxWindowID: String,
        tmuxPaneID: String,
        label: String? = nil,
        claudeSessionID: String? = nil,
        profileID: UUID? = nil,
        kind: TerminalKind? = nil,
        transport: TerminalTransport = .tmux,
        holderPID: Int32? = nil,
        childPID: Int32? = nil,
        holderChildStartedAt: Date? = nil,
        serverName: String? = nil,
        sessionIncarnationID: UUID? = nil,
        claudeSpawnExtras: ClaudeSpawnExtras? = nil,
        codexLaunchOptions: CodexLaunchOptions? = nil
    ) async throws -> Terminal {
        var terminal = Terminal(
            id: id,
            worktreeID: worktreeID,
            tmuxWindowID: tmuxWindowID,
            tmuxPaneID: tmuxPaneID,
            label: label,
            claudeSessionID: claudeSessionID,
            profileID: profileID,
            kind: kind,
            transport: transport,
            holderPID: holderPID,
            childPID: childPID,
            holderChildStartedAt: holderChildStartedAt
        )
        // Assigned rather than passed: `Terminal`'s memberwise initializer is
        // already at the Swift type-checker's expression budget here.
        terminal.serverName = serverName
        terminal.sessionIncarnationID = sessionIncarnationID
        terminal.claudeSpawnExtras = claudeSpawnExtras
        terminal.codexLaunchOptions = codexLaunchOptions
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

    /// Every Claude session ID any terminal row names, as raw column text.
    /// Read through SQL rather than `list()` so a row whose other columns fail
    /// to decode still counts as a reference: `OrphanGC`'s session-directory
    /// arm reclaims whatever is NOT referenced.
    public func claudeSessionReferences() async throws -> Set<String> {
        try await writer.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT claudeSessionID FROM terminal WHERE claudeSessionID IS NOT NULL
                """))
        }
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

    /// The Codex launch options a relaunch of this tab must honor, read
    /// strictly. The row model degrades an unreadable value to "none", which
    /// is unsafe here: the value may name a dedicated Codex home, and a
    /// relaunch without it would run on the shared home with no guard. So a
    /// recorded value that does not decode throws, and the relaunch refuses.
    public func codexLaunchOptionsForRelaunch(id: UUID) async throws -> CodexLaunchOptions? {
        let raw = try await writer.read { db in
            try TerminalRecord.fetchOne(db, key: id.uuidString)?.codex_launch_options
        }
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8),
              let options = try? JSONDecoder().decode(CodexLaunchOptions.self, from: data) else {
            throw UnreadableCodexLaunchOptions(terminalID: id)
        }
        return options
    }

    /// Delete a terminal by ID.
    public func delete(id: UUID) async throws {
        let deleted = try await writer.write { db in
            try TerminalRecord.deleteOne(db, key: id.uuidString)
        }
        if deleted {
            await deletions.notifyDeleted([id])
        }
    }

    /// Delete all terminals for a worktree.
    public func deleteForWorktree(worktreeID: UUID) async throws {
        let deleted = try await writer.write { db -> [UUID] in
            let ids = try TerminalDeletionNotifier.terminalIDs(db, worktreeID: worktreeID)
            try TerminalRecord
                .filter(Column("worktreeID") == worktreeID.uuidString)
                .deleteAll(db)
            return ids
        }
        await deletions.notifyDeleted(deleted)
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
            record.codexTranscriptBoundaryOffset = nil
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

    /// Replace a terminal session identity without an ordered SessionStart.
    /// Any Codex boundary belongs to the replaced process and is cleared in the
    /// same write; Claude terminals have no boundary, so their behavior is
    /// unchanged.
    public func updateSessionID(id: UUID, sessionID: String) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = sessionID
            record.codexTranscriptBoundaryOffset = nil
            try record.update(db)
        }
    }

    /// Persist a same-process session recapture only while the process token
    /// observed before capture still names the current terminal incarnation
    /// and no replacement is being staged. A replacement that lands during
    /// the detector await wins atomically.
    @discardableResult
    func updateSessionIDIfIncarnationMatches(
        id: UUID,
        expectedIncarnationID: UUID?,
        sessionID: String
    ) async throws -> Bool {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard record.pendingSessionIncarnationID == nil,
                  record.sessionIncarnationID == expectedIncarnationID?.uuidString else {
                return false
            }
            record.claudeSessionID = sessionID
            record.codexTranscriptBoundaryOffset = nil
            try record.update(db)
            return true
        }
    }

    /// Update the session ID and absolute JSONL transcript path in one write.
    /// Direct lifecycle callers use this when they do not have a SessionStart
    /// observation to order, so the same write clears any Codex boundary. The
    /// hook bridge uses `applySessionStart` below to establish one instead.
    public func updateSession(id: UUID, sessionID: String, transcriptPath: String?) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = sessionID
            // This writer has no ordered SessionStart observation with which
            // to choose a safe lifecycle fence. A replacement identity must
            // not inherit the prior Codex process's durable boundary.
            record.codexTranscriptBoundaryOffset = nil
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

    /// Apply a SessionStart's session identity in one database transaction.
    /// Codex session identity uses its own ordering rail; other agent kinds
    /// retain their established last-writer session semantics. Neither path
    /// writes activity or the wait reason: the agent reports those itself
    /// over OSC 7501, and `ProgramStatusStore` is their only writer.
    ///
    /// Codex session identity is ordered only against other SessionStarts.
    /// Codex SessionStart is first-wins at an equal session watermark; an exact
    /// retry is an idempotent no-op and therefore cannot move a transcript
    /// boundary. The same transaction classifies an initial attachment from the
    /// complete prior session history so callers never decide from a stale row
    /// snapshot.
    /// A handler's durable incarnation snapshot must still match, preventing
    /// a delayed hook from attaching to a recreated terminal even when tmux
    /// reuses the same launch coordinates.
    func applySessionStart(
        id: UUID,
        expectedIncarnation: TerminalSessionIncarnation,
        reportedIncarnationID: UUID? = nil,
        sessionID: String,
        transcriptPath: String?,
        observedTranscriptBoundary: ObservedTranscriptBoundary? = nil,
        observedAt: Date
    ) async throws -> AppliedTerminalSessionStart? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            // Legacy terminals, and fresh rows spawned with every session-mod
            // feature off, carry no process token on either side until their
            // first managed replacement. A row that holds a durable token —
            // rotated in by a replacement, or written at creation by a fresh
            // Claude spawn made with a feature on — accepts only a SessionStart
            // echoing that exact value; nil and mismatches are stale by
            // construction.
            guard record.pendingSessionIncarnationID == nil else { return nil }
            guard record.sessionIncarnationID == reportedIncarnationID?.uuidString else {
                return nil
            }
            guard expectedIncarnation.matches(record) else { return nil }
            let isCodex = record.kind == TerminalKind.codex.rawValue
                || record.label == TerminalLabel.codex
            guard isCodex else {
                // Preserve the established Claude/shell hook behavior: the
                // last SessionStart to finish replaces identity. The ordering
                // rail exists only for Codex transcript reconciliation.
                record.claudeSessionID = sessionID
                if let transcriptPath {
                    record.transcriptPath = transcriptPath
                }
                record.sessionOrderObservedAt = nil
                try record.update(db)
                return AppliedTerminalSessionStart(
                    sessionID: sessionID,
                    transcriptPath: record.transcriptPath,
                    orderObservedAt: nil,
                    transcriptBoundaryOffset: record.codexTranscriptBoundaryOffset,
                    isInitialAttachment: false)
            }
            let isInitialAttachment = record.claudeSessionID == nil
                && record.transcriptPath == nil
                && record.sessionOrderObservedAt == nil
                && record.codexTranscriptBoundaryOffset == nil
            if let storedSessionOrder = record.sessionOrderObservedAt,
               storedSessionOrder >= observedAt {
                return nil
            }
            record.sessionOrderObservedAt = observedAt

            let effectiveTranscriptPath = transcriptPath ?? record.transcriptPath
            record.claudeSessionID = sessionID
            if let transcriptPath {
                record.transcriptPath = transcriptPath
            }
            // The initial Codex process owns the rollout from byte zero, even
            // when its hook arrives after the file starts growing. Every later
            // accepted process is fenced at the caller-observed EOF only while
            // that observation still names the transaction's effective path;
            // nil means no safe matching offset was available when accepted.
            if isInitialAttachment {
                record.codexTranscriptBoundaryOffset = 0
            } else if let observedTranscriptBoundary,
                      observedTranscriptBoundary.path == effectiveTranscriptPath,
                      observedTranscriptBoundary.eof >= 0 {
                record.codexTranscriptBoundaryOffset = observedTranscriptBoundary.eof
            } else {
                record.codexTranscriptBoundaryOffset = nil
            }
            try record.update(db)
            guard let persistedRecord = try TerminalRecord.fetchOne(
                db, key: id.uuidString
            ) else {
                throw DatabaseError(message: "Terminal disappeared after SessionStart")
            }
            return AppliedTerminalSessionStart(
                sessionID: sessionID,
                transcriptPath: persistedRecord.transcriptPath,
                // The tracker must use the exact durable generation a later
                // terminal-list read will reload.
                orderObservedAt: persistedRecord.sessionOrderObservedAt,
                transcriptBoundaryOffset: persistedRecord.codexTranscriptBoundaryOffset,
                isInitialAttachment: isInitialAttachment)
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
            _ = resetRecreatedShellLifecycle(record: &record, at: date)
            try record.update(db)
        }
    }

    /// Bind a newly staged shell window to its terminal row before launching
    /// the interactive shell. The returned token must be injected into that
    /// shell so a manually launched agent can identify this incarnation.
    func replaceRecreatedShellWindow(
        id: UUID,
        expectedIncarnation: TerminalSessionIncarnation,
        windowID: String,
        paneID: String,
        at date: Date
    ) async throws -> UUID? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard expectedIncarnation.matches(record) else { return nil }
            record.tmuxWindowID = windowID
            record.tmuxPaneID = paneID
            // The rebuilt window runs a plain login shell, not the dev
            // server's command, so the tab stops being that server's: left
            // in place, the name would make the server read Running off the
            // shell and make stop or archive signal the shell's group.
            record.server_name = nil
            let incarnationID = resetRecreatedShellLifecycle(record: &record, at: date)
            try record.update(db)
            return incarnationID
        }
    }

    /// Replace a dead Codex window with a fresh process while keeping the tab's
    /// Codex identity. The replacement process has not announced a session yet,
    /// so prior session and activity facts must not make its first SessionStart
    /// look like a resume of the dead process.
    func replaceRecreatedCodexWindow(
        id: UUID,
        expectedIncarnation: TerminalSessionIncarnation,
        windowID: String,
        paneID: String,
        at date: Date
    ) async throws -> UUID? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard expectedIncarnation.matches(record) else { return nil }
            record.tmuxWindowID = windowID
            record.tmuxPaneID = paneID
            let incarnationID = UUID()
            record.sessionIncarnationID = incarnationID.uuidString
            record.pendingSessionIncarnationID = nil
            record.claudeSessionID = nil
            record.transcriptPath = nil
            record.sessionOrderObservedAt = nil
            record.codexTranscriptBoundaryOffset = nil
            record.suspendedAt = nil
            record.suspendedSnapshot = nil
            record.hibernatedAt = nil
            record.hibernateReason = nil
            record.start_held_reason = nil
            record.start_held_at = nil
            resetActivityColumns(record: &record, at: date)
            try record.update(db)
            return incarnationID
        }
    }

    /// Commit the complete intended state for an in-place profile replacement
    /// before tmux starts the new Claude process. The returned token is the
    /// exact value the caller must inject into that process environment.
    func prepareProfileAgentRespawn(
        id: UUID,
        expectedState: TerminalReplacementSnapshot,
        sessionID: String,
        transcriptPath: String?,
        profileID: UUID?,
        at date: Date
    ) async throws -> UUID? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard expectedState.matches(record) else { return nil }
            record.profile_id = profileID?.uuidString
            let incarnationID = resetAgentProcessLifecycle(
                record: &record,
                sessionID: sessionID,
                transcriptPath: transcriptPath,
                at: date)
            try record.update(db)
            return incarnationID
        }
    }

    /// Fence a positively-idle Codex row for Continue-in-Claude without
    /// changing any provider, session, rollout, profile, or active-process
    /// identity. The pending token makes every old-process hook stale while
    /// leaving the source identity durable for rollback and restart recovery.
    func beginContinueInClaude(
        id: UUID,
        expectedState: TerminalContinueInClaudeSnapshot,
        pendingIncarnationID: UUID
    ) async throws -> Terminal? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard expectedState.matches(record),
                  record.kind == TerminalKind.codex.rawValue,
                  record.hibernatedAt == nil,
                  record.suspendedAt == nil,
                  record.pendingSessionIncarnationID == nil else {
                return nil
            }
            record.pendingSessionIncarnationID = pendingIncarnationID.uuidString
            try record.update(db)
            return record.toModel()
        }
    }

    /// Retract a staged Continue fence before its first destructive tmux act.
    /// Exact-token matching means a stale refusal cannot clear another
    /// transaction's recovery intent.
    func abortContinueInClaudeBeforeLaunch(
        id: UUID,
        pendingIncarnationID: UUID
    ) async throws -> Terminal? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                return nil
            }
            guard record.kind == TerminalKind.codex.rawValue,
                  record.pendingSessionIncarnationID == pendingIncarnationID.uuidString else {
                return nil
            }
            record.pendingSessionIncarnationID = nil
            try record.update(db)
            return record.toModel()
        }
    }

    /// Rotate the failed Claude destination token to a fresh Codex recovery
    /// token. The row remains entirely Codex; delayed hooks from both dead
    /// processes become stale in the same write.
    func rotateContinueInClaudeToCodexRecovery(
        id: UUID,
        expectedPendingIncarnationID: UUID,
        recoveryIncarnationID: UUID
    ) async throws -> Terminal? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                return nil
            }
            guard record.kind == TerminalKind.codex.rawValue,
                  record.hibernatedAt == nil,
                  record.suspendedAt == nil,
                  record.pendingSessionIncarnationID
                    == expectedPendingIncarnationID.uuidString else {
                return nil
            }
            record.pendingSessionIncarnationID = recoveryIncarnationID.uuidString
            try record.update(db)
            return record.toModel()
        }
    }

    /// Persist a recreated inert window under an existing recovery token
    /// before Codex is launched into it. No session/provider fact changes.
    func movePendingCodexRecovery(
        id: UUID,
        expectedPendingIncarnationID: UUID,
        windowID: String,
        paneID: String
    ) async throws -> Terminal? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                return nil
            }
            guard record.kind == TerminalKind.codex.rawValue,
                  record.pendingSessionIncarnationID
                    == expectedPendingIncarnationID.uuidString else {
                return nil
            }
            record.tmuxWindowID = windowID
            record.tmuxPaneID = paneID
            try record.update(db)
            return record.toModel()
        }
    }

    /// Atomically publish the Claude destination only after its exact pending
    /// token produced SessionStart readiness.
    func finalizeContinueInClaude(
        id: UUID,
        expectedPendingIncarnationID: UUID,
        profileID: UUID?,
        sessionID: String,
        transcriptPath: String?,
        observedAt: Date
    ) async throws -> Terminal? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                return nil
            }
            guard record.kind == TerminalKind.codex.rawValue,
                  record.pendingSessionIncarnationID
                    == expectedPendingIncarnationID.uuidString else {
                return nil
            }
            record.kind = TerminalKind.claude.rawValue
            record.label = TerminalLabel.claudeCode
            // The tab now runs Claude; its Codex options no longer describe it.
            record.codex_launch_options = nil
            record.profile_id = profileID?.uuidString
            record.claudeSessionID = sessionID
            record.transcriptPath = transcriptPath
            record.sessionOrderObservedAt = observedAt
            record.codexTranscriptBoundaryOffset = nil
            record.sessionIncarnationID = expectedPendingIncarnationID.uuidString
            record.pendingSessionIncarnationID = nil
            // A new incarnation: nothing is known about it until its agent
            // reports, exactly as `resetAgentProcessLifecycle` records it.
            record.activityState = TerminalActivityState.unknown.rawValue
            record.activityStateSource = FactColumnJSON.encode(FactSource.derived)
            record.activityStateObservedAt = observedAt
            record.activityStateOrderObservedAt = observedAt
            record.awaitingInputReason = nil
            record.awaitingInputObservedAt = nil
            record.pendingResumeAt = nil
            try record.update(db)
            return record.toModel()
        }
    }

    /// Promote a ready Codex rollback/recovery process while retaining the
    /// immutable source thread and rollout identity captured before Continue.
    func finalizePendingCodexRecovery(
        id: UUID,
        expectedPendingIncarnationID: UUID,
        sourceThreadID: String,
        sourceRolloutPath: String,
        observedAt: Date
    ) async throws -> Terminal? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                return nil
            }
            guard record.kind == TerminalKind.codex.rawValue,
                  record.pendingSessionIncarnationID
                    == expectedPendingIncarnationID.uuidString else {
                return nil
            }
            record.label = TerminalLabel.codex
            record.profile_id = nil
            record.claudeSessionID = sourceThreadID
            record.transcriptPath = sourceRolloutPath
            record.sessionOrderObservedAt = observedAt
            record.codexTranscriptBoundaryOffset = nil
            record.sessionIncarnationID = expectedPendingIncarnationID.uuidString
            record.pendingSessionIncarnationID = nil
            // A new incarnation: nothing is known about it until its agent
            // reports, exactly as `resetAgentProcessLifecycle` records it.
            record.activityState = TerminalActivityState.unknown.rawValue
            record.activityStateSource = FactColumnJSON.encode(FactSource.derived)
            record.activityStateObservedAt = observedAt
            record.activityStateOrderObservedAt = observedAt
            record.awaitingInputReason = nil
            record.awaitingInputObservedAt = nil
            record.pendingResumeAt = nil
            try record.update(db)
            return record.toModel()
        }
    }

    /// Durable recovery candidates: awake Codex rows whose replacement fence
    /// survived a crash or a failed rollback. Parked pending rows belong to the
    /// hibernation reconciler and are intentionally excluded.
    func listPendingCodexContinuations() async throws -> [Terminal] {
        try await writer.read { db in
            try TerminalRecord
                .filter(Column("kind") == TerminalKind.codex.rawValue)
                .filter(Column("pendingSessionIncarnationID") != nil)
                .filter(Column("hibernatedAt") == nil)
                .filter(Column("suspendedAt") == nil)
                .order(Column("createdAt").asc, Column("id").asc)
                .fetchAll(db)
                .compactMap { $0.toModel() }
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

    /// Re-home a parked session only while the complete launch state observed
    /// by the caller is still current. A wake or replacement that wins first
    /// rejects this write atomically instead of leaving the row's profile out
    /// of sync with the process that was launched.
    ///
    /// `sessionID` names the conversation the row is to hold once it is
    /// re-homed, and it travels in THIS statement rather than a write of its
    /// own so the two cannot land separately. The in-place profile swap on a
    /// holder row is what needs it: a blank session is spawned fresh under a
    /// new id rather than resumed, and a second write that failed after the
    /// re-home would leave the row on the destination account naming a
    /// conversation whose transcript was never carried there — the "no
    /// conversation found" the swap exists to avoid. It is the same
    /// commitment `prepareProfileAgentRespawn` above makes for the tmux
    /// transport. nil leaves both session columns exactly as they are, which
    /// is what the cold swap and every resume pass.
    ///
    /// `transcriptPath` is honoured only alongside a `sessionID`: a transcript
    /// file belongs to the conversation named beside it and never travels on
    /// its own.
    func setParkedProfileID(
        id: UUID,
        expectedState: TerminalReplacementSnapshot,
        profileID: UUID?,
        sessionID: String? = nil,
        transcriptPath: String? = nil
    ) async throws -> Terminal? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard expectedState.matches(record),
                  record.hibernatedAt != nil || record.suspendedAt != nil else {
                return nil
            }
            record.profile_id = profileID?.uuidString
            if let sessionID {
                record.claudeSessionID = sessionID
                // No ordered SessionStart observation is available here, so a
                // replacement identity must not inherit the prior Codex
                // process's durable boundary — the same reason `updateSession`
                // clears it.
                record.codexTranscriptBoundaryOffset = nil
                if let transcriptPath {
                    record.transcriptPath = transcriptPath
                }
            }
            try record.update(db)
            return record.toModel()
        }
    }

    /// Move a parked session to another transport only while the complete
    /// state observed by the caller is still current; nil means the snapshot
    /// was stale and nothing was written.
    ///
    /// The tmux coordinates are blanked in the SAME statement as the transport.
    /// Two writes that could land separately might leave a holder row still
    /// naming a pane, the stale-coordinate hazard that let daemon keystrokes
    /// reach the wrong session.
    func setParkedTransport(
        id: UUID,
        expectedState: TerminalReplacementSnapshot,
        transport: TerminalTransport
    ) async throws -> Terminal? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard expectedState.matches(record),
                  record.hibernatedAt != nil || record.suspendedAt != nil else {
                return nil
            }
            record.transport = transport.rawValue
            record.tmuxWindowID = ""
            record.tmuxPaneID = ""
            try record.update(db)
            return record.toModel()
        }
    }

    /// Move a RUNNING session that has no conversation to resume onto the pty
    /// holder, in one guarded write: the transport, the blanked tmux
    /// coordinates, the holder's processes and the dead process's session and
    /// activity facts all land in the same statement. nil means the snapshot
    /// was stale and nothing was written.
    ///
    /// **Why one write rather than a prepare-then-record pair.** The caller
    /// mints the incarnation, so the replacement program is already carrying it
    /// before any column moves. This write is therefore the single moment at
    /// which the row stops describing a dead tmux pane and starts describing a
    /// live holder, and a caller that fails anywhere before it leaves the row
    /// untouched — still `tmux`, still awake, naming a window that is now dead,
    /// which is the ordinary window-died state `terminal.recreateWindow`
    /// repairs.
    ///
    /// **The guard is the complement of `setParkedTransport`'s.** That one
    /// requires the row to read parked; this one requires it to read awake and
    /// not already holder-backed, so neither can be used for the other's case
    /// by mistake. Between the caller's kill and this write the app may notice
    /// the dead window and recreate it, which rotates the row's incarnation:
    /// the snapshot then fails to match, nothing is written, and the caller
    /// abandons the holder it started.
    ///
    /// The session and activity columns are cleared through the same helper
    /// `replaceRecreatedShellWindow` uses, because this is the same event — a
    /// dead process's facts must not make the replacement's first hook look
    /// like a resume. The incarnation that helper mints is overwritten with the
    /// caller's, which is the one the live job actually carries.
    ///
    /// **One of that helper's columns is put back: the label.** It is not a
    /// display detail — `WorktreeLifecycle+Recovery` and the app's
    /// `PrimaryTerminal` both FIND a tab by its label — and a session that
    /// moves transport is meant to come back as the same tab, so a hook tab
    /// renamed `shell` by this gesture would be found by nothing. The `kind`
    /// is deliberately NOT put back: the helper's `shell` is the truth about
    /// what is now running, and preserving an agent kind here would mint a row
    /// shape that has never existed — holder-backed, agent-kinded, with no
    /// session — for which the daemon would keep paying transcript and
    /// context-window work on behalf of a bare login shell.
    ///
    /// `startedAt` doubles as the activity observation's timestamp: it is the
    /// moment the replacement job started, which is when this row's `unknown`
    /// activity was observed.
    func moveRunningShellToHolder(
        id: UUID,
        expectedState: TerminalReplacementSnapshot,
        incarnationID: UUID,
        holderPID: Int32,
        childPID: Int32,
        startedAt: Date
    ) async throws -> Terminal? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard expectedState.matches(record),
                  record.transport != TerminalTransport.holder.rawValue,
                  record.hibernatedAt == nil, record.suspendedAt == nil else {
                return nil
            }
            let label = record.label
            _ = resetRecreatedShellLifecycle(record: &record, at: startedAt)
            record.label = label
            // The holder job is a plain login shell, not a dev server's
            // command — the same reason `replaceRecreatedShellWindow` drops
            // the name.
            record.server_name = nil
            record.sessionIncarnationID = incarnationID.uuidString
            record.transport = TerminalTransport.holder.rawValue
            record.tmuxWindowID = ""
            record.tmuxPaneID = ""
            record.holder_pid = holderPID
            record.child_pid = childPID
            record.holder_child_started_at = startedAt
            try record.update(db)
            return record.toModel()
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
            record.sessionIncarnationID = UUID().uuidString
            record.pendingSessionIncarnationID = nil
            try record.update(db)
        }
    }

    /// Record an observation of a terminal's activity state, unconditionally.
    ///
    /// The seeding writer for mock mode (`MockSeeder`) and for tests. A live
    /// agent's state reaches the columns through `applyProgramStatusActivity`,
    /// which validates incarnation, park state and report order first.
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
    ///
    /// Returns whether a standing wait reason was RETRACTED — a reason stood
    /// before and none stands now — so a caller can announce the retraction
    /// without re-reading the row. A call that installs a reason returns false:
    /// there is nothing retracted to announce, and a caller that passes one is
    /// responsible for broadcasting what it wrote.
    @discardableResult
    public func setActivityState(
        id: UUID,
        activityState: TerminalActivityState,
        source: FactSource,
        observedAt: Date = Date(),
        awaitingInputReason: AwaitingInputReason? = nil
    ) async throws -> Bool {
        let outcome = try await writer.write { db -> ActivityWriteOutcome<Bool> in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            // Read before the mutation below: `working -> idle` is the moment a
            // turn completed, and it is only visible against the state the row
            // held on entry.
            let previousState = record.activityState
                .flatMap(TerminalActivityState.init(rawValue:))
            let rowProfileID = record.profile_id.flatMap(UUID.init(uuidString:))
            let hadReason = record.awaitingInputReason != nil
                || record.awaitingInputObservedAt != nil
            record.activityState = activityState.rawValue
            record.activityStateSource = FactColumnJSON.encode(source)
            record.activityStateObservedAt = observedAt
            record.activityStateOrderObservedAt = observedAt
            // Unconditional, including the nil case: a reason belongs to the
            // state written beside it, so a write that names none clears the
            // old one rather than leaving a wait standing under a state that
            // no longer has it. Making this write conditional on a non-nil
            // reason would leave stale waits pinned to the row forever.
            record.awaitingInputReason = FactColumnJSON.encode(awaitingInputReason)
            record.awaitingInputObservedAt = awaitingInputReason == nil ? nil : observedAt
            try record.update(db)
            let becameIdle = previousState == .working && activityState == .idle
            return ActivityWriteOutcome(
                result: hadReason && awaitingInputReason == nil,
                becameIdleProfileID: becameIdle ? rowProfileID : nil)
        }
        if let profileID = outcome.becameIdleProfileID {
            activityTransitions.notifySessionBecameIdle(profileID: profileID)
        }
        return outcome.result
    }

    /// Write the activity columns from an agent's own OSC 7501 report — the
    /// one writer `ProgramStatusStore` uses.
    ///
    /// Every guard runs inside the write transaction, against the row as it
    /// stands at commit. The store suspends on this call and can ingest the
    /// next report meanwhile, so the order two calls commit in is not the
    /// order their reports were observed in; checking here is what keeps an
    /// older report from landing last.
    ///
    /// Returns nil, writing nothing, when the row:
    /// - is gone (no throw: the session ended under the report);
    /// - is parked or suspended: a park wrote `.idle` with `.database`, and no
    ///   agent runs to contradict it;
    /// - has a staged replacement (`pendingSessionIncarnationID`), so no
    ///   process is entitled to write;
    /// - belongs to another incarnation than `scope` names;
    /// - carries an ordering watermark (`activityStateOrderObservedAt`) at or
    ///   after this report, whichever writer stamped it, and holds a different
    ///   value. A report at the watermark that repeats the stored value is
    ///   accepted and changes nothing.
    ///
    /// The value is the state, the wait reason and the `source` together
    /// (`.programStatus` for a report, `.processLiveness` for a child exit's
    /// `.unknown`). When the row already holds all three, the value and
    /// `activityStateObservedAt` stay as they are, so the at-rest clock
    /// hibernation reads keeps the moment the value was first reported; only
    /// the ordering watermark advances, so every accepted report fences off
    /// older ones. Otherwise all three, both observation stamps and the
    /// wait-reason stamp are written together, so the stored reason always
    /// describes the state beside it and the source names who wrote both. A
    /// write that changes only the source still counts as a change: a child
    /// exit over a never-reported `.unknown` tells the app the process is
    /// gone, which the sidebar's no-status mark reads.
    ///
    /// A `.working` report cancels a pending scheduled resume — the session is
    /// already running a turn — and `working -> idle` notifies
    /// `activityTransitions` after the commit.
    public func applyProgramStatusActivity(
        id: UUID,
        scope: ProgramStatusWriteScope,
        activityState: TerminalActivityState,
        awaitingInputReason: AwaitingInputReason?,
        observedAt: Date,
        source: FactSource = .programStatus
    ) async throws -> ProgramStatusActivityWrite? {
        let outcome = try await writer.write { db -> ProgramStatusWriteOutcome in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString),
                  let worktreeID = UUID(uuidString: record.worktreeID) else {
                return ProgramStatusWriteOutcome(result: nil)
            }
            guard record.hibernatedAt == nil, record.suspendedAt == nil,
                  record.pendingSessionIncarnationID == nil else {
                return ProgramStatusWriteOutcome(result: nil)
            }
            if case .incarnation(let incarnationID) = scope,
               record.sessionIncarnationID != incarnationID?.uuidString {
                return ProgramStatusWriteOutcome(result: nil)
            }

            let previousState = record.activityState
                .flatMap(TerminalActivityState.init(rawValue:)) ?? .unknown
            let storedReason = FactColumnJSON.decode(
                AwaitingInputReason.self, from: record.awaitingInputReason)
            let storedSource = FactColumnJSON.decode(
                FactSource.self, from: record.activityStateSource)
            let stateChanged = previousState != activityState
            let reasonChanged = storedReason != awaitingInputReason
            let sourceChanged = storedSource != source
            let valueChanged = ProgramStatusActivityWrite.changesValue(
                stateChanged: stateChanged, reasonChanged: reasonChanged, sourceChanged: sourceChanged)
            // Ordered against the stamp whoever wrote it — a report, a park, a
            // wake's reset — so a report older than the value standing can
            // never land over it. A tie is not newer: it is refused unless it
            // repeats the stored value, so of two writes stamped alike the
            // first to commit stands, and the rule says which without a
            // tiebreak on the values.
            let storedOrder = record.activityStateOrderObservedAt ?? record.activityStateObservedAt
            let isNewer = storedOrder.map { $0 < observedAt } ?? true
            guard isNewer || !valueChanged else {
                return ProgramStatusWriteOutcome(result: nil)
            }
            if !valueChanged {
                // The report repeats the stored value: only the ordering
                // watermark moves, so an older report still in flight is
                // refused when it commits after this one.
                if isNewer {
                    record.activityStateOrderObservedAt = observedAt
                    try record.update(db)
                }
            } else {
                record.activityState = activityState.rawValue
                record.activityStateSource = FactColumnJSON.encode(source)
                record.activityStateObservedAt = observedAt
                record.activityStateOrderObservedAt = observedAt
                record.awaitingInputReason = FactColumnJSON.encode(awaitingInputReason)
                record.awaitingInputObservedAt = awaitingInputReason == nil ? nil : observedAt
                try record.update(db)
            }
            // AFTER record.update: the routine nils `pendingResumeAt` via raw
            // SQL, and an update of the record fetched above would write the
            // old value back (the `persistHibernatedState` ordering).
            var cancelledPendingResume = false
            if activityState == .working {
                cancelledPendingResume = try ScheduledResumeStore.cancelPendingInTransaction(
                    db, terminalID: id.uuidString)
            }
            let becameIdle = previousState == .working && activityState == .idle
            return ProgramStatusWriteOutcome(
                result: ProgramStatusActivityWrite(
                    worktreeID: worktreeID,
                    previousActivityState: previousState,
                    stateChanged: stateChanged,
                    reasonChanged: reasonChanged,
                    sourceChanged: sourceChanged,
                    cancelledPendingResume: cancelledPendingResume),
                becameIdleProfileID: becameIdle
                    ? record.profile_id.flatMap(UUID.init(uuidString:)) : nil)
        }
        if let profileID = outcome.becameIdleProfileID {
            activityTransitions.notifySessionBecameIdle(profileID: profileID)
        }
        return outcome.result
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
    /// Park sites whose process is already replaced use this complete
    /// transition. `HibernationCoordinator.performHibernate` instead uses the
    /// staged begin/finalize pair below so a failed first tmux replacement can
    /// retain a still-running agent's token. Both paths cancel any scheduled
    /// auto-resume atomically with their park intent: while a row is parked, a
    /// resume must not type into either the outgoing agent or its replacement
    /// shell. Wake (`clearHibernated`) deliberately does not resurrect the
    /// cancelled row.
    public func setHibernated(id: UUID, sessionID: String, snapshot: String? = nil, reason: HibernateReason? = nil, at date: Date = Date()) async throws {
        _ = try await persistHibernatedState(
            id: id,
            sessionID: sessionID,
            transcriptPathUpdate: .preserve,
            snapshot: snapshot,
            reason: reason,
            at: date)
    }

    /// Record the hibernation intent before replacing the live agent. The
    /// current process token remains intact until tmux has replaced that
    /// process with an inert pane, so startup reconciliation can safely unpark
    /// a still-running agent after a crash or failed respawn. A pending token
    /// makes process-bound hook writes inert during this interval; finalize
    /// promotes it once replacement is confirmed. A process-incarnation
    /// mismatch rejects without writing and returns nil.
    func beginHibernatedShellRespawn(
        id: UUID,
        expectedState: TerminalHibernationSnapshot,
        snapshot: String? = nil,
        reason: HibernateReason? = nil,
        at date: Date = Date()
    ) async throws -> TerminalSessionIncarnation? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard expectedState.matches(record) else { return nil }
            record.pendingSessionIncarnationID = UUID().uuidString
            record.hibernatedAt = date
            record.hibernateReason = reason?.rawValue
            if let snapshot {
                record.suspendedSnapshot = snapshot
            }
            record.activityState = TerminalActivityState.idle.rawValue
            record.activityStateSource = FactColumnJSON.encode(FactSource.database)
            record.activityStateObservedAt = date
            record.activityStateOrderObservedAt = date
            record.awaitingInputReason = nil
            record.awaitingInputObservedAt = nil
            try record.update(db)
            try ScheduledResumeStore.cancelPendingInTransaction(db, terminalID: id.uuidString)
            return TerminalSessionIncarnation(record: record)
        }
    }

    /// Fence the process that tmux has already replaced with an inert pane.
    /// The returned token belongs to the hibernated shell launched next; all
    /// ordering and activity evidence from the former agent clears atomically.
    /// A process-incarnation mismatch rejects without writing and returns nil.
    func finalizeHibernatedShellRespawn(
        id: UUID,
        expectedIncarnation: TerminalSessionIncarnation,
        at date: Date = Date()
    ) async throws -> UUID? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard expectedIncarnation.matches(record) else { return nil }
            guard record.hibernatedAt != nil || record.suspendedAt != nil else {
                throw DatabaseError(message: "Terminal is not parked")
            }
            guard let pendingIncarnationID = record.pendingSessionIncarnationID,
                  let incarnationID = UUID(uuidString: pendingIncarnationID) else {
                return nil
            }
            record.sessionOrderObservedAt = nil
            record.codexTranscriptBoundaryOffset = nil
            record.sessionIncarnationID = pendingIncarnationID
            record.pendingSessionIncarnationID = nil
            record.activityState = TerminalActivityState.idle.rawValue
            record.activityStateSource = FactColumnJSON.encode(FactSource.database)
            record.activityStateObservedAt = date
            record.activityStateOrderObservedAt = date
            record.awaitingInputReason = nil
            record.awaitingInputObservedAt = nil
            try record.update(db)
            return incarnationID
        }
    }

    private func persistHibernatedState(
        id: UUID,
        sessionID: String,
        transcriptPathUpdate: HibernatedTranscriptPathUpdate,
        snapshot: String?,
        reason: HibernateReason?,
        at date: Date
    ) async throws -> UUID {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.claudeSessionID = sessionID
            if case .replace(let transcriptPath) = transcriptPathUpdate {
                record.transcriptPath = transcriptPath
            }
            record.sessionOrderObservedAt = nil
            record.codexTranscriptBoundaryOffset = nil
            let incarnationID = UUID()
            record.sessionIncarnationID = incarnationID.uuidString
            record.pendingSessionIncarnationID = nil
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
            return incarnationID
        }
    }

    /// Clear a stale parked marker when startup reconciliation proves the
    /// recorded process is still alive, or after a replacement agent launches.
    /// Nils both the authoritative `hibernatedAt` and
    /// legacy `suspendedAt`, while preserving the live process's identity and
    /// current incarnation. Any abandoned pending replacement is rolled back.
    /// A real wake first uses
    /// `prepareHibernatedAgentRespawn` below before launching the process.
    ///
    /// An activity value other than `.unknown` is the park's own `.idle` (or an
    /// exit stamp's): the wake's reset has not replaced it, because this
    /// un-park launched nothing — a park rolled back over a child that would
    /// not die or could not be verified, startup finding the parked agent
    /// still running, a wake that adopts a live holder. That `.idle` describes
    /// a parked row, not the agent now running unparked, and on tmux no report
    /// ever replaces it, so it is reset to `.unknown` as a wake resets it. The
    /// reset keeps the stamp the park wrote, so a report the agent made after
    /// the park — a holder's parked backlog, replayed by the wake's drop, or
    /// one the app forwards late — still lands over it.
    public func clearHibernated(id: UUID, at date: Date = Date()) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.start_held_reason = nil
            record.start_held_at = nil
            record.hibernatedAt = nil
            record.suspendedAt = nil
            record.hibernateReason = nil
            record.pendingSessionIncarnationID = nil
            if record.activityState != TerminalActivityState.unknown.rawValue {
                let parkStamp = record.activityStateOrderObservedAt
                    ?? record.activityStateObservedAt
                    ?? date
                resetActivityColumns(record: &record, at: parkStamp)
            }
            try record.update(db)
        }
    }

    /// Record that the start-admission command held a wake of this parked row.
    /// Both columns are written together. Every write that un-parks the row
    /// clears them: a wake (`clearHibernated`, which every wake path ends in),
    /// a hand-started session (`clearSessionExitStamp`), and a recreated shell
    /// or Codex window. So a later park never shows an old hold.
    ///
    /// The command can run for seconds, so the row may have changed since the
    /// caller looked. The write happens only when the row is still parked and
    /// its session incarnation is still `expectedIncarnationID`; a row that was
    /// woken, or parked again under a new incarnation, gets no hold. Returns
    /// whether the hold was written.
    @discardableResult
    public func setStartHeld(
        id: UUID, reason: String, expectedIncarnationID: UUID?, at date: Date = Date()
    ) async throws -> Bool {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString),
                  record.hibernatedAt != nil || record.suspendedAt != nil,
                  record.sessionIncarnationID == expectedIncarnationID?.uuidString else {
                return false
            }
            record.start_held_reason = reason
            record.start_held_at = date
            try record.update(db)
            return true
        }
    }

    /// Park a row because Claude's own process left, reported by its `SessionEnd`
    /// hook. Returns whether the row actually changed.
    ///
    /// **Deliberately narrower than `setHibernated`.** That writer mints a new
    /// session incarnation and cancels pending scheduled resumes, because it
    /// describes a park TBD performed and a process TBD is about to replace. A
    /// hook only *reports* that the process is gone: nothing was replaced, and
    /// the session id, incarnation, and resume this row already points at are
    /// still the right ones — none of those move here.
    ///
    /// `activityState` DOES move, to `.idle`, alongside `hibernatedAt` and
    /// `hibernateReason`: whatever it last reported (plausibly `.working`,
    /// mid-turn) stopped being true the moment the process that was reporting it
    /// left, and nothing else will ever retract a stale `.working` for a process
    /// that no longer exists to finish that turn.
    ///
    /// It refuses on an already-parked row for the same reason the awaiting-input
    /// rail refuses an uninformative overwrite: `hibernateReason` is the record of
    /// WHO parked a session, `HibernationCoordinator`'s wake-on-focus sweep reads
    /// it, and a late `SessionEnd` from the process TBD itself killed would
    /// otherwise rewrite a deliberate `.manual` park into `.exited`.
    ///
    /// `reportedIncarnationID` is the hook's own process-incarnation nonce,
    /// checked by exact equality against the record's — the same reading
    /// `applySessionStart` and `updateSessionIDIfIncarnationMatches` each give
    /// it. A mismatch means the
    /// hook describes a process TBD has already replaced, so stamping would
    /// park a live successor. A `nil` report matches only a record that still
    /// carries no incarnation of its own — once TBD mints one (a replacement
    /// launch, via `updateTmuxIDs`), a delayed `SessionEnd` from the
    /// pre-incarnation predecessor process reads as a mismatch too, not as an
    /// unchecked report.
    ///
    /// The stamp is tmux-only. On a holder-backed row the Claude process IS the
    /// holder's whole job: there is no shell left in the pane for a send to
    /// mis-execute, and the hibernation coordinator's wake respawns into a tmux
    /// window, which cannot bring a holder session back. Parking such a row
    /// would leave a park nothing can wake and no reconciler reclaims, so the
    /// row stays unstamped and the holder path answers for its own liveness.
    ///
    /// The stamp is Claude-tab-only (`Terminal.isClaudeTab`) for the same
    /// reason. `SessionStart` records an id onto a shell row whose
    /// hand-started Claude carries TBD's hook, so that Claude's `SessionEnd`
    /// reaches the row too. The wake that would lift the stamp refuses a tab
    /// that is not Claude's (`Terminal.claudeResumeDecision`), and a parked
    /// pane shows a frozen snapshot, so a stamp there would cost the person
    /// their shell until they closed the tab. Unstamped, the row stays the
    /// live shell it is, and a send to it is a shell send like any other. A
    /// stamp an earlier build left on such a tab is lifted at startup
    /// (`HibernationCoordinator.reconcileOnStartup`).
    ///
    /// `date` follows the one-shot stamp seam (CLAUDE.md, "Duration is behavior,
    /// Date is data").
    @discardableResult
    public func stampSessionExited(
        id: UUID, reportedIncarnationID: UUID?, at date: Date = Date()
    ) async throws -> Bool {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                return false
            }
            guard record.transport != TerminalTransport.holder.rawValue else { return false }
            guard record.toModel()?.isClaudeTab == true else { return false }
            guard record.hibernatedAt == nil else { return false }
            guard record.sessionIncarnationID == reportedIncarnationID?.uuidString else {
                return false
            }
            record.hibernatedAt = date
            record.hibernateReason = HibernateReason.exited.rawValue
            // The process that was reporting `activityState` just left, so
            // whatever it last reported (plausibly `.working`, mid-turn) is no
            // longer true of anything: there is no process left to finish that
            // turn. Written as the same provenance triple every other writer of
            // this column uses (state + source + both timestamps together) so a
            // later observation's ordering check compares against a source that
            // actually explains the stored value.
            record.activityState = TerminalActivityState.idle.rawValue
            record.activityStateSource = FactColumnJSON.encode(FactSource.hookEvent("SessionEnd"))
            record.activityStateObservedAt = date
            record.activityStateOrderObservedAt = date
            try record.update(db)
            return true
        }
    }

    /// Retract an exit stamp because the session came back — the `SessionStart`
    /// hook. Returns whether the row actually changed.
    ///
    /// Scoped to `.exited` on purpose. `SessionStart` also fires on `/clear` and
    /// `/compact` inside a live process, and on a resume; a blanket un-park there
    /// would undo an operator's deliberate `.manual` hibernate. `clearHibernated`
    /// stays the wake path's writer — it also clears `suspendedAt` and the pending
    /// incarnation, which belong to a respawn this never performs.
    ///
    /// The activity columns are reset as a wake resets them, at `date`: the
    /// stamp's `.idle` described the process that left, and the one that came
    /// back has reported nothing. Left standing, it is an `.idle` no writer
    /// replaces on tmux, where the stamp lives, so the idle sweep or merge-park
    /// would park — and kill — a Claude that is mid-turn.
    @discardableResult
    public func clearSessionExitStamp(id: UUID, at date: Date = Date()) async throws -> Bool {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                return false
            }
            guard record.hibernateReason == HibernateReason.exited.rawValue else { return false }
            record.hibernatedAt = nil
            record.hibernateReason = nil
            record.start_held_reason = nil
            record.start_held_at = nil
            resetActivityColumns(record: &record, at: date)
            try record.update(db)
            return true
        }
    }

    /// Prepare a parked shell for a fresh agent before launch. Preserve the
    /// captured session identity and transcript needed for a failed launch to
    /// retry, while clearing process-local ordering/activity and rotating the
    /// durable incarnation atomically. The parked marker remains until tmux
    /// confirms launch; `clearHibernated` then removes only that marker.
    func prepareHibernatedAgentRespawn(
        id: UUID,
        expectedState: TerminalReplacementSnapshot,
        windowID: String? = nil,
        paneID: String? = nil,
        at date: Date = Date()
    ) async throws -> UUID? {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            guard expectedState.matches(record),
                  record.hibernatedAt != nil || record.suspendedAt != nil else {
                return nil
            }
            if let windowID, let paneID {
                record.tmuxWindowID = windowID
                record.tmuxPaneID = paneID
            }
            let resumeSessionID = record.claudeSessionID
            let resumeTranscriptPath = record.transcriptPath
            let incarnationID = resetAgentProcessLifecycle(
                record: &record,
                sessionID: resumeSessionID,
                transcriptPath: resumeTranscriptPath,
                at: date)
            try record.update(db)
            return incarnationID
        }
    }

    /// Record — or clear — which processes carry a holder-transport row, in one
    /// write.
    ///
    /// The three facts move together on purpose. A pid without the start time
    /// that identifies it is a pid nothing may signal (`ProcessIdentityCheck`
    /// reads a missing start time as "not the same process"), and a start time
    /// without a pid names nothing at all, so a caller that could set one and
    /// forget another would leave the row saying something no reader can act
    /// on. Wake passes all three; park passes `nil` for all three, which is
    /// what a parked row means — no holder, no job, no anchor.
    public func setHolderProcess(
        id: UUID, holderPID: Int32?, childPID: Int32?, startedAt: Date?
    ) async throws {
        try await writer.write { db in
            guard var record = try TerminalRecord.fetchOne(db, key: id.uuidString) else {
                throw DatabaseError(message: "Terminal not found")
            }
            record.holder_pid = holderPID
            record.child_pid = childPID
            record.holder_child_started_at = startedAt
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

    /// Count live Claude sessions per profile. Live = kind is 'claude', profile_id
    /// is not NULL, and the session is not hibernated or suspended. Returns a map
    /// of profile_id → count. UUIDs that fail to parse are skipped silently
    /// (corrupted rows in the database; the count is conservative).
    public func liveSessionCountsByProfile() async throws -> [UUID: Int] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT profile_id, COUNT(*) as count FROM terminal
                WHERE kind = ? AND profile_id IS NOT NULL
                  AND hibernatedAt IS NULL AND suspendedAt IS NULL
                GROUP BY profile_id
                """, arguments: ["claude"])
            var result: [UUID: Int] = [:]
            for row in rows {
                if let profileIDStr: String = row["profile_id"],
                   let profileUUID = UUID(uuidString: profileIDStr),
                   let count: Int = row["count"] {
                    result[profileUUID] = count
                }
            }
            return result
        }
    }
}
