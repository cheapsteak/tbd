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
    /// Remote create-param defaults for this repo, keyed by the **provider's
    /// own** `create_params` field names. TBD stores and replays these values
    /// without interpreting what any of them mean — keying on the provider's
    /// vocabulary is what keeps a provider concept (`permission_mode`, say)
    /// out of TBD's schema.
    ///
    /// An absent key means "no opinion at this level": resolution falls
    /// through to the global map, then to the field's provider-declared
    /// `default` (see `RemoteCreateFormLogic.plan`).
    public var remoteCreateDefaults: [String: String]

    public init(id: UUID = UUID(), path: String, remoteURL: String? = nil,
                displayName: String, defaultBranch: String = "main", createdAt: Date = Date(),
                renamePrompt: String? = nil, customInstructions: String? = nil,
                profileOverrideID: UUID? = nil,
                worktreeSlot: String? = nil, worktreeRoot: String? = nil,
                status: RepoStatus = .ok, hidden: Bool = false,
                expanded: Bool = true,
                envOverrides: [String: String] = [:],
                remoteCreateDefaults: [String: String] = [:]) {
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
        self.remoteCreateDefaults = remoteCreateDefaults
    }

    enum CodingKeys: String, CodingKey {
        case id, path, remoteURL, displayName, defaultBranch, createdAt
        case renamePrompt, customInstructions, profileOverrideID
        case worktreeSlot, worktreeRoot, status, hidden, expanded
        case envOverrides, remoteCreateDefaults
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
        // Absent (older daemon, older persisted JSON) means the sender knew
        // nothing about repo-scoped create defaults, which is the same state
        // as an empty map: no opinion, defer to the global map.
        remoteCreateDefaults = try c.decodeIfPresent(
            [String: String].self, forKey: .remoteCreateDefaults) ?? [:]
    }
}

public enum WorktreeStatus: String, Codable, Sendable {
    case active, archived, main, creating, failed
}

public enum TerminalKind: String, Codable, Sendable {
    case shell
    case claude
    case codex

    /// Whether a terminal of this kind hosts an agent session — one with a
    /// transcript, a context window, and hooks that report state.
    ///
    /// A plain shell has none of those, so a surface that describes agent
    /// sessions must not describe it: a report explaining that a shell's
    /// context window is unknown because no statusline tee fired is a true
    /// sentence about a session that was never going to have one, and the stat
    /// and transcript-tail attempt behind it are paid every cycle for nothing.
    public var isAgentBearing: Bool { self != .shell }
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

/// The compiled provider's reserved name. Reserved **unconditionally** and not
/// behind the cloud flag: a name that became available when a feature was off
/// and unavailable when it was turned on would change which providers load as a
/// side effect of a toggle.
public enum ClaudeCloudProvider {
    public static let name = "claude-cloud"
}

/// Where a worktree's files live. `.local` means a git worktree on this
/// machine at the worktree's path. `.remote` means an agent session on a
/// machine TBD does not manage, reached through a registered provider; there is
/// no local checkout and no tmux server.
public enum WorktreeLocation: Equatable, Sendable, Hashable {
    case local
    case remote(provider: String, sessionID: String)

    public var isLocal: Bool { self == .local }

    /// The value a row of this location stores in `worktree.path`, or nil when
    /// the caller supplies the path itself.
    ///
    /// nil for `.local`: a local row's path is a real directory on this disk
    /// and only the caller knows it.
    ///
    /// Non-nil for `.remote`, because `worktree.path` is `NOT NULL UNIQUE` and
    /// a remote row has no path of its own. The empty string works for exactly
    /// one remote row — the second lane in a fan-out aborts on the constraint.
    /// A synthetic `remote://<provider>/<sessionID>` URI is unique per session
    /// and visibly not a filesystem path, so a row that ever leaks into
    /// path-consuming code fails loudly rather than silently operating on the
    /// current directory.
    ///
    /// Provider names and session IDs are provider-supplied strings that may
    /// contain `/` or other delimiters, so each component is percent-encoded
    /// against RFC 3986's unreserved set. That encoding is injective and the
    /// separator cannot survive it, so distinct `(provider, sessionID)` pairs
    /// always yield distinct paths.
    public var storagePath: String? {
        switch self {
        case .local:
            return nil
        case .remote(let provider, let sessionID):
            return "remote://\(Self.pathEscaped(provider))/\(Self.pathEscaped(sessionID))"
        }
    }

    /// RFC 3986's unreserved set; everything else is percent-encoded.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func pathEscaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: unreserved) ?? component
    }
}

/// Which provider session a lane came from, independent of where its files are
/// now. `WorktreeLocation` answers the second question; this answers the first,
/// and a landed lane needs both — `.local` files with the cloud session it was
/// reconstructed from. Kept a separate field rather than a payload on
/// `.local` so every existing `switch` over `WorktreeLocation` across the
/// daemon and the app compiles untouched.
public struct WorktreeOrigin: Codable, Equatable, Hashable, Sendable {
    public let provider: String
    public let sessionID: String
    public init(provider: String, sessionID: String) {
        self.provider = provider
        self.sessionID = sessionID
    }
}

public extension WorktreeLocation {
    /// The origin a `.remote` location implies, or nil for `.local`. Used to
    /// default `Worktree.origin` so a `.remote` row satisfies the
    /// "remote implies an origin" invariant by construction.
    var originPair: WorktreeOrigin? {
        guard case let .remote(provider, sessionID) = self else { return nil }
        return WorktreeOrigin(provider: provider, sessionID: sessionID)
    }
}

public struct Worktree: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// nil for scratch spaces (repo-less worktrees).
    public var repoID: UUID?
    public var name: String
    public var displayName: String
    public var branch: String
    /// Absolute path to the git worktree directory on THIS machine. Named
    /// `localPath` rather than `path` so that every read of it is visibly a
    /// local-only assumption; code that must work for any worktree goes
    /// through `LocalWorktree` instead. The wire key and the DB column both
    /// stay `path`.
    ///
    /// On a remote row this is not a filesystem path at all but the synthetic
    /// `remote://` URI from `WorktreeLocation.storagePath`, which exists only
    /// to satisfy the column's `NOT NULL UNIQUE` constraint.
    public var localPath: String
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
    /// Per-worktree auto-hibernate-on-PR-merge override. `nil` = follow the
    /// global default (`Config.autoHibernateOnMergeDefault`); `true`/`false` =
    /// explicit. Only set explicitly by user action (toolbar toggle / CLI);
    /// there is no UI to return to `nil`.
    public var autoHibernateOnMerge: Bool?
    /// Last-known GitHub PR status, persisted in the DB so the PR icon survives
    /// app/daemon restarts. nil = never observed. Refreshed live by the daemon's
    /// PR poll; the app seeds from this only when it has no fresher live value.
    public var prStatus: PRStatus?

    /// The outcome of the last attempt to learn this worktree's PR state,
    /// separate from `prStatus` (the value that attempt found, if any).
    ///
    /// `prStatus == nil` cannot distinguish "the forge answered; no PR on this
    /// branch" from "the query failed"; this can. `nil` here means no attempt
    /// has been recorded since the column existed.
    public var prObservation: PRObservation?

    /// Set only on promoted scratch rows: the repo created by `tbd scratch promote`.
    public var promotedToRepoID: UUID?

    /// Number of the GitHub PR this worktree was created from, if any. `nil` for
    /// worktrees created from a plain branch. Lets `PRStatusManager` resolve
    /// status by direct number lookup — the only way fork PRs (no matching
    /// local branch) get tracked.
    public var prNumber: Int?

    /// True when this worktree's *contents* were checked out from a ref TBD
    /// cannot vouch for — today, a `refs/pull/<n>/head` fetch of a PR whose
    /// commits may come from a third-party fork. TBD created the directory, but
    /// a stranger authored what is in it (`.claude/settings.json`, hooks, MCP
    /// config, `CLAUDE.md`), so the folder-trust question does *not* have a
    /// known answer and `ClaudeTrustSeeder` must not pre-answer it.
    ///
    /// Set only by the PR-head checkout branch of `completeCreateWorktree`.
    /// `false` for everything else — including a *decorated* same-repo PR row,
    /// which stamps `prNumber` for status tracking but checks out an ordinary
    /// local branch, so it stays seedable.
    public var foreignHead: Bool = false

    /// When this worktree was pinned to the sidebar dock; `nil` = unpinned.
    /// Purely a UI affordance — the daemon stores it but never acts on it.
    /// Ordering in the dock is ascending by this timestamp, so new pins append.
    public var pinnedAt: Date?

    /// Position in the sidebar dock's pinned list, ascending. `nil` = never
    /// explicitly ordered, in which case the dock falls back to `pinnedAt`
    /// order — which is what lets the column ship with no backfill.
    public var pinSortOrder: Int?

    /// Where this worktree's files live. Rows written before v70 decode as
    /// `.local`, which is what they are.
    public var location: WorktreeLocation = .local

    /// Which provider session this lane came from, past or present. Nil for a
    /// lane that never had one. Rows written before this field decode their
    /// origin from the same two wire keys `location` uses.
    public var origin: WorktreeOrigin?

    /// The `(provider, sessionID)` pair identifying this row's provider
    /// session, or nil when the row never had one. Reads `origin` rather than
    /// `location`, so it keeps meaning "the provider session behind this row"
    /// across a landing.
    public var providerBinding: (provider: String, sessionID: String)? {
        guard let origin else { return nil }
        return (origin.provider, origin.sessionID)
    }
    /// Text the operator composed at creation time and parked for the primary
    /// agent, `nil` when nothing is parked
    /// (`docs/specs/2026-08-10-queued-prompt-on-create-design.md`). Durable, so
    /// it survives the `preSession` window it exists to fill, a daemon restart,
    /// and a failed delivery — it is cleared on confirmed delivery and on
    /// nothing else, which makes the column the recovery store too.
    ///
    /// Not a queue: parking a second prompt replaces the first.
    public var pendingPrompt: String?

    /// True once this row has been given a parent — by adoption at mint time,
    /// by adoption healing a parentless row later, or by the user's own move.
    /// It is the fact `parentWorktreeID == nil` cannot carry: a nil edge on a
    /// marked row means somebody already placed this lane and then took the
    /// parent away, and adoption must leave it alone. `false` on every local
    /// row and on every remote row nobody has ever placed; no path clears it,
    /// because re-nesting after a deliberate un-nest is the bug it exists to
    /// prevent.
    public var remoteParentAssigned: Bool = false

    /// Whether delivering `pendingPrompt` ends with Enter, as recorded. `nil`
    /// on any row saved without naming the bit — the initializer defaults it to
    /// nil and `WorktreeRecord` writes that through as SQL NULL, which is what
    /// an ordinarily created worktree row holds. It is never `nil` alongside a
    /// prompt: `setPendingPrompt` is the only writer of either column and names
    /// both. Nobody resolves this optional at a call site: read
    /// `pendingPromptSubmitResolved` instead.
    /// Unlike `Config.queuedPromptEnabled` this is data rather than a feature
    /// gate — there is no third state to preserve, so its column carries an
    /// ordinary SQL default.
    public var pendingPromptSubmit: Bool?

    /// **The** resolution of `pendingPromptSubmit` — the one the delivery path
    /// acts on and the one every display surface must state. A single property
    /// so the two cannot answer differently about the same row: a read-back
    /// promising Enter over a prompt the daemon will merely stage is precisely
    /// the misreport the read-back exists to prevent.
    ///
    /// Absent resolves to `false`. Submitting is opt-in, and a row with nothing
    /// recorded is a prompt nobody asked to send; the asymmetry settles it —
    /// staging costs the operator one keypress, while an unasked-for turn
    /// cannot be taken back.
    public var pendingPromptSubmitResolved: Bool { pendingPromptSubmit ?? false }

    /// A scratch space is a repo-less worktree. Derived — no separate column.
    public var isScratch: Bool { repoID == nil }

    /// The mode-managed Watch Desk scratch worktree, identified by its fixed
    /// display name. Not user-pinnable — the sidebar's Day/Night toggle controls
    /// whether it is shown. Single definition shared by the dock's desk slot and
    /// the row-action menu's pin suppression, so the two cannot drift.
    public var isNightwatchDesk: Bool {
        isScratch && displayName == NightwatchDeskPrompts.deskDisplayName
    }

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
                autoHibernateOnMerge: Bool? = nil,
                promotedToRepoID: UUID? = nil,
                prStatus: PRStatus? = nil,
                prNumber: Int? = nil,
                foreignHead: Bool = false,
                pinnedAt: Date? = nil,
                pinSortOrder: Int? = nil,
                location: WorktreeLocation = .local,
                origin: WorktreeOrigin? = nil,
                pendingPrompt: String? = nil,
                pendingPromptSubmit: Bool? = nil,
                prObservation: PRObservation? = nil,
                remoteParentAssigned: Bool = false) {
        self.id = id
        self.repoID = repoID
        self.name = name
        self.displayName = displayName
        self.branch = branch
        self.localPath = path
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
        self.autoHibernateOnMerge = autoHibernateOnMerge
        self.promotedToRepoID = promotedToRepoID
        self.prStatus = prStatus
        self.prNumber = prNumber
        self.foreignHead = foreignHead
        self.pinnedAt = pinnedAt
        self.pinSortOrder = pinSortOrder
        self.location = location
        // Defaulted from the location's own pair so all existing construction
        // sites keep satisfying "a `.remote` row has an origin" without being
        // revisited.
        self.origin = origin ?? location.originPair
        self.pendingPrompt = pendingPrompt
        self.pendingPromptSubmit = pendingPromptSubmit
        self.prObservation = prObservation
        self.remoteParentAssigned = remoteParentAssigned
    }

    enum CodingKeys: String, CodingKey {
        case id, repoID, name, displayName, branch, path, status
        case hasConflicts, createdAt, archivedAt, tmuxServer
        case archivedClaudeSessions, sortOrder, archivedHeadSHA
        case liveClaudeSessionCount, parentWorktreeID, autoArchiveOnMerge
        case autoHibernateOnMerge
        case promotedToRepoID, prStatus, prNumber, foreignHead, pinnedAt, pinSortOrder
        case locationKind, providerName, providerSessionID, pendingPrompt, pendingPromptSubmit
        case prObservation, remoteParentAssigned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        repoID = try c.decodeIfPresent(UUID.self, forKey: .repoID)
        name = try c.decode(String.self, forKey: .name)
        displayName = try c.decode(String.self, forKey: .displayName)
        branch = try c.decode(String.self, forKey: .branch)
        localPath = try c.decode(String.self, forKey: .path)
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
        autoHibernateOnMerge = try c.decodeIfPresent(Bool.self, forKey: .autoHibernateOnMerge)
        promotedToRepoID = try c.decodeIfPresent(UUID.self, forKey: .promotedToRepoID)
        prStatus = try c.decodeIfPresent(PRStatus.self, forKey: .prStatus)
        prNumber = try c.decodeIfPresent(Int.self, forKey: .prNumber)
        // Absent in JSON written before v67 — those rows predate fork-PR
        // checkout tracking, so treat them as ordinary TBD-created contents.
        foreignHead = try c.decodeIfPresent(Bool.self, forKey: .foreignHead) ?? false
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        pinSortOrder = try c.decodeIfPresent(Int.self, forKey: .pinSortOrder)
        // Absent in JSON written before v70, and unknown kinds are what a
        // NEWER daemon will send an older app. Both land on `.local`: a
        // pre-v70 row genuinely is local, and an unrecognized kind is safer
        // read as local than dropped, which would fail the whole decode.
        //
        // The two provider keys carry the ORIGIN, and the kind decides only
        // whether the files are also over there. A landed row therefore
        // arrives as `locationKind: "local"` with the pair set.
        let kind = try c.decodeIfPresent(String.self, forKey: .locationKind) ?? "local"
        let provider = try c.decodeIfPresent(String.self, forKey: .providerName)
        let providerSession = try c.decodeIfPresent(String.self, forKey: .providerSessionID)
        if let provider, let providerSession {
            origin = WorktreeOrigin(provider: provider, sessionID: providerSession)
        } else {
            origin = nil
        }
        if kind == "remote", let provider, let providerSession {
            location = .remote(provider: provider, sessionID: providerSession)
        } else {
            location = .local
        }
        // The two keys are absent together, or not at all: a daemon old enough
        // to omit the submit bit omits the prompt too, so an absent bit here
        // never describes a prompt that is present. Nothing decides the
        // optional at this site either way — every consumer reads
        // `pendingPromptSubmitResolved`, which answers `false`.
        pendingPrompt = try c.decodeIfPresent(String.self, forKey: .pendingPrompt)
        pendingPromptSubmit = try c.decodeIfPresent(Bool.self, forKey: .pendingPromptSubmit)
        // Absent in JSON written before the PR-observation column: no attempt
        // is on record, which is itself distinct from a recorded `.none`.
        prObservation = try c.decodeIfPresent(PRObservation.self, forKey: .prObservation)
        // Absent in JSON written before v80. Those rows predate the marker, so
        // nothing recorded that adoption placed them; `false` is what the
        // column's own backfill then corrects for the rows it can.
        remoteParentAssigned = try c.decodeIfPresent(Bool.self, forKey: .remoteParentAssigned) ?? false
    }

    /// Hand-written because `location` is an enum with an associated value that
    /// rides the wire as three flat keys, which no synthesized encoder can
    /// produce. Every stored property is listed here: a property added to the
    /// struct and forgotten here would silently vanish between daemon and app.
    /// `WorktreeLocationTests.roundTripsAFullyPopulatedWorktree` is the guard.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(repoID, forKey: .repoID)
        try c.encode(name, forKey: .name)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(branch, forKey: .branch)
        try c.encode(localPath, forKey: .path)
        try c.encode(status, forKey: .status)
        try c.encode(hasConflicts, forKey: .hasConflicts)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try c.encode(tmuxServer, forKey: .tmuxServer)
        try c.encodeIfPresent(archivedClaudeSessions, forKey: .archivedClaudeSessions)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encodeIfPresent(archivedHeadSHA, forKey: .archivedHeadSHA)
        try c.encodeIfPresent(liveClaudeSessionCount, forKey: .liveClaudeSessionCount)
        try c.encodeIfPresent(parentWorktreeID, forKey: .parentWorktreeID)
        try c.encodeIfPresent(autoArchiveOnMerge, forKey: .autoArchiveOnMerge)
        try c.encodeIfPresent(autoHibernateOnMerge, forKey: .autoHibernateOnMerge)
        try c.encodeIfPresent(promotedToRepoID, forKey: .promotedToRepoID)
        try c.encodeIfPresent(prStatus, forKey: .prStatus)
        try c.encodeIfPresent(prNumber, forKey: .prNumber)
        try c.encode(foreignHead, forKey: .foreignHead)
        try c.encodeIfPresent(pinnedAt, forKey: .pinnedAt)
        try c.encodeIfPresent(pinSortOrder, forKey: .pinSortOrder)
        switch location {
        case .local: try c.encode("local", forKey: .locationKind)
        case .remote: try c.encode("remote", forKey: .locationKind)
        }
        // The origin rides the same two keys, whatever the kind says.
        try c.encodeIfPresent(origin?.provider, forKey: .providerName)
        try c.encodeIfPresent(origin?.sessionID, forKey: .providerSessionID)
        try c.encodeIfPresent(pendingPrompt, forKey: .pendingPrompt)
        try c.encodeIfPresent(pendingPromptSubmit, forKey: .pendingPromptSubmit)
        try c.encodeIfPresent(prObservation, forKey: .prObservation)
        try c.encode(remoteParentAssigned, forKey: .remoteParentAssigned)
    }
}

public enum TerminalActivityState: String, Codable, Sendable {
    case unknown
    case working
    case idle
    case waitingForUser = "waiting_for_user"
}

/// WHO parked a session — persisted alongside `hibernatedAt` so an explicit
/// user park can be distinguished from an automatic one (and survive the
/// wake-on-focus sweep, which must not silently undo a manual park).
public enum HibernateReason: String, Codable, Sendable {
    /// Idle-sweep auto-hibernation.
    case auto
    /// Explicit user "Hibernate now" (terminal.hibernate RPC or the legacy
    /// terminal.suspend shim). Excluded from wake-on-focus.
    case manual
    /// Crash-recovery / reconcile parking (window or server gone).
    case recovery
    /// Parked because the worktree's PR merged — system-initiated, so it
    /// auto-wakes on focus like `.auto`.
    case merged

    // Custom lenient decoder: the SYNTHESIZED `Decodable` throws
    // `DecodingError.dataCorrupted` on any raw value this build doesn't know.
    // Because `Terminal.hibernateReason` and `TerminalHibernationDelta`
    // .hibernateReason ride the RPC wire, a `.merged` (or any future case)
    // written by a newer daemon would fail the ENTIRE Terminal/delta decode on
    // an older app binary — the blank-app class of failure. Falling back to
    // `.auto` is semantically safe: wake-on-focus only special-cases `.manual`,
    // so an unknown reason and `.auto` behave identically. `Encodable` stays
    // synthesized (always writes the true raw value).
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HibernateReason(rawValue: raw) ?? .auto
    }
}
public enum WatchDeskRole: String, Codable, Sendable, Equatable {
    case judge
    case readOnlyCoordinator = "read_only_coordinator"

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // A role introduced by a newer daemon must never acquire mutable
        // semantics in an older app. Render it as read-only and keep decoding.
        self = Self(rawValue: raw) ?? .readOnlyCoordinator
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
    /// Ordering watermark for accepted SessionStart identity rollovers.
    /// Independent from activity and prompt timestamps because either hook
    /// can arrive late while describing the previous session.
    public var sessionOrderObservedAt: Date?
    public var kind: TerminalKind?
    public var activityState: TerminalActivityState
    /// Activity reconstructed for display from the current agent transcript.
    /// This is response-derived and is never persisted as hook activity.
    public var presentationActivityState: TerminalActivityState?
    /// When the daemon completed the transcript observation that produced
    /// `presentationActivityState`. Response-derived and never persisted.
    public var presentationActivityObservedAt: Date?
    /// When set, the terminal is HIBERNATED: its `claude` process was
    /// gracefully terminated to reclaim memory, but the tmux window (and its
    /// shell) is kept alive. `claudeSessionID` still points at the session to
    /// resume via `claude --resume` on wake. `nil` = not hibernated. Distinct
    /// from `suspendedAt` (which kills the tmux window's program entirely and
    /// snapshots the pane); a hibernated terminal keeps its live window.
    public var hibernatedAt: Date?
    /// WHO parked this session (see `HibernateReason`). Stamped together with
    /// `hibernatedAt` at park time and cleared with it on wake. `nil` on
    /// legacy rows parked before the column existed (pre-v46) — treated like
    /// `.auto`, i.e. still eligible for wake-on-focus.
    public var hibernateReason: HibernateReason?
    /// User pin that exempts this terminal from auto-hibernation. `false` =
    /// eligible for the idle timer; `true` = the daemon never auto-hibernates
    /// it (manual "Hibernate now" still works). Persisted per-terminal.
    public var keepWarm: Bool
    /// When non-nil, a session-limit auto-resume is scheduled to fire at this
    /// instant (mirrors the terminal's single `pending` scheduled_resumes
    /// row). Drives the "⏳ resumes 1:01pm" tab badge. Optional for
    /// decode-compat with pre-v43 rows/JSON.
    public var pendingResumeAt: Date?
    /// Explicit Watch Desk authority. Nil means an ordinary terminal.
    /// The lease row, not this display marker, is authoritative for mutation.
    public var watchDeskRole: WatchDeskRole?
    /// Where `activityState` came from. `nil` on rows written before the
    /// provenance columns existed, and on rows a future writer forgets to
    /// stamp — which is why `observedActivity` refuses to build a fact out of
    /// half a triple.
    public var activityStateSource: FactSource?
    /// When `activityState` was observed — the moment the machine fact was
    /// read, not the moment the row was written.
    public var activityStateObservedAt: Date?
    /// Ordering watermark for activity events. Unlike
    /// `activityStateObservedAt`, this advances for a newer observation that
    /// confirms the same semantic state, so it must not be used as an
    /// at-rest-since timestamp.
    public var activityStateOrderObservedAt: Date?
    /// The structured reason this session is waiting, carried verbatim from
    /// Claude Code's `Notification` hook. Superseded by the next activity
    /// observation, so it describes the *current* wait or nothing at all.
    public var awaitingInputReason: AwaitingInputReason?
    /// When `awaitingInputReason` was observed.
    public var awaitingInputObservedAt: Date?

    /// `activityState` as a fact — value, source, observed-at — or nil.
    ///
    /// Nil whenever either provenance column is missing, deliberately: a bare
    /// value with no source and no age must not be able to masquerade as an
    /// observation. Callers that want the raw enumeration can still read
    /// `activityState`; callers that want to *reason* about it get the triple
    /// or nothing.
    public var observedActivity: ObservedFact<TerminalActivityState>? {
        guard let activityStateSource, let activityStateObservedAt else { return nil }
        return ObservedFact(
            value: activityState, source: activityStateSource, observedAt: activityStateObservedAt)
    }

    /// The recorded wait reason as a fact — value, source, observed-at — or nil.
    ///
    /// The source is not a column of its own: a wait reason is only ever
    /// recorded from a hook event, and the event's name is already carried on
    /// the reason, so `.hookEvent(name)` IS the provenance rather than a second
    /// copy of it. A reason with no event name — or with an empty one, which
    /// names a source just as poorly — is therefore half a triple and reports
    /// no fact, on the same rule `observedActivity` follows.
    ///
    /// This is a *recorded reason*, not a claim about what the session is doing
    /// now — nothing here asserts `activityState`. Composing the two into a
    /// session state is the resolver's job.
    public var observedAwaitingInput: ObservedFact<AwaitingInputReason>? {
        guard let awaitingInputReason,
              let awaitingInputObservedAt,
              let hookEventName = awaitingInputReason.hookEventName,
              !hookEventName.isEmpty else { return nil }
        return ObservedFact(
            value: awaitingInputReason,
            source: .hookEvent(hookEventName),
            observedAt: awaitingInputObservedAt)
    }

    public init(id: UUID = UUID(), worktreeID: UUID, tmuxWindowID: String,
                tmuxPaneID: String, label: String? = nil, createdAt: Date = Date(),
                pinnedAt: Date? = nil, claudeSessionID: String? = nil,
                suspendedAt: Date? = nil, suspendedSnapshot: String? = nil,
                profileID: UUID? = nil,
                transcriptPath: String? = nil,
                sessionOrderObservedAt: Date? = nil,
                kind: TerminalKind? = nil,
                activityState: TerminalActivityState = .unknown,
                presentationActivityState: TerminalActivityState? = nil,
                presentationActivityObservedAt: Date? = nil,
                hibernatedAt: Date? = nil,
                hibernateReason: HibernateReason? = nil,
                keepWarm: Bool = false,
                pendingResumeAt: Date? = nil,
                watchDeskRole: WatchDeskRole? = nil,
                activityStateSource: FactSource? = nil,
                activityStateObservedAt: Date? = nil,
                activityStateOrderObservedAt: Date? = nil,
                awaitingInputReason: AwaitingInputReason? = nil,
                awaitingInputObservedAt: Date? = nil) {
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
        self.sessionOrderObservedAt = sessionOrderObservedAt
        self.kind = kind
        self.activityState = activityState
        self.presentationActivityState = presentationActivityState
        self.presentationActivityObservedAt = presentationActivityObservedAt
        self.hibernatedAt = hibernatedAt
        self.hibernateReason = hibernateReason
        self.keepWarm = keepWarm
        self.pendingResumeAt = pendingResumeAt
        self.watchDeskRole = watchDeskRole
        self.activityStateSource = activityStateSource
        self.activityStateObservedAt = activityStateObservedAt
        self.activityStateOrderObservedAt = activityStateOrderObservedAt
        self.awaitingInputReason = awaitingInputReason
        self.awaitingInputObservedAt = awaitingInputObservedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, worktreeID, tmuxWindowID, tmuxPaneID, label, createdAt
        case pinnedAt, claudeSessionID, suspendedAt, suspendedSnapshot, profileID, transcriptPath
        case sessionOrderObservedAt, kind
        case activityState, presentationActivityState, presentationActivityObservedAt
        case hibernatedAt, hibernateReason, keepWarm, pendingResumeAt, watchDeskRole
        case activityStateSource, activityStateObservedAt, activityStateOrderObservedAt
        case awaitingInputReason, awaitingInputObservedAt
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
        sessionOrderObservedAt = try c.decodeIfPresent(Date.self, forKey: .sessionOrderObservedAt)
        kind = try c.decodeIfPresent(TerminalKind.self, forKey: .kind)
        activityState = try c.decodeIfPresent(TerminalActivityState.self, forKey: .activityState) ?? .unknown
        presentationActivityState = try c.decodeIfPresent(
            TerminalActivityState.self, forKey: .presentationActivityState)
        presentationActivityObservedAt = try c.decodeIfPresent(
            Date.self, forKey: .presentationActivityObservedAt)
        hibernatedAt = try c.decodeIfPresent(Date.self, forKey: .hibernatedAt)
        hibernateReason = try c.decodeIfPresent(HibernateReason.self, forKey: .hibernateReason)
        keepWarm = try c.decodeIfPresent(Bool.self, forKey: .keepWarm) ?? false
        pendingResumeAt = try c.decodeIfPresent(Date.self, forKey: .pendingResumeAt)
        watchDeskRole = try c.decodeIfPresent(WatchDeskRole.self, forKey: .watchDeskRole)
        // Absent in JSON written before the state model's provenance columns.
        // Such a row carries a value with no source and no age, and
        // `observedActivity` reports exactly that by returning nil.
        activityStateSource = try c.decodeIfPresent(FactSource.self, forKey: .activityStateSource)
        activityStateObservedAt = try c.decodeIfPresent(Date.self, forKey: .activityStateObservedAt)
        activityStateOrderObservedAt = try c.decodeIfPresent(
            Date.self, forKey: .activityStateOrderObservedAt)
        awaitingInputReason = try c.decodeIfPresent(AwaitingInputReason.self, forKey: .awaitingInputReason)
        awaitingInputObservedAt = try c.decodeIfPresent(Date.self, forKey: .awaitingInputObservedAt)
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
    ///
    /// `hibernatedAt` is the ONE authoritative "parked" timestamp going forward.
    /// (`suspendedAt` is legacy-read-only — see `isParked`.)
    var isHibernated: Bool { hibernatedAt != nil }

    /// The single authoritative "is this session parked?" concept after the
    /// suspend/hibernate merge. A terminal is parked when its Claude process has
    /// been torn down and the row is holding a resume session id, regardless of
    /// which timestamp column recorded it:
    ///   - `hibernatedAt` — written by ALL new code (the unified park path).
    ///   - `suspendedAt` — LEGACY, read-only. Rows parked by the pre-merge
    ///     Suspend feature (or by an old daemon build) only have this column set;
    ///     they must still read as parked so the UI shows the moon + snapshot and
    ///     wake fully un-parks them. New code never writes `suspendedAt`; the v40
    ///     migration backfills existing legacy rows into `hibernatedAt`, but a row
    ///     written by an old binary after the migration ran would still land here.
    var isParked: Bool { hibernatedAt != nil || suspendedAt != nil }

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
    /// Drag-and-drop display order (mirrors `Worktree.sortOrder`). Defaults to
    /// 0 so existing JSON/rows without this field still decode.
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, kind: CredentialKind,
                baseURL: String? = nil, model: String? = nil,
                awsRegion: String? = nil, awsProfile: String? = nil,
                fallbackModels: [String]? = nil,
                envOverrides: [String: String] = [:],
                createdAt: Date = Date(), lastUsedAt: Date? = nil,
                sortOrder: Int = 0) {
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
        self.sortOrder = sortOrder
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, model, awsRegion, awsProfile, fallbackModels
        case envOverrides, createdAt, lastUsedAt, sortOrder
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
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
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

/// Machine-readable classification of a profile's last usage-fetch outcome,
/// so the UI can render honest, distinct states instead of parsing the
/// free-form `status` string. Separates auth failures from rate limits from
/// network errors — the three demand different user affordances ("needs
/// re-login" vs "retrying" vs "temporarily unavailable").
///
/// New field: `statusKind` is optional on `ProfileUsageSnapshot` with an
/// `.unknown` default so payloads from an older daemon (which only sent the
/// `status` string) still decode.
public enum ProfileUsageStatusKind: String, Codable, Sendable, Equatable {
    /// Last fetch succeeded; `buckets` are current.
    case ok
    /// HTTP 429 — rate limited. The poller is backing off and will retry.
    case rateLimited
    /// HTTP 401/403 with a credential the daemon believes is present but the
    /// server rejected, AND automatic token refresh could not recover it. The
    /// profile needs the user to re-run `/login`.
    case needsLogin
    /// No stored credential at all for this profile (never logged in, or the
    /// keychain item is gone).
    case noCredentials
    /// A transport-level failure (DNS, timeout, offline). Transient; retried.
    case networkError
    /// The server replied 200 but the body didn't parse. Retried.
    case decodeError
    /// Some other HTTP status, or a snapshot from an older daemon that didn't
    /// classify. Treated as a generic retryable failure by the UI.
    case unknown
}

/// Per-profile usage snapshot for logged-in OAuth profiles, maintained by
/// the daemon's background poller. Persisted by the daemon as a regenerating
/// JSON cache (`oauth_profile_usage_snapshot` table, migration v55), so new
/// fields MUST stay decode-compatible with older stored JSON (optional or
/// defaulted).
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
    /// Machine-readable classification of the last fetch outcome. Optional for
    /// decode-compat with older daemons; defaults to `.unknown` when absent.
    public var statusKind: ProfileUsageStatusKind

    public init(buckets: [ClaudeUsageLimitBucket], fetchedAt: Date? = nil,
                lastAttemptAt: Date, status: String,
                statusKind: ProfileUsageStatusKind = .unknown) {
        self.buckets = buckets
        self.fetchedAt = fetchedAt
        self.lastAttemptAt = lastAttemptAt
        self.status = status
        self.statusKind = statusKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.buckets = try container.decode([ClaudeUsageLimitBucket].self, forKey: .buckets)
        self.fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)
        self.lastAttemptAt = try container.decode(Date.self, forKey: .lastAttemptAt)
        self.status = try container.decode(String.self, forKey: .status)
        // Absent (older daemon) → infer from the legacy string so callers still
        // get a usable classification: "ok" → .ok, else .unknown.
        self.statusKind = try container.decodeIfPresent(
            ProfileUsageStatusKind.self, forKey: .statusKind)
            ?? (self.status == "ok" ? .ok : .unknown)
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
    /// Global default for auto-hibernate-on-PR-merge, applied to worktrees whose
    /// per-worktree override is `nil`.
    public var autoHibernateOnMergeDefault: Bool
    /// Global gate for session-limit auto-resume (spec 2026-07-03). Daemon-
    /// side because the daemon must act while the app is closed. Default OFF.
    public var autoResumeOnLimitReset: Bool
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
    /// OFF: the idle sweep drives a sanctioned TUI screen-scrape
    /// (`HibernationSafetyChecks.hasPendingInput`) whose failure direction is
    /// asymmetric — a composer-rendering change in Claude Code could let the
    /// park eat typed-but-unsent input — so it is opt-in. When true, idle
    /// Claude sessions are auto-hibernated to reclaim memory (their prompt
    /// cache has already expired, so resume is cheap). When false, only manual
    /// "Hibernate now" hibernates.
    public var autoHibernateEnabled: Bool
    /// Minutes a Claude session must sit idle-at-rest before the auto-hibernate
    /// timer terminates its process. Clamped to a sane floor by the daemon.
    public var hibernateIdleMinutes: Int
    /// Persisted opt-in for the tmux control-mode render path. The effective
    /// gate is `env || flag` (a truthy `TBD_TMUX_CONTROL_MODE` is the
    /// developer override) AND tmux >= 3.2; applies to newly created panes.
    public var controlModeEnabled: Bool
    /// Global gate for transient-API-error auto-resume (spec 2026-07-08).
    /// Sibling of `autoResumeOnLimitReset` but governs `ScheduledResume` rows
    /// classified as `ScheduledResume.apiErrorLimitType` rather than a hard
    /// usage-limit hit. Default OFF.
    public var autoResumeOnApiError: Bool
    /// Soak flag for the input-pipeline pending-input veto (design spec
    /// 2026-07-09). When true, the auto-hibernate idle sweep includes a
    /// machine-interface guard against parking a pane with typed-but-unsent
    /// input: if any keystroke arrived at or after the session went idle, the
    /// park is vetoed. When false (the default), only the TUI scrape veto
    /// applies. The input veto is opt-in until it soaks and the v50 master
    /// default is reverted.
    public var hibernateInputVetoEnabled: Bool
    /// Soak flag for auto-closing the setup-hook tab after a clean run.
    /// When true AND a setup hook resolves, the hook's exit code is written
    /// to a marker file; exit 0 closes the tab (kills the pane, deletes the
    /// terminal/tab rows), nonzero leaves the tab open with an interactive
    /// shell for debugging. Default OFF: this kills a pane and deletes rows
    /// without a user gesture, so it is opt-in until it soaks.
    public var autoCloseSetupEnabled: Bool
    /// Pre-accept Claude Code's folder-trust dialog for the worktrees TBD
    /// created in a registered repo, and for that repo's own checkout.
    /// Default ON.
    ///
    /// The dialog asks "is this a project you created or one you trust?" — and
    /// for a worktree TBD created from a repo the operator registered, TBD
    /// already holds every fact the question is about, so the answer is yes by
    /// construction. The repo's `.main` checkout is covered by the second half
    /// of the question: TBD did not create it, but registering it with
    /// `tbd repo add` was itself a deliberate trust gesture. Seeding writes that
    /// answer through Claude's own config persistence and the dialog never
    /// renders. That matters because the dialog blocks BEFORE SessionStart: no
    /// hook fires while it is up, so a stalled-on-trust session is invisible to
    /// TBD and prevention is the only available fix.
    ///
    /// Worktrees flagged `Worktree.foreignHead` — contents fetched from a PR
    /// head that a third-party fork may have authored — are never seeded, on or
    /// off: TBD vouches for the directory it created, not for what was fetched
    /// into it.
    ///
    /// Turning this OFF only stops future seeding of non-scratch worktrees —
    /// including worktrees that already exist but were never seeded — and never
    /// un-trusts a path. Scratch spaces are seeded unconditionally and are not
    /// governed by this flag.
    public var autoTrustWorktrees: Bool
    /// Master switch for the daemon-owned orphan GC sweep. Default ON.
    public var gcEnabled: Bool
    /// Minimum age (seconds) an orphaned worktree/scratchpad must reach
    /// before the sweep reaps it, so a directory mid-teardown isn't raced.
    public var gcGraceSeconds: Int
    /// Days a reap snapshot (`refs/tbd/snapshots/...`) is retained before
    /// being pruned.
    public var gcSnapshotRetentionDays: Int
    /// Master switch for the daemon-owned panel-surface store (spec C Phase
    /// 2 §8). Default OFF: the store is inert (no reads/writes) until this
    /// flips on. See `Database/CLAUDE.md` three-place migration rule for the
    /// `v59_panel_surface` migration that backs this column.
    public var panelSurfaceEnabled: Bool
    /// Gate for agent-originated panel-surface mutations. Default OFF, and
    /// independent of `panelSurfaceEnabled` — an agent may only mutate panel
    /// layout once both flags are true.
    public var agentPanelControlEnabled: Bool
    /// Master switch for remote agent backends (spec 2026-07-24). Default OFF:
    /// the daemon polls provider executables in the background and can stop
    /// remote sessions, so it is opt-in until it soaks.
    public var remoteBackendsEnabled: Bool
    /// Soak flag for delivery acknowledgement — the machinery that establishes
    /// whether a dispatched payload actually landed (fleet-supervision design
    /// §12). Default OFF: the re-check acts on no user gesture and its single
    /// retry types into a live session, so the whole path is opt-in.
    ///
    /// What it gates: arming the re-check, the evidence-bounded retry, and the
    /// startup replay. While it is off, `terminal.send --verify` is *refused*
    /// with the flag named and nothing is typed — a caller that asked for
    /// evidence must never be answered with a silence that reads like
    /// confirmation.
    ///
    /// What it deliberately does NOT gate: the dispatch envelope. Attribution
    /// belongs on every text dispatch to an agent, verified or not, and a prefix
    /// that comes and goes with a config column is worse than one that is always
    /// there. (Whether a target receives the envelope at all is a property of
    /// the target, not of this flag: shells do not.)
    public var deliveryVerificationEnabled: Bool
    /// Soak flag for the queued prompt taken at worktree creation
    /// (`docs/specs/2026-08-10-queued-prompt-on-create-design.md`). What it
    /// gates is the daemon typing into a session — with it off the app does not
    /// open the modal, `worktree.setPendingPrompt` is refused, and the spawn
    /// path ignores the column.
    ///
    /// **Resolved, not stored.** The backing column carries no SQL default and
    /// is genuinely NULL until somebody touches the toggle, so this property is
    /// `queued_prompt_enabled ?? Config.queuedPromptDefault`. NULL means "never
    /// chose" and follows the shipped default wherever it goes; `0`/`1` is an
    /// explicit gesture and is honored forever.
    public var queuedPromptEnabled: Bool
    /// The fleet brake for supervision
    /// (`docs/specs/2026-07-26-fleet-supervision-design.md` §3, §8): one bit,
    /// fleet-wide, ANDed over every project's mark and writing none of them.
    /// Released (`true`) means TBD may act where a mark stands; engaged
    /// (`false`, the shipped state) means TBD's authority is paused everywhere,
    /// with the marks left exactly as they were.
    ///
    /// **Resolved, not stored**, like `queuedPromptEnabled`: the backing column
    /// carries no SQL default and stays NULL until somebody touches the toggle,
    /// so this property is
    /// `supervision_enabled ?? Config.supervisionEnabledDefault`. NULL means
    /// "never chose" and follows the shipped default wherever it goes; `0`/`1`
    /// is an explicit gesture and is honored forever.
    public var supervisionEnabled: Bool
    /// Gate for the orphan-GC phase that reclaims per-profile config
    /// directories under `~/tbd/profiles/`
    /// (`docs/specs/2026-08-15-profile-dir-gc-design.md`). Read on top of
    /// `gcEnabled`: both must be on for the phase to run. It ships OFF because
    /// those directories hold per-profile credentials and user content with no
    /// other copy, so a brand-new orphan classifier over them soaks behind its
    /// own switch rather than riding the default-ON master switch.
    ///
    /// **Resolved, not stored**, like `supervisionEnabled`: the backing column
    /// carries no SQL default and stays NULL until somebody touches the
    /// toggle, so this property is
    /// `gc_profile_dirs_enabled ?? Config.gcProfileDirsEnabledDefault`. NULL
    /// means "never chose" and follows the shipped default wherever it goes;
    /// `0`/`1` is an explicit gesture and is honored forever.
    public var gcProfileDirsEnabled: Bool
    /// The Claude cloud sessions gate
    /// (`docs/specs/2026-08-15-cloud-sessions-slice-1-design.md` §7). A second
    /// gate INSIDE `remoteBackendsEnabled`, never a bypass: cloud is reached
    /// through the `remote.*` verbs, so it requires both.
    ///
    /// **Resolved, not stored**, like `queuedPromptEnabled`: the backing column
    /// carries no SQL default and stays NULL until somebody touches the toggle,
    /// so this property is
    /// `claude_cloud_enabled ?? Config.claudeCloudEnabledDefault`.
    public var claudeCloudEnabled: Bool
    /// Gate for the orphan-GC phase that reclaims processes which outlived the
    /// worktree they were rooted in
    /// (`docs/specs/2026-08-18-orphan-process-gc-design.md`). Read on top of
    /// `gcEnabled`: both must be on for the phase to run. It ships OFF because
    /// this is the one GC phase that signals processes rather than moving
    /// bytes, and a process it misjudges cannot be restored.
    ///
    /// **Resolved, not stored**, like `gcProfileDirsEnabled`: the backing
    /// column carries no SQL default and stays NULL until somebody touches the
    /// toggle, so this property is
    /// `gc_orphan_processes_enabled ?? Config.gcOrphanProcessesEnabledDefault`.
    /// NULL means "never chose" and follows the shipped default wherever it
    /// goes; `0`/`1` is an explicit gesture and is honored forever.
    public var gcOrphanProcessesEnabled: Bool
    /// Machine-wide remote create-param defaults, keyed by the **provider's
    /// own** `create_params` field names — the fall-through level beneath
    /// `Repo.remoteCreateDefaults`. TBD stores and replays these values
    /// without interpreting them; see `Repo.remoteCreateDefaults` for why the
    /// map is keyed generically rather than given a column per concept.
    public var remoteCreateDefaults: [String: String]

    /// Default idle-timeout for auto-hibernation, in minutes.
    public static let defaultHibernateIdleMinutes = 30
    /// Floor for `hibernateIdleMinutes` — a zero/negative value would make the
    /// idle sweep hibernate everything on its next tick.
    public static let minHibernateIdleMinutes = 1
    /// Ceiling for `hibernateIdleMinutes` — 99 days. Enforced at every layer:
    /// the Settings amount+unit control clamps input to it, `ConfigStore`
    /// clamps on both write and read, and `HibernationCoordinator.sweep()`
    /// floors the value it reads for the idle timer.
    public static let maxHibernateIdleMinutes = 99 * 24 * 60
    /// Default grace period before the orphan-GC sweep reaps a directory.
    public static let defaultGCGraceSeconds = 3600
    /// Default retention window for reap snapshots.
    public static let defaultGCSnapshotRetentionDays = 30
    /// The shipped default for `queuedPromptEnabled`, and the single place it
    /// lives. Every row that never touched the toggle is NULL, so graduating
    /// the feature is a change to this constant — no forcing `UPDATE`
    /// migration, and an explicit opt-out is left alone.
    public static let queuedPromptDefault = false
    /// The shipped default for `supervisionEnabled`, and the single place it
    /// lives. Supervision ships with the brake engaged; graduating it is a
    /// change to this constant — no forcing `UPDATE` migration, and an explicit
    /// opt-out is left alone.
    public static let supervisionEnabledDefault = false
    /// The shipped default for `gcProfileDirsEnabled`, and the single place it
    /// lives. The profile-dir collector ships off; graduating it is a change to
    /// this constant — no forcing `UPDATE` migration, and an explicit opt-out
    /// is left alone.
    public static let gcProfileDirsEnabledDefault = false
    /// The shipped default for `claudeCloudEnabled`, and the single place it
    /// lives. Cloud ships off; graduating it is a change to this constant — no
    /// forcing `UPDATE` migration, and an explicit opt-out is left alone.
    public static let claudeCloudEnabledDefault = false
    /// The shipped default for `gcOrphanProcessesEnabled`, and the single place
    /// it lives. The orphaned-process collector ships off; graduating it is a
    /// change to this constant — no forcing `UPDATE` migration, and an explicit
    /// opt-out is left alone.
    public static let gcOrphanProcessesEnabledDefault = false

    public init(defaultProfileID: UUID? = nil,
                primaryAgentPreference: PrimaryAgentPreference = .defaultValue,
                envSettingOverrides: [String: ClaudeEnvValue] = [:],
                envOverrides: [String: String] = [:],
                autoArchiveOnMergeDefault: Bool = false,
                autoHibernateOnMergeDefault: Bool = false,
                autoResumeOnLimitReset: Bool = false,
                scratchInstructions: String? = nil,
                scratchRenamePrompt: String? = nil,
                scratchProfileOverrideID: UUID? = nil,
                nightwatchMode: NightwatchMode = .off,
                autoHibernateEnabled: Bool = false,
                hibernateIdleMinutes: Int = Config.defaultHibernateIdleMinutes,
                controlModeEnabled: Bool = false,
                autoResumeOnApiError: Bool = false,
                hibernateInputVetoEnabled: Bool = false,
                autoCloseSetupEnabled: Bool = false,
                autoTrustWorktrees: Bool = true,
                gcEnabled: Bool = true,
                gcGraceSeconds: Int = Config.defaultGCGraceSeconds,
                gcSnapshotRetentionDays: Int = Config.defaultGCSnapshotRetentionDays,
                panelSurfaceEnabled: Bool = false,
                agentPanelControlEnabled: Bool = false,
                remoteBackendsEnabled: Bool = false,
                deliveryVerificationEnabled: Bool = false,
                queuedPromptEnabled: Bool = Config.queuedPromptDefault,
                supervisionEnabled: Bool = Config.supervisionEnabledDefault,
                gcProfileDirsEnabled: Bool = Config.gcProfileDirsEnabledDefault,
                claudeCloudEnabled: Bool = Config.claudeCloudEnabledDefault,
                gcOrphanProcessesEnabled: Bool = Config.gcOrphanProcessesEnabledDefault,
                remoteCreateDefaults: [String: String] = [:]) {
        self.defaultProfileID = defaultProfileID
        self.primaryAgentPreference = primaryAgentPreference
        self.envSettingOverrides = envSettingOverrides
        self.envOverrides = envOverrides
        self.autoArchiveOnMergeDefault = autoArchiveOnMergeDefault
        self.autoHibernateOnMergeDefault = autoHibernateOnMergeDefault
        self.autoResumeOnLimitReset = autoResumeOnLimitReset
        self.scratchInstructions = scratchInstructions
        self.scratchRenamePrompt = scratchRenamePrompt
        self.scratchProfileOverrideID = scratchProfileOverrideID
        self.nightwatchMode = nightwatchMode
        self.autoHibernateEnabled = autoHibernateEnabled
        self.hibernateIdleMinutes = hibernateIdleMinutes
        self.controlModeEnabled = controlModeEnabled
        self.autoResumeOnApiError = autoResumeOnApiError
        self.hibernateInputVetoEnabled = hibernateInputVetoEnabled
        self.autoCloseSetupEnabled = autoCloseSetupEnabled
        self.autoTrustWorktrees = autoTrustWorktrees
        self.gcEnabled = gcEnabled
        self.gcGraceSeconds = gcGraceSeconds
        self.gcSnapshotRetentionDays = gcSnapshotRetentionDays
        self.panelSurfaceEnabled = panelSurfaceEnabled
        self.agentPanelControlEnabled = agentPanelControlEnabled
        self.remoteBackendsEnabled = remoteBackendsEnabled
        self.deliveryVerificationEnabled = deliveryVerificationEnabled
        self.queuedPromptEnabled = queuedPromptEnabled
        self.supervisionEnabled = supervisionEnabled
        self.gcProfileDirsEnabled = gcProfileDirsEnabled
        self.claudeCloudEnabled = claudeCloudEnabled
        self.gcOrphanProcessesEnabled = gcOrphanProcessesEnabled
        self.remoteCreateDefaults = remoteCreateDefaults
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
        autoHibernateOnMergeDefault = try c.decodeIfPresent(
            Bool.self, forKey: .autoHibernateOnMergeDefault) ?? false
        autoResumeOnLimitReset = try c.decodeIfPresent(
            Bool.self, forKey: .autoResumeOnLimitReset) ?? false
        scratchInstructions = try c.decodeIfPresent(String.self, forKey: .scratchInstructions) ?? nil
        scratchRenamePrompt = try c.decodeIfPresent(String.self, forKey: .scratchRenamePrompt) ?? nil
        scratchProfileOverrideID = try c.decodeIfPresent(UUID.self, forKey: .scratchProfileOverrideID)
        nightwatchMode = try c.decodeIfPresent(
            NightwatchMode.self, forKey: .nightwatchMode) ?? .off
        autoHibernateEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoHibernateEnabled) ?? false
        hibernateIdleMinutes = try c.decodeIfPresent(Int.self, forKey: .hibernateIdleMinutes)
            ?? Config.defaultHibernateIdleMinutes
        controlModeEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .controlModeEnabled) ?? false
        autoResumeOnApiError = try c.decodeIfPresent(
            Bool.self, forKey: .autoResumeOnApiError) ?? false
        hibernateInputVetoEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .hibernateInputVetoEnabled) ?? false
        autoCloseSetupEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .autoCloseSetupEnabled) ?? false
        // Absent (older daemon / older persisted JSON) defaults to ON, matching
        // the column default — the trust answer is known by construction.
        autoTrustWorktrees = try c.decodeIfPresent(
            Bool.self, forKey: .autoTrustWorktrees) ?? true
        gcEnabled = try c.decodeIfPresent(Bool.self, forKey: .gcEnabled) ?? true
        gcGraceSeconds = try c.decodeIfPresent(Int.self, forKey: .gcGraceSeconds)
            ?? Config.defaultGCGraceSeconds
        gcSnapshotRetentionDays = try c.decodeIfPresent(Int.self, forKey: .gcSnapshotRetentionDays)
            ?? Config.defaultGCSnapshotRetentionDays
        panelSurfaceEnabled = try c.decodeIfPresent(Bool.self, forKey: .panelSurfaceEnabled) ?? false
        agentPanelControlEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .agentPanelControlEnabled) ?? false
        remoteBackendsEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .remoteBackendsEnabled) ?? false
        // Absent (older daemon / older persisted JSON) defaults to OFF, matching
        // the v69 column default — the soak has to be opted into.
        deliveryVerificationEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .deliveryVerificationEnabled) ?? false
        // Absent (older daemon / older persisted JSON) means the sender knew
        // nothing about the flag, which is the same situation as a NULL column:
        // fall through to the shipped default rather than hardcoding `false`.
        queuedPromptEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .queuedPromptEnabled) ?? Config.queuedPromptDefault
        // Same tri-state as above: absent means the sender knew nothing about
        // the flag, which is the NULL column's situation — follow the shipped
        // default rather than hardcoding `false` here as well.
        supervisionEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .supervisionEnabled) ?? Config.supervisionEnabledDefault
        // Same tri-state again: absent means the sender knew nothing about the
        // flag, which is the NULL column's situation — follow the shipped
        // default rather than hardcoding `false`.
        gcProfileDirsEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .gcProfileDirsEnabled) ?? Config.gcProfileDirsEnabledDefault
        claudeCloudEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .claudeCloudEnabled) ?? Config.claudeCloudEnabledDefault
        // Same tri-state again: absent means the sender knew nothing about the
        // flag, which is the NULL column's situation — follow the shipped
        // default rather than hardcoding `false`.
        gcOrphanProcessesEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .gcOrphanProcessesEnabled) ?? Config.gcOrphanProcessesEnabledDefault
        // Absent means the sender knew nothing about global create defaults —
        // the same state as an empty map: no opinion at this level, so every
        // field falls through to its provider-declared `default`.
        remoteCreateDefaults = try c.decodeIfPresent(
            [String: String].self, forKey: .remoteCreateDefaults) ?? [:]
    }
}

public extension Config {
    /// Which auto-resume gate governs a `scheduled_resumes` row: the
    /// transient-API-error gate for `ScheduledResume.apiErrorLimitType` rows,
    /// or the hard usage-limit gate for everything else (session/debug/weekly).
    func autoResumeEnabled(forLimitType limitType: String) -> Bool {
        limitType == ScheduledResume.apiErrorLimitType ? autoResumeOnApiError : autoResumeOnLimitReset
    }
}

public enum ScheduledResumeStatus: String, Codable, Sendable {
    case pending
    case sent
    case cancelled
    case failed
}

/// One scheduled "type `continue` at reset time" action. At most one
/// `pending` row exists per terminal — the row IS the double-send latch.
public struct ScheduledResume: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let terminalID: UUID
    public let worktreeID: UUID
    public let claudeSessionID: String?
    /// Absolute reset instant (structured epoch or parsed-once display text).
    public let resetsAt: Date
    /// Next actuation attempt: resetsAt + 60s slack + jitter(0-30s) at insert;
    /// pushed +2min per copy-mode retry. Persisted so reschedules survive
    /// daemon restarts.
    public var fireAt: Date
    public let limitType: String
    public let rawMessage: String
    public let createdAt: Date
    public var status: ScheduledResumeStatus
    public var attemptCount: Int

    public init(id: UUID = UUID(), terminalID: UUID, worktreeID: UUID,
                claudeSessionID: String? = nil, resetsAt: Date, fireAt: Date,
                limitType: String, rawMessage: String, createdAt: Date = Date(),
                status: ScheduledResumeStatus = .pending, attemptCount: Int = 0) {
        self.id = id
        self.terminalID = terminalID
        self.worktreeID = worktreeID
        self.claudeSessionID = claudeSessionID
        self.resetsAt = resetsAt
        self.fireAt = fireAt
        self.limitType = limitType
        self.rawMessage = rawMessage
        self.createdAt = createdAt
        self.status = status
        self.attemptCount = attemptCount
    }
}

extension ScheduledResume {
    /// `limitType` sentinel for rows scheduled from a transient API-error
    /// classification (as opposed to a hard usage-limit hit) — distinguishes
    /// the two in the scheduler/actuator's gating logic.
    public static let apiErrorLimitType = "api_error"
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

/// Metadata for a closed terminal whose scrollback was captured at close time.
/// The captured text is file-backed at
/// `~/tbd/terminal-history/<worktreeID>/<terminalID>.txt`
/// (`TBDConstants.terminalHistoryPath`); the app reads the file directly and
/// shows it read-only in Session History → Closed Terminals.
public struct TerminalHistoryEntry: Codable, Sendable, Identifiable, Equatable {
    /// The closed terminal's UUID (also names the content file).
    public let id: UUID
    public var worktreeID: UUID
    public var label: String?
    public var kind: TerminalKind?
    public var closedAt: Date
    public var claudeSessionID: String?
    /// Line count of the captured text (display metadata).
    public var lineCount: Int

    public init(id: UUID, worktreeID: UUID, label: String? = nil,
                kind: TerminalKind? = nil, closedAt: Date = Date(),
                claudeSessionID: String? = nil, lineCount: Int = 0) {
        self.id = id
        self.worktreeID = worktreeID
        self.label = label
        self.kind = kind
        self.closedAt = closedAt
        self.claudeSessionID = claudeSessionID
        self.lineCount = lineCount
    }
}

/// Kind of reaped directory a `ReapRecord` describes.
public enum ReapKind: String, Codable, Sendable {
    case agentWorktree
    case scratchpad
    /// A TBD worktree directory reclaimed after its archive failed to remove
    /// it, or drained from a pool's `.deleting/` queue.
    case archivedWorktree
    /// A per-profile config directory under `~/tbd/profiles/<uuid>/` whose
    /// `model_profiles` row is gone.
    ///
    /// Reaped by **quarantine**, not deletion: the directory is renamed into
    /// `.reaped/` and `quarantinePath` records where, so its credentials and
    /// user content stay hand-recoverable until the retention window expires.
    /// It is **not restorable** — `OrphanGC.restore` accepts `.agentWorktree`
    /// only, and must keep doing so: the profile row this directory depends on
    /// is already gone, so renaming it back would just recreate an orphan for
    /// the next sweep.
    case profileDir
    /// A process that outlived the worktree it was rooted in — reclaimed by
    /// `OrphanProcessCollector`
    /// (`docs/specs/2026-08-18-orphan-process-gc-design.md`).
    ///
    /// The record describes a **kill**, not a directory, so it reads the
    /// `ReapRecord` fields differently from every other kind:
    /// - `worktreePath` is the dead worktree the process was rooted in — the
    ///   TBD-managed root its resolved cwd fell under, not a path this reap
    ///   removed. Nothing on disk was touched.
    /// - `processDescription` carries the pid and a truncated argv, so the
    ///   record says *what* was killed and not merely where it lived.
    /// - `branch`, `headSHA`, `snapshotRef` and `quarantinePath` are unused
    ///   and always `nil`: they are path- and git-shaped, and a process has
    ///   neither a git identity nor a quarantine.
    ///
    /// It is **not restorable** — `OrphanGC.restore` rejects it explicitly. A
    /// killed process cannot be brought back, so the record is an audit trail
    /// rather than an undo.
    case orphanProcess
}

/// Record of a directory the daemon-owned orphan GC swept and (optionally)
/// snapshotted before removal. Persisted so a swept worktree/scratchpad can
/// be listed and restored later.
public struct ReapRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var kind: ReapKind
    /// Main repo root ("" for scratchpads with no repo).
    public var repoPath: String
    /// Reaped dir (agent worktree path, or scratchpad path).
    public var worktreePath: String
    /// `agentWorktree` only.
    public var branch: String?
    /// `agentWorktree` only.
    public var headSHA: String?
    /// `refs/tbd/snapshots/...` when dirty state was captured.
    public var snapshotRef: String?
    /// `du -sk` * 1024 at reap time.
    public var apparentBytes: Int64?
    /// Where a quarantined reap parked the directory (`profileDir` only).
    /// `nil` for kinds that delete outright. Not a restore pointer —
    /// `OrphanGC.restore` rejects `.profileDir` — but the path a user needs to
    /// retrieve anything by hand before the retention window expires.
    public var quarantinePath: String?
    /// What was killed (`orphanProcess` only): the pid and a truncated argv.
    /// `nil` for every directory-shaped kind, and for rows written before the
    /// column existed.
    public var processDescription: String?
    public var reapedAt: Date
    public var restoredAt: Date?

    public init(id: UUID = UUID(), kind: ReapKind, repoPath: String, worktreePath: String,
                branch: String? = nil, headSHA: String? = nil, snapshotRef: String? = nil,
                apparentBytes: Int64? = nil, quarantinePath: String? = nil,
                processDescription: String? = nil,
                reapedAt: Date = Date(), restoredAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.repoPath = repoPath
        self.worktreePath = worktreePath
        self.branch = branch
        self.headSHA = headSHA
        self.snapshotRef = snapshotRef
        self.apparentBytes = apparentBytes
        self.quarantinePath = quarantinePath
        self.processDescription = processDescription
        self.reapedAt = reapedAt
        self.restoredAt = restoredAt
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
    /// A session/weekly usage limit was hit. Message carries either the
    /// scheduled auto-resume time (gate on) or the reset time (gate off).
    case limitReached = "limit_reached"

    public var severity: Int {
        switch self {
        case .error: 4
        case .attentionNeeded: 3
        case .focusRequest: 3
        case .limitReached: 3
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
    /// List of files changed in the PR (lazy-fetched on demand by the merge gate).
    public let files: [String]?
    /// Number of commits in the PR (lazy-fetched on demand by the merge gate).
    public let commits: Int?
    /// UUID of the worktree that authored this PR, if known.
    public let authorWorktreeID: UUID?
    /// 1-indexed position in GitHub's merge queue (front of queue == 1), or nil
    /// when the PR is not in a merge queue. Sourced from
    /// `PullRequest.mergeQueueEntry.position` — not expressible via
    /// `mergeStateStatus` (there is no `QUEUED` value). Optional with a nil
    /// default so JSON persisted before this field existed still decodes: it
    /// rides in the existing `worktree.prStatus` TEXT column (migration v34),
    /// so no new migration is required.
    public let mergeQueuePosition: Int?

    /// When this status was read from the forge.
    ///
    /// The persisted `PRStatus` is display-tier and must be labeled as such:
    /// this cache was measured showing "Ready to merge" for pull requests
    /// merged days earlier, so no surface may render it as current truth
    /// without its age. Optional with a nil default so JSON persisted before
    /// this field existed still decodes — it rides in the existing
    /// `worktree.prStatus` TEXT column (migration v34), exactly as
    /// `mergeQueuePosition` does, so **no migration is required**.
    ///
    /// `var`, unlike every field beside it, so `withObservedAt(_:)` can restamp
    /// a whole value without re-listing the others — see `sameValue(as:)`.
    public var observedAt: Date?

    public init(number: Int, url: String, state: PRMergeableState, reason: String? = nil,
                files: [String]? = nil, commits: Int? = nil, authorWorktreeID: UUID? = nil,
                mergeQueuePosition: Int? = nil, observedAt: Date? = nil) {
        self.number = number
        self.url = url
        self.state = state
        self.reason = reason
        self.files = files
        self.commits = commits
        self.authorWorktreeID = authorWorktreeID
        self.mergeQueuePosition = mergeQueuePosition
        self.observedAt = observedAt
    }

    /// Whether two readings describe the **same pull request state**, ignoring
    /// when each was read.
    ///
    /// **Change detection uses this; `==` does not.** `observedAt` advances on
    /// every poll, so an equality that includes it answers "different" every
    /// cadence — which turns any "on change" rule built on it into "every
    /// time". That is not hypothetical: including the stamp in `Equatable` once
    /// turned `PRStatusManager.apply`'s persist-on-change into one SQLite write
    /// transaction per worktree per poll, forever, on a fleet whose steady
    /// state had been zero. A freshness stamp is a fact *about* a reading, and
    /// a fact about a reading may never decide whether the reading changed.
    ///
    /// `Equatable` itself deliberately keeps the stamp: two `PRStatus` values
    /// read at different moments really are different values, and a persisted
    /// round trip has to be able to prove the stamp survived.
    ///
    /// **Structural, not a hand-written field list**, and that is the whole
    /// point of the shape. A list has to be remembered: a ninth property added
    /// to this type and forgotten here would silently stop persisting on change,
    /// with nothing red to say so. Stamping both sides to the same `observedAt`
    /// and deferring to synthesized `Equatable` covers every field this type
    /// will ever have, because the compiler writes that comparison.
    public func sameValue(as other: PRStatus) -> Bool {
        withObservedAt(nil) == other.withObservedAt(nil)
    }

    /// This reading with its freshness stamp replaced.
    ///
    /// A whole-value copy (`var copy = self`), deliberately, rather than a call
    /// to the memberwise initializer: every parameter there past `reason` has a
    /// default, so a field added to the struct and omitted from such a call
    /// would compile and be silently dropped. Copying carries fields this code
    /// has never heard of.
    public func withObservedAt(_ date: Date?) -> PRStatus {
        var copy = self
        copy.observedAt = date
        return copy
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
    case nestedMemory
    case other

    /// Lenient decode: an unrecognized raw value degrades to `.other` rather
    /// than throwing. Adding a case would otherwise make an OLD app binary
    /// fail to decode a NEW daemon's payload — the schema-skew failure class
    /// documented in CLAUDE.md. The encoder stays synthesized.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SystemKind(rawValue: raw) ?? .other
    }
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
    /// `source` names where injected context came from (a `displayPath` like
    /// `.github/CLAUDE.md`, or a hook name like `PostToolUse:Read`) and
    /// `truncatedTo` carries the ORIGINAL character count when `text` was
    /// capped — same semantics as `toolCall.inputTruncatedTo`. Both default to
    /// nil; only attachment-derived reminders populate them.
    case systemReminder(id: String, kind: SystemKind, text: String, timestamp: Date?,
                        source: String? = nil, truncatedTo: Int? = nil)
    case slashCommand(id: String, name: String, args: String?, timestamp: Date?)

    public var id: String {
        switch self {
        case .userPrompt(let id, _, _): return id
        case .assistantText(let id, _, _, _): return id
        case .toolCall(let id, _, _, _, _, _, _, _): return id
        case .thinking(let id, _, _): return id
        case .systemReminder(let id, _, _, _, _, _): return id
        case .slashCommand(let id, _, _, _): return id
        }
    }

    public var timestamp: Date? {
        switch self {
        case .userPrompt(_, _, let t),
             .assistantText(_, _, let t, _),
             .toolCall(_, _, _, _, _, _, let t, _),
             .thinking(_, _, let t),
             .systemReminder(_, _, _, let t, _, _),
             .slashCommand(_, _, _, let t):
            return t
        }
    }

    /// The `TokenUsage` stamped on items derived from an assistant API call,
    /// `nil` for all other item kinds. Used by the transcript pane to find
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
