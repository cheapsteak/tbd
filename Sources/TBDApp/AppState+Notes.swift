import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "AppState+Notes")

extension AppState {
    // MARK: - Note Actions

    /// Create a note in a worktree and add a new tab for it.
    func createNote(worktreeID: UUID) async {
        do {
            let note = try await daemonClient.createNote(worktreeID: worktreeID)
            notes[worktreeID, default: []].append(note)
            let tab = Tab(id: note.id, content: .note(noteID: note.id), label: note.title)
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to create note: \(error)")
            handleConnectionError(error)
        }
    }

    /// Update a note's title and/or content.
    func updateNote(noteID: UUID, worktreeID: UUID, title: String? = nil, content: String? = nil) async {
        do {
            let updated = try await daemonClient.updateNote(noteID: noteID, title: title, content: content)
            if let idx = notes[worktreeID]?.firstIndex(where: { $0.id == noteID }) {
                notes[worktreeID]?[idx] = updated
            }
            // Update tab label if title changed
            if let newTitle = title {
                if let tabIdx = tabs[worktreeID]?.firstIndex(where: { $0.id == noteID }) {
                    tabs[worktreeID]?[tabIdx].label = newTitle
                }
            }
        } catch {
            logger.error("Failed to update note: \(error)")
            handleConnectionError(error)
        }
    }

    /// Delete a note.
    func deleteNote(noteID: UUID, worktreeID: UUID) async {
        do {
            try await daemonClient.deleteNote(noteID: noteID)
            notes[worktreeID]?.removeAll { $0.id == noteID }
        } catch {
            logger.error("Failed to delete note: \(error)")
            handleConnectionError(error)
        }
    }

    /// Fork a Claude terminal by resuming from an existing session ID.
    func forkClaudeTerminal(worktreeID: UUID, sessionID: String) async {
        do {
            let terminal = try await daemonClient.createTerminal(
                worktreeID: worktreeID,
                resumeSessionID: sessionID
            )
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id))
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to fork Claude terminal: \(error)")
            handleConnectionError(error)
        }
    }

    /// Create a Claude terminal in a worktree and add a new tab for it.
    func createClaudeTerminal(worktreeID: UUID) async {
        do {
            let terminal = try await daemonClient.createTerminal(
                worktreeID: worktreeID,
                cmd: nil,
                type: .claude
            )
            terminals[worktreeID, default: []].append(terminal)
            let tab = Tab(id: terminal.id, content: .terminal(terminalID: terminal.id))
            tabs[worktreeID, default: []].append(tab)
        } catch {
            logger.error("Failed to create Claude terminal: \(error)")
            handleConnectionError(error)
        }
    }
}
