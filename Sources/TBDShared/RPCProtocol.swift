import Foundation

// MARK: - RPC Request / Response

/// RPC request with method string and raw JSON params.
/// The router decodes params based on the method string.
/// Params are stored as a JSON string so the wire format is human-readable (not base64).
public struct RPCRequest: Codable, Sendable {
    public let method: String
    public let params: String

    public init(method: String, params: String = "{}") {
        self.method = method
        self.params = params
    }

    /// Convenience: encode a Codable param struct into an RPCRequest.
    public init<P: Encodable>(method: String, params: P) throws {
        self.method = method
        let data = try JSONEncoder().encode(params)
        self.params = String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Decode the params JSON string into Data for JSONDecoder consumption.
    public var paramsData: Data {
        Data(params.utf8)
    }
}

/// RPC response with success flag, optional raw JSON result, and optional error message.
/// The caller decodes the result based on what it expects for the method it called.
/// Result is stored as a JSON string so the wire format is human-readable (not base64).
public struct RPCResponse: Codable, Sendable {
    public let success: Bool
    public let result: String?
    public let error: String?
    /// Machine-readable code carried alongside `error`'s human string,
    /// so the app can branch on a specific failure without matching message text.
    /// Optional on the wire — nil for errors that carry no code.
    public let errorCode: String?

    public init<R: Encodable>(result: R) throws {
        self.success = true
        let data = try JSONEncoder().encode(result)
        self.result = String(data: data, encoding: .utf8)
        self.error = nil
        self.errorCode = nil
    }

    public init(error: String, code: String? = nil) {
        self.success = false
        self.result = nil
        self.error = error
        self.errorCode = code
    }

    /// Convenience for success responses with no meaningful result payload.
    public static func ok() -> RPCResponse {
        RPCResponse(successWithNoResult: ())
    }

    private init(successWithNoResult: Void) {
        self.success = true
        self.result = nil
        self.error = nil
        self.errorCode = nil
    }

    /// Decode the result payload into the expected type.
    public func decodeResult<R: Decodable>(_ type: R.Type) throws -> R {
        guard let resultString = result else {
            throw RPCError.noResultData
        }
        let data = Data(resultString.utf8)
        return try JSONDecoder().decode(type, from: data)
    }
}

public enum RPCError: Error, Sendable {
    case noResultData
}

/// Machine-readable code carried alongside `RPCResponse.error`'s human string,
/// so the app can branch on a specific failure (e.g. offer a fallback) without
/// matching message text. Optional on the wire — nil for errors that carry no code.
public enum RPCErrorCode: String, Sendable {
    /// A parked terminal's pinned model profile no longer resolves; the wake was
    /// refused. The app offers a default-account fallback retry
    /// (`TerminalWakeParams.fallbackToDefaultProfile`).
    case profileMissing
}

// MARK: - RPC Method Names

public enum RPCMethod {
    public static let repoAdd = "repo.add"
    public static let repoRemove = "repo.remove"
    public static let repoList = "repo.list"
    public static let worktreeCreate = "worktree.create"
    public static let worktreeList = "worktree.list"
    public static let worktreeArchive = "worktree.archive"
    public static let worktreeRerunPreSession = "worktree.rerunPreSession"
    public static let worktreeRevive = "worktree.revive"
    public static let worktreeAdopt = "worktree.adopt"
    public static let worktreeRename = "worktree.rename"
    public static let worktreeReorder = "worktree.reorder"
    public static let worktreeMove = "worktree.move"
    public static let worktreeForget = "worktree.forget"
    public static let terminalCreate = "terminal.create"
    public static let terminalList = "terminal.list"
    public static let terminalSend = "terminal.send"
    public static let terminalFocus = "terminal.focus"
    public static let terminalDelete = "terminal.delete"
    public static let terminalSetPin = "terminal.setPin"
    public static let notify = "notify"
    public static let daemonStatus = "daemon.status"
    public static let stateSubscribe = "state.subscribe"
    public static let resolvePath = "resolve.path"
    public static let notificationsList = "notifications.list"
    public static let notificationsMarkRead = "notifications.markRead"
    public static let prList    = "pr.list"
    public static let prRefresh = "pr.refresh"
    public static let cleanup = "cleanup"
    public static let claudeSetSpawnPreferences = "claude.setSpawnPreferences"
    public static let claudeRateLimitDetected = "claude.rateLimitDetected"
    public static let claudeTransientApiErrorDetected = "claude.transientApiErrorDetected"
    public static let terminalSuspend = "terminal.suspend"
    public static let terminalResume = "terminal.resume"
    public static let worktreeSuspend = "worktree.suspend"
    public static let worktreeResume = "worktree.resume"
    public static let attachRequest = "attach.request"
    public static let attachReady = "attach.ready"
    public static let paneDetach = "pane.detach"
    public static let paneResize = "pane.resize"
    public static let daemonCapabilities = "daemon.capabilities"
    public static let terminalRecreateWindow = "terminal.recreateWindow"
    public static let noteCreate = "note.create"
    public static let noteGet = "note.get"
    public static let noteUpdate = "note.update"
    public static let noteDelete = "note.delete"
    public static let noteList = "note.list"
    public static let terminalHistoryList = "terminalHistory.list"
    public static let terminalHistoryRevive = "terminalHistory.revive"
    public static let terminalOutput = "terminal.output"
    public static let terminalConversation = "terminal.conversation"
    public static let terminalTranscript = "terminal.transcript"
    public static let terminalTranscriptItemFullBody = "terminal.transcriptItemFullBody"
    public static let repoUpdateInstructions = "repo.updateInstructions"
    public static let modelProfileList = "modelProfile.list"
    public static let modelProfileAdd = "modelProfile.add"
    public static let modelProfileDelete = "modelProfile.delete"
    public static let modelProfileRename = "modelProfile.rename"
    public static let modelProfileUpdateEndpoint = "modelProfile.updateEndpoint"
    public static let modelProfileUpdateBedrock = "modelProfile.updateBedrock"
    public static let modelProfileSetGlobalDefault = "modelProfile.setGlobalDefault"
    public static let modelProfileSetPrimaryAgentPreference = "modelProfile.setPrimaryAgentPreference"
    public static let modelProfileSetRepoOverride = "modelProfile.setRepoOverride"
    public static let modelProfileReorder = "modelProfile.reorder"
    public static let modelProfileFetchUsage = "modelProfile.fetchUsage"
    public static let modelProfileUsageRefresh = "modelProfile.usageRefresh"
    public static let modelProfileHealthCheck = "modelProfile.healthCheck"
    public static let modelProfilePrepareConfigDir = "modelProfile.prepareConfigDir"
    public static let terminalSwapProfile = "terminal.swapProfile"
    public static let terminalSessionEvent = "terminal.sessionEvent"
    public static let terminalActivityEvent = "terminal.activityEvent"
    public static let terminalAskUserQuestionPending = "terminal.askUserQuestionPending"
    public static let terminalAskUserQuestionCleared = "terminal.askUserQuestionCleared"
    public static let appSetForegroundState = "app.setForegroundState"
    public static let repoRelocate = "repo.relocate"
    public static let repoRename = "repo.rename"
    public static let repoSetHidden = "repo.setHidden"
    public static let repoSetExpanded = "repo.setExpanded"
    public static let sessionList = "session.list"
    public static let sessionMessages = "session.messages"
    public static let setMainAreaSize = "app.setMainAreaSize"
    public static let daemonLegacyHooksStatus = "daemon.legacyHooksStatus"
    public static let daemonRemoveLegacyGlobalHooks = "daemon.removeLegacyGlobalHooks"
    public static let tabSetLabel = "tab.setLabel"
    public static let tabSetOrder = "tab.setOrder"
    public static let tabList     = "tab.list"
    public static let worktreeSetActiveTab = "worktree.setActiveTab"
    public static let appearanceUpdateColorFgBg = "appearance.updateColorFgBg"
    public static let repoListBranches = "repo.listBranches"
    public static let repoListOpenPRs = "repo.listOpenPRs"
    public static let configSetEnvOverrides       = "config.setEnvOverrides"
    public static let repoSetEnvOverrides         = "repo.setEnvOverrides"
    public static let modelProfileSetEnvOverrides = "modelProfile.setEnvOverrides"
    public static let worktreeSetAutoArchive = "worktree.setAutoArchive"
    public static let worktreeSetAutoHibernate = "worktree.setAutoHibernate"
    public static let configGet = "config.get"
    public static let configSetAutoArchiveOnMergeDefault = "config.setAutoArchiveOnMergeDefault"
    public static let configSetAutoHibernateOnMergeDefault = "config.setAutoHibernateOnMergeDefault"
    public static let configSetAutoResumeOnLimitReset = "config.setAutoResumeOnLimitReset"
    public static let configSetAutoResumeOnApiError = "config.setAutoResumeOnApiError"
    public static let configSetScratchInstructions = "config.setScratchInstructions"
    public static let configSetScratchRenamePrompt = "config.setScratchRenamePrompt"
    public static let configSetScratchProfileOverride = "config.setScratchProfileOverride"
    public static let terminalHibernate = "terminal.hibernate"
    public static let terminalWake = "terminal.wake"
    public static let terminalSetKeepWarm = "terminal.setKeepWarm"
    public static let configSetAutoHibernate = "config.setAutoHibernate"
    public static let scratchCreate = "scratch.create"
    public static let scratchDelete = "scratch.delete"
    public static let scratchPromote = "scratch.promote"
    public static let scratchArchive = "scratch.archive"
    public static let scratchRevive = "scratch.revive"
    public static let nightwatchSetMode = "nightwatch.setMode"
    public static let nightwatchReport = "nightwatch.report"
    public static let terminalCancelScheduledResume = "terminal.cancelScheduledResume"
    public static let configSetControlMode = "config.setControlMode"
    public static let configSetHibernateInputVeto = "config.setHibernateInputVeto"
    public static let configSetAutoCloseSetup = "config.setAutoCloseSetup"
    public static let gcList = "gc.list"
    public static let gcRestore = "gc.restore"
    public static let gcSweepNow = "gc.sweepNow"
    public static let configSetGCEnabled = "config.setGCEnabled"
    public static let panelGet = "panel.get"
    public static let panelApply = "panel.apply"
    public static let panelImportLegacy = "panel.importLegacy"
}

// MARK: - Branch Listing

/// Codable mirror of `BranchRef` for the `repo.listBranches` RPC.
public struct BranchInfo: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let localName: String
    public let isRemote: Bool

    public var id: String { name }

    public init(name: String, localName: String, isRemote: Bool) {
        self.name = name
        self.localName = localName
        self.isRemote = isRemote
    }
}

public struct RepoListBranchesParams: Codable, Sendable {
    public let repoID: UUID
    public init(repoID: UUID) { self.repoID = repoID }
}

public struct RepoListBranchesResult: Codable, Sendable {
    public let branches: [BranchInfo]
    public init(branches: [BranchInfo]) { self.branches = branches }
}

// MARK: - Open PR Listing

/// One open PR on a repo, for the `repo.listOpenPRs` RPC (branch picker).
public struct OpenPRInfo: Codable, Sendable, Equatable, Identifiable {
    public let number: Int
    public let title: String
    public let headRefName: String
    public let headOwner: String        // headRepositoryOwner.login; "" if absent
    public let isCrossRepository: Bool
    public let isDraft: Bool
    public var id: Int { number }

    public init(number: Int, title: String, headRefName: String, headOwner: String,
                isCrossRepository: Bool, isDraft: Bool) {
        self.number = number
        self.title = title
        self.headRefName = headRefName
        self.headOwner = headOwner
        self.isCrossRepository = isCrossRepository
        self.isDraft = isDraft
    }
}

public struct RepoListOpenPRsParams: Codable, Sendable {
    public let repoID: UUID
    public init(repoID: UUID) { self.repoID = repoID }
}

public struct RepoListOpenPRsResult: Codable, Sendable {
    public let prs: [OpenPRInfo]
    public init(prs: [OpenPRInfo]) { self.prs = prs }
}

// MARK: - Legacy Hook Detection / Removal

/// One detected legacy entry — surfaced to the user so they know what TBD
/// proposes to remove (or, for repo-level entries, what they can edit
/// themselves).
public struct LegacyHookEntry: Codable, Sendable, Equatable {
    /// "Stop", "SessionStart", etc. — the matcher event name.
    public let event: String
    /// Captured `command` string from the matched entry (truncated upstream
    /// if needed so the dialog stays readable).
    public let command: String
    public init(event: String, command: String) {
        self.event = event
        self.command = command
    }
}

public struct LegacyHooksStatusResult: Codable, Sendable {
    public let globalEntries: [LegacyHookEntry]
    /// Repo-level entries keyed by repo settings.json path. Surfaced
    /// informationally; TBD never auto-modifies repo files.
    public let repoEntries: [String: [LegacyHookEntry]]
    public init(globalEntries: [LegacyHookEntry], repoEntries: [String: [LegacyHookEntry]]) {
        self.globalEntries = globalEntries
        self.repoEntries = repoEntries
    }
}

public struct RemoveLegacyGlobalHooksResult: Codable, Sendable {
    public let removedCount: Int
    public let backupPath: String?
    public init(removedCount: Int, backupPath: String?) {
        self.removedCount = removedCount
        self.backupPath = backupPath
    }
}

// MARK: - Main Area Size

public struct SetMainAreaSizeParams: Codable, Sendable {
    public let cols: Int
    public let rows: Int
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

public struct AppSetForegroundStateParams: Codable, Sendable {
    public let isForeground: Bool
    public init(isForeground: Bool) { self.isForeground = isForeground }
}

// MARK: - Appearance RPC

public struct AppearanceUpdateColorFgBgParams: Codable, Sendable {
    /// COLORFGBG environment variable value computed from terminal color scheme's
    /// background luminance. Format: "0;15" for light bg or "15;0" for dark bg.
    public let value: String
    public init(value: String) { self.value = value }
}

// MARK: - Nightwatch RPC

public struct NightwatchSetModeParams: Codable, Sendable {
    public let mode: NightwatchMode
    public init(mode: NightwatchMode) { self.mode = mode }
}

public struct NightwatchReportParams: Codable, Sendable {
    public let since: Date?
    public let action: AuditAction?

    public init(since: Date? = nil, action: AuditAction? = nil) {
        self.since = since
        self.action = action
    }
}

// MARK: - Terminal Swap Profile

/// How `terminal.swapProfile` reshapes the session.
///
/// - `inPlace`: SEAMLESS account switch — interrupt the pane's current Claude,
///   respawn `claude --resume <id>` under the new profile IN THE SAME tmux
///   window, and update the existing terminal row in place. One tab, no new
///   row/tab. This is the "Switch account" action.
/// - `fork`: duplicate the conversation into a NEW tab/terminal row (the old
///   fork-into-new-tab behavior), leaving the source session untouched. This
///   is the explicit "Fork session" action.
public enum TerminalSwapMode: String, Codable, Sendable, Equatable {
    case inPlace
    case fork
}

public struct TerminalSwapProfileParams: Codable, Sendable {
    public let terminalID: UUID
    public let newProfileID: UUID?
    /// Initial tmux window size in cells (see WorktreeCreateParams).
    public let cols: Int?
    public let rows: Int?
    /// Swap reshaping mode. Optional + `decodeIfPresent` so payloads from older
    /// clients still decode; a missing value defaults to `.inPlace` (seamless
    /// same-tab switch) — the common "Switch account" path.
    public let mode: TerminalSwapMode?
    public init(
        terminalID: UUID,
        newProfileID: UUID?,
        cols: Int? = nil,
        rows: Int? = nil,
        mode: TerminalSwapMode? = nil
    ) {
        self.terminalID = terminalID
        self.newProfileID = newProfileID
        self.cols = cols
        self.rows = rows
        self.mode = mode
    }

    /// Resolved mode with the default applied — `.inPlace` when the field is
    /// absent (older clients / the common switch-account path).
    public var resolvedMode: TerminalSwapMode { mode ?? .inPlace }
}

// MARK: - Model Profile RPC

public enum ModelProfileAddKind: String, Codable, Sendable, Equatable {
    case claudeDirect   // existing OAuth / api-key path; uses `token`
    case proxy          // existing proxy path; uses `token` + `baseURL`
    case bedrock        // NEW; uses `awsRegion` + optional `awsProfile`; no token
}

public struct ModelProfileAddParams: Codable, Sendable {
    public let kind: ModelProfileAddKind?
    public let name: String
    public let token: String?
    public let baseURL: String?
    public let model: String?
    public let awsRegion: String?
    public let awsProfile: String?
    /// Ordered list of fallback model ids (tried in order on overload). nil =
    /// none. Optional/decodeIfPresent so payloads from older clients still decode.
    public let fallbackModels: [String]?

    public init(name: String,
                kind: ModelProfileAddKind? = nil,
                token: String? = nil,
                baseURL: String? = nil,
                model: String? = nil,
                awsRegion: String? = nil,
                awsProfile: String? = nil,
                fallbackModels: [String]? = nil) {
        self.kind = kind
        self.name = name
        self.token = token
        self.baseURL = baseURL
        self.model = model
        self.awsRegion = awsRegion
        self.awsProfile = awsProfile
        self.fallbackModels = fallbackModels
    }

    enum CodingKeys: String, CodingKey {
        case kind, name, token, baseURL, model, awsRegion, awsProfile, fallbackModels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(ModelProfileAddKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        awsRegion = try c.decodeIfPresent(String.self, forKey: .awsRegion)
        awsProfile = try c.decodeIfPresent(String.self, forKey: .awsProfile)
        fallbackModels = try c.decodeIfPresent([String].self, forKey: .fallbackModels)
    }
}

public struct ModelProfileAddResult: Codable, Sendable {
    public let profile: ModelProfile
    public let warning: String?
    public init(profile: ModelProfile, warning: String? = nil) {
        self.profile = profile
        self.warning = warning
    }
}

public struct ModelProfileDeleteParams: Codable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

public struct ModelProfileRenameParams: Codable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID, name: String) {
        self.id = id; self.name = name
    }
}

public struct ModelProfileUpdateEndpointParams: Codable, Sendable {
    public let id: UUID
    public let baseURL: String?
    public let model: String?
    /// Ordered fallback model ids; nil = leave unset/clear. Optional/
    /// decodeIfPresent so older payloads still decode.
    public let fallbackModels: [String]?
    public init(id: UUID, baseURL: String?, model: String?, fallbackModels: [String]? = nil) {
        self.id = id; self.baseURL = baseURL; self.model = model
        self.fallbackModels = fallbackModels
    }

    enum CodingKeys: String, CodingKey {
        case id, baseURL, model, fallbackModels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        fallbackModels = try c.decodeIfPresent([String].self, forKey: .fallbackModels)
    }
}

public struct ModelProfileUpdateBedrockParams: Codable, Sendable {
    public let id: UUID
    public let awsRegion: String
    public let awsProfile: String?
    public let model: String
    /// Ordered fallback model ids; nil = leave unset/clear. Optional/
    /// decodeIfPresent so older payloads still decode.
    public let fallbackModels: [String]?
    public init(id: UUID, awsRegion: String, awsProfile: String?, model: String, fallbackModels: [String]? = nil) {
        self.id = id
        self.awsRegion = awsRegion
        self.awsProfile = awsProfile
        self.model = model
        self.fallbackModels = fallbackModels
    }

    enum CodingKeys: String, CodingKey {
        case id, awsRegion, awsProfile, model, fallbackModels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        awsRegion = try c.decode(String.self, forKey: .awsRegion)
        awsProfile = try c.decodeIfPresent(String.self, forKey: .awsProfile)
        model = try c.decode(String.self, forKey: .model)
        fallbackModels = try c.decodeIfPresent([String].self, forKey: .fallbackModels)
    }
}

public struct ModelProfileSetGlobalDefaultParams: Codable, Sendable {
    public let id: UUID?
    public init(id: UUID?) { self.id = id }
}

public struct ModelProfileSetAgentPreferenceParams: Codable, Sendable {
    public let preference: PrimaryAgentPreference
    public init(preference: PrimaryAgentPreference) { self.preference = preference }
}

public struct ModelProfileSetRepoOverrideParams: Codable, Sendable {
    public let repoID: UUID
    public let profileID: UUID?
    public init(repoID: UUID, profileID: UUID?) {
        self.repoID = repoID; self.profileID = profileID
    }
}

public struct ModelProfileFetchUsageParams: Codable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

public struct ModelProfileListResult: Codable, Sendable {
    public let profiles: [ModelProfileWithUsage]
    public let defaultID: UUID?
    public let primaryAgentPreference: PrimaryAgentPreference
    /// The global free-form env overrides (config scope). Carried alongside the
    /// other config-derived fields so the app loads it in one round-trip.
    public let globalEnvOverrides: [String: String]
    public let autoArchiveOnMergeDefault: Bool
    public let autoHibernateOnMergeDefault: Bool
    public let nightwatchMode: NightwatchMode
    public let autoResumeOnLimitReset: Bool
    public let autoResumeOnApiError: Bool
    /// The orphan-GC master switch (config mirror, default true).
    public let gcEnabled: Bool
    public init(
        profiles: [ModelProfileWithUsage],
        defaultID: UUID? = nil,
        primaryAgentPreference: PrimaryAgentPreference = .defaultValue,
        globalEnvOverrides: [String: String] = [:],
        autoArchiveOnMergeDefault: Bool = false,
        autoHibernateOnMergeDefault: Bool = false,
        nightwatchMode: NightwatchMode = .off,
        autoResumeOnLimitReset: Bool = false,
        autoResumeOnApiError: Bool = false,
        gcEnabled: Bool = true
    ) {
        self.profiles = profiles
        self.defaultID = defaultID
        self.primaryAgentPreference = primaryAgentPreference
        self.globalEnvOverrides = globalEnvOverrides
        self.autoArchiveOnMergeDefault = autoArchiveOnMergeDefault
        self.autoHibernateOnMergeDefault = autoHibernateOnMergeDefault
        self.nightwatchMode = nightwatchMode
        self.autoResumeOnLimitReset = autoResumeOnLimitReset
        self.autoResumeOnApiError = autoResumeOnApiError
        self.gcEnabled = gcEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decode([ModelProfileWithUsage].self, forKey: .profiles)
        defaultID = try c.decodeIfPresent(UUID.self, forKey: .defaultID)
        primaryAgentPreference = try c.decodeIfPresent(
            PrimaryAgentPreference.self,
            forKey: .primaryAgentPreference
        ) ?? .defaultValue
        globalEnvOverrides = try c.decodeIfPresent(
            [String: String].self,
            forKey: .globalEnvOverrides
        ) ?? [:]
        autoArchiveOnMergeDefault = try c.decodeIfPresent(
            Bool.self, forKey: .autoArchiveOnMergeDefault) ?? false
        autoHibernateOnMergeDefault = try c.decodeIfPresent(
            Bool.self, forKey: .autoHibernateOnMergeDefault) ?? false
        nightwatchMode = try c.decodeIfPresent(
            NightwatchMode.self, forKey: .nightwatchMode) ?? .off
        autoResumeOnLimitReset = try c.decodeIfPresent(
            Bool.self, forKey: .autoResumeOnLimitReset) ?? false
        autoResumeOnApiError = try c.decodeIfPresent(
            Bool.self, forKey: .autoResumeOnApiError) ?? false
        gcEnabled = try c.decodeIfPresent(Bool.self, forKey: .gcEnabled) ?? true
    }
}

public struct ModelProfileFetchUsageResult: Codable, Sendable {
    public let usage: ModelProfileUsage
    public init(usage: ModelProfileUsage) { self.usage = usage }
}

/// Params for `modelProfile.usageRefresh` — sweep the daemon's OAuth usage
/// poller for stale, eligible profiles (the picker dialog calls this on
/// open). Profiles with a fresh snapshot or inside a rate-limit backoff
/// window are skipped; their cached snapshot is returned instead. `id == nil`
/// covers every logged-in OAuth profile; a non-nil id just that profile.
public struct ModelProfileUsageRefreshParams: Codable, Sendable {
    public let id: UUID?
    public init(id: UUID? = nil) { self.id = id }
}

public struct ModelProfileUsageSnapshotEntry: Codable, Sendable, Equatable {
    public let profileID: UUID
    public let snapshot: ProfileUsageSnapshot
    public init(profileID: UUID, snapshot: ProfileUsageSnapshot) {
        self.profileID = profileID
        self.snapshot = snapshot
    }
}

public struct ModelProfileUsageRefreshResult: Codable, Sendable {
    /// Post-sweep snapshots. All logged-in OAuth profiles when params.id was
    /// nil; at most the one requested profile otherwise (empty when that
    /// profile is not an eligible logged-in OAuth profile).
    public let snapshots: [ModelProfileUsageSnapshotEntry]
    public init(snapshots: [ModelProfileUsageSnapshotEntry]) {
        self.snapshots = snapshots
    }
}

public struct ModelProfileHealthCheckParams: Codable, Sendable {
    public let baseURL: String
    public init(baseURL: String) { self.baseURL = baseURL }
}

public struct ModelProfileHealthCheckResult: Codable, Sendable {
    public let reachable: Bool
    public let statusCode: Int?
    public let detail: String?
    public init(reachable: Bool, statusCode: Int?, detail: String?) {
        self.reachable = reachable; self.statusCode = statusCode; self.detail = detail
    }
}

/// Params for `modelProfile.prepareConfigDir` — ensure an OAuth profile's
/// isolated `CLAUDE_CONFIG_DIR` exists and is seeded (`.claude.json` +
/// host-mirror symlinks) so a client can hand it to a `claude` process
/// (e.g. `tbd profile login`) without reimplementing provisioning.
public struct ModelProfilePrepareConfigDirParams: Codable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

public struct ModelProfilePrepareConfigDirResult: Codable, Sendable {
    /// Absolute path of the profile's isolated `CLAUDE_CONFIG_DIR`
    /// (`~/tbd/profiles/<lowercased-uuid>/claude`).
    public let configDirPath: String
    public init(configDirPath: String) { self.configDirPath = configDirPath }
}

public struct NotificationsListResult: Codable, Sendable {
    /// Legacy field — highest-severity unread type per worktree. Retained
    /// for backwards compatibility during rollout. Newer clients should
    /// prefer `summaries`. Always populated by the daemon.
    public let notifications: [UUID: NotificationType]

    /// New field (v0.1.1+) — full unread summary including timestamps.
    /// Optional for backwards compatibility: an older daemon will omit it
    /// and a newer app should reconstruct summaries from `notifications`
    /// when `summaries` is absent.
    public let summaries: [UUID: UnreadSummary]?

    public init(
        notifications: [UUID: NotificationType],
        summaries: [UUID: UnreadSummary]? = nil
    ) {
        self.notifications = notifications
        self.summaries = summaries
    }
}

public struct NotificationsMarkReadParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct PRListResult: Codable, Sendable {
    public let statuses: [UUID: PRStatus]
    public init(statuses: [UUID: PRStatus]) { self.statuses = statuses }
}

public struct PRRefreshParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

// PRRefreshResult wraps an optional PRStatus.
// nil means no PR found for this worktree's branch.
public struct PRRefreshResult: Codable, Sendable {
    public let status: PRStatus?
    public init(status: PRStatus?) { self.status = status }
}

// MARK: - Parameter Structs

public struct RepoAddParams: Codable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
}

public struct ScratchCreateParams: Codable, Sendable {
    public let name: String?
    public init(name: String? = nil) { self.name = name }
}

public struct ScratchDeleteParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct ScratchPromoteParams: Codable, Sendable {
    public let worktreeID: UUID
    public let destPath: String
    public let displayName: String?
    public init(worktreeID: UUID, destPath: String, displayName: String? = nil) {
        self.worktreeID = worktreeID; self.destPath = destPath; self.displayName = displayName
    }
}

public struct ScratchArchiveParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct ScratchReviveParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct ScratchPromoteResult: Codable, Sendable {
    public let worktreeID: UUID
    public let repoID: UUID
    public let repoPath: String
    public let repoDisplayName: String
    public init(worktreeID: UUID, repoID: UUID, repoPath: String, repoDisplayName: String) {
        self.worktreeID = worktreeID; self.repoID = repoID
        self.repoPath = repoPath; self.repoDisplayName = repoDisplayName
    }
}

public struct RepoRemoveParams: Codable, Sendable {
    public let repoID: UUID
    public let force: Bool
    public init(repoID: UUID, force: Bool = false) { self.repoID = repoID; self.force = force }
}

public struct RepoUpdateInstructionsParams: Codable, Sendable {
    public let repoID: UUID
    public let renamePrompt: String?
    public let customInstructions: String?
    public init(repoID: UUID, renamePrompt: String?, customInstructions: String?) {
        self.repoID = repoID
        self.renamePrompt = renamePrompt
        self.customInstructions = customInstructions
    }
}

public struct RepoRelocateParams: Codable, Sendable {
    public let repoID: UUID
    public let newPath: String
    public init(repoID: UUID, newPath: String) {
        self.repoID = repoID
        self.newPath = newPath
    }
}

public struct RepoRelocateResult: Codable, Sendable {
    public let repo: Repo
    public let worktreesRepaired: [UUID]
    public let worktreesFailed: [UUID]
    public init(repo: Repo, worktreesRepaired: [UUID], worktreesFailed: [UUID]) {
        self.repo = repo
        self.worktreesRepaired = worktreesRepaired
        self.worktreesFailed = worktreesFailed
    }
}

public struct RepoRenameParams: Codable, Sendable {
    public let repoID: UUID
    public let displayName: String
    public init(repoID: UUID, displayName: String) {
        self.repoID = repoID; self.displayName = displayName
    }
}

public struct RepoSetHiddenParams: Codable, Sendable {
    public let repoID: UUID
    public let hidden: Bool
    public init(repoID: UUID, hidden: Bool) {
        self.repoID = repoID; self.hidden = hidden
    }
}

public struct RepoSetExpandedParams: Codable, Sendable {
    public let repoID: UUID
    public let expanded: Bool
    public init(repoID: UUID, expanded: Bool) {
        self.repoID = repoID; self.expanded = expanded
    }
}

public struct WorktreeCreateParams: Codable, Sendable {
    public let repoID: UUID
    public let folder: String?
    public let branch: String?
    public let displayName: String?
    public let prompt: String?
    /// Initial tmux window size in cells. When nil, the daemon falls back to a
    /// generous default (220x50) so Claude doesn't render at tmux's 80x24
    /// default and produce hard-wrapped scrollback that can never be reflowed.
    public let cols: Int?
    public let rows: Int?
    // Nested-worktree support. All optional, defaulted for backward compat.
    public let parentWorktreeID: UUID?     // --parent
    public let siblingOfWorktreeID: UUID?  // --sibling (caller worktree id)
    public let callerWorktreeID: UUID?     // TBD_WORKTREE_ID env
    public let suppressAutoParent: Bool?   // --no-parent
    /// When true, `branch` is treated as the name of an existing branch
    /// (local like `feat/x` or remote like `origin/feat/x`) to be checked
    /// out into a new worktree — no fresh `tbd/*` branch is created.
    /// Optional/defaulted for backward compatibility with older clients.
    public let useExistingBranch: Bool?
    /// Explicit per-creation model-profile override. When non-nil, the daemon
    /// resolves THIS profile for the new worktree's primary Claude terminal,
    /// bypassing the repo/scratch/global precedence chain. nil preserves the
    /// existing precedence-based resolution. Not persisted — creation-time only.
    /// Optional/defaulted for backward compatibility with older clients.
    public let profileID: UUID?
    /// Explicit per-creation Claude model override (e.g. "claude-fable-5"),
    /// injected as ANTHROPIC_MODEL for the new worktree's INITIAL Claude spawn
    /// only — later respawns (hibernation wake, new sessions) fall back to the
    /// profile default. nil preserves the profile's own model. Optional/
    /// defaulted for backward compatibility with older clients.
    public let model: String?
    /// Extra Claude Code settings (a JSON OBJECT string) deep-merged into TBD's
    /// per-session `--settings` overlay for this spawn's Claude agent. General
    /// passthrough — TBD does not interpret the contents. Optional/defaulted for
    /// backward compatibility (old daemons ignore the unknown key; old clients omit it).
    public let claudeSettingsOverlay: String?
    /// GitHub PR number this worktree is being created from. Stamped on the row
    /// (with `useExistingBranch == true`) so `PRStatusManager` tracks it by
    /// number — set for BOTH decorated same-repo rows and fork rows.
    /// Optional/defaulted for backward compatibility (old daemons ignore the
    /// unknown key; old clients omit it).
    public let prNumber: Int?
    /// When true, the daemon fetches `refs/pull/<prNumber>/head` into a fresh
    /// local branch and checks THAT out (fork PRs, whose head has no local
    /// ref). When false/omitted, `branch` is checked out via the plain
    /// existing-branch path even if `prNumber` is set — this is the decorated
    /// same-repo row, which must behave exactly like picking that branch today.
    /// `prNumber` alone can't disambiguate: a fork head name may coincide with
    /// an unrelated local branch. Optional/defaulted for backward compatibility.
    public let checkoutPRHead: Bool?
    /// When true, the daemon arms this worktree's per-worktree
    /// auto-archive-on-merge override (sets the `autoArchiveOnMerge` column to
    /// true), so it self-archives when its PR merges regardless of the global
    /// default. nil means "follow the global default" (unchanged behavior).
    /// Optional/defaulted for backward compatibility (old daemons ignore the
    /// unknown key; old clients omit it).
    public let autoArchiveOnMerge: Bool?
    public init(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, prompt: String? = nil, cols: Int? = nil, rows: Int? = nil, parentWorktreeID: UUID? = nil, siblingOfWorktreeID: UUID? = nil, callerWorktreeID: UUID? = nil, suppressAutoParent: Bool? = nil, useExistingBranch: Bool? = nil, profileID: UUID? = nil, model: String? = nil, claudeSettingsOverlay: String? = nil, prNumber: Int? = nil, checkoutPRHead: Bool? = nil, autoArchiveOnMerge: Bool? = nil) {
        self.repoID = repoID; self.folder = folder; self.branch = branch; self.displayName = displayName; self.prompt = prompt
        self.cols = cols; self.rows = rows
        self.parentWorktreeID = parentWorktreeID
        self.siblingOfWorktreeID = siblingOfWorktreeID
        self.callerWorktreeID = callerWorktreeID
        self.suppressAutoParent = suppressAutoParent
        self.useExistingBranch = useExistingBranch
        self.profileID = profileID
        self.model = model
        self.claudeSettingsOverlay = claudeSettingsOverlay
        self.prNumber = prNumber
        self.checkoutPRHead = checkoutPRHead
        self.autoArchiveOnMerge = autoArchiveOnMerge
    }
}

public struct WorktreeListParams: Codable, Sendable {
    public let repoID: UUID?
    public let status: WorktreeStatus?
    public let limit: Int?
    public let offset: Int?
    /// When true, the daemon omits archived worktrees from the result.
    /// Optional (nil == false) for backward compatibility — old daemons
    /// ignore the unknown key and return everything; old clients omit it.
    public let excludeArchived: Bool?
    /// When true, restrict the result to repo-less (scratch) worktrees.
    /// Optional (nil == false) for backward compatibility — old daemons
    /// ignore the unknown key and return everything; old clients omit it.
    /// Note `repoID: nil` means "no repo filter" (every repo plus scratch),
    /// NOT "scratch only" — this flag is the only way to get scratch-only rows.
    public let scratchOnly: Bool?
    /// When false, the daemon skips per-row live session-file counting for the
    /// archived listing (an expensive `~/.claude/projects/*` scan per row). The
    /// deep-link archived lookup opts out with `false` because it only needs the
    /// row's identity, not its session count. Optional (nil == true) for
    /// backward compatibility — old daemons ignore the unknown key and always
    /// enrich; old clients omit it and get the enriched default.
    public let includeSessionCounts: Bool?
    public init(
        repoID: UUID? = nil,
        status: WorktreeStatus? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        excludeArchived: Bool? = nil,
        scratchOnly: Bool? = nil,
        includeSessionCounts: Bool? = nil
    ) {
        self.repoID = repoID
        self.status = status
        self.limit = limit
        self.offset = offset
        self.excludeArchived = excludeArchived
        self.scratchOnly = scratchOnly
        self.includeSessionCounts = includeSessionCounts
    }
}

public struct WorktreeArchiveParams: Codable, Sendable {
    public let worktreeID: UUID
    public let force: Bool
    public init(worktreeID: UUID, force: Bool = false) {
        self.worktreeID = worktreeID; self.force = force
    }
}

/// Params for `gc.list` — lists reaped `ReapRecord`s, optionally scoped to
/// one repo (`nil` == every repo, including scratch reap records).
public struct GCListParams: Codable, Sendable {
    public var repoPath: String?
    public init(repoPath: String? = nil) {
        self.repoPath = repoPath
    }
}

/// Params for `gc.restore` — restores a swept `ReapRecord` by id.
public struct GCRestoreParams: Codable, Sendable {
    public var recordID: UUID
    public init(recordID: UUID) {
        self.recordID = recordID
    }
}

/// Params for `gc.sweepNow` — triggers an out-of-band sweep. `dryRun: true`
/// plans without reaping.
public struct GCSweepNowParams: Codable, Sendable {
    public var dryRun: Bool
    public init(dryRun: Bool = false) {
        self.dryRun = dryRun
    }
}

/// Result of a `gc.sweepNow` sweep (dry-run or real). Also the direct return
/// type of `OrphanGC.sweep(dryRun:)` in TBDDaemon — one type, no daemon-side
/// mirror.
public struct GCSweepResult: Codable, Sendable, Equatable {
    /// Human-readable plan lines, e.g. "REAP agent-worktree /path …", "KEEP locked /path".
    public var planned: [String]
    public var reaped: Int
    public init(planned: [String], reaped: Int) {
        self.planned = planned
        self.reaped = reaped
    }
}

/// Re-run the `preSession` hook for a worktree in a fresh, non-focused tab.
public struct WorktreeRerunPreSessionParams: Codable, Sendable {
    public let worktreeID: UUID
    /// Initial tmux window size in cells (see WorktreeCreateParams). Optional
    /// so older app builds' JSON (no cols/rows) still decodes.
    public let cols: Int?
    public let rows: Int?

    public init(worktreeID: UUID, cols: Int? = nil, rows: Int? = nil) {
        self.worktreeID = worktreeID
        self.cols = cols
        self.rows = rows
    }
}

public struct WorktreeReviveParams: Codable, Sendable {
    public let worktreeID: UUID
    /// Initial tmux window size in cells (see WorktreeCreateParams).
    public let cols: Int?
    public let rows: Int?
    /// When set, the daemon reorders the worktree's stored
    /// `archivedClaudeSessions` so this ID is first before resuming the
    /// primary Claude terminal. Optional — nil preserves existing order.
    public let preferredSessionID: String?
    public init(worktreeID: UUID, cols: Int? = nil, rows: Int? = nil, preferredSessionID: String? = nil) {
        self.worktreeID = worktreeID
        self.cols = cols
        self.rows = rows
        self.preferredSessionID = preferredSessionID
    }
}

public struct WorktreeAdoptParams: Codable, Sendable {
    public let repoID: UUID
    public let path: String
    public let displayName: String?
    public init(repoID: UUID, path: String, displayName: String? = nil) {
        self.repoID = repoID
        self.path = path
        self.displayName = displayName
    }
}

public struct WorktreeRenameParams: Codable, Sendable {
    public let worktreeID: UUID
    public let displayName: String
    public init(worktreeID: UUID, displayName: String) {
        self.worktreeID = worktreeID; self.displayName = displayName
    }
}

public struct WorktreeReorderParams: Codable, Sendable {
    public let repoID: UUID
    public let worktreeIDs: [UUID]
    public init(repoID: UUID, worktreeIDs: [UUID]) {
        self.repoID = repoID; self.worktreeIDs = worktreeIDs
    }
}

/// Params for `modelProfile.reorder`. Profiles are global — no repoID scoping
/// (unlike `WorktreeReorderParams`).
public struct ModelProfileReorderParams: Codable, Sendable {
    public let profileIDs: [UUID]
    public init(profileIDs: [UUID]) {
        self.profileIDs = profileIDs
    }
}

public struct WorktreeMoveParams: Codable, Sendable {
    public let worktreeID: UUID
    public let newParentID: UUID?
    public let newSortOrder: Int

    public init(worktreeID: UUID, newParentID: UUID?, newSortOrder: Int) {
        self.worktreeID = worktreeID
        self.newParentID = newParentID
        self.newSortOrder = newSortOrder
    }
}

/// Params for `worktree.forget`: remove a worktree from TBD's tracking without
/// deleting its on-disk directory (no `git worktree remove`).
public struct WorktreeForgetParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

/// Result for `worktree.forget`. Echoes the forgotten worktree's id and the
/// path that was deliberately left in place on disk.
public struct WorktreeForgetResult: Codable, Sendable {
    public let worktreeID: UUID
    public let path: String
    public init(worktreeID: UUID, path: String) {
        self.worktreeID = worktreeID
        self.path = path
    }
}

public enum TerminalCreateType: String, Codable, Sendable {
    case shell
    case claude
    case codex
}

public struct TerminalCreateParams: Codable, Sendable {
    public let worktreeID: UUID
    public let cmd: String?
    public let type: TerminalCreateType?
    /// Session ID to resume from (for forking a Claude session).
    public let resumeSessionID: String?
    /// Initial prompt for a fresh Claude or Codex session.
    public let prompt: String?
    /// Pin a specific profile ID for this terminal, bypassing resolve(repoID:).
    public let overrideProfileID: UUID?
    /// True for a profile *login session* (Settings → "Open login session"):
    /// requires `overrideProfileID`; the daemon labels the terminal
    /// `TerminalLabel.login`, auto-types `/login` once Claude is up, and
    /// watches the profile's config dir so the UI badge flips on completion.
    /// Optional so older clients/params decode unchanged (nil = false).
    public let loginSession: Bool?
    /// Initial tmux window size in cells (see WorktreeCreateParams).
    public let cols: Int?
    public let rows: Int?
    /// COLORFGBG environment variable value computed from active terminal color scheme's
    /// background luminance. Format: "0;15" for light bg or "15;0" for dark bg.
    public let colorFgBg: String?
    /// Extra Claude Code settings (a JSON OBJECT string) deep-merged into TBD's
    /// per-session `--settings` overlay for this spawn's Claude agent. General
    /// passthrough — TBD does not interpret the contents. Optional/defaulted for
    /// backward compatibility (old daemons ignore the unknown key; old clients omit it).
    public let claudeSettingsOverlay: String?
    public init(worktreeID: UUID, cmd: String? = nil, type: TerminalCreateType? = nil, resumeSessionID: String? = nil, prompt: String? = nil, overrideProfileID: UUID? = nil, loginSession: Bool? = nil, cols: Int? = nil, rows: Int? = nil, colorFgBg: String? = nil, claudeSettingsOverlay: String? = nil) {
        self.worktreeID = worktreeID; self.cmd = cmd; self.type = type; self.resumeSessionID = resumeSessionID; self.prompt = prompt; self.overrideProfileID = overrideProfileID
        self.loginSession = loginSession
        self.cols = cols; self.rows = rows; self.colorFgBg = colorFgBg
        self.claudeSettingsOverlay = claudeSettingsOverlay
    }
}

public struct TerminalListParams: Codable, Sendable {
    public let worktreeID: UUID?
    public init(worktreeID: UUID? = nil) { self.worktreeID = worktreeID }
}

public struct TerminalSendParams: Codable, Sendable {
    public let terminalID: UUID
    public let text: String
    /// When true, sends an Enter keypress after the text to submit it.
    public let submit: Bool?
    public init(terminalID: UUID, text: String, submit: Bool? = nil) {
        self.terminalID = terminalID; self.text = text; self.submit = submit
    }
}

public struct TerminalDeleteParams: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

/// Params for `terminalHistory.list` — closed-terminal capture metadata for a
/// worktree, newest first. Result type: `[TerminalHistoryEntry]`. Content is
/// NOT sent over RPC; the app reads the file at
/// `TBDConstants.terminalHistoryPath` directly.
public struct TerminalHistoryListParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

/// Params for `terminalHistory.revive` — spawn a NEW terminal in `worktreeID`
/// from the closed-terminal history entry `id`. Claude entries with a session
/// id resume that session; every other kind opens a fresh shell with the raw
/// capture (colors intact) printed above the prompt. Result type: `Terminal`.
public struct TerminalHistoryReviveParams: Codable, Sendable {
    public let worktreeID: UUID
    public let id: UUID
    public let cols: Int?
    public let rows: Int?
    public init(worktreeID: UUID, id: UUID, cols: Int? = nil, rows: Int? = nil) {
        self.worktreeID = worktreeID; self.id = id; self.cols = cols; self.rows = rows
    }
}

public struct TerminalSetPinParams: Codable, Sendable {
    public let terminalID: UUID
    public let pinned: Bool
    public init(terminalID: UUID, pinned: Bool) {
        self.terminalID = terminalID; self.pinned = pinned
    }
}

public struct NotifyParams: Codable, Sendable {
    public let worktreeID: UUID?
    public let type: NotificationType
    public let message: String?
    /// Originating terminal id. Optional for backwards compatibility — older
    /// CLI callers and clients won't include it. The daemon persists it on
    /// the notification row and forwards it on the broadcast delta so the
    /// app's banner-click handler can switch to the right tab.
    public let terminalID: UUID?
    public init(worktreeID: UUID? = nil, type: NotificationType, message: String? = nil,
                terminalID: UUID? = nil) {
        self.worktreeID = worktreeID; self.type = type; self.message = message
        self.terminalID = terminalID
    }
}

public struct TerminalFocusParams: Codable, Sendable {
    /// Target terminal. The daemon resolves the owning worktree from this.
    public let terminalID: UUID
    /// Banner text. Falls back to a generic message when nil.
    public let message: String?
    /// When true, foreground + select the tab immediately (loud pull).
    /// When false (default), soft push: banner + unread, no focus steal.
    public let activate: Bool
    public init(terminalID: UUID, message: String? = nil, activate: Bool = false) {
        self.terminalID = terminalID
        self.message = message
        self.activate = activate
    }
}

public struct ResolvePathParams: Codable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
}

/// Params for `claude.setSpawnPreferences`. Carries the user's Claude
/// spawn-env setting overrides, keyed by `ClaudeEnvSetting.id` (semantic
/// key — never an env-var name). Optional/defaulted for backward
/// compatibility with clients that omit it.
public struct ClaudeSpawnPreferences: Codable, Sendable, Equatable {
    public let settingOverrides: [String: ClaudeEnvValue]?
    public init(settingOverrides: [String: ClaudeEnvValue]? = nil) {
        self.settingOverrides = settingOverrides
    }
}

/// Params for `config.setEnvOverrides` — the global free-form env overrides.
public struct SetGlobalEnvOverridesParams: Codable, Sendable, Equatable {
    public let overrides: [String: String]
    public init(overrides: [String: String]) { self.overrides = overrides }
}

public struct WorktreeSetAutoArchiveParams: Codable, Sendable {
    public let worktreeID: UUID
    public let enabled: Bool
    public init(worktreeID: UUID, enabled: Bool) {
        self.worktreeID = worktreeID; self.enabled = enabled
    }
}

public struct ConfigSetAutoArchiveDefaultParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

public struct WorktreeSetAutoHibernateParams: Codable, Sendable {
    public let worktreeID: UUID
    public let enabled: Bool
    public init(worktreeID: UUID, enabled: Bool) {
        self.worktreeID = worktreeID; self.enabled = enabled
    }
}

public struct ConfigSetAutoHibernateDefaultParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setAutoResumeOnLimitReset` — the session-limit
/// auto-resume gate (default OFF). Disabling cancels all pending resumes.
public struct ConfigSetAutoResumeOnLimitResetParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setAutoResumeOnApiError` — the transient-API-error
/// auto-continue gate (default OFF). Disabling cancels only pending
/// `api_error`-scoped resumes (session-limit rows are untouched).
public struct ConfigSetAutoResumeOnApiErrorParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setScratchInstructions` — the global scratch-space
/// system-prompt override. `nil` (or blank) resets to the built-in default.
public struct ConfigSetScratchInstructionsParams: Codable, Sendable {
    public let instructions: String?
    public init(instructions: String?) { self.instructions = instructions }
}

/// Params for `config.setScratchRenamePrompt` — the global scratch-space
/// rename-nudge override. `nil` (or blank) resets to the built-in default.
public struct ConfigSetScratchRenamePromptParams: Codable, Sendable {
    public let renamePrompt: String?
    public init(renamePrompt: String?) { self.renamePrompt = renamePrompt }
}

/// Params for `config.setScratchProfileOverride` — the global model-profile
/// override applied to scratch terminal spawns. `nil` clears the override.
public struct ConfigSetScratchProfileOverrideParams: Codable, Sendable {
    public let profileID: UUID?
    public init(profileID: UUID?) { self.profileID = profileID }
}

// MARK: - Session Hibernation

/// Params for `terminal.hibernate` — manually hibernate one Claude terminal
/// (kill its process, keep the tmux window). Subject to the running/permission
/// rails but not keep-warm or idle-time.
public struct TerminalHibernateParams: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

/// Params for `terminal.wake` — respawn `claude --resume <id>` in the
/// hibernated terminal's kept-alive tmux window. Idempotent: waking a
/// non-hibernated terminal is a no-op.
public struct TerminalWakeParams: Codable, Sendable {
    public let terminalID: UUID
    /// Initial tmux window size in cells (see TerminalSwapProfileParams).
    public let cols: Int?
    public let rows: Int?
    /// Opt-in: when the pinned profile no longer resolves, resume on the ambient
    /// default login instead of failing with `.profileMissing`. nil == false ==
    /// strict (the default). Set true only on an explicit user retry.
    public let fallbackToDefaultProfile: Bool?
    /// Optional prompt delivered as a trailing argv to `claude --resume` —
    /// atomic with the respawn. It reaches ONLY a session this call actually
    /// woke; on the idempotent no-op paths (already awake / wake in flight)
    /// it is never delivered anywhere, which is what makes it safe for
    /// autonomous callers (nightwatch wake.py) racing a human wake.
    public let prompt: String?
    public init(terminalID: UUID, cols: Int? = nil, rows: Int? = nil, fallbackToDefaultProfile: Bool? = nil, prompt: String? = nil) {
        self.terminalID = terminalID
        self.cols = cols
        self.rows = rows
        self.fallbackToDefaultProfile = fallbackToDefaultProfile
        self.prompt = prompt
    }
}

/// Result payload for `terminal.wake`.
public struct TerminalWakeResult: Codable, Sendable {
    /// true — this call respawned `claude --resume` (the terminal was parked);
    /// false — idempotent no-op (already awake, or another wake in flight).
    /// A `prompt` param is delivered only when true.
    public let woken: Bool
    public init(woken: Bool) { self.woken = woken }
}

/// Params for `terminal.setKeepWarm` — pin/unpin a terminal against
/// auto-hibernation.
public struct TerminalSetKeepWarmParams: Codable, Sendable {
    public let terminalID: UUID
    public let keepWarm: Bool
    public init(terminalID: UUID, keepWarm: Bool) {
        self.terminalID = terminalID
        self.keepWarm = keepWarm
    }
}

/// Params for `config.setAutoHibernate` — master enable + idle-timeout minutes
/// for the auto-hibernate idle timer.
public struct ConfigSetAutoHibernateParams: Codable, Sendable {
    public let enabled: Bool
    public let idleMinutes: Int
    public init(enabled: Bool, idleMinutes: Int) {
        self.enabled = enabled
        self.idleMinutes = idleMinutes
    }
}

/// Params for `config.setControlMode` — persist the tmux control-mode opt-in
/// (M5). The gate is `env || flag`; the change applies to newly created
/// panes, existing attaches are untouched.
public struct ConfigSetControlModeParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setHibernateInputVeto` — persist the pending-input veto
/// for auto-hibernate (machine-interface guard that prevents hibernation of
/// sessions with typed-but-unsent input). The change applies on the next
/// hibernation sweep; no daemon restart required.
public struct ConfigSetHibernateInputVetoParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setAutoCloseSetup` — the auto-close-setup-tab soak
/// flag (default OFF). Read fresh at spawn time; applies to the next
/// worktree creation, no daemon restart required.
public struct ConfigSetAutoCloseSetupParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setGCEnabled` — the orphan-GC master switch.
public struct ConfigSetGCEnabledParams: Codable, Sendable {
    public var enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `repo.setEnvOverrides` — per-repo free-form env overrides.
public struct SetRepoEnvOverridesParams: Codable, Sendable, Equatable {
    public let repoID: UUID
    public let overrides: [String: String]
    public init(repoID: UUID, overrides: [String: String]) {
        self.repoID = repoID
        self.overrides = overrides
    }
}

/// Params for `modelProfile.setEnvOverrides` — per-profile free-form env overrides.
public struct SetProfileEnvOverridesParams: Codable, Sendable, Equatable {
    public let profileID: UUID
    public let overrides: [String: String]
    public init(profileID: UUID, overrides: [String: String]) {
        self.profileID = profileID
        self.overrides = overrides
    }
}

public struct TerminalSuspendParams: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

/// Params for `attach.request` — ask the daemon to vend a control-mode pipe
/// fd for one pane. Carries `worktreeID` because tmux pane IDs are only
/// unique per tmux server; the daemon resolves worktree → `tmuxServer` and
/// keys everything by the (server, paneID) composite.
public struct AttachRequestParams: Codable, Sendable {
    public let worktreeID: UUID
    public let paneID: String
    public let windowID: String
    /// Per-request nonce minted by the app and echoed back in the vend
    /// header, so the app's sidecar demux can tell two in-flight attaches for
    /// the SAME pane apart (the daemon replaces the pane's pipe on re-attach;
    /// without the nonce, the superseded attach's dead fd could be delivered
    /// to the fresh attach's waiter if it arrived first).
    public let attachID: UUID
    public init(worktreeID: UUID, paneID: String, windowID: String, attachID: UUID) {
        self.worktreeID = worktreeID
        self.paneID = paneID
        self.windowID = windowID
        self.attachID = attachID
    }
}

/// Result of `attach.request`.
public struct AttachRequestResult: Codable, Sendable {
    /// One of "pending" (fd vended; waiting for attach.ready) or
    /// "unavailable" (control mode off / not configured).
    public let status: String
    /// Daemon-side fanout generation of the vended attach ("pending" only).
    /// The app echoes it back in `pane.detach` so a stale detach — a closing
    /// view racing a fresh attach for the same pane — cannot kill the newer
    /// attach's sink. Optional for wire back-compat with older daemons.
    public let generation: UInt64?
    public init(status: String, generation: UInt64? = nil) {
        self.status = status
        self.generation = generation
    }
}

/// Params for `attach.ready` — the app's ack that its reader is draining the
/// vended fd; opens the daemon-side write gate.
public struct AttachReadyParams: Codable, Sendable {
    public let worktreeID: UUID
    public let paneID: String
    /// The attach generation this ready acknowledges (echoed from
    /// `AttachRequestResult.generation`). When present, the daemon runs the
    /// replay sequence ONLY if it still matches the pane's current attach —
    /// a stale ready (a superseded viewer's ack landing after a successor's
    /// attach) must send NOTHING on the shared per-server command client:
    /// pause state is keyed per PANE there, so a stale pause/continue would
    /// freeze the pane or resume output into the successor's closed gate.
    /// Optional for wire back-compat; absent → behave as before.
    public let generation: UInt64?
    public init(worktreeID: UUID, paneID: String, generation: UInt64? = nil) {
        self.worktreeID = worktreeID
        self.paneID = paneID
        self.generation = generation
    }
}

/// Params for `pane.detach` — the app stops rendering this pane; the daemon
/// closes the pipe write end (the app's reader sees EOF).
public struct PaneDetachParams: Codable, Sendable {
    public let worktreeID: UUID
    public let paneID: String
    /// The attach generation this detach targets (from
    /// `AttachRequestResult.generation`). When present the daemon detaches
    /// generation-checked — a stale detach from a closing view no-ops against
    /// a newer attach's sink. Absent (older app) → unconditional detach.
    public let generation: UInt64?
    public init(worktreeID: UUID, paneID: String, generation: UInt64? = nil) {
        self.worktreeID = worktreeID
        self.paneID = paneID
        self.generation = generation
    }
}

/// Params for `pane.resize` — the app's debounced desired size for one
/// control-mode window. Carries `windowID` because the daemon sizes per WINDOW
/// (the same tmux server hosts other windows' viewers), and `worktreeID` to
/// resolve the server (pane/window ids are only unique per server).
public struct PaneResizeParams: Codable, Sendable {
    public let worktreeID: UUID
    public let windowID: String
    public let cols: Int
    public let rows: Int
    public init(worktreeID: UUID, windowID: String, cols: Int, rows: Int) {
        self.worktreeID = worktreeID
        self.windowID = windowID
        self.cols = cols
        self.rows = rows
    }
}

/// Result of `daemon.capabilities` — feature flags the app cannot derive
/// locally (it is launched via `open`, which drops shell env, so it cannot
/// read the daemon's gate variables itself).
public struct DaemonCapabilitiesResult: Codable, Sendable {
    /// Effective control-mode gate: `(env || persisted flag) && tmux >= 3.2`,
    /// re-evaluated by the daemon on every call.
    public let controlModeEnabled: Bool
    /// tmux version the daemon detected at startup (e.g. "3.6a"); nil when
    /// detection failed (tmux missing/unparseable).
    public let tmuxVersion: String?
    /// Whether the detected tmux meets the control-mode minimum (>= 3.2).
    /// Computed daemon-side so the app never parses version strings.
    public let controlModeSupported: Bool
    /// Whether the pending-input veto for auto-hibernate is enabled. Guards
    /// against hibernating sessions with typed-but-unsent input. Re-evaluated
    /// by the daemon on every call.
    public let hibernateInputVetoEnabled: Bool
    /// Whether the setup-hook tab auto-closes after a clean run (soak flag,
    /// default OFF). Re-evaluated by the daemon on every call.
    public let autoCloseSetupEnabled: Bool

    public init(controlModeEnabled: Bool,
                tmuxVersion: String? = nil,
                controlModeSupported: Bool = false,
                hibernateInputVetoEnabled: Bool = false,
                autoCloseSetupEnabled: Bool = false) {
        self.controlModeEnabled = controlModeEnabled
        self.tmuxVersion = tmuxVersion
        self.controlModeSupported = controlModeSupported
        self.hibernateInputVetoEnabled = hibernateInputVetoEnabled
        self.autoCloseSetupEnabled = autoCloseSetupEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controlModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .controlModeEnabled) ?? false
        // New in M5 — absent when talking to a pre-M5 daemon; default to the
        // conservative "unsupported / unknown version".
        tmuxVersion = try c.decodeIfPresent(String.self, forKey: .tmuxVersion)
        controlModeSupported = try c.decodeIfPresent(Bool.self, forKey: .controlModeSupported) ?? false
        // New field for pending-input veto; absent from older daemons defaults to false (soaking).
        hibernateInputVetoEnabled = try c.decodeIfPresent(Bool.self, forKey: .hibernateInputVetoEnabled) ?? false
        // New field for setup-tab auto-close; absent from older daemons defaults to false (soaking).
        autoCloseSetupEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoCloseSetupEnabled) ?? false
    }
}

public struct TerminalResumeParams: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

public struct WorktreeSuspendParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct WorktreeResumeParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct TerminalRecreateWindowParams: Codable, Sendable {
    public let terminalID: UUID
    /// Initial tmux window size in cells (see WorktreeCreateParams).
    public let cols: Int?
    public let rows: Int?
    public init(terminalID: UUID, cols: Int? = nil, rows: Int? = nil) {
        self.terminalID = terminalID
        self.cols = cols
        self.rows = rows
    }
}

public struct NoteCreateParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct NoteGetParams: Codable, Sendable {
    public let noteID: UUID
    public init(noteID: UUID) { self.noteID = noteID }
}

public struct NoteUpdateParams: Codable, Sendable {
    public let noteID: UUID
    public let title: String?
    public let content: String?
    public init(noteID: UUID, title: String? = nil, content: String? = nil) {
        self.noteID = noteID; self.title = title; self.content = content
    }
}

public struct NoteDeleteParams: Codable, Sendable {
    public let noteID: UUID
    public init(noteID: UUID) { self.noteID = noteID }
}

public struct NoteListParams: Codable, Sendable {
    public let worktreeID: UUID?
    public init(worktreeID: UUID? = nil) { self.worktreeID = worktreeID }
}

// MARK: - Session Params

public struct SessionListParams: Codable, Sendable {
    public let worktreeID: UUID

    public init(worktreeID: UUID) {
        self.worktreeID = worktreeID
    }
}

// MARK: - Result Structs

public struct DaemonStatusResult: Codable, Sendable {
    public let version: String
    public let uptime: TimeInterval
    public let connectedClients: Int
    /// Absolute path to the running daemon's executable. Optional for backward
    /// compatibility — older daemons won't include this field.
    public let executablePath: String?
    public init(
        version: String,
        uptime: TimeInterval,
        connectedClients: Int,
        executablePath: String? = nil
    ) {
        self.version = version
        self.uptime = uptime
        self.connectedClients = connectedClients
        self.executablePath = executablePath
    }
}

public struct ResolvedPathResult: Codable, Sendable {
    public let repoID: UUID?
    public let worktreeID: UUID?
    public init(repoID: UUID?, worktreeID: UUID?) {
        self.repoID = repoID; self.worktreeID = worktreeID
    }
}

public struct CleanupResult: Codable, Sendable {
    public let reposProcessed: Int
    public let worktreesReconciled: Int
    public let errors: [String]
    public init(reposProcessed: Int, worktreesReconciled: Int, errors: [String] = []) {
        self.reposProcessed = reposProcessed
        self.worktreesReconciled = worktreesReconciled
        self.errors = errors
    }
}

// MARK: - Terminal Output

public struct TerminalOutputParams: Codable, Sendable {
    public let terminalID: UUID
    public let lines: Int?
    public init(terminalID: UUID, lines: Int? = nil) {
        self.terminalID = terminalID; self.lines = lines
    }
}

public struct TerminalOutputResult: Codable, Sendable {
    public let output: String
    public init(output: String) { self.output = output }
}

// MARK: - Terminal Conversation

public struct TerminalConversationParams: Codable, Sendable {
    public let terminalID: UUID
    public let messages: Int?  // number of assistant messages to return, default 1
    public init(terminalID: UUID, messages: Int? = nil) {
        self.terminalID = terminalID; self.messages = messages
    }
}

public struct TerminalConversationResult: Codable, Sendable {
    public let messages: [ConversationMessage]
    public let sessionID: String?
    public init(messages: [ConversationMessage], sessionID: String? = nil) {
        self.messages = messages; self.sessionID = sessionID
    }
}

public struct ConversationMessage: Codable, Sendable {
    public let role: String  // "assistant" or "user"
    public let content: String
    public init(role: String, content: String) {
        self.role = role; self.content = content
    }
}

// MARK: - Terminal Transcript

public struct TerminalTranscriptParams: Codable, Sendable {
    public let terminalID: UUID
    /// When nil (the default), the daemon returns the FULL parsed transcript —
    /// the original behavior, decoded identically by older encoded params that
    /// never wrote this field. When set, the daemon returns only the last N
    /// visible items (tail-first fast open for the table pane).
    public let tailLimit: Int?
    public init(terminalID: UUID, tailLimit: Int? = nil) {
        self.terminalID = terminalID
        self.tailLimit = tailLimit
    }
}

public struct TerminalTranscriptResult: Codable, Sendable {
    public let messages: [TranscriptItem]
    public let sessionID: String?
    public init(messages: [TranscriptItem], sessionID: String?) {
        self.messages = messages
        self.sessionID = sessionID
    }
}

public struct TerminalTranscriptItemFullBodyParams: Codable, Sendable {
    public let terminalID: UUID
    public let itemID: String
    public init(terminalID: UUID, itemID: String) {
        self.terminalID = terminalID
        self.itemID = itemID
    }
}

public struct TerminalTranscriptItemFullBodyResult: Codable, Sendable {
    public let text: String
    public init(text: String) {
        self.text = text
    }
}

// MARK: - Terminal Session Event (Claude SessionStart hook bridge)

/// Payload reported by the SessionStart hook (relayed via `tbd session-event`).
/// `source` is one of the values Claude Code emits: `startup`, `resume`,
/// `clear`, `compact`. We pass it through opaquely so future Claude
/// hook payload changes don't immediately break this bridge.
public struct TerminalSessionEventParams: Codable, Sendable {
    public let terminalID: UUID
    public let sessionID: String
    public let transcriptPath: String?
    public let source: String?
    /// Claude's reported working directory (`cwd` in the SessionStart hook
    /// payload). Transient — used only to validate that the reported session
    /// belongs to the target terminal's worktree, guarding against a foreign
    /// Claude session (e.g. a multi-agent teammate that inherited the
    /// terminal's `TBD_TERMINAL_ID` env) hijacking the session pointer.
    /// Optional for backward compatibility with older CLIs that don't send it.
    public let cwd: String?
    public init(
        terminalID: UUID,
        sessionID: String,
        transcriptPath: String?,
        source: String?,
        cwd: String? = nil
    ) {
        self.terminalID = terminalID
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.source = source
        self.cwd = cwd
    }
}

public struct TerminalActivityEventParams: Codable, Sendable {
    public let terminalID: UUID
    public let activityState: TerminalActivityState
    public init(terminalID: UUID, activityState: TerminalActivityState) {
        self.terminalID = terminalID
        self.activityState = activityState
    }
}

/// Params for `claude.rateLimitDetected` — sent by `tbd hooks stop-failure`
/// when the transcript's last API error is a HARD usage limit. `resetsAt`
/// is absolute: parsed once CLI-side, never re-derived from display text.
public struct RateLimitDetectedParams: Codable, Sendable {
    public let terminalID: UUID
    public let resetsAt: Date
    public let limitType: String
    public let rawMessage: String
    public init(terminalID: UUID, resetsAt: Date, limitType: String, rawMessage: String) {
        self.terminalID = terminalID
        self.resetsAt = resetsAt
        self.limitType = limitType
        self.rawMessage = rawMessage
    }
}

/// Params for `claude.transientApiErrorDetected` — sent by `tbd hooks
/// stop-failure` when the turn died on an allowlisted transient API error
/// (5xx / overloaded / network blip) rather than a hard usage limit.
public struct TransientApiErrorDetectedParams: Codable, Sendable {
    public let terminalID: UUID
    public let errorClass: String
    public let rawMessage: String
    public init(terminalID: UUID, errorClass: String, rawMessage: String) {
        self.terminalID = terminalID
        self.errorClass = errorClass
        self.rawMessage = rawMessage
    }
}

/// Result for `claude.transientApiErrorDetected`.
/// `handled == true` → the daemon owns user messaging (scheduled / gave-up /
/// latch-silenced); the CLI prints nothing. `handled == false` → toggle off
/// or unknown terminal; the CLI falls back to the legacy error print.
public struct TransientApiErrorDetectedResult: Codable, Sendable {
    public let handled: Bool
    public init(handled: Bool) { self.handled = handled }
}

/// Params for `terminal.cancelScheduledResume` — explicit user cancel from
/// the tab context menu / notification.
public struct CancelScheduledResumeParams: Codable, Sendable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

/// PreToolUse:AskUserQuestion hook bridge — fires when Claude is about to
/// render the question picker. The daemon stores this payload and uses it
/// to synthesize a transcript item while the assistant `tool_use` line is
/// still missing from the JSONL.
public struct TerminalAskUserQuestionPendingParams: Codable, Sendable {
    public let terminalID: UUID
    public let toolUseID: String
    public let inputJSON: String
    public let timestampMillis: Int64
    public init(terminalID: UUID, toolUseID: String, inputJSON: String, timestampMillis: Int64) {
        self.terminalID = terminalID
        self.toolUseID = toolUseID
        self.inputJSON = inputJSON
        self.timestampMillis = timestampMillis
    }
}

/// PostToolUse:AskUserQuestion hook bridge — fires after the user has
/// answered. The handler is intentionally a no-op today; the merger
/// performs lazy cleanup when it observes the matching `tool_use` line in
/// the JSONL. Keeping the wire format reserved means a future change to
/// eager cleanup won't ship a protocol break.
public struct TerminalAskUserQuestionClearedParams: Codable, Sendable {
    public let terminalID: UUID
    public let toolUseID: String
    public init(terminalID: UUID, toolUseID: String) {
        self.terminalID = terminalID
        self.toolUseID = toolUseID
    }
}

// MARK: - Tab Params

public struct TabSetLabelParams: Codable, Sendable {
    public let tabID: UUID
    public let worktreeID: UUID
    public let label: String?  // nil = clear override (delete row)
    public init(tabID: UUID, worktreeID: UUID, label: String?) {
        self.tabID = tabID
        self.worktreeID = worktreeID
        self.label = label
    }
}

public struct TabSetOrderParams: Codable, Sendable {
    public let worktreeID: UUID
    public let tabIDs: [UUID]
    public init(worktreeID: UUID, tabIDs: [UUID]) {
        self.worktreeID = worktreeID
        self.tabIDs = tabIDs
    }
}

public struct TabListParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct TabListResponse: Codable, Sendable {
    public let tabs: [TabState]   // only tabs with overrides
    public let order: [UUID]      // contents of worktree.tab_order; [] if never reordered
    public let activeTabID: UUID?  // persisted active tab UUID, nil if never set
    public init(tabs: [TabState], order: [UUID], activeTabID: UUID? = nil) {
        self.tabs = tabs
        self.order = order
        self.activeTabID = activeTabID
    }
}

public struct WorktreeSetActiveTabParams: Codable, Sendable {
    public let worktreeID: UUID
    public let tabID: UUID?  // nil clears the stored selection
    public init(worktreeID: UUID, tabID: UUID?) {
        self.worktreeID = worktreeID
        self.tabID = tabID
    }
}
