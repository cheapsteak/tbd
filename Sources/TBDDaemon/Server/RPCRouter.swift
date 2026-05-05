import Foundation
import TBDShared

/// Maps RPC method names to handler functions.
/// Decodes raw JSON params, dispatches to the appropriate subsystem, and returns an RPCResponse.
public final class RPCRouter: Sendable {
    public let db: TBDDatabase
    public let lifecycle: WorktreeLifecycle
    public let tmux: TmuxManager
    public let git: GitManager
    public let startTime: Date
    public let subscriptions: StateSubscriptionManager
    public let prManager: PRStatusManager
    public let suspendResumeCoordinator: SuspendResumeCoordinator
    public let conductorManager: ConductorManager
    public let usageFetcher: ClaudeUsageFetcher
    public let modelProfileResolver: ModelProfileResolver
    public nonisolated(unsafe) var claudeUsagePoller: ClaudeUsagePoller?

    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    public init(
        db: TBDDatabase,
        lifecycle: WorktreeLifecycle,
        tmux: TmuxManager,
        git: GitManager = GitManager(),
        startTime: Date = Date(),
        subscriptions: StateSubscriptionManager = StateSubscriptionManager(),
        prManager: PRStatusManager = PRStatusManager(),
        conductorManager: ConductorManager? = nil,
        usageFetcher: ClaudeUsageFetcher = LiveClaudeUsageFetcher(),
        modelProfileResolver: ModelProfileResolver? = nil
    ) {
        self.db = db
        self.lifecycle = lifecycle
        self.tmux = tmux
        self.git = git
        self.startTime = startTime
        self.subscriptions = subscriptions
        self.prManager = prManager
        let resolvedModelProfileResolver = modelProfileResolver ?? ModelProfileResolver(
            profiles: db.modelProfiles,
            repos: db.repos,
            config: db.config
        )
        self.modelProfileResolver = resolvedModelProfileResolver
        self.suspendResumeCoordinator = SuspendResumeCoordinator(
            db: db, tmux: tmux, modelProfileResolver: resolvedModelProfileResolver
        )
        self.conductorManager = conductorManager ?? ConductorManager(db: db, tmux: tmux)
        self.usageFetcher = usageFetcher
    }

    /// Handle a raw JSON Data blob representing an RPCRequest.
    /// Returns an RPCResponse.
    public func handleRaw(_ data: Data) async -> RPCResponse {
        do {
            let request = try decoder.decode(RPCRequest.self, from: data)
            return await handle(request)
        } catch {
            return RPCResponse(error: "Failed to decode request: \(error.localizedDescription)")
        }
    }

    /// Handle a decoded RPCRequest and return an RPCResponse.
    public func handle(_ request: RPCRequest) async -> RPCResponse {
        do {
            switch request.method {
            case RPCMethod.repoAdd:
                return try await handleRepoAdd(request.paramsData)
            case RPCMethod.repoRemove:
                return try await handleRepoRemove(request.paramsData)
            case RPCMethod.repoList:
                return try await handleRepoList()
            case RPCMethod.repoUpdateInstructions:
                return try await handleRepoUpdateInstructions(request.paramsData)
            case RPCMethod.repoRelocate:
                return try await handleRepoRelocate(request.paramsData)
            case RPCMethod.repoRename:
                return try await handleRepoRename(request.paramsData)
            case RPCMethod.worktreeCreate:
                return try await handleWorktreeCreate(request.paramsData)
            case RPCMethod.worktreeList:
                return try await handleWorktreeList(request.paramsData)
            case RPCMethod.worktreeArchive:
                return try await handleWorktreeArchive(request.paramsData)
            case RPCMethod.worktreeRevive:
                return try await handleWorktreeRevive(request.paramsData)
            case RPCMethod.worktreeRename:
                return try await handleWorktreeRename(request.paramsData)
            case RPCMethod.worktreeReorder:
                return try await handleWorktreeReorder(request.paramsData)
            case RPCMethod.terminalCreate:
                return try await handleTerminalCreate(request.paramsData)
            case RPCMethod.terminalList:
                return try await handleTerminalList(request.paramsData)
            case RPCMethod.terminalSend:
                return try await handleTerminalSend(request.paramsData)
            case RPCMethod.terminalDelete:
                return try await handleTerminalDelete(request.paramsData)
            case RPCMethod.terminalSetPin:
                return try await handleTerminalSetPin(request.paramsData)
            case RPCMethod.terminalSwapProfile:
                return try await handleTerminalSwapProfile(request.paramsData)
            case RPCMethod.notify:
                return try await handleNotify(request.paramsData)
            case RPCMethod.daemonStatus:
                return try handleDaemonStatus()
            case RPCMethod.resolvePath:
                return try await handleResolvePath(request.paramsData)
            case RPCMethod.notificationsList:
                return try await handleNotificationsList()
            case RPCMethod.notificationsMarkRead:
                return try await handleNotificationsMarkRead(request.paramsData)
            case RPCMethod.cleanup:
                return try await handleCleanup()
            case RPCMethod.prList:
                return try await handlePRList()
            case RPCMethod.prRefresh:
                return try await handlePRRefresh(request.paramsData)
            case RPCMethod.worktreeSelectionChanged:
                return try await handleWorktreeSelectionChanged(request.paramsData)
            case RPCMethod.terminalSuspend:
                return try await handleTerminalSuspend(request.paramsData)
            case RPCMethod.terminalResume:
                return try await handleTerminalResume(request.paramsData)
            case RPCMethod.worktreeSuspend:
                return try await handleWorktreeSuspend(request.paramsData)
            case RPCMethod.worktreeResume:
                return try await handleWorktreeResume(request.paramsData)
            case RPCMethod.terminalRecreateWindow:
                return try await handleTerminalRecreateWindow(request.paramsData)
            case RPCMethod.noteCreate:
                return try await handleNoteCreate(request.paramsData)
            case RPCMethod.noteGet:
                return try await handleNoteGet(request.paramsData)
            case RPCMethod.noteUpdate:
                return try await handleNoteUpdate(request.paramsData)
            case RPCMethod.noteDelete:
                return try await handleNoteDelete(request.paramsData)
            case RPCMethod.noteList:
                return try await handleNoteList(request.paramsData)
            case RPCMethod.terminalOutput:
                return try await handleTerminalOutput(request.paramsData)
            case RPCMethod.terminalConversation:
                return try await handleTerminalConversation(request.paramsData)
            case RPCMethod.conductorSetup:
                return try await handleConductorSetup(request.paramsData)
            case RPCMethod.conductorStart:
                return try await handleConductorStart(request.paramsData)
            case RPCMethod.conductorStop:
                return try await handleConductorStop(request.paramsData)
            case RPCMethod.conductorTeardown:
                return try await handleConductorTeardown(request.paramsData)
            case RPCMethod.conductorList:
                return try await handleConductorList()
            case RPCMethod.conductorStatus:
                return try await handleConductorStatus(request.paramsData)
            case RPCMethod.conductorSuggest:
                return try await handleConductorSuggest(request.paramsData)
            case RPCMethod.conductorClearSuggestion:
                return try await handleConductorClearSuggestion(request.paramsData)
            case RPCMethod.modelProfileList:
                return try await handleModelProfileList()
            case RPCMethod.modelProfileAdd:
                return try await handleModelProfileAdd(request.paramsData)
            case RPCMethod.modelProfileDelete:
                return try await handleModelProfileDelete(request.paramsData)
            case RPCMethod.modelProfileRename:
                return try await handleModelProfileRename(request.paramsData)
            case RPCMethod.modelProfileUpdateEndpoint:
                return try await handleModelProfileUpdateEndpoint(request.paramsData)
            case RPCMethod.modelProfileSetGlobalDefault:
                return try await handleModelProfileSetGlobalDefault(request.paramsData)
            case RPCMethod.modelProfileSetRepoOverride:
                return try await handleModelProfileSetRepoOverride(request.paramsData)
            case RPCMethod.modelProfileFetchUsage:
                return try await handleModelProfileFetchUsage(request.paramsData)
            case RPCMethod.modelProfileHealthCheck:
                return try await handleModelProfileHealthCheck(request.paramsData)
            case RPCMethod.appSetForegroundState:
                let params = try decoder.decode(AppSetForegroundStateParams.self, from: request.paramsData)
                await claudeUsagePoller?.onFocusChanged(isForeground: params.isForeground)
                return .ok()
            case RPCMethod.setMainAreaSize:
                return try await handleSetMainAreaSize(request.paramsData)
            case RPCMethod.sessionList:
                return try await handleSessionList(request.paramsData)
            case RPCMethod.sessionMessages:
                return try await handleSessionMessages(request.paramsData)
            case RPCMethod.stateSubscribe:
                return RPCResponse(error: "state.subscribe must be handled by SocketServer")
            default:
                return RPCResponse(error: "Unknown method: \(request.method)")
            }
        } catch {
            return RPCResponse(error: "\(error)")
        }
    }

    // MARK: - PR Status

    private func handlePRList() async throws -> RPCResponse {
        // Fetch fresh PR data for all active worktrees before returning the cache.
        // This is called every ~30s by the app, so one GraphQL call per poll is acceptable.
        let worktrees = try await db.worktrees.list(status: .active)
        let infos = worktrees.map { (id: $0.id, branch: $0.branch, repoPath: $0.path) }
        await prManager.fetchAll(worktrees: infos)
        let statuses = await prManager.allStatuses()
        return try RPCResponse(result: PRListResult(statuses: statuses))
    }

    private func handlePRRefresh(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PRRefreshParams.self, from: paramsData)

        // Look up worktree and repo to get branch and repoPath
        guard let wt = try await db.worktrees.get(id: params.worktreeID),
              let repo = try await db.repos.get(id: wt.repoID) else {
            return try RPCResponse(result: PRRefreshResult(status: nil))
        }

        let status = await prManager.refresh(
            worktreeID: wt.id,
            branch: wt.branch,
            repoPath: repo.path
        )
        return try RPCResponse(result: PRRefreshResult(status: status))
    }
}
