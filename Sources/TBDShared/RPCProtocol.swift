import Foundation

// MARK: - RPC Request / Response

/// RPC request with method string and raw JSON params.
/// The router decodes params based on the method string.
/// Params are stored as a JSON string so the wire format is human-readable (not base64).
public struct RPCRequest: Codable, Sendable {
    public let method: String
    public let params: String
    /// Optional caller identity declaration, deliberately a TOP-LEVEL field
    /// beside `method`/`params` rather than a member of any per-method params
    /// struct — so no verb's parameter shape changes. An absent field means
    /// the caller declared nothing and the daemon records `anonymous`; old
    /// clients simply omit it, and daemons that predate it ignore the key.
    public let actor: ActuationActor?

    public init(method: String, params: String = "{}", actor: ActuationActor? = nil) {
        self.method = method
        self.params = params
        self.actor = actor
    }

    /// Convenience: encode a Codable param struct into an RPCRequest.
    public init<P: Encodable>(method: String, params: P, actor: ActuationActor? = nil) throws {
        self.method = method
        let data = try JSONEncoder().encode(params)
        self.params = String(data: data, encoding: .utf8) ?? "{}"
        self.actor = actor
    }

    /// Returns a copy carrying `actor`, leaving an already-declared identity
    /// alone. Clients stamp their own identity at their single encode
    /// chokepoint rather than at every call site.
    public func stamping(actor: ActuationActor?) -> RPCRequest {
        guard self.actor == nil, let actor else { return self }
        return RPCRequest(method: method, params: params, actor: actor)
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

public enum RPCError: LocalizedError, Sendable {
    case noResultData

    public var errorDescription: String? {
        switch self {
        case .noResultData:
            return "RPC response carried no result payload to decode"
        }
    }
}

/// Machine-readable code carried alongside `RPCResponse.error`'s human string,
/// so the app can branch on a specific failure (e.g. offer a fallback) without
/// matching message text. Optional on the wire — nil for errors that carry no code.
public enum RPCErrorCode: String, Sendable {
    /// A parked terminal's pinned model profile no longer resolves; the wake was
    /// refused. The app offers a default-account fallback retry
    /// (`TerminalWakeParams.fallbackToDefaultProfile`).
    case profileMissing
    /// A `terminal.delete` with `respectActivityRails` was refused because the
    /// terminal is mid-turn or holding a permission prompt AND its window is
    /// still alive. The CLI maps this to exit 2; `--force` drops the rails.
    case terminalBusy
    /// A `terminal.wake` was aimed at a row TBD believes is awake whose pane
    /// positively disagrees — it is gone, its process exited, or it answers
    /// with another terminal's id. Reported as an error rather than the benign
    /// `woken: false` no-op, because there is no live session behind the row:
    /// the caller's `prompt` went nowhere and the terminal needs recovery.
    case terminalSessionGone
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
    public static let worktreeReviveConversationFresh = "worktree.reviveConversationFresh"
    public static let worktreeAdopt = "worktree.adopt"
    public static let worktreeRename = "worktree.rename"
    public static let worktreeReorder = "worktree.reorder"
    public static let worktreeMove = "worktree.move"
    public static let worktreeForget = "worktree.forget"
    public static let terminalCreate = "terminal.create"
    public static let terminalContinueInCodex = "terminal.continueInCodex"
    public static let terminalList = "terminal.list"
    public static let terminalAttachCommand = "terminal.attachCommand"
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
    public static let prList     = "pr.list"
    public static let prRefresh  = "pr.refresh"
    public static let prBindings = "pr.bindings"
    public static let prBindingsAll = "pr.bindingsAll"
    public static let prAttach   = "pr.attach"
    public static let prDetach   = "pr.detach"
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
    public static let codexUsageFetch = "codex.usage.fetch"
    public static let modelProfileSetRepoOverride = "modelProfile.setRepoOverride"
    public static let modelProfileReorder = "modelProfile.reorder"
    public static let modelProfileFetchUsage = "modelProfile.fetchUsage"
    public static let modelProfileUsageRefresh = "modelProfile.usageRefresh"
    public static let modelProfileHealthCheck = "modelProfile.healthCheck"
    public static let modelProfilePrepareConfigDir = "modelProfile.prepareConfigDir"
    public static let terminalSwapProfile = "terminal.swapProfile"
    public static let terminalSessionEvent = "terminal.sessionEvent"
    public static let terminalActivityEvent = "terminal.activityEvent"
    public static let terminalSessionEnded = "terminal.sessionEnded"
    public static let terminalNotificationEvent = "terminal.notificationEvent"
    public static let terminalAskUserQuestionPending = "terminal.askUserQuestionPending"
    public static let terminalAskUserQuestionCleared = "terminal.askUserQuestionCleared"
    public static let appSetForegroundState = "app.setForegroundState"
    public static let repoRelocate = "repo.relocate"
    public static let repoRename = "repo.rename"
    public static let repoSetHidden = "repo.setHidden"
    public static let repoSetExpanded = "repo.setExpanded"
    public static let sessionList = "session.list"
    public static let sessionMessages = "session.messages"
    public static let sessionStates = "session.states"
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
    public static let configSetRemoteCreateDefaults = "config.setRemoteCreateDefaults"
    public static let repoSetRemoteCreateDefaults   = "repo.setRemoteCreateDefaults"
    public static let modelProfileSetEnvOverrides = "modelProfile.setEnvOverrides"
    public static let worktreeSetAutoArchive = "worktree.setAutoArchive"
    public static let worktreeSetAutoHibernate = "worktree.setAutoHibernate"
    public static let worktreeSetPin = "worktree.setPin"
    public static let worktreeReorderPins = "worktree.reorderPins"
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
    public static let nightwatchLeaseStatus = "nightwatch.lease.status"
    public static let nightwatchLeaseAcquire = "nightwatch.lease.acquire"
    public static let nightwatchLeaseValidate = "nightwatch.lease.validate"
    public static let nightwatchLeaseRenew = "nightwatch.lease.renew"
    public static let nightwatchLeaseTransfer = "nightwatch.lease.transfer"
    public static let nightwatchLeaseRelease = "nightwatch.lease.release"
    public static let terminalCancelScheduledResume = "terminal.cancelScheduledResume"
    public static let configSetControlMode = "config.setControlMode"
    public static let configSetHibernateInputVeto = "config.setHibernateInputVeto"
    public static let configSetDeliveryVerification = "config.setDeliveryVerification"
    public static let configSetQueuedPrompt = "config.setQueuedPrompt"
    public static let configSetClaudeCloud = "config.setClaudeCloud"
    public static let configSetAutoCreateNotes = "config.setAutoCreateNotes"
    public static let configSetSupervisionEnabled = "config.setSupervisionEnabled"
    public static let superviseStatus = "supervise.status"
    public static let superviseSetProjectMark = "supervise.setProjectMark"
    public static let superviseSetMode = "supervise.setMode"
    public static let superviseProjectList = "supervise.projectList"
    public static let superviseProjectCreate = "supervise.projectCreate"
    public static let superviseProjectDelete = "supervise.projectDelete"
    public static let superviseProjectMove = "supervise.projectMove"
    public static let supervisePlaybook = "supervise.playbook"
    public static let supervisePlaybookCustomize = "supervise.playbookCustomize"
    public static let superviseReadout = "supervise.readout"
    public static let superviseLedger = "supervise.ledger"
    public static let superviseBrief = "supervise.brief"
    public static let worktreeSetPendingPrompt = "worktree.setPendingPrompt"
    public static let configSetAutoCloseSetup = "config.setAutoCloseSetup"
    public static let configSetAutoTrustWorktrees = "config.setAutoTrustWorktrees"
    public static let gcList = "gc.list"
    public static let gcRestore = "gc.restore"
    public static let gcSweepNow = "gc.sweepNow"
    public static let configSetGCEnabled = "config.setGCEnabled"
    public static let configSetGCProfileDirsEnabled = "config.setGCProfileDirsEnabled"
    public static let configSetGCOrphanProcessesEnabled = "config.setGCOrphanProcessesEnabled"
    public static let remoteProviders = "remote.providers"
    public static let remoteSessions = "remote.sessions"
    public static let remoteCreate = "remote.create"
    public static let remoteStop = "remote.stop"
    public static let remoteArchive = "remote.archive"
    public static let remoteUnarchive = "remote.unarchive"
    public static let remoteSend = "remote.send"
    public static let remoteLog = "remote.log"
    public static let remoteRename = "remote.rename"
    public static let remoteDismiss = "remote.dismiss"
    public static let remoteSetPin = "remote.setPin"
    public static let remoteReportAttachExit = "remote.reportAttachExit"

    /// Every `remote.*` verb addressed by a `provider` field in its params (or,
    /// for the two worktree-addressed retirement routes, by the worktree's
    /// bound `location`) — as opposed to `remoteProviders`/`remoteSessions`,
    /// which enumerate across every provider and take none.
    ///
    /// This is the single list the daemon's cloud gate (`RPCRouter.cloudGate`)
    /// must cover and `ClaudeCloudGateTests` asserts against, so the two
    /// cannot independently go stale against each other the way they did
    /// before `remote.archive`/`remote.unarchive` were found ungated — the
    /// test's list had quietly come to describe the bug instead of the
    /// contract. It is still a hand-maintained array, not something the
    /// compiler enforces: `RPCMethod` is a namespace of static string
    /// constants, not a `CaseIterable` enum, so nothing stops a new
    /// `remote.*` case from being added to `RPCRouter.handle`'s switch
    /// without a matching entry here. Add any new provider-named `remote.*`
    /// method to this array in the same commit that adds its RPC case.
    public static let providerNamedRemoteMethods: [String] = [
        remoteCreate, remoteStop, remoteArchive, remoteUnarchive,
        remoteSend, remoteLog, remoteRename, remoteDismiss,
        remoteSetPin, remoteReportAttachExit,
    ]

    public static let configSetRemoteBackends = "config.setRemoteBackends"
    public static let panelGet = "panel.get"
    public static let panelApply = "panel.apply"
    public static let panelImportLegacy = "panel.importLegacy"
}

public struct NightwatchLeaseStatusParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct NightwatchLeaseAcquireParams: Codable, Sendable {
    public let worktreeID: UUID
    public let terminalID: UUID
    public init(worktreeID: UUID, terminalID: UUID) {
        self.worktreeID = worktreeID
        self.terminalID = terminalID
    }
}

public struct NightwatchLeaseCredentialsParams: Codable, Sendable {
    public let worktreeID: UUID
    public let terminalID: UUID
    public let token: UUID
    public let generation: Int64
    public init(worktreeID: UUID, terminalID: UUID, token: UUID, generation: Int64) {
        self.worktreeID = worktreeID; self.terminalID = terminalID
        self.token = token; self.generation = generation
    }
}

public struct NightwatchLeaseTransferParams: Codable, Sendable {
    public let worktreeID: UUID
    public let fromTerminalID: UUID
    public let toTerminalID: UUID
    public let token: UUID
    public let generation: Int64
    public init(
        worktreeID: UUID, fromTerminalID: UUID, toTerminalID: UUID,
        token: UUID, generation: Int64
    ) {
        self.worktreeID = worktreeID; self.fromTerminalID = fromTerminalID
        self.toTerminalID = toTerminalID; self.token = token
        self.generation = generation
    }
}

public struct NightwatchLeaseStatusResult: Codable, Sendable {
    public let held: Bool
    public let lease: WatchDeskLeaseSnapshot?
    public init(held: Bool, lease: WatchDeskLeaseSnapshot?) {
        self.held = held; self.lease = lease
    }
}

public struct WatchDeskLeaseSnapshot: Codable, Sendable {
    public let worktreeID: UUID
    public let terminalID: UUID
    public let generation: Int64
    public let acquiredAt: Date
    public let renewedAt: Date
    public let expiresAt: Date
    public let valid: Bool
    public let role: WatchDeskRole
    /// `role` defaults to the powerless role for the same reason
    /// `WatchDeskRole`'s decoder falls back to it: an unstated role must never
    /// be reported as mutable authority. Callers that know the lease is valid
    /// pass `.judge` explicitly.
    public init(
        worktreeID: UUID, terminalID: UUID, generation: Int64,
        acquiredAt: Date, renewedAt: Date, expiresAt: Date, valid: Bool,
        role: WatchDeskRole = .readOnlyCoordinator
    ) {
        self.worktreeID = worktreeID; self.terminalID = terminalID
        self.generation = generation; self.acquiredAt = acquiredAt
        self.renewedAt = renewedAt; self.expiresAt = expiresAt; self.valid = valid
        self.role = role
    }
}

public struct NightwatchLeaseAcquisitionResult: Codable, Sendable {
    public let lease: WatchDeskLeaseSnapshot
    public let credentialFile: String
    public init(lease: WatchDeskLeaseSnapshot, credentialFile: String) {
        self.lease = lease
        self.credentialFile = credentialFile
    }
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
    /// Whether ordinary new worktrees start with an empty Notes tab.
    public let autoCreateNotesEnabled: Bool
    /// The machine-wide remote create-param defaults (config scope), keyed by
    /// the provider's own `create_params` field names. Carried alongside the
    /// other config-derived fields so the app loads it in one round-trip.
    public let globalRemoteCreateDefaults: [String: String]
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
        gcEnabled: Bool = true,
        autoCreateNotesEnabled: Bool = Config.autoCreateNotesDefault,
        globalRemoteCreateDefaults: [String: String] = [:]
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
        self.autoCreateNotesEnabled = autoCreateNotesEnabled
        self.globalRemoteCreateDefaults = globalRemoteCreateDefaults
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
        autoCreateNotesEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .autoCreateNotesEnabled
        ) ?? Config.autoCreateNotesDefault
        // Absent (older daemon) means the daemon knew nothing about create
        // defaults — the same state as an empty map: no opinion at this level.
        globalRemoteCreateDefaults = try c.decodeIfPresent(
            [String: String].self,
            forKey: .globalRemoteCreateDefaults
        ) ?? [:]
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

    /// The outcome of the last attempt to learn each worktree's PR state.
    ///
    /// Carried beside `statuses` rather than folded into it, because the two
    /// answer different questions and routinely disagree: a worktree absent
    /// from `statuses` may have no PR (`.none`) or may be one nobody could ask
    /// about (`.undetermined`), and a worktree *present* in `statuses` may be
    /// holding a value the last attempt failed to reconfirm. Collapsing them
    /// is the bug this field exists to prevent — an outage that reads as a
    /// fleet with no pull requests looks exactly like a calm night.
    ///
    /// Empty when the daemon predates the field; a missing entry means no
    /// attempt is on record, which is a third thing again from either outcome.
    public let observations: [UUID: PRObservation]

    public init(statuses: [UUID: PRStatus], observations: [UUID: PRObservation] = [:]) {
        self.statuses = statuses
        self.observations = observations
    }

    private enum CodingKeys: String, CodingKey {
        case statuses
        case observations
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statuses = try c.decode([UUID: PRStatus].self, forKey: .statuses)
        observations = try c.decodeIfPresent([UUID: PRObservation].self, forKey: .observations) ?? [:]
    }
}

public struct PRRefreshParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

/// The result of an on-demand `pr.refresh`.
///
/// `status` is the newest value anyone holds for the worktree — which is not
/// the same as the value this refresh found. A refresh that could not reach the
/// forge deliberately returns the *previous cached* status rather than guessing,
/// so a non-nil `status` does not mean "confirmed just now", and a nil `status`
/// does not mean "no PR": it means nothing is cached, whether because the forge
/// said there is no PR or because nobody ever got an answer.
///
/// `observation` is what disambiguates. It reports the outcome of *this*
/// attempt — `.observed`, `.none`, or `.undetermined(cause:)` — with the moment
/// it was made. nil only when the attempt could not be made at all (the
/// worktree is no longer known), or when talking to a daemon that predates the
/// field.
public struct PRRefreshResult: Codable, Sendable {
    public let status: PRStatus?
    public let observation: PRObservation?

    public init(status: PRStatus?, observation: PRObservation? = nil) {
        self.status = status
        self.observation = observation
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case observation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(PRStatus.self, forKey: .status)
        observation = try c.decodeIfPresent(PRObservation.self, forKey: .observation)
    }
}

// MARK: - PR bindings (multi-PR per worktree)

public struct PRBindingsParams: Codable, Sendable {
    public let worktreeID: UUID
    public init(worktreeID: UUID) { self.worktreeID = worktreeID }
}

public struct PRBindingsResult: Codable, Sendable {
    /// Live bindings only — tombstoned ones are not reported.
    public let bindings: [PRBinding]
    /// How many of this worktree's bindings are tombstoned (detached).
    ///
    /// This is what separates the two ways `bindings` comes back empty. The app
    /// falls back to the worktree's cached single `prStatus` when a worktree has
    /// no bindings, because a worktree whose repo `gh` cannot resolve never gets
    /// one and would otherwise lose its PR control entirely. But a user who ran
    /// `tbd pr detach` on their last PR reaches the same empty list, and there
    /// the fallback resurrects exactly what they asked to remove. A non-zero
    /// count says the emptiness is a decision, not an absence.
    ///
    /// Optional so a response from an older daemon still decodes; `nil` reads as
    /// "unknown", which every caller treats as zero — the pre-existing
    /// behaviour.
    public let detachedCount: Int?
    public init(bindings: [PRBinding], detachedCount: Int? = nil) {
        self.bindings = bindings
        self.detachedCount = detachedCount
    }
}

/// One worktree's row in a `pr.bindingsAll` response.
public struct PRBindingsAllEntry: Codable, Sendable {
    public let worktreeID: UUID
    /// Live bindings only, in bind order — tombstoned ones are not reported.
    public let bindings: [PRBinding]
    /// How many of this worktree's bindings are tombstoned. Carries the same
    /// meaning as `PRBindingsResult.detachedCount` and is optional for the same
    /// reason: an older daemon omits it and `nil` reads as zero.
    public let detachedCount: Int?
    public init(worktreeID: UUID, bindings: [PRBinding], detachedCount: Int? = nil) {
        self.worktreeID = worktreeID
        self.bindings = bindings
        self.detachedCount = detachedCount
    }
}

/// Every worktree's bindings in ONE round trip — what the app polls.
///
/// The per-worktree `pr.bindings` cannot answer the app's question, because the
/// app does not know which worktrees to ask about: a worktree whose only PR was
/// bound by the `gh pr create` hook, on a branch it never checked out, appears
/// in no branch-derived status cache, so a per-worktree fan-out can only reach
/// worktrees already known to have PRs. This method carries no worktree
/// parameter for exactly that reason — the daemon reports the whole table and
/// the app replaces its map wholesale.
///
/// A worktree appears here when it has at least one live binding OR at least one
/// tombstone; a worktree with neither is simply absent.
public struct PRBindingsAllResult: Codable, Sendable {
    public let worktrees: [PRBindingsAllEntry]
    public init(worktrees: [PRBindingsAllEntry]) {
        self.worktrees = worktrees
    }
}

/// Identify a PR either by full URL or by number within the worktree's own repo.
///
/// `source` decides tombstone semantics, so it is part of the reference rather
/// than a handler default: a `hook` attach must not revive a PR the user
/// detached, while a `manual` one must.
public struct PRBindingRefParams: Codable, Sendable {
    public let worktreeID: UUID
    public let url: String?
    public let number: Int?
    /// A `PRBindingSource` raw value. Absent or unrecognised means `manual` —
    /// the safe reading for a hand-typed attach, and what older clients send.
    public let source: String?
    public init(worktreeID: UUID, url: String? = nil, number: Int? = nil,
                source: String? = nil) {
        self.worktreeID = worktreeID
        self.url = url
        self.number = number
        self.source = source
    }
}

public struct PRAttachResult: Codable, Sendable {
    /// Mirrors `PRBindingCoordinator.BindOutcome`, flattened for the wire.
    public let outcome: String
    public let binding: PRBinding?
    /// Populated for `rejectedWrongRepo` so the CLI can name the other repo.
    public let detail: String?
    public init(outcome: String, binding: PRBinding? = nil, detail: String? = nil) {
        self.outcome = outcome
        self.binding = binding
        self.detail = detail
    }
}

public struct PRDetachResult: Codable, Sendable {
    /// Whether the call **changed the record**, never whether it succeeded —
    /// false is not an error.
    ///
    /// True when a live binding was tombstoned, and when a tombstone was
    /// recorded for a PR this worktree had no row for at all (a detach asserts
    /// that a PR does not belong here; it does not merely edit a row that
    /// happens to exist). False when the PR was already tombstoned, and when
    /// there was nothing to tombstone and nothing tied the reference to this
    /// worktree — in both of those the PR is not tracked here, which is what
    /// the caller asked for, and callers may say exactly that.
    ///
    /// A request that could not be honoured at all is an RPC **error**, never a
    /// false, precisely so that sentence stays true.
    public let detached: Bool
    public init(detached: Bool) { self.detached = detached }
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
    /// Explicit per-creation Claude model override — either a Claude Code alias
    /// ("opus", what the model rail sends) or an exact id ("claude-opus-5"),
    /// injected as ANTHROPIC_MODEL for the new worktree's INITIAL Claude spawn
    /// only — later respawns (hibernation wake, new sessions) fall back to the
    /// profile default. nil preserves the profile's own model. Optional/
    /// defaulted for backward compatibility with older clients.
    public let model: String?
    /// Explicit primary-agent override for this creation only. nil preserves
    /// the configured global preference. Optional for backward compatibility.
    public let primaryAgentPreference: PrimaryAgentPreference?
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
    public init(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, prompt: String? = nil, cols: Int? = nil, rows: Int? = nil, parentWorktreeID: UUID? = nil, siblingOfWorktreeID: UUID? = nil, callerWorktreeID: UUID? = nil, suppressAutoParent: Bool? = nil, useExistingBranch: Bool? = nil, profileID: UUID? = nil, model: String? = nil, primaryAgentPreference: PrimaryAgentPreference? = nil, claudeSettingsOverlay: String? = nil, prNumber: Int? = nil, checkoutPRHead: Bool? = nil, autoArchiveOnMerge: Bool? = nil) {
        self.repoID = repoID; self.folder = folder; self.branch = branch; self.displayName = displayName; self.prompt = prompt
        self.cols = cols; self.rows = rows
        self.parentWorktreeID = parentWorktreeID
        self.siblingOfWorktreeID = siblingOfWorktreeID
        self.callerWorktreeID = callerWorktreeID
        self.suppressAutoParent = suppressAutoParent
        self.useExistingBranch = useExistingBranch
        self.profileID = profileID
        self.model = model
        self.primaryAgentPreference = primaryAgentPreference
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
    /// Substring filter over the worktree's folder `name` **and** its
    /// `displayName`: a row matches when the query appears anywhere in either
    /// (not just as a prefix). Matching is case-insensitive for ASCII — the
    /// daemon implements this with SQLite `LIKE`, whose built-in case folding
    /// does not cover non-ASCII characters.
    ///
    /// nil or blank (whitespace-only) means "no filter". The filter is applied
    /// *before* `limit`/`offset`, so pagination pages over the matching set.
    /// Optional (nil == no filter) for backward compatibility — old daemons
    /// ignore the unknown key and return everything; old clients omit it.
    public let nameQuery: String?
    public init(
        repoID: UUID? = nil,
        status: WorktreeStatus? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        excludeArchived: Bool? = nil,
        scratchOnly: Bool? = nil,
        includeSessionCounts: Bool? = nil,
        nameQuery: String? = nil
    ) {
        self.repoID = repoID
        self.status = status
        self.limit = limit
        self.offset = offset
        self.excludeArchived = excludeArchived
        self.scratchOnly = scratchOnly
        self.includeSessionCounts = includeSessionCounts
        self.nameQuery = nameQuery
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

/// Result of `remote.providers` — every registered provider's negotiated
/// contract + current health.
public struct RemoteProvidersResult: Codable, Sendable {
    public let providers: [RemoteProviderStatus]
    public init(providers: [RemoteProviderStatus]) { self.providers = providers }
}

/// One row of the `remote.sessions` mirror — the provider-scoped payload
/// plus the drift bookkeeping (`gone`/`dismissed`) the app needs to render
/// (or hide) a stale session.
public struct RemoteSessionInfo: Codable, Sendable, Identifiable, Equatable {
    /// Stable synthetic identity for this mirror row — see
    /// `RemoteSessionIdentity`. ALWAYS recomputed from `provider`/
    /// `payload.id` rather than trusted off the wire (see `init(from:)`):
    /// since it's a pure function of those two fields, an older daemon that
    /// never sent this key, or any future transport that drops it, still
    /// produces an IDENTICAL id client-side — there is nothing to default or
    /// version. It's still included on the wire (for other/non-Swift
    /// consumers and debugging), just never trusted as the source of truth.
    public let id: UUID
    public let provider: String
    public let payload: RemoteSessionPayload
    public let gone: Bool
    public let dismissed: Bool
    public let lastSeen: Date
    /// The local repo this session was resolved to, via `meta["repo"]`
    /// (`docs/remote-provider-contract.md` § Session object) matched against
    /// registered repos' `remoteURL` (`RemoteRepoMatching`). Pinned at first
    /// sighting by the daemon (`RemoteSessionStore`) — nil means either "the
    /// provider reported no repo" or "not resolved yet", and the daemon
    /// keeps retrying resolution only while this stays nil. Once non-nil, it
    /// never changes, even if the provider's reported meta later does.
    public let resolvedRepoID: UUID?
    /// When the user pinned this session to the sidebar's pinned dock, or nil
    /// when it isn't pinned. Stamped daemon-side (`remote.setPin`) so pin
    /// ORDER is server-assigned, exactly like `Worktree.pinnedAt`. Survives
    /// app and daemon restarts because it lives on the mirror row, whose
    /// primary key `(provider, sessionID)` is durable by contract.
    /// `decodeIfPresent` so a payload from an older daemon still decodes.
    public let pinnedAt: Date?

    public init(provider: String, payload: RemoteSessionPayload,
                gone: Bool, dismissed: Bool, lastSeen: Date, resolvedRepoID: UUID? = nil,
                pinnedAt: Date? = nil) {
        self.id = RemoteSessionIdentity.uuid(provider: provider, sessionID: payload.id)
        self.provider = provider; self.payload = payload
        self.gone = gone; self.dismissed = dismissed; self.lastSeen = lastSeen
        self.resolvedRepoID = resolvedRepoID
        self.pinnedAt = pinnedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, payload, gone, dismissed, lastSeen, resolvedRepoID, pinnedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        payload = try c.decode(RemoteSessionPayload.self, forKey: .payload)
        gone = try c.decode(Bool.self, forKey: .gone)
        dismissed = try c.decode(Bool.self, forKey: .dismissed)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        resolvedRepoID = try c.decodeIfPresent(UUID.self, forKey: .resolvedRepoID)
        pinnedAt = try c.decodeIfPresent(Date.self, forKey: .pinnedAt)
        // See the `id` doc comment — deliberately recomputed, never decoded.
        id = RemoteSessionIdentity.uuid(provider: provider, sessionID: payload.id)
    }
}

public struct RemoteSessionsResult: Codable, Sendable {
    public let sessions: [RemoteSessionInfo]
    public init(sessions: [RemoteSessionInfo]) { self.sessions = sessions }
}

public struct RemoteCreateParams: Codable, Sendable {
    public let provider: String
    /// Raw JSON object of create-form values; passed to the provider verbatim
    /// inside the contract's create request. Kept as a string so RPC stays
    /// schema-free about provider-specific fields.
    public let paramsJSON: String
    /// Where the caller clicked: the worktree the new lane should nest under,
    /// or nil for a top-level lane.
    ///
    /// TBD-local and deliberately outside the provider contract — it is not
    /// sent on `create`'s stdin and the provider never learns it. The parent
    /// edge is TBD's own policy (the same column a drag sets), so the only
    /// thing the provider could add is a round trip through
    /// `meta["tbd_parent_worktree_id"]` that could be dropped, garbled, or
    /// contradicted. The daemon applies it at adoption instead, as an override
    /// of that stamp.
    ///
    /// Optional and defaulted: params encoded by an older app still decode.
    public let parentWorktreeID: UUID?
    public init(provider: String, paramsJSON: String, parentWorktreeID: UUID? = nil) {
        self.provider = provider
        self.paramsJSON = paramsJSON
        self.parentWorktreeID = parentWorktreeID
    }
}

public struct RemoteStopParams: Codable, Sendable {
    public let provider: String
    public let sessionID: String
    public init(provider: String, sessionID: String) {
        self.provider = provider; self.sessionID = sessionID
    }
}

public struct RemoteArchiveParams: Codable, Sendable {
    public let provider: String
    public let sessionID: String
    public init(provider: String, sessionID: String) {
        self.provider = provider; self.sessionID = sessionID
    }
}

public struct RemoteUnarchiveParams: Codable, Sendable {
    public let provider: String
    public let sessionID: String
    public init(provider: String, sessionID: String) {
        self.provider = provider; self.sessionID = sessionID
    }
}

public struct RemoteSendParams: Codable, Sendable {
    public let provider: String
    public let sessionID: String
    public let text: String
    public init(provider: String, sessionID: String, text: String) {
        self.provider = provider; self.sessionID = sessionID; self.text = text
    }
}

public struct RemoteLogParams: Codable, Sendable {
    public let provider: String
    public let sessionID: String
    public let lines: Int?
    public init(provider: String, sessionID: String, lines: Int? = nil) {
        self.provider = provider; self.sessionID = sessionID; self.lines = lines
    }
}

public struct RemoteLogResult: Codable, Sendable {
    public let text: String
    public init(text: String) { self.text = text }
}

public struct RemoteDismissParams: Codable, Sendable {
    public let provider: String
    public let sessionID: String
    public init(provider: String, sessionID: String) {
        self.provider = provider; self.sessionID = sessionID
    }
}

/// Pin or unpin a remote session for the sidebar dock. Purely local — no
/// provider verb is involved, so this works for any provider regardless of
/// declared capabilities, and for a `gone` row too. Mirrors
/// `WorktreeSetPinParams`: the client only says whether it wants the pin on
/// or off, and the daemon stamps `pinnedAt` so pin order is server-assigned.
public struct RemoteSetPinParams: Codable, Sendable {
    public let provider: String
    public let sessionID: String
    public let pinned: Bool
    public init(provider: String, sessionID: String, pinned: Bool) {
        self.provider = provider; self.sessionID = sessionID; self.pinned = pinned
    }
}

/// Params for `remote.reportAttachExit` — the app reporting the exit code of
/// an `attach` process IT spawned (the provider is exec'd on a terminal's own
/// TTY, so the daemon never sees that exit itself).
///
/// The exit code is the ONLY thing reported: `attach`'s stdout is a PTY byte
/// stream and MUST NOT be parsed (`docs/remote-provider-contract.md` §
/// `attach`), so there is no error object to carry. The daemon classifies it
/// and, for the auth class only, moves provider health.
public struct RemoteReportAttachExitParams: Codable, Sendable {
    public let provider: String
    public let sessionID: String
    public let exitCode: Int32
    public init(provider: String, sessionID: String, exitCode: Int32) {
        self.provider = provider; self.sessionID = sessionID; self.exitCode = exitCode
    }
}

/// Params for `remote.rename` — pushes a display-name rename to a provider
/// that declares the optional `rename` capability
/// (`docs/remote-provider-contract.md` § `rename`). `title` rides as a
/// single argv value (never shell-escaped — the daemon execs the provider
/// directly, per contract).
public struct RemoteRenameParams: Codable, Sendable {
    public let provider: String
    public let sessionID: String
    public let title: String
    public init(provider: String, sessionID: String, title: String) {
        self.provider = provider; self.sessionID = sessionID; self.title = title
    }
}

public struct ConfigSetRemoteBackendsParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
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

public struct WorktreeReviveConversationFreshParams: Codable, Sendable {
    public let archivedWorktreeID: UUID
    public let sessionID: String
    public let cols: Int?
    public let rows: Int?

    public init(
        archivedWorktreeID: UUID,
        sessionID: String,
        cols: Int? = nil,
        rows: Int? = nil
    ) {
        self.archivedWorktreeID = archivedWorktreeID
        self.sessionID = sessionID
        self.cols = cols
        self.rows = rows
    }
}

public struct WorktreeReviveConversationFreshResult: Codable, Sendable {
    public let worktree: Worktree
    public let warning: String?

    public init(worktree: Worktree, warning: String?) {
        self.worktree = worktree
        self.warning = warning
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

public struct TerminalContinueInCodexParams: Codable, Sendable {
    public let terminalID: UUID

    public init(terminalID: UUID) {
        self.terminalID = terminalID
    }
}

public struct TerminalContinueInCodexResult: Codable, Sendable, Equatable {
    public let terminalID: UUID
    public let threadID: String

    public init(terminalID: UUID, threadID: String) {
        self.terminalID = terminalID
        self.threadID = threadID
    }
}

public struct TerminalListParams: Codable, Sendable {
    public let worktreeID: UUID?
    public init(worktreeID: UUID? = nil) { self.worktreeID = worktreeID }
}

/// Params for `terminal.attachCommand`: compose the shell command that attaches
/// an external terminal emulator to this terminal's tmux window.
///
/// Both ids are required. The worktree names the tmux server, the terminal
/// names the window — and the daemon refuses a pair that disagrees rather than
/// composing a command aimed at a window on another repo's server.
public struct TerminalAttachCommandParams: Codable, Sendable {
    public let worktreeID: UUID
    public let terminalID: UUID
    public init(worktreeID: UUID, terminalID: UUID) {
        self.worktreeID = worktreeID
        self.terminalID = terminalID
    }
}

/// Result for `terminal.attachCommand`: the rendered script plus every
/// coordinate that went into it.
///
/// The coordinates are carried alongside the script deliberately. The sharper
/// instrument for the byte-burst question this feature serves is
/// `tmux pipe-pane -o`, which needs a pane id and a socket path and attaches no
/// client at all — so a caller can drive that instead of pasting the script,
/// and neither has to re-derive values the daemon already resolved.
public struct TerminalAttachCommandResult: Codable, Sendable, Equatable {
    /// Absolute path to the tmux server's socket. Pinned with `-S` rather than
    /// named with `-L` so a shell holding a different `TMUX_TMPDIR` cannot
    /// resolve it to a fresh, empty server.
    public let socketPath: String
    /// The `tbd-ext-<tid8>` session the script creates or reuses.
    public let sessionName: String
    /// The terminal's stable `@N` tmux window id — never a window index.
    public let windowID: String
    /// The `%N` pane id **the identity probe answered for**, not a separately
    /// resolved value: a second resolution that could disagree with the
    /// verified one is how reused pane coordinates previously sent keystrokes
    /// into an unrelated live session (issue #384).
    public let paneID: String
    public let terminalID: UUID
    /// The shell snippet, with every interpolated value single-quoted. No
    /// trailing newline — a caller printing it adds one.
    public let script: String

    public init(
        socketPath: String,
        sessionName: String,
        windowID: String,
        paneID: String,
        terminalID: UUID,
        script: String
    ) {
        self.socketPath = socketPath
        self.sessionName = sessionName
        self.windowID = windowID
        self.paneID = paneID
        self.terminalID = terminalID
        self.script = script
    }
}

/// Which terminals `session.states` should report on. Absent `worktreeID` means
/// the whole fleet — the ordinary call, since the point of the method is asking
/// about every agent every cycle.
public struct SessionStatesParams: Codable, Sendable {
    public let worktreeID: UUID?
    public init(worktreeID: UUID? = nil) { self.worktreeID = worktreeID }
}

/// One `session.states` answer: a `SessionStateReport` per terminal.
///
/// A wrapper rather than a bare array so a later slice can add a fleet-level
/// field (a pass timestamp, a count of terminals skipped) without changing the
/// shape every existing reader decodes.
public struct SessionStatesResult: Codable, Sendable {
    public let reports: [SessionStateReport]
    public init(reports: [SessionStateReport]) { self.reports = reports }
}

/// One `terminal.send` request. Exactly one payload kind per call — `text` or
/// `keys`, never both and never neither (design §3, "Payloads, not verbs").
///
/// **`text` is optional only to admit `keys`.** An older CLI sending
/// `{terminalID, text, submit}` decodes and behaves byte-identically: `keys`
/// and `verify` are absent, which is exactly a text send. `--text` and
/// `--submit` keep their exact current semantics — bare `--text` types without
/// submitting, and `--submit` is not deprecated.
public struct TerminalSendParams: Codable, Sendable {
    public let terminalID: UUID
    /// The message, verbatim. Delivered to an agent session behind a
    /// `<tbd-dispatch …/>` envelope line (§12) and to a shell as-is; either way
    /// the record stores what the caller wrote, not the envelope.
    /// An empty string keeps its existing meaning: nothing is pasted, and a
    /// bare `--submit` still presses Enter.
    public let text: String?
    /// Whitespace-separated tmux key names — `"Escape"`, `"C-c"`,
    /// `"Escape Enter"` — sent one at a time, paced. Mutually exclusive with
    /// `text`. Carries no envelope (a key sequence has nowhere to put a line of
    /// text) and cannot be verified (keys reach no transcript).
    public let keys: String?
    /// When true, sends an Enter keypress after the text to submit it.
    /// Incoherent with `keys`, where Enter is itself a key.
    public let submit: Bool?
    /// Arms delivery acknowledgement for this send (§12). Requires `submit`
    /// (unsubmitted text never enters the conversation, so it can never reach a
    /// transcript) and is incompatible with `keys`. Refused, never silently
    /// downgraded, while `delivery_verification_enabled` is off.
    public let verify: Bool?
    public init(
        terminalID: UUID, text: String? = nil, keys: String? = nil,
        submit: Bool? = nil, verify: Bool? = nil
    ) {
        self.terminalID = terminalID
        self.text = text
        self.keys = keys
        self.submit = submit
        self.verify = verify
    }
}

public struct TerminalDeleteParams: Codable, Sendable {
    public let terminalID: UUID
    /// When true, refuse to close a terminal that is mid-turn or holding a
    /// permission prompt, returning `RPCErrorCode.terminalBusy`. Optional and
    /// defaulting to nil (= no rails) so the app's tab-close — a direct human
    /// gesture on a visible tab — keeps its existing unconditional semantics,
    /// and so older callers still decode.
    ///
    /// The CLI sets it; `--force` drops it. See `handleTerminalDelete` for why
    /// the check is additionally qualified on the window being alive.
    public let respectActivityRails: Bool?
    public init(terminalID: UUID, respectActivityRails: Bool? = nil) {
        self.terminalID = terminalID
        self.respectActivityRails = respectActivityRails
    }
}

/// Result for `terminal.delete`. Mirrors `TerminalWakeResult`'s shape: the call
/// is idempotent, and the caller learns which of the two success paths it took.
public struct TerminalDeleteResult: Codable, Sendable {
    /// true — this call tore the terminal down; false — it was already gone.
    public let closed: Bool
    /// true when there was no such terminal row. Not an error: closing an
    /// already-closed terminal is a no-op success, matching `terminal wake`.
    public let alreadyGone: Bool
    /// Echoed so an autonomous caller keeps a resume pointer after the row is
    /// gone (the transcript survives on disk). nil for non-Claude terminals and
    /// for the already-gone path.
    public let claudeSessionID: String?
    public init(closed: Bool, alreadyGone: Bool, claudeSessionID: String? = nil) {
        self.closed = closed
        self.alreadyGone = alreadyGone
        self.claudeSessionID = claudeSessionID
    }
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

/// Pin or unpin a worktree for the sidebar dock. The `pinnedAt` timestamp is
/// stamped daemon-side, so pin ORDER is server-assigned and consistent across
/// clients — the client only says whether it wants the pin on or off.
public struct WorktreeSetPinParams: Codable, Sendable {
    public let worktreeID: UUID
    public let pinned: Bool
    public init(worktreeID: UUID, pinned: Bool) {
        self.worktreeID = worktreeID; self.pinned = pinned
    }
}

/// Params for `worktree.reorderPins`. The dock is one flat cross-repo list, so
/// there is no repoID scoping (unlike `WorktreeReorderParams`).
public struct WorktreeReorderPinsParams: Codable, Sendable {
    public let worktreeIDs: [UUID]
    public init(worktreeIDs: [UUID]) {
        self.worktreeIDs = worktreeIDs
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

/// Params for `config.setDeliveryVerification` — the delivery-acknowledgement
/// soak flag (default OFF, fleet-supervision design §12). This is the
/// operator's enable path for the soak, and **enabling it means restarting the
/// daemon afterwards**: the column is read per `--verify` send, but the
/// observation machinery it gates is wired once at startup. Until that restart
/// `--verify` is refused with a message saying so. Turning it off makes
/// `--verify` a refusal again on the next send, with no restart.
public struct ConfigSetDeliveryVerificationParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setQueuedPrompt` — the queued-prompt soak flag (default
/// OFF, design 2026-08-10). Read fresh at spawn time and on every
/// `worktree.setPendingPrompt`, so no daemon restart is required.
///
/// Sending either value is an explicit gesture: the backing column is NULL
/// until this verb writes to it, and a written `false` stays off even after the
/// shipped default graduates.
public struct ConfigSetQueuedPromptParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setAutoCreateNotes` — the default-ON preference for
/// adding an empty Notes tab to ordinary new worktrees. Conversation carryover
/// creates its populated provenance note independently of this preference.
public struct ConfigSetAutoCreateNotesParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setClaudeCloud` — the Claude cloud sessions gate
/// (design 2026-08-15 §7, default OFF). A second gate inside
/// `remote_backends_enabled`, never a bypass.
///
/// Sending either value is an explicit gesture: the backing column is NULL
/// until this verb writes to it, and a written `false` stays off even after the
/// shipped default graduates.
public struct ConfigSetClaudeCloudParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

// MARK: - Supervision

/// Params for `config.setSupervisionEnabled` — the fleet brake
/// (`docs/specs/2026-07-26-fleet-supervision-design.md` §3, §8). `true`
/// releases the brake, `false` engages it; either way the per-project marks are
/// untouched, so releasing restores exactly the coverage that stood.
///
/// Sending either value is an explicit gesture: the backing column is NULL
/// until this verb writes to it, and a written `false` stays engaged even after
/// the shipped default graduates.
public struct ConfigSetSupervisionEnabledParams: Codable, Sendable, Equatable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// A stable code a program may branch on, carried in `SupervisionStatus`.
public enum SupervisionWarningCode: String, Codable, Sendable {
    /// The brake is released and not one project is marked on — supervision is
    /// on but nothing is being supervised. The loud case: the CLI says so in
    /// words a human reads, and this code is the same fact for a program.
    case noProjectsOn
    /// One or more projects have a name that cannot be a directory, so nothing
    /// can be written beside them — no playbook, journal, proposals, or
    /// programs (`SupervisionTopology.projectsWithoutUsableDirectory(in:)`).
    /// Supervision covers them regardless; the fix is renaming the repo, and
    /// the message names which ones.
    case unusableProjectName
    /// Two or more repos share a display name, so none of them resolves to a
    /// project and none is supervised — a project is identified by its name,
    /// and two candidates for one name identify nothing
    /// (`SupervisionTopology.ambiguousRepoNames(file:repos:)`). The rest of the
    /// fleet is unaffected. The message names the repos; the operator's fix is
    /// to rename one, or to declare a project naming them.
    case ambiguousRepoName
    /// The brake is engaged while at least one project's mark stands — the
    /// exact mirror of `noProjectsOn`. An operator who runs
    /// `tbd supervise on acme` against an engaged brake sees `on: acme` and
    /// forms the belief that supervision is running; nothing is watching.
    ///
    /// **Emitted only when a mark actually stands.** An engaged brake over a
    /// fleet with nothing marked is a deliberately quiet system, not a warning,
    /// and warning there would train an operator to ignore the line — which
    /// costs more than it buys.
    ///
    /// `SupervisionStatus.effectivelySupervising` is false in this state and in
    /// `noProjectsOn` alike, and cannot tell them apart; they call for opposite
    /// actions — release the brake, or mark a project — so the code is what a
    /// program branches on.
    case brakeEngagedWithProjectsOn
}

/// One warning on the status readout: a stable code, and the sentence a human
/// gets.
public struct SupervisionWarning: Codable, Sendable, Equatable {
    public let code: SupervisionWarningCode
    public let message: String
    public init(code: SupervisionWarningCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// Result of `supervise.status`: the brake, then one entry per resolved project
/// (declared and singleton alike — nothing here distinguishes them).
public struct SupervisionStatus: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let brake: SupervisionBrakeState
    /// Whether TBD's own attention actually covers anything right now: the
    /// brake released AND at least one project marked on.
    public let effectivelySupervising: Bool
    public let projects: [SupervisionStatusProject]
    public let warnings: [SupervisionWarning]

    public init(brake: SupervisionBrakeState, effectivelySupervising: Bool,
                projects: [SupervisionStatusProject], warnings: [SupervisionWarning],
                schemaVersion: Int = SupervisionStatus.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.brake = brake
        self.effectivelySupervising = effectivelySupervising
        self.projects = projects
        self.warnings = warnings
    }
}

/// One project's row on the status readout.
public struct SupervisionStatusProject: Codable, Sendable, Equatable {
    public let name: String
    /// The project's mark. Effectively on is this AND a released brake.
    public let on: Bool
    public let mode: String
    public let declaredModes: [String]
    public let supervisor: SupervisionSupervisorArrangement
    /// When the current coverage span opened, or null when the project is off
    /// or the record holds no opening line.
    public let spanStartedAt: SupervisionInstant?
    /// When a sweep program last made contact, or null when it never has.
    public let lastSweepContactAt: SupervisionInstant?
    /// The project's declared contact window, or null when it declares none —
    /// which is what the readout's "coverage unknown" reports. Null is the
    /// honest not-yet value; nothing here invents a coverage claim.
    public let coverageWindow: String?

    public init(name: String, on: Bool, mode: String, declaredModes: [String],
                supervisor: SupervisionSupervisorArrangement,
                spanStartedAt: SupervisionInstant?, lastSweepContactAt: SupervisionInstant?,
                coverageWindow: String?) {
        self.name = name
        self.on = on
        self.mode = mode
        self.declaredModes = declaredModes
        self.supervisor = supervisor
        self.spanStartedAt = spanStartedAt
        self.lastSweepContactAt = lastSweepContactAt
        self.coverageWindow = coverageWindow
    }

    private enum CodingKeys: String, CodingKey {
        case name, on, mode, declaredModes, supervisor
        case spanStartedAt, lastSweepContactAt, coverageWindow
    }

    /// Written by hand because synthesized `Codable` *omits* a nil optional.
    /// The honest not-yet values are the point of these three fields, so they
    /// are present and null rather than absent.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(on, forKey: .on)
        try container.encode(mode, forKey: .mode)
        try container.encode(declaredModes, forKey: .declaredModes)
        try container.encode(supervisor, forKey: .supervisor)
        try container.encode(spanStartedAt, forKey: .spanStartedAt)
        try container.encode(lastSweepContactAt, forKey: .lastSweepContactAt)
        try container.encode(coverageWindow, forKey: .coverageWindow)
    }
}

/// Params for `supervise.setProjectMark` — `tbd supervise on|off <project>`.
/// The mark is coverage, never protection: it binds TBD's own hand and builds
/// no wall around a terminal.
public struct SuperviseSetProjectMarkParams: Codable, Sendable, Equatable {
    public let project: String
    public let on: Bool
    public init(project: String, on: Bool) {
        self.project = project
        self.on = on
    }
}

/// Result of `supervise.setProjectMark`. `changed` is false when the mark
/// already stood as asked — a no-op is not a decision, and no ledger line is
/// written for one.
public struct SuperviseSetProjectMarkResult: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let project: String
    public let on: Bool
    public let changed: Bool

    public init(project: String, on: Bool, changed: Bool,
                schemaVersion: Int = SuperviseSetProjectMarkResult.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.on = on
        self.changed = changed
    }
}

/// Params for `supervise.setMode` — the per-project selection, validated
/// against the project's declared list (a lookup within `supervision.json`;
/// TBD never parses the playbook to derive one).
public struct SuperviseSetModeParams: Codable, Sendable, Equatable {
    public let project: String
    public let mode: String
    public init(project: String, mode: String) {
        self.project = project
        self.mode = mode
    }
}

/// Result of `supervise.setMode`, carrying the choices so the CLI can show them
/// without a second call. `changed` is false when the mode already stood.
public struct SuperviseSetModeResult: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let project: String
    public let mode: String
    public let declaredModes: [String]
    public let changed: Bool

    public init(project: String, mode: String, declaredModes: [String], changed: Bool,
                schemaVersion: Int = SuperviseSetModeResult.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.mode = mode
        self.declaredModes = declaredModes
        self.changed = changed
    }
}

/// A member repo on the topology readout: the id the file holds, and the name a
/// human typed or reads.
public struct SupervisionProjectRepoRef: Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// One project on the topology readout.
///
/// Declared projects and singletons appear alike, and no field distinguishes
/// them: a reader sees a project with its repos and its policy, which is all
/// there is to see (design §5).
public struct SupervisionProjectTopologyEntry: Codable, Sendable, Equatable {
    public let name: String
    public let repos: [SupervisionProjectRepoRef]
    public let policy: SupervisionPolicySource
    /// The project's own sweep program, when one has been customized.
    public let sweepScript: String?

    public init(name: String, repos: [SupervisionProjectRepoRef],
                policy: SupervisionPolicySource, sweepScript: String?) {
        self.name = name
        self.repos = repos
        self.policy = policy
        self.sweepScript = sweepScript
    }
}

/// Result of `supervise.projectList`, and of every project mutation — a
/// mutation answers with the topology it produced.
public struct SuperviseProjectListResult: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let projects: [SupervisionProjectTopologyEntry]

    public init(projects: [SupervisionProjectTopologyEntry],
                schemaVersion: Int = SuperviseProjectListResult.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.projects = projects
    }
}

/// The policy source as a caller names it: `--policy repo:<id>` or
/// `--policy operator`. The repo arrives as a string because the CLI accepts a
/// repo UUID or a repo display name; resolving it to a `UUID` is the daemon's
/// job.
public enum SupervisionPolicyRequest: Codable, Sendable, Equatable {
    case repo(String)
    case `operator`

    private enum CodingKeys: String, CodingKey {
        case repo
        case `operator`
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let repo = try container.decodeIfPresent(String.self, forKey: .repo) {
            self = .repo(repo)
            return
        }
        if let isOperator = try container.decodeIfPresent(Bool.self, forKey: .operator), isOperator {
            self = .operator
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .repo, in: container,
            debugDescription: "a policy must be {\"repo\": \"<repo>\"} or {\"operator\": true}")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .repo(let repo): try container.encode(repo, forKey: .repo)
        case .operator: try container.encode(true, forKey: .operator)
        }
    }
}

/// Params for `supervise.projectCreate`. `repos` entries are repo UUIDs or repo
/// display names, as typed.
public struct SuperviseProjectCreateParams: Codable, Sendable, Equatable {
    public let name: String
    public let repos: [String]
    public let policy: SupervisionPolicyRequest

    public init(name: String, repos: [String], policy: SupervisionPolicyRequest) {
        self.name = name
        self.repos = repos
        self.policy = policy
    }
}

/// Params for `supervise.projectDelete`. Deleting a declaration returns its
/// member repos to being their own projects.
public struct SuperviseProjectDeleteParams: Codable, Sendable, Equatable {
    public let name: String
    public init(name: String) { self.name = name }
}

/// Params for `supervise.projectMove` — the only membership verb, because an
/// add/remove pair can express states the "exactly one project" model forbids.
/// `repo` is a repo UUID or display name; `to` is a project name or the
/// documented `"singleton"` sentinel.
public struct SuperviseProjectMoveParams: Codable, Sendable, Equatable {
    /// The value of `to` that returns a repo to being its own project.
    public static let singletonTarget = SupervisionMoveTarget.singletonArgument

    public let repo: String
    public let to: String

    public init(repo: String, to: String) {
        self.repo = repo
        self.to = to
    }
}

/// Params for `worktree.setPendingPrompt` — park the text the operator composed
/// while the worktree was still being created (design 2026-08-10). Sent as a
/// second, independent RPC after `worktree.create` is already in flight; it
/// never participates in creation.
///
/// `text: nil` unparks without delivering. A second call replaces the first —
/// this is one prompt per worktree, not a queue.
public struct WorktreeSetPendingPromptParams: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let text: String?
    /// Whether delivery ends with Enter. **Opt-in, defaulting to `false`**:
    /// staged text costs the operator one keypress, while a turn nobody asked
    /// for cannot be taken back — and a submitted delivery is no more verifiable
    /// than an unsubmitted one, so the safer answer is also the honest one. A
    /// client that omits the key gets staging.
    public let submit: Bool

    public init(worktreeID: UUID, text: String?, submit: Bool = false) {
        self.worktreeID = worktreeID
        self.text = text
        self.submit = submit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        worktreeID = try c.decode(UUID.self, forKey: .worktreeID)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        submit = try c.decodeIfPresent(Bool.self, forKey: .submit) ?? false
    }
}

/// Result of `worktree.setPendingPrompt` — which of the two delivery paths the
/// prompt was committed to, decided once by whether the primary agent had
/// already spawned when the prompt arrived.
///
/// Encoded as `{"status": …}` plus a `reason` on refusals rather than as a
/// synthesized enum payload, so a status this build does not recognise decodes
/// as a refusal naming it instead of throwing.
public enum WorktreeSetPendingPromptResult: Codable, Sendable, Equatable {
    /// Written to the column, to be typed into the primary agent once its pane
    /// comes up. The common case — and the certain one while a `preSession`
    /// hook is still running.
    ///
    /// It promises that the text is parked and that this daemon session holds
    /// the licence to deliver it, not that delivery will succeed: the readiness
    /// ceiling starts only when the pane exists, and an outcome that is not a
    /// successful paste leaves the text in the column with a notification.
    case parkedForSpawn
    /// The primary agent is already up, so the prompt is armed against its
    /// readiness signal and will be pasted verbatim.
    case awaitingReady
    /// Nothing was parked. Carries an operator-readable reason — the flag being
    /// off, a worktree that does not exist, and so on.
    case refused(reason: String)

    private enum CodingKeys: String, CodingKey { case status, reason }
    private enum Status: String { case parkedForSpawn, awaitingReady, refused }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .parkedForSpawn:
            try c.encode(Status.parkedForSpawn.rawValue, forKey: .status)
        case .awaitingReady:
            try c.encode(Status.awaitingReady.rawValue, forKey: .status)
        case .refused(let reason):
            try c.encode(Status.refused.rawValue, forKey: .status)
            try c.encode(reason, forKey: .reason)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .status)
        switch Status(rawValue: raw) {
        case .parkedForSpawn: self = .parkedForSpawn
        case .awaitingReady: self = .awaitingReady
        case .refused:
            self = .refused(reason: try c.decodeIfPresent(String.self, forKey: .reason)
                ?? "refused")
        case nil:
            // A newer daemon answered with a path this build has no idea how to
            // wait on. "Not parked" is the safe reading.
            self = .refused(reason: "unrecognized pending-prompt status '\(raw)'")
        }
    }
}

/// Params for `config.setAutoCloseSetup` — the auto-close-setup-tab soak
/// flag (default OFF). Read fresh at spawn time; applies to the next
/// worktree creation, no daemon restart required.
public struct ConfigSetAutoCloseSetupParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setAutoTrustWorktrees` — pre-accept Claude's folder-trust
/// dialog for TBD-created worktrees (default ON). Read fresh at every Claude
/// spawn/wake, so the change applies to the next one; no daemon restart needed.
/// Turning it off never un-trusts an already-seeded path.
public struct ConfigSetAutoTrustWorktreesParams: Codable, Sendable {
    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setGCEnabled` — the orphan-GC master switch.
public struct ConfigSetGCEnabledParams: Codable, Sendable {
    public var enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setGCProfileDirsEnabled` — the gate for the profile-dir
/// collector, which reclaims orphaned `~/tbd/profiles/<uuid>/` directories
/// (default OFF during soak, on top of the GC master switch).
public struct ConfigSetGCProfileDirsEnabledParams: Codable, Sendable {
    public var enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setGCOrphanProcessesEnabled` — the gate for the
/// orphaned-process collector, which reclaims processes that outlived the
/// worktree they were rooted in (default OFF during soak, on top of the GC
/// master switch). Design: `docs/specs/2026-08-18-orphan-process-gc-design.md`.
public struct ConfigSetGCOrphanProcessesEnabledParams: Codable, Sendable {
    public var enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }
}

/// Params for `config.setRemoteCreateDefaults` — the machine-wide remote
/// create-param defaults, keyed by the provider's own field names.
public struct SetGlobalRemoteCreateDefaultsParams: Codable, Sendable, Equatable {
    public let defaults: [String: String]
    public init(defaults: [String: String]) { self.defaults = defaults }
}

/// Params for `repo.setRemoteCreateDefaults` — per-repo remote create-param
/// defaults, keyed by the provider's own field names.
public struct SetRepoRemoteCreateDefaultsParams: Codable, Sendable, Equatable {
    public let repoID: UUID
    public let defaults: [String: String]
    public init(repoID: UUID, defaults: [String: String]) {
        self.repoID = repoID
        self.defaults = defaults
    }
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
    /// tmux version the daemon detects for this request (e.g. "3.6a"); nil
    /// when detection fails (tmux missing/unparseable).
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
    /// Whether delivery acknowledgement is armed (`delivery_verification_enabled`,
    /// design §12). Default OFF while it soaks. This is the read-back for the
    /// soak's enable path: while it is false, `terminal.send --verify` is
    /// refused rather than quietly downgraded. Re-evaluated on every call.
    public let deliveryVerificationEnabled: Bool
    /// Whether TBD pre-accepts Claude's folder-trust dialog for the worktrees of
    /// registered repos — the ones TBD created plus the repo's own checkout, but
    /// never a fork-PR-head checkout (default ON). Re-evaluated by the daemon on
    /// every call.
    public let autoTrustWorktrees: Bool
    /// Whether the daemon owns panel-surface state (`daemon_panel_surface_enabled`,
    /// spec C Phase 2 §8/§10). Default OFF while the feature soaks — the app
    /// uses this to decide whether `panel.get`/`panel.apply` are live or the
    /// legacy client-owned layout path should still be used.
    public let panelSurfaceEnabled: Bool
    /// Whether `config.remoteBackendsEnabled` is currently set. Default OFF
    /// while the feature soaks (Task 7). The app can already read this off
    /// `Config`, but this lets `remoteBackendsLive` sit next to it in one
    /// payload — see that field's doc comment for why both are needed.
    public let remoteBackendsEnabled: Bool
    /// Whether the daemon actually constructed a `RemoteProviderManager` at
    /// boot — `false` when the flag is off, AND when the flag is on but was
    /// flipped on after the daemon last started (it only constructs the
    /// manager at boot; see `Daemon.swift`). Lets the app distinguish "flag
    /// on and live" from "flag on but needs a restart" without calling a
    /// `remote.*` verb and parsing its error string.
    ///
    /// True from the moment the manager is *constructed*, not from when it
    /// has finished describing providers — so during the brief boot window
    /// before `remoteManager.start()` completes, `remoteBackendsLive` can be
    /// true while the provider list is still empty. Fine for the
    /// restart-required distinction this field exists for; just don't read
    /// it as "at least one provider is up."
    public let remoteBackendsLive: Bool
    /// Whether the queued prompt at worktree creation is enabled (design
    /// 2026-08-10). Default OFF while it soaks. The app gates the whole modal
    /// on this — with it false, creation behaves exactly as it did before.
    /// Re-evaluated on every call, and resolved through
    /// `Config.queuedPromptDefault`, so an install that never touched the
    /// toggle reports whatever the shipped default currently is.
    public let queuedPromptEnabled: Bool
    /// Whether the Claude cloud sessions gate is currently set (design
    /// 2026-08-15 §7). Default OFF while it soaks. Resolved through
    /// `Config.claudeCloudEnabledDefault`, so an install that never touched the
    /// toggle reports whatever the shipped default currently is.
    public let claudeCloudEnabled: Bool
    /// Whether the daemon actually wired the built-in cloud provider at boot.
    /// `false` when either gate was off at that moment — AND when the flag was
    /// flipped on afterwards, since the provider manager is constructed only at
    /// boot and flipping a flag cannot conjure a provider into a running actor.
    /// Lets the app say "on, but needs a restart" without calling a `remote.*`
    /// verb and parsing its error string, exactly as `remoteBackendsLive` does
    /// for the outer flag.
    public let claudeCloudLive: Bool

    public init(controlModeEnabled: Bool,
                tmuxVersion: String? = nil,
                controlModeSupported: Bool = false,
                hibernateInputVetoEnabled: Bool = false,
                autoCloseSetupEnabled: Bool = false,
                deliveryVerificationEnabled: Bool = false,
                autoTrustWorktrees: Bool = true,
                panelSurfaceEnabled: Bool = false,
                remoteBackendsEnabled: Bool = false,
                remoteBackendsLive: Bool = false,
                queuedPromptEnabled: Bool = Config.queuedPromptDefault,
                claudeCloudEnabled: Bool = Config.claudeCloudEnabledDefault,
                claudeCloudLive: Bool = false) {
        self.controlModeEnabled = controlModeEnabled
        self.tmuxVersion = tmuxVersion
        self.controlModeSupported = controlModeSupported
        self.hibernateInputVetoEnabled = hibernateInputVetoEnabled
        self.autoCloseSetupEnabled = autoCloseSetupEnabled
        self.deliveryVerificationEnabled = deliveryVerificationEnabled
        self.autoTrustWorktrees = autoTrustWorktrees
        self.panelSurfaceEnabled = panelSurfaceEnabled
        self.remoteBackendsEnabled = remoteBackendsEnabled
        self.remoteBackendsLive = remoteBackendsLive
        self.queuedPromptEnabled = queuedPromptEnabled
        self.claudeCloudEnabled = claudeCloudEnabled
        self.claudeCloudLive = claudeCloudLive
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
        // New field for delivery acknowledgement; absent from older daemons defaults to false (soaking).
        deliveryVerificationEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .deliveryVerificationEnabled) ?? false
        // New field for worktree auto-trust; absent from older daemons defaults
        // to true, matching the column default (it is not a soak flag).
        autoTrustWorktrees = try c.decodeIfPresent(Bool.self, forKey: .autoTrustWorktrees) ?? true
        // New field for the panel-surface flag; absent from older daemons defaults to false (soaking).
        panelSurfaceEnabled = try c.decodeIfPresent(Bool.self, forKey: .panelSurfaceEnabled) ?? false
        // New fields for the remote-backends flag; absent from older daemons defaults to false (soaking).
        remoteBackendsEnabled = try c.decodeIfPresent(Bool.self, forKey: .remoteBackendsEnabled) ?? false
        remoteBackendsLive = try c.decodeIfPresent(Bool.self, forKey: .remoteBackendsLive) ?? false
        // New field for the queued-prompt flag; a daemon that does not send it
        // cannot honor a parked prompt either, so fall through to the shipped
        // default rather than assuming the feature is live.
        queuedPromptEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .queuedPromptEnabled) ?? Config.queuedPromptDefault
        // New fields for the Claude cloud gate. A daemon that does not send
        // `claudeCloudEnabled` cannot serve the feature either, so fall through
        // to the shipped default rather than assuming it is live. `live` is a
        // fact about THIS daemon's boot, so an absent value is honestly false.
        claudeCloudEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .claudeCloudEnabled) ?? Config.claudeCloudEnabledDefault
        claudeCloudLive = try c.decodeIfPresent(Bool.self, forKey: .claudeCloudLive) ?? false
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
    /// Whether the response carries the item's body text. `false` asks for the
    /// injection metadata alone — the transcript opens *every* injected row on
    /// appear just to read that metadata, and an injected CLAUDE.md body can be
    /// tens of KB that the caller immediately discards.
    ///
    /// Defaults to `true`, and a payload that omits the key decodes as `true`,
    /// so every existing caller and any older client keeps the body.
    public let includeBody: Bool
    public init(terminalID: UUID, itemID: String, includeBody: Bool = true) {
        self.terminalID = terminalID
        self.itemID = itemID
        self.includeBody = includeBody
    }

    enum CodingKeys: String, CodingKey {
        case terminalID, itemID, includeBody
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalID = try c.decode(UUID.self, forKey: .terminalID)
        itemID = try c.decode(String.self, forKey: .itemID)
        includeBody = try c.decodeIfPresent(Bool.self, forKey: .includeBody) ?? true
    }
}

/// How one injected-context row got into the context window: the hook that ran
/// (name, event, command, exit status, timing, stderr), the memory tier / path
/// of a loaded file, and the tool call that triggered it.
///
/// Rides the `terminal.transcriptItemFullBody` round-trip rather than living on
/// `TranscriptItem`: it is only read when a row is opened, and every extra
/// associated value on `TranscriptItem.systemReminder` costs ~15 switch sites.
/// Every field is optional — only what a row actually carries is populated, and
/// the overlay omits the rest rather than rendering placeholders.
public struct TranscriptAttachmentMetadata: Codable, Sendable, Equatable {
    public let hookName: String?
    public let hookEvent: String?
    public let command: String?
    public let exitCode: Int?
    public let durationMs: Int?
    public let stderr: String?
    /// `nested_memory`'s inner `content.type` — the memory tier, e.g. "Project".
    /// Passed through verbatim; the set of values is Claude Code's, not ours.
    public let memoryType: String?
    /// Absolute path of the loaded file, for display (tilde-abbreviated) and
    /// copy (verbatim).
    public let path: String?
    /// Short summary of the `tool_use` named by `attachment.toolUseID`, e.g.
    /// "Read ai-review-gate.yml". Nil when the row carries no `toolUseID` or
    /// the id resolves to nothing — never guessed from row position.
    public let triggeredBy: String?

    public var isEmpty: Bool {
        hookName == nil && hookEvent == nil && command == nil && exitCode == nil
            && durationMs == nil && stderr == nil && memoryType == nil
            && path == nil && triggeredBy == nil
    }

    public init(
        hookName: String? = nil,
        hookEvent: String? = nil,
        command: String? = nil,
        exitCode: Int? = nil,
        durationMs: Int? = nil,
        stderr: String? = nil,
        memoryType: String? = nil,
        path: String? = nil,
        triggeredBy: String? = nil
    ) {
        self.hookName = hookName
        self.hookEvent = hookEvent
        self.command = command
        self.exitCode = exitCode
        self.durationMs = durationMs
        self.stderr = stderr
        self.memoryType = memoryType
        self.path = path
        self.triggeredBy = triggeredBy
    }
}

public struct TerminalTranscriptItemFullBodyResult: Codable, Sendable {
    /// The un-truncated body, or `""` when the request passed
    /// `includeBody: false` (metadata-only fetch).
    public let text: String
    /// Present only for `attachment` rows (hook output, CLAUDE.md / file bodies).
    public let attachment: TranscriptAttachmentMetadata?
    public init(text: String, attachment: TranscriptAttachmentMetadata? = nil) {
        self.text = text
        self.attachment = attachment
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

public enum TerminalActivityEventOrigin: String, Codable, Sendable {
    /// The app observed the user explicitly interrupting the foreground agent.
    case userInterrupt = "user_interrupt"
}

public struct TerminalActivityEventParams: Codable, Sendable {
    public let terminalID: UUID
    public let activityState: TerminalActivityState
    /// Codex hook session identity when the caller consumed hook stdin.
    /// Optional for older hook overlays and non-hook callers.
    public let sessionID: String?
    /// Absent for the existing agent-hook bridge. Optional so older clients'
    /// payloads continue to decode unchanged.
    public let origin: TerminalActivityEventOrigin?
    public init(
        terminalID: UUID,
        activityState: TerminalActivityState,
        sessionID: String? = nil,
        origin: TerminalActivityEventOrigin? = nil
    ) {
        self.terminalID = terminalID
        self.activityState = activityState
        self.sessionID = sessionID
        self.origin = origin
    }
}

/// Params for `terminal.sessionEnded` — sent by `tbd session-end` from the
/// Claude Code `SessionEnd` hook. Carries identity only: the daemon decides
/// what ending a session means.
///
/// A dedicated method rather than a new `TerminalActivityEventOrigin` case:
/// an unknown enum raw value throws inside the shared params decode on an
/// older daemon, while an unknown *method* fails cleanly and the hook's
/// trailing `|| true` swallows it. `~/.local/bin/tbd` can be stale relative
/// to a running daemon, so that skew is real.
public struct TerminalSessionEndedParams: Codable, Sendable, Equatable {
    public let terminalID: UUID
    public init(terminalID: UUID) { self.terminalID = terminalID }
}

/// Params for `terminal.notificationEvent` — sent by `tbd hooks notification`
/// for EVERY Claude Code `Notification` event, whatever its type.
///
/// The CLI interprets nothing: it lifts the fields it can name, carries the
/// whole payload in `rawPayload`, and lets the daemon do the only classifying
/// there is. Keeping the fork daemon-side is deliberate — the hook entry lives
/// in a file an operator can edit, so a matcher or a branch out there would be
/// a policy decision TBD could not rely on.
public struct TerminalNotificationEventParams: Codable, Sendable, Equatable {
    public let terminalID: UUID
    /// `notification_type` verbatim, or nil when the payload carried none.
    /// Never normalized, never defaulted to a known type.
    public let notificationType: String?
    /// The notification text, verbatim.
    public let message: String
    /// The notification title, when the payload carried one. Reported rather
    /// than persisted in a column of its own: `AwaitingInputReason` models the
    /// message and the type, and the title survives inside `rawPayload` for a
    /// consumer that wants it. Carried on the wire anyway so the daemon can
    /// start using it without a CLI release — an older CLI is the thing that
    /// cannot be fixed retroactively.
    public let title: String?
    /// The entire stdin payload as it arrived, so a later consumer can read a
    /// field this build does not model.
    public let rawPayload: String?
    /// Claude's reported working directory, used only for the same
    /// foreign-session guard `terminal.sessionEvent` applies: a hook fired by a
    /// session living in another worktree must not write to this terminal.
    /// Optional for backward compatibility with older CLIs.
    public let cwd: String?

    public init(
        terminalID: UUID,
        notificationType: String?,
        message: String,
        title: String? = nil,
        rawPayload: String? = nil,
        cwd: String? = nil
    ) {
        self.terminalID = terminalID
        self.notificationType = notificationType
        self.message = message
        self.title = title
        self.rawPayload = rawPayload
        self.cwd = cwd
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
