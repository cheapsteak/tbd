import Foundation

// MARK: - Delta Event Types

/// Represents a state change event that can be broadcast to subscribers.
public enum StateDelta: Codable, Sendable {
    case worktreeCreated(WorktreeDelta)
    case worktreeArchived(WorktreeIDDelta)
    case worktreeRevived(WorktreeDelta)
    case worktreeRenamed(WorktreeRenameDelta)
    case notificationReceived(NotificationDelta)
    case repoAdded(RepoDelta)
    case repoRemoved(RepoIDDelta)
    case repoRenamed(RepoRenameDelta)
    case repoHiddenChanged(RepoHiddenDelta)
    case repoExpandedChanged(RepoExpandedDelta)
    case terminalCreated(TerminalDelta)
    case terminalRemoved(TerminalIDDelta)
    case worktreeConflictsChanged(WorktreeConflictDelta)
    case terminalPinChanged(TerminalPinDelta)
    case worktreeReordered(RepoIDDelta)
    case modelProfileUsageUpdated(ModelProfileUsage)
    case modelProfilesChanged
    case terminalSessionUpdated(TerminalSessionDelta)
    case terminalActivityUpdated(TerminalActivityDelta)
    case terminalProfileChanged(TerminalProfileDelta)
    /// Explicit Watch Desk Judge/Read-only role markers changed. The app
    /// refetches that worktree's terminal rows; lease credentials stay daemon-side.
    case watchDeskRolesChanged(WorktreeIDDelta)
    case worktreeMoved(WorktreeMovedDelta)
    case terminalHibernationChanged(TerminalHibernationDelta)
    case controlModeInputHealthChanged(ControlModeInputHealthDelta)
    /// Fired when the orphan GC sweep reaps or restores a `ReapRecord`. No
    /// payload (mirrors `.modelProfilesChanged`) — subscribers refetch via
    /// `gc.list`.
    case reapRecordsChanged
    /// Committed panel-surface change for a worktree (Spec C §10.1). Carries
    /// full affected-tab snapshots + the originating operation ID so the app
    /// can dedupe its own RPC response against the subscription echo.
    case panelSurfaceChanged(PanelSurfaceDelta)
    /// Remote-backend mirror changed (sessions upserted/gone, or provider
    /// health changed). No payload (mirrors `.reapRecordsChanged`) —
    /// subscribers refetch via `remote.sessions` / `remote.providers`.
    case remoteSessionsChanged
    /// A remote session crossed a notify-worthy agent-state edge
    /// (→ waiting_input or → exited). Banner-only: remote sessions have no
    /// worktree, so this does not ride `NotificationDelta`.
    case remoteSessionAttention(RemoteSessionAttentionDelta)
}

/// Delta payload for a terminal's hibernation state change (hibernate / wake)
/// or a keep-warm pin toggle. Keeps the SAME terminal row — the app updates
/// `hibernatedAt`/`keepWarm` in place so the row's whisper indicator and the
/// action menu re-render without a full terminal refetch.
public struct TerminalHibernationDelta: Codable, Sendable {
    public let terminalID: UUID
    public let worktreeID: UUID
    /// True when the terminal is now hibernated; false when it was woken.
    public let hibernated: Bool
    /// Current keep-warm pin state (carried on every hibernation delta so a
    /// keep-warm toggle can reuse this same channel).
    public let keepWarm: Bool
    /// The terminal's CURRENT tmux window/pane ids, carried on wake so the app
    /// updates its cached row together with the un-park flag. Without them, a
    /// wake that RECREATED the window (post-reboot) flips `hibernated` first
    /// and the terminal view rebuilds keyed on the DEAD window id — the failed
    /// attach then triggers the dead-window recreate path, which kills the
    /// just-spawned claude and re-parks the row (wake flap). Optional with a
    /// nil default so payloads from older daemons still decode.
    public let tmuxWindowID: String?
    public let tmuxPaneID: String?
    /// The ANSI pane snapshot captured just before the park's kill, carried on
    /// hibernate so the app updates its cached row together with the
    /// `hibernated` flip. Without it, the parked TerminalPanelView — which
    /// materializes the instant `isParked` flips and reads `initialSnapshot`
    /// from the cached row ONCE at creation — sees a still-nil
    /// `suspendedSnapshot` and shows a blank pane; the snapshot arriving in
    /// the later `refreshTerminals` refetch never reaches the already-built
    /// view. Nil on wake deltas (the daemon's `clearHibernated` keeps the DB
    /// snapshot, so the app keeps its cached one too). Optional with a nil
    /// default so payloads from older daemons still decode.
    public let suspendedSnapshot: String?
    /// WHO parked the session (`.manual` / `.auto` / `.recovery`), carried on
    /// hibernate so the cached row has it between the delta and the next
    /// refetch. Wake-on-focus filters on this reason; without it a focus
    /// event landing in that gap could wrongly auto-wake a just-manually-
    /// parked session. Nil on wake deltas (the apply clears it, matching
    /// `clearHibernated`). Optional with a nil default so payloads from older
    /// daemons still decode.
    public let hibernateReason: HibernateReason?
    public init(
        terminalID: UUID, worktreeID: UUID, hibernated: Bool, keepWarm: Bool,
        tmuxWindowID: String? = nil, tmuxPaneID: String? = nil,
        suspendedSnapshot: String? = nil, hibernateReason: HibernateReason? = nil
    ) {
        self.terminalID = terminalID
        self.worktreeID = worktreeID
        self.hibernated = hibernated
        self.keepWarm = keepWarm
        self.tmuxWindowID = tmuxWindowID
        self.tmuxPaneID = tmuxPaneID
        self.suspendedSnapshot = suspendedSnapshot
        self.hibernateReason = hibernateReason
    }
}

/// Delta payload for a terminal's model-profile change that keeps the SAME
/// terminal row (the seamless in-place "Switch account" swap). The app updates
/// the row's `profileID` in place so its account chip re-renders without a full
/// terminal refetch. `newProfileID == nil` means the session switched to the
/// ambient (keychain/host) login.
public struct TerminalProfileDelta: Codable, Sendable {
    public let terminalID: UUID
    public let worktreeID: UUID
    public let newProfileID: UUID?
    public init(terminalID: UUID, worktreeID: UUID, newProfileID: UUID?) {
        self.terminalID = terminalID
        self.worktreeID = worktreeID
        self.newProfileID = newProfileID
    }
}

/// Delta payload for a control-mode input-delivery health transition (#318
/// polish ruling). EDGE-TRIGGERED by the daemon's `ControlModeInputRouter`:
/// one `healthy: false` when a pane's keystroke/paste delivery starts
/// failing, one `healthy: true` when a subsequent delivery succeeds — never
/// one per keystroke. The app shows/clears a passive "input not being
/// delivered" indicator on the affected pane; delivery plumbing stays
/// tolerant (nothing is torn down on failure).
public struct ControlModeInputHealthDelta: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    /// tmux pane id (`%N`) — only unique within one server, so it is always
    /// paired with `worktreeID` (same keying as `SidecarInputHeader`).
    public let paneID: String
    public let healthy: Bool
    /// Attach generation the health observation belongs to (R6-M7), stamped
    /// from the input route registered at attach time. The app applies a
    /// FAILING delta only when this matches its recorded attach generation —
    /// a stale attach's failure surfacing after a re-attach must not flag
    /// the fresh, healthy attach. Optional for wire back-compat: nil (older
    /// daemon, or a route registered without one) applies unchecked, as
    /// before. Recovery deltas clear regardless — clearing is always safe.
    public let generation: UInt64?
    public init(worktreeID: UUID, paneID: String, healthy: Bool, generation: UInt64? = nil) {
        self.worktreeID = worktreeID
        self.paneID = paneID
        self.healthy = healthy
        self.generation = generation
    }
}

/// Delta payload for Claude session ID/transcript path rollover, fired when
/// the SessionStart hook bridge reports a new session for an existing
/// terminal (e.g., post-`/clear`, `/compact`, or initial startup).
public struct TerminalSessionDelta: Codable, Sendable {
    public let terminalID: UUID
    public let worktreeID: UUID
    public let sessionID: String
    public let transcriptPath: String?
    public init(terminalID: UUID, worktreeID: UUID, sessionID: String, transcriptPath: String?) {
        self.terminalID = terminalID
        self.worktreeID = worktreeID
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
    }
}

public struct TerminalActivityDelta: Codable, Sendable {
    public let terminalID: UUID
    public let worktreeID: UUID
    public let activityState: TerminalActivityState
    public init(terminalID: UUID, worktreeID: UUID, activityState: TerminalActivityState) {
        self.terminalID = terminalID
        self.worktreeID = worktreeID
        self.activityState = activityState
    }
}

/// Delta payload for worktree creation/revival.
public struct WorktreeDelta: Codable, Sendable {
    public let worktreeID: UUID
    public let repoID: UUID?
    public let name: String
    public let path: String
    public let status: WorktreeStatus?
    public init(worktreeID: UUID, repoID: UUID?, name: String, path: String, status: WorktreeStatus? = nil) {
        self.worktreeID = worktreeID; self.repoID = repoID
        self.name = name; self.path = path; self.status = status
    }
}

/// Delta payload for worktree archive (just the ID).
public struct WorktreeIDDelta: Codable, Sendable {
    public let worktreeID: UUID
    /// True only when the daemon archived this row because its *creation*
    /// genuinely failed. Deliberate archives — CLI `tbd worktree archive`, the
    /// GUI menu, auto-archive-on-merge — leave it false.
    ///
    /// Clients must not infer creation failure from `status == .creating` at
    /// delta time: a `.creating` row can be archived deliberately (the CLI has
    /// no status guard, unlike the app's `archiveShortcutRoute`), and that
    /// legitimate cancel is indistinguishable from a git failure by status
    /// alone. Only the daemon knows which happened, so it says so here.
    public let creationFailed: Bool

    public init(worktreeID: UUID, creationFailed: Bool = false) {
        self.worktreeID = worktreeID
        self.creationFailed = creationFailed
    }

    // Explicit decoding: a synthesized `init(from:)` ignores property defaults
    // and would throw `keyNotFound` against an older daemon that never sends
    // this key. Absent means "not a creation failure".
    private enum CodingKeys: String, CodingKey {
        case worktreeID, creationFailed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.worktreeID = try c.decode(UUID.self, forKey: .worktreeID)
        self.creationFailed = try c.decodeIfPresent(Bool.self, forKey: .creationFailed) ?? false
    }
}

/// Delta payload for worktree rename.
public struct WorktreeRenameDelta: Codable, Sendable {
    public let worktreeID: UUID
    public let displayName: String
    public init(worktreeID: UUID, displayName: String) {
        self.worktreeID = worktreeID; self.displayName = displayName
    }
}

/// Delta payload for notification.
public struct NotificationDelta: Codable, Sendable {
    public let notificationID: UUID
    public let worktreeID: UUID
    public let type: NotificationType
    public let message: String?
    /// Optional terminal that triggered the notification. The app uses this
    /// to route a banner click to the originating tab. Nil when the
    /// notification didn't come from a specific terminal or from an older
    /// daemon that didn't include the field.
    public let terminalID: UUID?
    /// When true, the app foregrounds and selects the originating tab
    /// immediately (the `--activate` "loud" focus push). Defaults false so
    /// existing notify broadcasts and older daemons keep the soft behavior.
    public let activate: Bool
    public init(notificationID: UUID, worktreeID: UUID, type: NotificationType,
                message: String?, terminalID: UUID? = nil, activate: Bool = false) {
        self.notificationID = notificationID; self.worktreeID = worktreeID
        self.type = type; self.message = message
        self.terminalID = terminalID
        self.activate = activate
    }

    enum CodingKeys: String, CodingKey {
        case notificationID, worktreeID, type, message, terminalID, activate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notificationID = try c.decode(UUID.self, forKey: .notificationID)
        worktreeID = try c.decode(UUID.self, forKey: .worktreeID)
        type = try c.decode(NotificationType.self, forKey: .type)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        terminalID = try c.decodeIfPresent(UUID.self, forKey: .terminalID)
        activate = try c.decodeIfPresent(Bool.self, forKey: .activate) ?? false
    }
}

/// Delta payload for repo addition.
public struct RepoDelta: Codable, Sendable {
    public let repoID: UUID
    public let path: String
    public let displayName: String
    public init(repoID: UUID, path: String, displayName: String) {
        self.repoID = repoID; self.path = path; self.displayName = displayName
    }
}

/// Delta payload for repo removal (just the ID).
public struct RepoIDDelta: Codable, Sendable {
    public let repoID: UUID
    public init(repoID: UUID) { self.repoID = repoID }
}

/// Delta payload for repo rename.
public struct RepoRenameDelta: Codable, Sendable {
    public let repoID: UUID
    public let displayName: String
    public init(repoID: UUID, displayName: String) {
        self.repoID = repoID; self.displayName = displayName
    }
}

/// Delta payload for repo hidden-flag change.
public struct RepoHiddenDelta: Codable, Sendable {
    public let repoID: UUID
    public let hidden: Bool
    public init(repoID: UUID, hidden: Bool) {
        self.repoID = repoID; self.hidden = hidden
    }
}

/// Delta payload for repo expand/collapse change.
public struct RepoExpandedDelta: Codable, Sendable {
    public let repoID: UUID
    public let expanded: Bool
    public init(repoID: UUID, expanded: Bool) {
        self.repoID = repoID; self.expanded = expanded
    }
}

/// Delta payload for terminal creation.
public struct TerminalDelta: Codable, Sendable {
    public let terminalID: UUID
    public let worktreeID: UUID
    public let label: String?
    public init(terminalID: UUID, worktreeID: UUID, label: String?) {
        self.terminalID = terminalID; self.worktreeID = worktreeID; self.label = label
    }
}

/// Delta payload for terminal removal (just the ID).
public struct TerminalIDDelta: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

/// Delta payload for worktree conflict status change.
public struct WorktreeConflictDelta: Codable, Sendable {
    public let worktreeID: UUID
    public let hasConflicts: Bool
    public init(worktreeID: UUID, hasConflicts: Bool) {
        self.worktreeID = worktreeID; self.hasConflicts = hasConflicts
    }
}

/// Delta payload for terminal pin state change.
public struct TerminalPinDelta: Codable, Sendable {
    public let terminalID: UUID
    public let pinnedAt: Date?
    public init(terminalID: UUID, pinnedAt: Date?) {
        self.terminalID = terminalID; self.pinnedAt = pinnedAt
    }
}

public struct WorktreeMovedDelta: Codable, Sendable {
    public let worktreeID: UUID
    public let newParentID: UUID?
    public let newSortOrder: Int

    public init(worktreeID: UUID, newParentID: UUID?, newSortOrder: Int) {
        self.worktreeID = worktreeID
        self.newParentID = newParentID
        self.newSortOrder = newSortOrder
    }
}

/// Banner payload for a remote session needing attention. `kind` is the new
/// agent state's raw value ("waiting_input" | "exited").
public struct RemoteSessionAttentionDelta: Codable, Sendable {
    public let provider: String
    public let sessionID: String
    public let title: String?
    public let kind: String
    public let reason: String?
    /// The session's exit code at the moment this delta was raised, when
    /// `kind == "exited"` — carried on the delta itself so the app can
    /// classify error-vs-clean without racing the separate
    /// `.remoteSessionsChanged` mirror refresh (the two deltas are broadcast
    /// independently, and the attention delta can arrive first). Optional
    /// with a nil default so payloads from older daemons still decode; the
    /// app falls back to the mirror when nil.
    public let exitCode: Int?
    public init(provider: String, sessionID: String, title: String?, kind: String, reason: String?, exitCode: Int? = nil) {
        self.provider = provider; self.sessionID = sessionID
        self.title = title; self.kind = kind; self.reason = reason
        self.exitCode = exitCode
    }
}
