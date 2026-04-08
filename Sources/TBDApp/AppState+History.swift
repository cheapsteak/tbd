import Foundation
import TBDShared

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
}
