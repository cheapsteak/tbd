import AppKit
import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.app", category: "dev-servers")

enum DevServerAction: Sendable {
    case start
    case stop
}

/// Why a worktree's server list is fetched. The repo's `status` commands are
/// repo-authored shell, so they run only on a user gesture on the servers —
/// never because a worktree was selected or the daemon reported a change.
enum DevServerRefreshTrigger: Sendable {
    /// A single worktree became selected.
    case selection
    /// A `devServersChanged` delta.
    case change
    /// After a Start, Stop or Restart from the Servers menu.
    case action
    /// The Servers menu's "Refresh status".
    case refreshStatus

    var runsStatusCommands: Bool {
        switch self {
        case .selection, .change: false
        case .action, .refreshStatus: true
        }
    }
}

extension AppState {
    func refreshDevServerSummary() async {
        do {
            let ids = Set(try await devServerSummaryFetcher().runningWorktreeIDs)
            if ids != devServerRunningWorktreeIDs { devServerRunningWorktreeIDs = ids }
        } catch {
            logger.debug("server.summary failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetches a worktree's server list. Repo-authored `status` commands run
    /// only when `trigger` is a user gesture on the servers
    /// (`DevServerRefreshTrigger.runsStatusCommands`); otherwise the servers
    /// known only through one keep the state its last run found.
    func refreshDevServers(worktreeID: UUID, trigger: DevServerRefreshTrigger) async {
        let runStatus = trigger.runsStatusCommands
        let generation = (devServerListGenerations[worktreeID] ?? 0) &+ 1
        devServerListGenerations[worktreeID] = generation
        var statusGeneration: UInt64?
        if runStatus {
            let next = (devServerStatusGenerations[worktreeID] ?? 0) &+ 1
            devServerStatusGenerations[worktreeID] = next
            statusGeneration = next
        }
        let result: DevServerListResult
        do {
            result = try await devServerListFetcher(worktreeID, runStatus)
        } catch {
            logger.debug("server.list failed for \(worktreeID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        if let statusGeneration, devServerStatusGenerations[worktreeID] == statusGeneration {
            devServerLastStatus[worktreeID] = Self.statusOnlyStates(in: result)
        }
        if devServerListGenerations[worktreeID] == generation {
            devServerFetchedLists[worktreeID] = result
        } else if statusGeneration == nil {
            // A refresh started after this one owns the list now.
            return
        }
        // A superseded `status` run still updates the last-known answers,
        // laid over the newest list.
        guard let fetched = devServerFetchedLists[worktreeID] else { return }
        let shown = Self.withLastKnownStatus(fetched, lastKnown: devServerLastStatus[worktreeID] ?? [:])
        if devServerLists[worktreeID] != shown { devServerLists[worktreeID] = shown }
    }

    /// The Servers menu's "Refresh status": runs the worktree's `status`
    /// commands.
    func refreshDevServerStatus(worktreeID: UUID) async {
        await refreshDevServers(worktreeID: worktreeID, trigger: .refreshStatus)
    }

    /// A `devServersChanged` delta: the dot's set, and the selected
    /// worktree's list (without `status` commands — a delta is not a
    /// gesture).
    func refreshDevServersAfterChange() async {
        await refreshDevServerSummary()
        if selectedWorktreeIDs.count == 1, let id = selectedWorktreeIDs.first {
            await refreshDevServers(worktreeID: id, trigger: .change)
        }
    }

    /// The servers a `status`-command run found running or unknown by their
    /// `status` command alone: declared, with no TBD tab, no pid and no
    /// running-file URLs. Given how the daemon derives states, such a server
    /// reads running only when its `status` command exited 0 and unknown
    /// only when it timed out.
    nonisolated static func statusOnlyStates(in list: DevServerListResult) -> [String: DevServerStateKind] {
        var states: [String: DevServerStateKind] = [:]
        for server in list.servers
        where server.isDeclared && server.terminalID == nil && server.pid == nil && server.endpoints.isEmpty
            && (server.state == .running || server.state == .unknown) {
            states[server.name] = server.state
        }
        return states
    }

    /// A list fetched without `status` commands reads a status-only server
    /// as stopped; show the state its last `status` run found instead. Any
    /// other state comes from a running file or a TBD tab, which are live,
    /// and wins.
    nonisolated static func withLastKnownStatus(
        _ list: DevServerListResult, lastKnown: [String: DevServerStateKind]
    ) -> DevServerListResult {
        guard !lastKnown.isEmpty else { return list }
        var merged = list
        for index in merged.servers.indices where merged.servers[index].state == .stopped {
            if let known = lastKnown[merged.servers[index].name] { merged.servers[index].state = known }
        }
        return merged
    }

    func performDevServerAction(_ action: DevServerAction, worktreeID: UUID, names: [String]) async {
        var messages: [String] = []
        do {
            let result = try await devServerActionSender(action, worktreeID, names)
            messages = result.outcomes.filter { $0.status == .failed }
                .map { "\($0.name): \($0.message ?? "failed")" }
        } catch {
            messages = [error.localizedDescription]
            logger.error("server action failed: \(error.localizedDescription, privacy: .public)")
        }
        let stored = messages.isEmpty ? nil : messages
        if devServerActionMessages[worktreeID] != stored {
            devServerActionMessages[worktreeID] = stored
        }
        await refreshDevServers(worktreeID: worktreeID, trigger: .action)
        await refreshDevServerSummary()
    }

    func restartDevServers(worktreeID: UUID, names: [String]) async {
        await performDevServerAction(.stop, worktreeID: worktreeID, names: names)
        guard devServerActionMessages[worktreeID] == nil else { return }
        await performDevServerAction(.start, worktreeID: worktreeID, names: names)
    }

    func openDevServerURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// "Show last output" for an exited server: the saved entry in Session
    /// History's Closed Terminals viewer when the daemon saved one (holder
    /// transport), else the server's own tab, whose dead pane still shows the
    /// output (tmux).
    func showDevServerLastOutput(worktreeID: UUID, server: DevServerInfo) async {
        if let entryID = server.lastOutputID {
            await devServerLastOutputOpener(worktreeID, entryID)
        } else if let terminalID = server.terminalID {
            devServerTabFocuser(worktreeID, terminalID)
        }
    }

    /// Opens Session History on one Closed Terminals entry: shows the pane,
    /// refreshes its lists, then selects the entry — after the refresh,
    /// because `fetchSessions` may auto-select a session, which clears a
    /// closed-terminal selection. The cached text is dropped first: a later
    /// close of the same tab re-saves the entry under the same id.
    func openClosedTerminalEntry(worktreeID: UUID, entryID: UUID) async {
        if !historyActiveWorktrees.contains(worktreeID) { historyActiveWorktrees.insert(worktreeID) }
        await fetchSessions(worktreeID: worktreeID)
        guard let entry = closedTerminalHistories[worktreeID]?.first(where: { $0.id == entryID }) else {
            logger.debug("last output \(entryID.uuidString, privacy: .public) is no longer in Closed Terminals")
            return
        }
        closedTerminalContents.removeValue(forKey: entryID)
        await selectClosedTerminal(entry, worktreeID: worktreeID)
    }

    /// Brings a server's tab forward: leaves Session History if it is showing,
    /// selects the tab, and gives its terminal focus.
    func focusDevServerTab(worktreeID: UUID, terminalID: UUID) {
        if historyActiveWorktrees.contains(worktreeID) { historyActiveWorktrees.remove(worktreeID) }
        repointActiveTab(worktreeID: worktreeID, to: terminalID)
        revealTerminal(terminalID: terminalID)
    }

    /// The toolbar's primary click: the main URL of the first running server
    /// that has one; nil disables the primary half.
    nonisolated static func primaryDevServerURL(_ list: DevServerListResult?) -> String? {
        list?.servers.first { $0.state == .running && $0.mainURL != nil }?.mainURL
    }

    /// Shown only when the worktree has at least one declared or reported server.
    nonisolated static func showsServersButton(_ list: DevServerListResult?) -> Bool {
        !(list?.servers.isEmpty ?? true)
    }
}
