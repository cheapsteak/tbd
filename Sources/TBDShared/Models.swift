import Foundation

public enum RepoStatus: String, Codable, Sendable {
    case ok
    case missing
}

public struct Repo: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var path: String
    public var remoteURL: String?
    public var displayName: String
    public var defaultBranch: String
    public var createdAt: Date
    public var renamePrompt: String?
    public var customInstructions: String?
    public var profileOverrideID: UUID?
    public var worktreeSlot: String?
    public var worktreeRoot: String?
    public var status: RepoStatus
    public var hidden: Bool
    /// Whether the repo's worktree rows are shown in the sidebar. Defaults to
    /// expanded (true). Collapsing hides the main worktree row and all child
    /// worktree rows beneath the repo header.
    public var expanded: Bool
    /// Free-form env-var overrides applied to spawned sessions (repo scope).
    public var envOverrides: [String: String]

    public init(id: UUID = UUID(), path: String, remoteURL: String? = nil,
                displayName: String, defaultBranch: String = "main", createdAt: Date = Date(),
                renamePrompt: String? = nil, customInstructions: String? = nil,
                profileOverrideID: UUID? = nil,
                worktreeSlot: String? = nil, worktreeRoot: String? = nil,
                status: RepoStatus = .ok, hidden: Bool = false,
                expanded: Bool = true,
                envOverrides: [String: String] = [:]) {
        self.id = id
        self.path = path
        self.remoteURL = remoteURL
        self.displayName = displayName
        self.defaultBranch = defaultBranch
        self.createdAt = createdAt
        self.renamePrompt = renamePrompt
        self.customInstructions = customInstructions
        self.profileOverrideID = profileOverrideID
        self.worktreeSlot = worktreeSlot
        self.worktreeRoot = worktreeRoot
        self.status = status
        self.hidden = hidden
        self.expanded = expanded
        self.envOverrides = envOverrides
    }

    enum CodingKeys: String, CodingKey {
        case id, path, remoteURL, displayName, defaultBranch, createdAt
        case renamePrompt, customInstructions, profileOverrideID
        case worktreeSlot, worktreeRoot, status, hidden, expanded
        case envOverrides
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        remoteURL = try c.decodeIfPresent(String.self, forKey: .remoteURL)
        displayName = try c.decode(String.self, forKey: .displayName)
        defaultBranch = try c.decode(String.self, forKey: .defaultBranch)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        renamePrompt = try c.decodeIfPresent(String.self, forKey: .renamePrompt)
        customInstructions = try c.decodeIfPresent(String.self, forKey: .customInstructions)
        profileOverrideID = try c.decodeIfPresent(UUID.self, forKey: .profileOverrideID)
        worktreeSlot = try c.decodeIfPresent(String.self, forKey: .worktreeSlot)
        worktreeRoot = try c.decodeIfPresent(String.self, forKey: .worktreeRoot)
        status = try c.decodeIfPresent(RepoStatus.self, forKey: .status) ?? .ok
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded) ?? true
        envOverrides = try c.decodeIfPresent(
            [String: String].self, forKey: .envOverrides) ?? [:]
    }
}

public enum WorktreeStatus: String, Codable, Sendable {
    case active, archived, main, creating, failed
}

public enum TerminalKind: String, Codable, Sendable {
    case shell
    case claude
    case codex
}

public enum PrimaryAgentPreference: String, Codable, Sendable, Equatable, CaseIterable {
    case claude
    case codex

    public static let defaultValue: Self = .claude

    public var terminalKind: TerminalKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }
}

public enum NightwatchMode: String, Codable, Sendable, CaseIterable {
    case off
    case daywatch
    case nightwatch
}

public struct Worktree: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// nil for scratch spaces (repo-less worktrees).
    public var repoID: UUID?
    public var name: String
    public var displayName: String
    public var branch: String
    public var path: String
    public var status: WorktreeStatus
    public var hasConflicts: Bool = false
    public var createdAt: Date
    public var archivedAt: Date?
    public var tmuxServer: String
    public var archivedClaudeSessions: [String]?
    public var sortOrder: Int = 0
    /// HEAD SHA captured at archive time. Used as a fallback when reviving a
    /// worktree whose branch was renamed or deleted before archive ran.
    public var archivedHeadSHA: String?
    /// Transient enrichment populated by the daemon's `worktree.list` handler
    /// for archived worktrees: count of actual session JSONL files in the
    /// resolved Claude project directory. Not persisted in the DB. nil when
    /// not enriched (active worktrees, or archived worktrees whose Claude
    /// project dir could not be resolved).
    public var liveClaudeSessionCount: Int?
    public var parentWorktreeID: UUID?
    /// Per-worktree auto-archive-on-PR-merge override. `nil` = follow the
    /// global default (`Config.autoArchiveOnMergeDefault`); `true`/`false` =
    /// explicit. Only set explicitly by user action (toolbar toggle / CLI);
    /// there is no UI to return to `nil`.
    public var autoArchiveOnMerge: Bool?
    /// Last-known GitHub PR status, persisted in the DB so the PR icon survives
    /// app/daemon restarts. nil = never observed. Refreshed live by the daemon's
    /// PR poll; the app seeds from this only when it has no fresher live value.
    public var prStatus: PRStatus?

    /// Set only on promoted scratch rows: the repo created by `tbd scratch promote`.
    public var promotedToRepoID: UUID?

    /// A scratch space is a repo-less worktree. Derived — no separate column.
    public var isScratch: Bool { repoID == nil }

    /// True when `displayName` has never been customized away from the
    /// auto-generated `name`. Single source of truth for "still default"
    /// shared by the `stop-rename-check` hook (skip firing when already
    /// customized) and `scratch promote` (display-name fallback priority).
    public var hasDefaultDisplayName: Bool { displayName == name }

    public init(id: UUID = UUID(), repoID: UUID?, name: String, displayName: String,
                branch: String, path: String, status: WorktreeStatus = .active,
                hasConflicts: Bool = false,
                createdAt: Date = Date(), archivedAt: Date? = nil, tmuxServer: String,
                archivedClaudeSessions: [String]? = nil, sortOrder: Int = 0,
                archivedHeadSHA: String? = nil,
                liveClaudeSessionCount: Int? = nil,
                parentWorktreeID: UUID? = nil,
                autoArchiveOnMerge: Bool? = nil,
                promotedToRepoID: UUID? = nil,
                prStatus: PRStatus? = nil) {
        self.id = id
        self.repoID = repoID
        self.name = name
        self.displayName = displayName
        self.branch = branch
        self.path = path
        self.status = status
        self.hasConflicts = hasConflicts
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.tmuxServer = tmuxServer
        self.archivedClaudeSessions = archivedClaudeSessions
        self.sortOrder = sortOrder
        self.archivedHeadSHA = archivedHeadSHA
        self.liveClaudeSessionCount = liveClaudeSessionCount
        self.parentWorktreeID = parentWorktreeID
        self.autoArchiveOnMerge = autoArchiveOnMerge
        self.promotedToRepoID = promotedToRepoID
        self.prStatus = prStatus
    }

    enum CodingKeys: String, CodingKey {
        case id, repoID, name, displayName, branch, path, status
        case hasConflicts, createdAt, archivedAt, tmuxServer
        case archivedClaudeSessions, sortOrder, archivedHeadSHA
        case liveClaudeSessionCount, parentWorktreeID, autoArchiveOnMerge
        case promotedToRepoID, prStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        repoID = try c.decodeIfPresent(UUID.self, forKey: .repoID)
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decode(String.self, forKey: .displayName)
        branch = try c.decode(String.self, forKey: .branch)
        path = try c.decode(String.self, forKey: .path)
        status = try c.decode(WorktreeStatus.self, forKey: .status)
        hasConflicts = try c.decodeIfPresent(Bool.self, forKey: .hasConflicts) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        tmuxServer = try c.decode(String.self, forKey: .tmuxServer)
        archivedClaudeSessions = try c.decodeIfPresent([String].self, forKey: .archivedClaudeSessions)
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        archivedHeadSHA = try c.decodeIfPresent(String.self, forKey: .archivedHeadSHA)
        liveClaudeSessionCount = try c.decodeIfPresent(Int.self, forKey: .liveClaudeSessionCount)
        parentWorktreeID = try c.decodeIfPresent(UUID.self, forKey: .parentWorktreeID)
        autoArchiveOnMerge = try c.decodeIfPresent(Bool.self, forKey: .autoArchiveOnMerge)
        promotedToRepoID = try c.decodeIfPresent(UUID.self, forKey: .promotedToRepoID)
        prStatus = try c.decodeIfPresent(PRStatus.self, forKey: .prStatus)
    }
}

public enum TerminalActivityState: String, Codable, Sendable {
    case unknown
    case working
    case idle
    case waitingForUser = "waiting_for_user"
}
public struct Terminal: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var worktreeID: UUID
    public var tmuxWindowID: String
    public var tmuxPaneID: String
    public var label: String?
    public var createdAt: Date
    public var pinnedAt: Date?
    public var claudeSessionID: String?
    public var suspendedAt: Date?
    public var suspendedSnapshot: String?
    public var profileID: UUID?
    /// Absolute path to the JSONL file Claude is writing for the current
    /// session, captured via the SessionStart hook. Persisted so the
    /// transcript handler can re-target accurately across `/clear` and
    /// `/compact` rollovers (where Claude may pick a different
    /// `~/.claude/projects/` subdirectory than cwd would suggest).
    public var transcriptPath: String?
    public var kind: TerminalKind?
    public var activityState: TerminalActivityState
    /// When set, the terminal is HIBERNATED: its `claude` process was
    /// gracefully terminated to reclaim memory, but the tmux window (and its
    /// shell) is kept alive. `claudeSessionID` still points at the session to
    /// resume via `claude --resume` on wake. `nil` = not hibernated. Distinct
    /// from `suspendedAt` (which kills the tmux window's program entirely and
    /// snapshots the pane); a hibernated terminal keeps its live window.
    public var hibernatedAt: Date?
    /// User pin that exempts this terminal from auto-hibernation. `false` =
    /// eligible for the idle timer; `true` = the daemon never auto-hibernates
    /// it (manual "Hibernate now" still works). Persisted per-terminal.
    public var keepWarm: Bool

    public init(id: UUID = UUID(), worktreeID: UUID, tmuxWindowID: String,
                tmuxPaneID: String, label: String? = nil, createdAt: Date = Date(),
                pinnedAt: Date? = nil, claudeSessionID: String? = nil,
                suspendedAt: Date? = nil, suspendedSnapshot: String? = nil,
                profileID: UUID? = nil,
                transcriptPath: String? = nil,
                kind: TerminalKind? = nil,
                activityState: TerminalActivityState = .unknown,
                hibernatedAt: Date? = nil,
                keepWarm: Bool = false) {
        self.id = id
        self.worktreeID = worktreeID
        self.tmuxWindowID = tmuxWindowID
        self.tmuxPaneID = tmuxPaneID
        self.label = label
        self.createdAt = createdAt
        self.pinnedAt = pinnedAt
        self.claudeSessionID = claudeSessionID
        self.suspendedAt = suspendedAt
        self.suspendedSnapshot = suspendedSnapshot
        self.profileID = profileID
        self.transcriptPath = transcriptPath
        self.kind = kind
        self.activityState = activityState
        self.hibernatedAt = hibernatedAt
        self.keepWarm = keepWarm
    }

    enum CodingKeys: String, CodingKey {
        case id, worktreeID, tmuxWindowID, tmuxPaneID, label, createdAt
        case pinnedAt, claudeSessionID, suspendedAt, suspendedSnapshot, profileID, transcriptPath, kind
        case activityState
        case hibernatedAt, keepWarm
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        worktreeID = try c.decode(UUID.self, forKey: .worktreeID)
        tmuxWindowID = try c.decode(String.self, forKey: .tmuxWindowID)
        tmuxPaneID = try c.decode(String.self, forKey: .tmuxPaneID)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        suspendedAt = try c.decodeIfPresent(Date.self, forKey: .suspendedAt)
        suspendedSnapshot = try c.decodeIfPresent(String.self, forKey: .suspendedSnapshot)
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        kind = try c.decodeIfPresent(TerminalKind.self, forKey: .kind)
        activityState = try c.decodeIfPresent(TerminalActivityState.self, forKey: .activityState) ?? .unknown
        hibernatedAt = try c.decodeIfPresent(Date.self, forKey: .hibernatedAt)
        keepWarm = try c.decodeIfPresent(Bool.self, forKey: .keepWarm) ?? false
    }
}

public extension Terminal {
    var isCodexTerminal: Bool {
        kind == .codex || label == TerminalLabel.codex
    }

    /// True only for Claude terminals whose session can be resumed through
    /// Claude-specific lifecycle flows like suspend/resume and dead-window
    /// preservation.
    var isClaudeResumable: Bool {
        guard claudeSessionID != nil, !isCodexTerminal else { return false }
        return kind == .claude || kind == nil
    }

    /// True when the terminal is currently hibernated (claude process killed,
    /// tmux window kept alive). See `hibernatedAt`.
    var isHibernated: Bool { hibernatedAt != nil }

    /// Whether this terminal may be AUTO-hibernated by the idle timer right
    /// now. Encodes the hard safety rails (see `HibernationGate` for the
    /// idle-duration check, which needs the timeout + clock this pure property
    /// can't see):
    ///   - must be a resumable Claude session,
    ///   - not already hibernated or suspended,
    ///   - not pinned keep-warm,
    ///   - not actively running a turn (`.working`),
    ///   - not waiting on a permission prompt (`.waitingForUser` — a raised
    ///     hand; hibernating would eat it).
    /// Manual "Hibernate now" bypasses the keep-warm and idle checks but keeps
    /// the running/permission rails (see `isManuallyHibernatable`).
    var isAutoHibernationEligible: Bool {
        isManuallyHibernatable && !keepWarm
    }

    /// Whether a MANUAL "Hibernate now" may act on this terminal. Same rails as
    /// auto except keep-warm and idle-time don't apply — the user asked
    /// explicitly. Still refuses to hibernate an in-flight turn or a raised
    /// permission hand.
    var isManuallyHibernatable: Bool {
        guard isClaudeResumable else { return false }
        guard hibernatedAt == nil, suspendedAt == nil else { return false }
        switch activityState {
        case .working, .waitingForUser:
            return false
        case .idle, .unknown:
            return true
        }
    }
}

public enum CredentialKind: String, Codable, Sendable {
    case oauth
    case apiKey
    case bedrock
}

public struct ModelProfile: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var kind: CredentialKind
    /// Optional Anthropic-compatible endpoint URL. nil = use Claude default
    /// (i.e. don't set ANTHROPIC_BASE_URL when spawning).
    public var baseURL: String?
    /// Optional model id passed via ANTHROPIC_MODEL. nil = use Claude default.
    public var model: String?
    /// AWS region for Bedrock profiles (e.g. "us-west-2"). nil for non-Bedrock kinds.
    public var awsRegion: String?
    /// Named AWS profile to use for credential lookup. nil = use ambient credentials.
    public var awsProfile: String?
    /// Ordered list of fallback model ids (up to three) written into the Claude
    /// Code `fallbackModel` settings.json key, so spawned interactive sessions
    /// degrade to an alternate model on overload instead of hard-failing. The
    /// id namespace is profile-specific (bedrock/proxy/oauth differ), so this
    /// lives on the profile, not globally. nil/empty = no fallback configured.
    public var fallbackModels: [String]?
    /// Free-form env-var overrides applied to spawned sessions (profile scope).
    public var envOverrides: [String: String]
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), name: String, kind: CredentialKind,
                baseURL: String? = nil, model: String? = nil,
                awsRegion: String? = nil, awsProfile: String? = nil,
                fallbackModels: [String]? = nil,
                envOverrides: [String: String] = [:],
                createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.awsRegion = awsRegion
        self.awsProfile = awsProfile
        self.fallbackModels = fallbackModels
        self.envOverrides = envOverrides
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, model, awsRegion, awsProfile, fallbackModels
        case envOverrides, createdAt, lastUsedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(CredentialKind.self, forKey: .kind)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        awsRegion = try c.decodeIfPresent(String.self, forKey: .awsRegion)
        awsProfile = try c.decodeIfPresent(String.self, forKey: .awsProfile)
        fallbackModels = try c.decodeIfPresent([String].self, forKey: .fallbackModels)
        envOverrides = try c.decodeIfPresent(
            [String: String].self, forKey: .envOverrides) ?? [:]
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

public struct ModelProfileUsage: Codable, Sendable, Equatable {
    public var profileID: UUID
    public var fiveHourPct: Double?
    public var sevenDayPct: Double?
    public var fiveHourResetsAt: Date?
    public var sevenDayResetsAt: Date?
    public var fetchedAt: Date?
    public var lastStatus: String?

    public init(profileID: UUID, fiveHourPct: Double? = nil, sevenDayPct: Double? = nil,
                fiveHourResetsAt: Date? = nil, sevenDayResetsAt: Date? = nil,
                fetchedAt: Date? = nil, lastStatus: String? = nil) {
        self.profileID = profileID
        self.fiveHourPct = fiveHourPct
        self.sevenDayPct = sevenDayPct
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayResetsAt = sevenDayResetsAt
        self.fetchedAt = fetchedAt
        self.lastStatus = lastStatus
    }

    enum CodingKeys: String, CodingKey {
        case profileID, tokenID  // tokenID is the legacy key for one release window
        case fiveHourPct, sevenDayPct, fiveHourResetsAt, sevenDayResetsAt, fetchedAt, lastStatus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .profileID) {
            profileID = id
        } else {
            profileID = try c.decode(UUID.self, forKey: .tokenID)
        }
        fiveHourPct = try c.decodeIfPresent(Double.self, forKey: .fiveHourPct)
        sevenDayPct = try c.decodeIfPresent(Double.self, forKey: .sevenDayPct)
        fiveHourResetsAt = try c.decodeIfPresent(Date.self, forKey: .fiveHourResetsAt)
        sevenDayResetsAt = try c.decodeIfPresent(Date.self, forKey: .sevenDayResetsAt)
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profileID, forKey: .profileID)
        try c.encodeIfPresent(fiveHourPct, forKey: .fiveHourPct)
        try c.encodeIfPresent(sevenDayPct, forKey: .sevenDayPct)
        try c.encodeIfPresent(fiveHourResetsAt, forKey: .fiveHourResetsAt)
        try c.encodeIfPresent(sevenDayResetsAt, forKey: .sevenDayResetsAt)
        try c.encodeIfPresent(fetchedAt, forKey: .fetchedAt)
        try c.encodeIfPresent(lastStatus, forKey: .lastStatus)
    }
}

/// One rate-limit bucket from the Claude OAuth usage API's `limits[]` array
/// (`GET https://api.anthropic.com/api/oauth/usage`). Captured as data —
/// unknown `kind` values flow through untouched so new API buckets appear
/// without a code change.
///
/// Observed kinds (2026-07): `session` (5-hour window), `weekly_all`
/// (weekly, all models), `weekly_scoped` (weekly, one model family —
/// `modelDisplayName` carries the family label, e.g. "Fable").
public struct ClaudeUsageLimitBucket: Codable, Sendable, Equatable {
    /// Bucket identifier as the API names it (`session`, `weekly_all`,
    /// `weekly_scoped`, or a future kind).
    public var kind: String
    /// Grouping label from the API (`session`, `weekly`). nil if absent.
    public var group: String?
    /// Utilization percent on a 0–100 scale.
    public var percent: Double
    /// Severity label from the API (`normal`, `warning`, `critical`). nil if absent.
    public var severity: String?
    /// When this window resets. nil when the API sends null (e.g. an unused
    /// scoped bucket).
    public var resetsAt: Date?
    /// For scoped buckets: `scope.model.display_name` (e.g. "Fable").
    /// nil = bucket is not model-scoped.
    public var modelDisplayName: String?
    /// The API's `is_active` flag (which limit is currently binding). nil if absent.
    public var isActive: Bool?

    public init(kind: String, group: String? = nil, percent: Double,
                severity: String? = nil, resetsAt: Date? = nil,
                modelDisplayName: String? = nil, isActive: Bool? = nil) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.modelDisplayName = modelDisplayName
        self.isActive = isActive
    }
}

/// In-memory per-profile usage snapshot for logged-in OAuth profiles,
/// maintained by the daemon's background poller (never persisted).
public struct ProfileUsageSnapshot: Codable, Sendable, Equatable {
    /// Buckets from the last successful fetch (empty if none succeeded yet).
    public var buckets: [ClaudeUsageLimitBucket]
    /// When the buckets were last successfully fetched. nil = never.
    public var fetchedAt: Date?
    /// When a fetch was last attempted (success or failure).
    public var lastAttemptAt: Date
    /// "ok", or a failure description like
    /// "stale since 2026-07-03T18:00:00Z; fetch failed: HTTP 401".
    public var status: String

    public init(buckets: [ClaudeUsageLimitBucket], fetchedAt: Date? = nil,
                lastAttemptAt: Date, status: String) {
        self.buckets = buckets
        self.fetchedAt = fetchedAt
        self.lastAttemptAt = lastAttemptAt
        self.status = status
    }

    public var isOK: Bool { status == "ok" }
}

public struct ModelProfileWithUsage: Codable, Sendable, Equatable {
    public let profile: ModelProfile
    public let usage: ModelProfileUsage?
    /// Computed by the daemon at list time (never persisted): the
    /// `oauthAccount.emailAddress` from the profile's isolated config dir
    /// `.claude.json`. Non-nil only for `.oauth` profiles that have completed
    /// `/login` inside a session. nil = not logged in, non-oauth kind, or an
    /// older daemon that doesn't send the field.
    public let loginIdentity: String?
    /// Absolute path of the profile's isolated `CLAUDE_CONFIG_DIR`
    /// (`~/tbd/profiles/<lowercased-uuid>/claude`). nil for bedrock profiles
    /// (no config-dir isolation) or an older daemon that doesn't send the field.
    public let configDirPath: String?
    /// Cached per-profile usage snapshot from the daemon's in-memory OAuth
    /// usage poller. Non-nil only for logged-in `.oauth` profiles once the
    /// poller has attempted a fetch. nil = non-oauth kind, not logged in, or
    /// an older daemon that doesn't send the field.
    public let usageSnapshot: ProfileUsageSnapshot?
    public init(profile: ModelProfile, usage: ModelProfileUsage? = nil,
                loginIdentity: String? = nil, configDirPath: String? = nil,
                usageSnapshot: ProfileUsageSnapshot? = nil) {
        self.profile = profile
        self.usage = usage
        self.loginIdentity = loginIdentity
        self.configDirPath = configDirPath
        self.usageSnapshot = usageSnapshot
    }
}


public struct Config: Codable, Sendable, Equatable {
    public var defaultProfileID: UUID?
    public var primaryAgentPreference: PrimaryAgentPreference
    /// Claude spawn-env setting overrides, keyed by `ClaudeEnvSetting.id`.
    public var envSettingOverrides: [String: ClaudeEnvValue]
    /// Free-form env-var overrides applied to spawned sessions (global scope).
    public var envOverrides: [String: String]
    /// Global default for auto-archive-on-PR-merge, applied to worktrees whose
    /// per-worktree override is `nil`.
    public var autoArchiveOnMergeDefault: Bool
    /// Global, user-customizable system-prompt layer for scratch spaces
    /// (repo-less worktrees). `nil` means "use the built-in default"
    /// (`RepoConstants.defaultScratchInstructions`).
    public var scratchInstructions: String?
    /// Global, user-customizable override for the scratch-space rename-nudge
    /// system-prompt layer. `nil` means "use the built-in default"
    /// (`RepoConstants.defaultScratchRenamePrompt`).
    public var scratchRenamePrompt: String?
    /// Global model-profile override applied to scratch (repo-less) terminal
    /// spawns. `nil` means "fall back to the global default profile"
    /// (`defaultProfileID`).
    public var scratchProfileOverrideID: UUID?
    /// Nightwatch mode flag: off, daywatch, or nightwatch.
    public var nightwatchMode: NightwatchMode
    /// Master switch for the daemon-side auto-hibernate idle timer. Default
    /// ON: idle Claude sessions are auto-hibernated to reclaim memory (their
    /// prompt cache has already expired, so resume is cheap). When false, only
    /// manual "Hibernate now" hibernates.
    public var autoHibernateEnabled: Bool
    /// Minutes a Claude session must sit idle-at-rest before the auto-hibernate
    /// timer terminates its process. Clamped to a sane floor by the daemon.
    public var hibernateIdleMinutes: Int

    /// Default idle-timeout for auto-hibernation, in minutes.
    public static let defaultHibernateIdleMinutes = 30

    public init(defaultProfileID: UUID? = nil,
                primaryAgentPreference: PrimaryAgentPreference = .defaultValue,
                envSettingOverrides: [String: ClaudeEnvValue] = [:],
                envOverrides: [String: String] = [:],
                autoArchiveOnMergeDefault: Bool = false,
                scratchInstructions: String? = nil,
                scratchRenamePrompt: String? = nil,
                scratchProfileOverrideID: UUID? = nil,
                nightwatchMode: NightwatchMode = .off,
                autoHibernateEnabled: Bool = true,
                hibernateIdleMinutes: Int = Config.defaultHibernateIdleMinutes) {
        self.defaultProfileID = defaultProfileID
        self.primaryAgentPreference = primaryAgentPreference
        self.envSettingOverrides = envSettingOverrides
        self.envOverrides = envOverrides
        self.autoArchiveOnMergeDefault = autoArchiveOnMergeDefault
        self.scratchInstructions = scratchInstructions
        self.scratchRenamePrompt = scratchRenamePrompt
        self.scratchProfileOverrideID = scratchProfileOverrideID
        self.nightwatchMode = nightwatchMode
        self.autoHibernateEnabled = autoHibernateEnabled
        self.hibernateIdleMinutes = hibernateIdleMinutes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultProfileID = try c.decodeIfPresent(UUID.self, forKey: .defaultProfileID)
        primaryAgentPreference = try c.decodeIfPresent(
            PrimaryAgentPreference.self,
            forKey: .primaryAgentPreference
        ) ?? .defaultValue
        envSettingOverrides = try c.decodeIfPresent(
            [String: ClaudeEnvValue].self, forKey: .envSettingOverrides) ?? [:]
        envOverrides = try c.decodeIfPresent(
            [String: String].self, forKey: .envOverrides) ?? [:]
        autoArchiveOnMergeDefault = try c.decodeIfPresent(
            Bool.self, forKey: .autoArchiveOnMergeDefault) ?? false
        scratchInstructions = try c.decodeIfPresent(String.self, forKey: .scratchInstructions) ?? nil
        scratchRenamePrompt = try c.decodeIfPresent(String.self, forKey: .scratchRenamePrompt) ?? nil
        scratchProfileOverrideID = try c.decodeIfPresent(UUID.self, forKey: .scratchProfileOverrideID)
        nightwatchMode = try c.decodeIfPresent(
            NightwatchMode.self, forKey: .nightwatchMode) ?? .off
        autoHibernateEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoHibernateEnabled) ?? true
        hibernateIdleMinutes = try c.decodeIfPresent(Int.self, forKey: .hibernateIdleMinutes)
            ?? Config.defaultHibernateIdleMinutes
    }
}

public struct Note: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var worktreeID: UUID
    public var title: String
    public var content: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), worktreeID: UUID, title: String,
                content: String = "", createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.worktreeID = worktreeID
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum NotificationType: String, Codable, Sendable {
    case responseComplete = "response_complete"
    case error
    case taskComplete = "task_complete"
    case attentionNeeded = "attention_needed"
    /// A focus push from `tbd terminal focus`. Rendered like `.attentionNeeded`
    /// in-app; the macOS banner adds a distinguishing title prefix.
    case focusRequest = "focus_request"

    public var severity: Int {
        switch self {
        case .error: 4
        case .attentionNeeded: 3
        case .focusRequest: 3
        case .taskComplete: 2
        case .responseComplete: 1
        }
    }
}

public struct TBDNotification: Codable, Sendable, Identifiable {
    public let id: UUID
    public var worktreeID: UUID
    public var type: NotificationType
    public var message: String?
    public var read: Bool
    public var createdAt: Date
    /// Optional terminal that triggered the notification. When present, the
    /// app can route a banner click to the originating tab rather than just
    /// selecting the worktree. Nil for older rows or for notifications that
    /// don't originate from a specific terminal.
    public var terminalID: UUID?

    public init(id: UUID = UUID(), worktreeID: UUID, type: NotificationType,
                message: String? = nil, read: Bool = false, createdAt: Date = Date(),
                terminalID: UUID? = nil) {
        self.id = id
        self.worktreeID = worktreeID
        self.type = type
        self.message = message
        self.read = read
        self.createdAt = createdAt
        self.terminalID = terminalID
    }

    enum CodingKeys: String, CodingKey {
        case id, worktreeID, type, message, read, createdAt, terminalID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        worktreeID = try c.decode(UUID.self, forKey: .worktreeID)
        type = try c.decode(NotificationType.self, forKey: .type)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        read = try c.decodeIfPresent(Bool.self, forKey: .read) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        terminalID = try c.decodeIfPresent(UUID.self, forKey: .terminalID)
    }
}

/// Per-worktree summary of unread notifications. Returned by
/// `NotificationStore.unreadSummaryByWorktree()` and surfaced through the
/// `listNotifications` RPC so the app can render severity badges AND sort
/// the cmd-K jump menu by most-recent-notification time.
public struct UnreadSummary: Codable, Sendable, Equatable {
    public let type: NotificationType
    public let mostRecentAt: Date

    public init(type: NotificationType, mostRecentAt: Date) {
        self.type = type
        self.mostRecentAt = mostRecentAt
    }
}

public enum PRMergeableState: String, Codable, Sendable {
    case pending            // PR exists, but mergeability/checks are still computing
    case blocked            // PR is known to be not currently mergeable
    case changesRequested   // reviewer requested changes
    case draft              // PR exists, but is marked draft
    case checksFailed       // PR has failing CI/status checks
    case mergeable          // GitHub considers it clean (checks + reviews satisfied)
    case merged             // PR was merged
    case closed             // PR was closed without merging

    /// Human-readable reason for this state (fallback when PRStatus.reason is nil).
    public var displayReason: String {
        switch self {
        case .pending:          return "Checks pending"
        case .blocked:          return "Blocked"
        case .changesRequested: return "Changes requested"
        case .draft:            return "Draft"
        case .checksFailed:     return "Checks failing"
        case .mergeable:        return "Ready to merge"
        case .merged:           return "Merged"
        case .closed:           return "Closed"
        }
    }
}

public struct PRStatus: Codable, Sendable, Equatable {
    public let number: Int
    public let url: String
    public let state: PRMergeableState
    public let reason: String?

    public init(number: Int, url: String, state: PRMergeableState, reason: String? = nil) {
        self.number = number
        self.url = url
        self.state = state
        self.reason = reason
    }
}

// MARK: - SessionSummary

public struct SessionSummary: Codable, Sendable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let filePath: String
    public let modifiedAt: Date
    public let fileSize: Int64
    public let lineCount: Int
    public let firstUserMessage: String?
    public let lastUserMessage: String?
    public let cwd: String?
    public let gitBranch: String?
    /// Timestamp of the last message in the session (from JSONL), falls back to file mtime.
    public let lastMessageAt: Date

    public init(
        sessionId: String,
        filePath: String,
        modifiedAt: Date,
        fileSize: Int64,
        lineCount: Int,
        firstUserMessage: String?,
        lastUserMessage: String?,
        cwd: String?,
        gitBranch: String?,
        lastMessageAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.filePath = filePath
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        self.lineCount = lineCount
        self.firstUserMessage = firstUserMessage
        self.lastUserMessage = lastUserMessage
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.lastMessageAt = lastMessageAt ?? modifiedAt
    }
}

// MARK: - Session Messages Params

public struct SessionMessagesParams: Codable, Sendable {
    public let filePath: String
    public init(filePath: String) { self.filePath = filePath }
}

// MARK: - Transcript Items (rich rendering)

public enum SystemKind: String, Codable, Sendable, Equatable, Hashable {
    case toolReminder
    case hookOutput
    case environmentDetails
    case slashEnvelope
    case skillBody
    case taskNotification
    case other
}

public struct ToolResult: Codable, Sendable, Equatable, Hashable {
    public let text: String
    public let truncatedTo: Int?
    public let isError: Bool
    public init(text: String, truncatedTo: Int?, isError: Bool) {
        self.text = text
        self.truncatedTo = truncatedTo
        self.isError = isError
    }
}

public struct Subagent: Codable, Sendable, Equatable, Hashable {
    public let agentID: String
    public let agentType: String?
    public let items: [TranscriptItem]
    public init(agentID: String, agentType: String?, items: [TranscriptItem]) {
        self.agentID = agentID
        self.agentType = agentType
        self.items = items
    }
}

/// Token-count snapshot from a single Claude API response, captured per
/// assistant JSONL line. The three fields together represent the size of
/// the prompt sent on that request — see docs/transcript-context-usage.md
/// for the meaning of each.
public struct TokenUsage: Codable, Sendable, Equatable, Hashable {
    public let inputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int

    public init(inputTokens: Int, cacheCreationTokens: Int, cacheReadTokens: Int) {
        self.inputTokens = inputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
    }

    /// Total prompt size for this request — what `/context` reports.
    public var contextTotal: Int {
        inputTokens + cacheCreationTokens + cacheReadTokens
    }
}

public indirect enum TranscriptItem: Codable, Sendable, Identifiable, Equatable, Hashable {
    case userPrompt(id: String, text: String, timestamp: Date?)
    case assistantText(id: String, text: String, timestamp: Date?, usage: TokenUsage? = nil)
    case toolCall(id: String, name: String, inputJSON: String,
                  inputTruncatedTo: Int?,
                  result: ToolResult?, subagent: Subagent?, timestamp: Date?,
                  usage: TokenUsage? = nil)
    case thinking(id: String, text: String, timestamp: Date?)
    case systemReminder(id: String, kind: SystemKind, text: String, timestamp: Date?)
    case slashCommand(id: String, name: String, args: String?, timestamp: Date?)

    public var id: String {
        switch self {
        case .userPrompt(let id, _, _): return id
        case .assistantText(let id, _, _, _): return id
        case .toolCall(let id, _, _, _, _, _, _, _): return id
        case .thinking(let id, _, _): return id
        case .systemReminder(let id, _, _, _): return id
        case .slashCommand(let id, _, _, _): return id
        }
    }

    public var timestamp: Date? {
        switch self {
        case .userPrompt(_, _, let t),
             .assistantText(_, _, let t, _),
             .toolCall(_, _, _, _, _, _, let t, _),
             .thinking(_, _, let t),
             .systemReminder(_, _, _, let t),
             .slashCommand(_, _, _, let t):
            return t
        }
    }

    /// The `TokenUsage` stamped on items derived from an assistant API call,
    /// `nil` for all other item kinds. Used by `TranscriptItemsView` to find
    /// the latest item whose context size is worth surfacing in the UI.
    public var usage: TokenUsage? {
        switch self {
        case .assistantText(_, _, _, let u): return u
        case .toolCall(_, _, _, _, _, _, _, let u): return u
        default: return nil
        }
    }
}

// MARK: - ModelProfile display

extension ModelProfile {
    /// Short capsule label for the kind badge.
    public var kindLabel: String {
        switch kind {
        case .oauth:   return "OAuth"
        case .apiKey:  return baseURL != nil ? "Proxy" : "API key"
        case .bedrock: return "Bedrock"
        }
    }

    /// Secondary detail line. `nil` when there's nothing useful to show
    /// beyond the kind badge (a plain direct api-key profile).
    public var detailCaption: String? {
        switch kind {
        case .oauth:
            // OAuth profiles need a one-time /login to establish credentials
            // in the isolated config dir. Show this hint even for simple OAuth,
            // plus the pinned model (if any) so the Edit sheet's effect is visible.
            var parts = ["Run /login once"]
            if let baseURL { parts.append("via \(baseURL)") }
            if let model, !model.isEmpty { parts.append(model) }
            return parts.joined(separator: " · ")
        case .apiKey:
            guard let baseURL else {
                // Direct api-key profile: nothing to show unless a model is pinned.
                if let model, !model.isEmpty { return model }
                return nil
            }
            if let model, !model.isEmpty { return "via \(baseURL) · \(model)" }
            return "via \(baseURL)"
        case .bedrock:
            let region = awsRegion ?? "?"
            if let model, !model.isEmpty { return "\(region) · \(model)" }
            return region
        }
    }

    /// What goes in a tab title, menu item, or anywhere we render the profile
    /// as a single line. Today just `name`; the seam exists for future
    /// per-kind divergence.
    public var tabDisplayName: String { name }
}

// MARK: - Tab Metadata

/// Per-tab metadata persisted in the daemon DB. A row exists only when
/// a tab has user-set metadata; absence means "use auto-derived defaults".
public struct TabState: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var worktreeID: UUID
    public var label: String?
    public var createdAt: Date

    public init(id: UUID, worktreeID: UUID, label: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.worktreeID = worktreeID
        self.label = label
        self.createdAt = createdAt
    }
}
