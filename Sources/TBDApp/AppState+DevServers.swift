import AppKit
import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.app", category: "dev-servers")

enum DevServerAction: Sendable {
    case start
    case stop
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

    func refreshDevServers(worktreeID: UUID, runStatusCommands: Bool) async {
        do {
            let result = try await devServerListFetcher(worktreeID, runStatusCommands)
            if devServerLists[worktreeID] != result { devServerLists[worktreeID] = result }
        } catch {
            logger.debug("server.list failed for \(worktreeID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A `devServersChanged` delta: the dot's set, and the selected
    /// worktree's list (with `status` commands).
    func refreshDevServersAfterChange() async {
        await refreshDevServerSummary()
        if selectedWorktreeIDs.count == 1, let id = selectedWorktreeIDs.first {
            await refreshDevServers(worktreeID: id, runStatusCommands: true)
        }
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
        await refreshDevServers(worktreeID: worktreeID, runStatusCommands: true)
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
