import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+History")

// MARK: - HistoryLoadState

enum HistoryLoadState {
    case idle
    case loading                            // first load — no prior data
    case loadingStale([SessionSummary])     // refetch — stale data kept visible
    case loaded([SessionSummary])
    case failed(String)                     // error message for display

    var currentSessions: [SessionSummary] {
        switch self {
        case .loadingStale(let s), .loaded(let s): return s
        default: return []
        }
    }

    var isLoading: Bool {
        switch self {
        case .loading, .loadingStale: return true
        default: return false
        }
    }
}

// MARK: - Equatable

extension HistoryLoadState: Equatable {
    static func == (lhs: HistoryLoadState, rhs: HistoryLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.loading, .loading): return true
        case (.loadingStale(let a), .loadingStale(let b)): return a.map(\.id) == b.map(\.id)
        case (.loaded(let a), .loaded(let b)): return a.map(\.id) == b.map(\.id)
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - AppState History Extension

extension AppState {

    /// Toggle the history pane for a worktree. Shows it (and triggers a fetch) or hides it.
    func toggleHistory(worktreeID: UUID) {
        if historyActiveWorktrees.contains(worktreeID) {
            historyActiveWorktrees.remove(worktreeID)
        } else {
            historyActiveWorktrees.insert(worktreeID)
            Task { await fetchSessions(worktreeID: worktreeID) }
        }
    }

    /// Fetch sessions from the daemon, keeping stale data visible during the request.
    func fetchSessions(worktreeID: UUID) async {
        let current = historyLoadStates[worktreeID]?.currentSessions ?? []
        historyLoadStates[worktreeID] = current.isEmpty ? .loading : .loadingStale(current)

        do {
            let fresh = try await daemonClient.listSessions(worktreeID: worktreeID)
            historyLoadStates[worktreeID] = .loaded(fresh)
            // Auto-select the first session on initial load if nothing is selected yet.
            // Applies to both active and archived worktrees.
            if selectedSessionIDs[worktreeID] == nil, let first = fresh.first {
                await selectSession(first, worktreeID: worktreeID)
            }
        } catch {
            historyLoadStates[worktreeID] = .failed(error.localizedDescription)
        }
    }

    /// Select a session and load its transcript (stale-while-revalidate: skip if already loaded).
    func selectSession(_ summary: SessionSummary, worktreeID: UUID) async {
        selectedSessionIDs[worktreeID] = summary.sessionId
        guard sessionTranscripts[summary.sessionId] == nil else { return }
        sessionTranscriptLoading.insert(summary.sessionId)
        defer { sessionTranscriptLoading.remove(summary.sessionId) }
        do {
            let messages = try await daemonClient.sessionMessages(filePath: summary.filePath)
            sessionTranscripts[summary.sessionId] = messages
        } catch {
            // leave empty, user can try again
        }
    }

    /// Resume a Claude session in a new terminal tab and switch focus to it.
    func resumeSession(worktreeID: UUID, sessionId: String) async {
        do {
            let terminal = try await daemonClient.createTerminal(
                worktreeID: worktreeID,
                resumeSessionID: sessionId
            )
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id))
            tabs[worktreeID, default: []].append(tab)
            let index = (tabs[worktreeID]?.count ?? 1) - 1
            activeTabIndices[worktreeID] = index
            historyActiveWorktrees.remove(worktreeID)
        } catch {
            handleConnectionError(error)
        }
    }

    /// Revive an archived worktree and resume the selected Claude session.
    /// Marks the row as `inFlight` immediately so the archived view can show
    /// a status pill, then flips to `.done` on success or clears on failure.
    func reviveWithSession(worktreeID: UUID, sessionId: String) async {
        // Find the snapshot in archivedWorktrees so we can keep the row visible
        // after the daemon reconciles the worktree out of the archived list.
        guard let snapshot = archivedWorktrees.values
            .flatMap({ $0 })
            .first(where: { $0.id == worktreeID })
        else {
            logger.warning("reviveWithSession: no archived snapshot for \(worktreeID, privacy: .public)")
            return
        }
        revivingArchived[worktreeID] = .inFlight(snapshot: snapshot)

        // Advance the archived row selection if this row is currently selected
        // (rule: in-flight rows are non-selectable).
        advanceArchivedSelectionIfNeeded(worktreeID: worktreeID)

        do {
            let size = mainAreaTerminalSize()
            try await daemonClient.reviveWorktree(
                id: worktreeID,
                cols: size.cols,
                rows: size.rows,
                preferredSessionID: sessionId
            )
            revivingArchived[worktreeID] = .done(snapshot: snapshot)
            await refreshWorktrees()
            await refreshArchivedWorktrees(repoID: snapshot.repoID)
        } catch {
            revivingArchived.removeValue(forKey: worktreeID)
            handleConnectionError(error)
        }
    }

    /// If the in-flight worktree was the selected archived row for its repo,
    /// move selection to the next-most-recent archived row (or clear).
    private func advanceArchivedSelectionIfNeeded(worktreeID: UUID) {
        let repoID = archivedWorktrees.first(where: { (_, wts) in
            wts.contains(where: { $0.id == worktreeID })
        })?.key
        guard let repoID, selectedArchivedWorktreeIDs[repoID] == worktreeID else { return }
        let remaining = (archivedWorktrees[repoID] ?? [])
            .filter { $0.id != worktreeID }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        if let next = remaining.first {
            selectedArchivedWorktreeIDs[repoID] = next.id
        } else {
            selectedArchivedWorktreeIDs.removeValue(forKey: repoID)
        }
    }
}
