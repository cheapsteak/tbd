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

/// What a `status`-command run decided for one server, remembered across
/// refreshes that do not run `status` commands.
struct DevServerRememberedStatus: Sendable, Equatable {
    var state: DevServerStateKind
    /// The server's TBD tab when the run answered, if it had one.
    var terminalID: UUID?
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
    /// whose state a `status` command decided keep the answer its last run
    /// found (`withLastKnownStatus`).
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
        // Compared against the newest run that answered, not the newest
        // started: a newer run that failed leaves an older one's answers
        // standing.
        if let statusGeneration, statusGeneration > (devServerLandedStatusGenerations[worktreeID] ?? 0) {
            devServerLandedStatusGenerations[worktreeID] = statusGeneration
            devServerLastStatus[worktreeID] = Self.statusCommandStates(in: result)
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
        let remembered = Self.prunedLastKnownStatus(devServerLastStatus[worktreeID] ?? [:], for: fetched)
        devServerLastStatus[worktreeID] = remembered.isEmpty ? nil : remembered
        let shown = Self.withLastKnownStatus(fetched, lastKnown: remembered)
        if devServerLists[worktreeID] != shown { devServerLists[worktreeID] = shown }
    }

    /// Drops what the app holds about a worktree's dev servers, when the
    /// worktree leaves app state.
    func forgetDevServerState(worktreeID: UUID) {
        devServerFetchedLists.removeValue(forKey: worktreeID)
        devServerLastStatus.removeValue(forKey: worktreeID)
        devServerStatusGenerations.removeValue(forKey: worktreeID)
        devServerLandedStatusGenerations.removeValue(forKey: worktreeID)
        devServerLists.removeValue(forKey: worktreeID)
        devServerActionMessages.removeValue(forKey: worktreeID)
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

    /// The servers whose state a `status`-command run decided — the daemon
    /// marks them `stateFromStatusCommand` — with the TBD tab each had then.
    /// Such a server reads running when its `status` command exited 0 and
    /// unknown when it timed out, with nothing ranked above it.
    nonisolated static func statusCommandStates(in list: DevServerListResult) -> [String: DevServerRememberedStatus] {
        var states: [String: DevServerRememberedStatus] = [:]
        for server in list.servers where server.stateFromStatusCommand == true {
            states[server.name] = DevServerRememberedStatus(state: server.state, terminalID: server.terminalID)
        }
        return states
    }

    /// The remembered answers still worth keeping against the newest list: a
    /// server that is gone, or whose declaration no longer has a `status`
    /// command, has nothing left to answer for it.
    nonisolated static func prunedLastKnownStatus(
        _ lastKnown: [String: DevServerRememberedStatus], for list: DevServerListResult
    ) -> [String: DevServerRememberedStatus] {
        guard !lastKnown.isEmpty else { return lastKnown }
        var servers: [String: DevServerInfo] = [:]
        for server in list.servers { servers[server.name] = server }
        return lastKnown.filter { name, _ in
            guard let server = servers[name] else { return false }
            return server.hasStatusCommand != false
        }
    }

    /// A list fetched without `status` commands cannot see what only a
    /// `status` command can: a server known only through one reads stopped,
    /// and one whose command detached (`docker compose up -d`) reads exited
    /// by its finished TBD tab. Show the state the last `status` run found
    /// instead — over a stopped server, or over an exited one whose tab is
    /// the one that run saw. A newer exited tab, and every other state (a
    /// running file, a running or unreadable TBD tab), is live and wins.
    nonisolated static func withLastKnownStatus(
        _ list: DevServerListResult, lastKnown: [String: DevServerRememberedStatus]
    ) -> DevServerListResult {
        guard !lastKnown.isEmpty else { return list }
        var merged = list
        for index in merged.servers.indices {
            let server = merged.servers[index]
            guard let known = lastKnown[server.name] else { continue }
            switch server.state {
            case .stopped:
                merged.servers[index].state = known.state
            case .exited:
                // Once the tab's row is gone, its saved output carries the
                // tab's id.
                guard let seen = known.terminalID, (server.terminalID ?? server.lastOutputID) == seen else { continue }
                merged.servers[index].state = known.state
                merged.servers[index].exitCode = nil
                merged.servers[index].lastOutputID = nil
            default:
                continue
            }
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
