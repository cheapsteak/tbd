import Foundation
import os
import TBDShared

private let restorePlanLogger = Logger(subsystem: "com.tbd.daemon", category: "archive")

/// Match each saved tab at most once, including snapshots containing two tabs
/// for one conversation. A provider's bare session ID never matches another.
internal func missingArchivedAgentTabs(_ tabs: [ArchivedAgentTab], terminals: [Terminal]) -> [ArchivedAgentTab] {
    var available = terminals.compactMap { $0.recoveryResumePlan?.identity }
    return tabs.filter { tab in
        guard let index = available.firstIndex(of: tab.identity) else { return true }
        available.remove(at: index)
        return false
    }
}

extension WorktreeLifecycle {
    /// Legacy histories prove ownership through their archive or the same
    /// worktree-scoped scanner used by Session History, never a global ID scan.
    func legacyClaudeSessionBelongs(_ identity: AgentSessionIdentity, to worktree: Worktree) -> Bool {
        guard identity.agentKind == .claude else { return false }
        if worktree.resolvedArchivedAgentTabs.contains(where: { $0.identity == identity })
            || worktree.archivedClaudeSessions?.contains(identity.sessionID) == true { return true }
        guard let project = ClaudeProjectDirectory.resolve(worktreePath: worktree.localPath) else { return false }
        return ClaudeSessionScanner.listSessions(projectDir: project).contains { $0.identity == identity }
    }

    /// Admission and spawning consume the same plan, including a selected
    /// history conversation that was not open when the worktree was archived.
    func archivedRestorePlan(worktreeID: UUID, preferred: AgentSessionIdentity?) async throws -> [ArchivedAgentTab] {
        var tabs = try await db.worktrees.archivedAgentTabsForRevive(id: worktreeID)
        guard let preferred else { return tabs }
        let association = try await db.localAgentSessions.get(worktreeID: worktreeID, identity: preferred)
        guard preferred.agentKind != .codex || association != nil else {
            throw WorktreeLifecycleError.invalidOperation("Selected Codex session is not associated with this worktree")
        }
        if !tabs.contains(where: { $0.identity == preferred }) {
            guard let worktree = try await db.worktrees.get(id: worktreeID) else {
                throw WorktreeLifecycleError.worktreeNotFound(worktreeID)
            }
            guard association != nil || legacyClaudeSessionBelongs(preferred, to: worktree) else {
                throw WorktreeLifecycleError.invalidOperation("Selected session is not associated with this worktree")
            }
            tabs.append(ArchivedAgentTab(identity: preferred, ordinal: (tabs.map(\.ordinal).max() ?? -1) + 1,
                isPrimary: true, claudeSpawnExtras: worktree.archivedClaudeSpawnExtras?[preferred.sessionID],
                codexLaunchOptions: association?.codexLaunchOptions))
        }
        return preferredArchivedAgentTabs(tabs, preferred: preferred)
    }

    /// Restore focus/order from the complete plan even when earlier attempts
    /// committed some terminal rows before a later spawn failed.
    func orderArchivedRestore(worktreeID: UUID, tabs: [ArchivedAgentTab]) async throws {
        var terminals = try await db.terminals.list(worktreeID: worktreeID)
        var agents: [UUID] = []
        for tab in orderedArchivedAgentTabs(tabs) {
            guard let index = terminals.firstIndex(where: { $0.recoveryResumePlan?.identity == tab.identity }) else { continue }
            agents.append(terminals.remove(at: index).id)
        }
        guard let primary = agents.first else { return }
        let oldOrder = try await db.worktrees.getTabOrder(worktreeID: worktreeID)
        let remaining = terminals.sorted { $0.createdAt < $1.createdAt }.map(\.id)
        let others = oldOrder.filter { remaining.contains($0) } + remaining.filter { !oldOrder.contains($0) }
        try await db.worktrees.setTabOrder(worktreeID: worktreeID, tabIDs: [primary] + others + agents.dropFirst())
        try await db.worktrees.setActiveTabID(worktreeID: worktreeID, tabID: primary)
    }

    func disarmMergeActionsAfterRevive(worktreeID: UUID) async {
        do {
            try await db.worktrees.setAutoArchiveOnMerge(id: worktreeID, value: false)
        } catch {
            restorePlanLogger.warning("failed to disarm auto-archive for \(worktreeID, privacy: .public)")
        }
        do {
            try await db.worktrees.setAutoHibernateOnMerge(id: worktreeID, value: false)
        } catch {
            restorePlanLogger.warning("failed to disarm auto-hibernate for \(worktreeID, privacy: .public)")
        }
    }

    /// A valid checkout with an unfinished snapshot is explicitly retryable.
    /// Keep it visible on failure; clear the snapshot only after every spawn.
    func completeArchivedRestore(
        worktree: Worktree, repo: Repo, tabs: [ArchivedAgentTab],
        prepared: [Int: CodexLaunchPreparation]? = nil, cols: Int? = nil, rows: Int? = nil
    ) async throws -> WorktreeReviveCompletion {
        await disarmMergeActionsAfterRevive(worktreeID: worktree.id)
        do {
            _ = try await spawnPrimaryTerminals(worktree: worktree, repo: repo, skipClaude: false,
                archivedAgentTabs: tabs, preparedArchivedCodexLaunches: prepared,
                cols: cols, rows: rows, preSessionTerminalID: nil)
            try await db.worktrees.revive(id: worktree.id, clearSessions: true)
        } catch {
            try? await orderArchivedRestore(worktreeID: worktree.id, tabs: tabs)
            try? await db.worktrees.revive(id: worktree.id, clearSessions: false)
            throw error
        }
        guard let restored = try await db.worktrees.get(id: worktree.id) else {
            throw WorktreeLifecycleError.worktreeNotFound(worktree.id)
        }
        return .ready(restored)
    }
}
