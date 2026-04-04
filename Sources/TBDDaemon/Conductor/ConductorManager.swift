import Foundation
import os
import TBDShared

public final class ConductorManager: Sendable {
    let db: TBDDatabase
    let tmux: TmuxManager
    private let _suggestions = OSAllocatedUnfairLock(initialState: [String: ConductorSuggestion]())

    public init(db: TBDDatabase, tmux: TmuxManager) {
        self.db = db
        self.tmux = tmux
    }

    // MARK: - Suggestions

    public func suggest(name: String, worktreeID: UUID, worktreeName: String, label: String?) async throws {
        guard let _ = try await db.conductors.get(name: name) else {
            throw ConductorError.notFound(name: name)
        }
        let suggestion = ConductorSuggestion(worktreeID: worktreeID, worktreeName: worktreeName, label: label)
        _suggestions.withLock { $0[name] = suggestion }
    }

    public func clearSuggestion(name: String) async throws {
        guard let _ = try await db.conductors.get(name: name) else {
            throw ConductorError.notFound(name: name)
        }
        _suggestions.withLock { $0.removeValue(forKey: name) }
    }

    public func suggestion(for name: String) -> ConductorSuggestion? {
        _suggestions.withLock { $0[name] }
    }

    // MARK: - Setup

    nonisolated(unsafe) static let nameRegex = try! Regex(#"^[a-zA-Z0-9][a-zA-Z0-9_-]*$"#)

    public func setup(
        name: String,
        repos: [String] = ["*"],
        worktrees: [String]? = nil,
        terminalLabels: [String]? = nil,
        heartbeatIntervalMinutes: Int = 10
    ) async throws -> Conductor {
        // Validate name: alphanumeric start, then alphanumeric/underscore/hyphen, max 64 chars
        guard !name.isEmpty, name.count <= 64, (try? Self.nameRegex.wholeMatch(in: name)) != nil else {
            throw ConductorError.invalidName(name)
        }

        // Create config directory + synthetic worktree — clean up directory if worktree creation fails
        let conductorDir = TBDConstants.conductorsDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: conductorDir, withIntermediateDirectories: true)

        let syntheticWorktree: Worktree
        do {
            syntheticWorktree = try await db.worktrees.create(
                repoID: TBDConstants.conductorsRepoID,
                name: "conductor-\(name)",
                branch: "conductor",
                path: conductorDir.path,
                tmuxServer: TBDConstants.conductorsTmuxServer,
                status: .conductor
            )
        } catch {
            try? FileManager.default.removeItem(at: conductorDir)
            throw error
        }

        // Create conductor DB row — if this fails (e.g. duplicate name), clean up
        let conductor: Conductor
        do {
            var c = try await db.conductors.create(
                name: name,
                repos: repos,
                worktrees: worktrees,
                terminalLabels: terminalLabels,
                heartbeatIntervalMinutes: heartbeatIntervalMinutes
            )
            c.worktreeID = syntheticWorktree.id
            try await db.conductors.updateWorktreeID(conductorID: c.id, worktreeID: syntheticWorktree.id)
            conductor = c
        } catch {
            // Rollback: remove synthetic worktree and directory
            try? await db.worktrees.delete(id: syntheticWorktree.id)
            try? FileManager.default.removeItem(at: conductorDir)
            throw error
        }

        // Write CLAUDE.md template — rollback on failure
        do {
            let template = Self.generateTemplate(name: name, repos: repos)
            let claudePath = conductorDir.appendingPathComponent("CLAUDE.md")
            try template.write(to: claudePath, atomically: true, encoding: .utf8)
        } catch {
            try? await db.conductors.delete(id: conductor.id)
            if let wid = conductor.worktreeID { try? await db.worktrees.delete(id: wid) }
            try? FileManager.default.removeItem(at: conductorDir)
            throw error
        }

        return conductor
    }

    // MARK: - Start

    public func start(name: String) async throws -> Terminal {
        guard let conductor = try await db.conductors.get(name: name) else {
            throw ConductorError.notFound(name: name)
        }
        guard let worktreeID = conductor.worktreeID else {
            throw ConductorError.noWorktree(name: name)
        }

        // Guard against double-start: if terminalID is set, check if it's actually alive
        if let existingTerminalID = conductor.terminalID,
           let existingTerminal = try await db.terminals.get(id: existingTerminalID) {
            let alive = await tmux.windowExists(
                server: TBDConstants.conductorsTmuxServer,
                windowID: existingTerminal.tmuxWindowID
            )
            if alive {
                throw ConductorError.alreadyRunning(name: name)
            }
            // Window is dead — clean up stale terminal record
            try await db.terminals.delete(id: existingTerminalID)
            try await db.conductors.updateTerminalID(conductorID: conductor.id, terminalID: nil)
        }

        let conductorDir = TBDConstants.conductorsDir.appendingPathComponent(name)
        let shellCommand = "claude --dangerously-skip-permissions"

        try await tmux.ensureServer(
            server: TBDConstants.conductorsTmuxServer,
            session: "main",
            cwd: conductorDir.path
        )

        let window = try await tmux.createWindow(
            server: TBDConstants.conductorsTmuxServer,
            session: "main",
            cwd: conductorDir.path,
            shellCommand: shellCommand
        )

        let terminal = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: window.windowID,
            tmuxPaneID: window.paneID,
            label: "conductor:\(name)"
        )

        try await db.conductors.updateTerminalID(conductorID: conductor.id, terminalID: terminal.id)

        return terminal
    }

    // MARK: - Stop

    public func stop(name: String) async throws {
        guard let conductor = try await db.conductors.get(name: name) else {
            throw ConductorError.notFound(name: name)
        }

        if let terminalID = conductor.terminalID,
           let terminal = try await db.terminals.get(id: terminalID) {
            try? await tmux.killWindow(
                server: TBDConstants.conductorsTmuxServer,
                windowID: terminal.tmuxWindowID
            )
            try await db.terminals.delete(id: terminalID)
        }

        try await db.conductors.updateTerminalID(conductorID: conductor.id, terminalID: nil)
    }

    // MARK: - Teardown

    public func teardown(name: String) async throws {
        // Stop first (kills window + deletes terminal)
        try await stop(name: name)

        guard let conductor = try await db.conductors.get(name: name) else {
            throw ConductorError.notFound(name: name)
        }

        // Delete synthetic worktree
        if let worktreeID = conductor.worktreeID {
            try await db.worktrees.delete(id: worktreeID)
        }

        // Delete conductor DB row
        try await db.conductors.delete(id: conductor.id)

        // Remove directory
        let conductorDir = TBDConstants.conductorsDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: conductorDir)
    }

    // MARK: - Template

    public static func generateTemplate(
        name: String,
        repos: [String],
        worktrees: [String]? = nil,
        terminalLabels: [String]? = nil
    ) -> String {
        let repoDisplay = repos.contains("*") ? "All repos" : repos.joined(separator: ", ")
        let worktreeDisplay = worktrees?.joined(separator: ", ") ?? "All worktrees"
        let labelDisplay = terminalLabels?.joined(separator: ", ") ?? "All terminals"

        return """
        # Conductor: \(name)

        You are a conductor — a persistent Claude Code session that monitors and
        orchestrates other Claude terminals managed by TBD.

        ## Your Scope
        - Repos: \(repoDisplay)
        - Worktrees: \(worktreeDisplay)
        - Terminal labels: \(labelDisplay)

        ## Startup Checklist

        Run this when you first start, after a restart, or after context compaction:
        1. Read `./state.json` if it exists (restore context from previous session)
        2. Run `tbd worktree list --json` to see active worktrees
        3. Run `tbd terminal list --json` to discover terminal IDs
        4. Run `tbd conductor status \(name) --json` to verify your scope
        5. Log startup in `./task-log.md`
        6. Output: "Conductor \(name) online. N terminals found across M worktrees."

        ## How You Work (Manual Polling)

        You must actively poll terminals to check on them:

        1. Run `tbd worktree list --json` to get worktree names/IDs
        2. For each worktree, run `tbd terminal list <worktree-name> --json` to get terminal IDs
        3. For each terminal of interest, run `tbd terminal output <id> --lines 50`
        4. Review the output — is the agent waiting for input?
        5. If waiting: decide to auto-respond or escalate
        6. If running: leave it alone

        ## Core Rules

        1. **Never send to running terminals.** Only respond to terminals that are
           waiting for input (look for the ❯ prompt with no "esc to interrupt" indicator).
        2. **When unsure, escalate.** The cost of a false escalation (user gets a notification)
           is much lower than a wrong auto-response (agent goes off track).
        3. **Log everything.** Every action goes in `./task-log.md`.
        4. **Keep responses SHORT.** Status updates: 1-3 sentences. Use bullet points.
        5. **Don't poll in a loop.** Check when asked or when relevant. If no terminals are
           active, say so and wait.

        ## CLI Commands

        | Command | Description |
        |---------|-------------|
        | `tbd worktree list --json` | List all worktrees with IDs |
        | `tbd terminal list <worktree> --json` | List terminals in a worktree |
        | `tbd terminal output <id> --lines 50` | Read last 50 lines of terminal output |
        | `tbd terminal send --terminal <id> --text "message"` | Send message to a terminal |
        | `tbd conductor list --json` | List all conductors |
        | `tbd conductor status \(name) --json` | Your own scope and config |
        | `tbd notify --type attention_needed "message"` | Escalate to user via macOS notification |
        | `tbd conductor suggest \(name) --worktree <id> [--label "text"]` | Show navigation pill in UI |
        | `tbd conductor clear-suggestion \(name)` | Clear navigation pill |

        Terminal IDs are UUIDs. Use the full ID from `tbd terminal list` output.

        ## Navigation Suggestions

        When discussing a specific worktree, help the user navigate to it:

        | Command | Description |
        |---------|-------------|
        | `tbd conductor suggest \(name) --worktree <id>` | Show a "Go to" pill in the UI |
        | `tbd conductor suggest \(name) --worktree <id> --label "waiting for input"` | With context label |
        | `tbd conductor clear-suggestion \(name)` | Remove the pill |

        Set a suggestion when surfacing info about a worktree. Clear it when moving on
        to a different topic or when the user has acknowledged it.

        ## Terminal States

        When reading terminal output, look for these indicators:
        - **Waiting for input:** ❯ prompt visible, status bar shows "⏵⏵" or "? for shortcuts"
        - **Running/busy:** Status bar shows "esc to interrupt" or "to stop agents"
        - **Idle (no Claude):** Shell prompt (zsh/bash), no Claude process running
        - **Unknown:** Can't determine — terminal may be dead. Escalate if persistent.

        ## Auto-Response Guidelines

        ### Safe to Auto-Respond
        - "Should I proceed?" / "Should I continue?" → Yes, if the plan looks reasonable
        - "Tests passed. What's next?" → Direct to the next logical step
        - Compilation/lint errors with obvious fixes → Suggest the fix
        - Questions about project conventions → Answer from context

        ### Always Escalate
        - Destructive actions (delete, force-push, drop table)
        - Security issues
        - Design decisions with multiple valid approaches
        - Requests for credentials or API keys
        - "I'm stuck and don't know how to proceed"
        - Anything you're unsure about

        ## Handling Send Rejections

        If `tbd terminal send` returns an error, the terminal may have transitioned
        since you last checked. Do NOT retry immediately. Re-read the terminal output
        to see its current state, then decide what to do.

        ## Escalation

        When escalating, notify the user:
        ```
        tbd notify --type attention_needed "worktree-name: brief description"
        ```

        ## State Management

        Maintain `./state.json` for context across context compactions:
        ```json
        {
          "terminals": {},
          "last_checked": null,
          "auto_responses_today": 0,
          "escalations_today": 0
        }
        ```

        Read state.json at the start of each interaction. Update it after taking action.

        ## Task Log

        Append every action to `./task-log.md` with timestamps.
        """
    }
}

public enum ConductorError: Error, LocalizedError {
    case invalidName(String)
    case notFound(name: String)
    case noWorktree(name: String)
    case alreadyRunning(name: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            "Invalid conductor name '\(name)': must start with alphanumeric, contain only [a-zA-Z0-9_-], max 64 chars"
        case .notFound(let name): "Conductor not found: \(name)"
        case .alreadyRunning(let name): "Conductor '\(name)' is already running. Stop it first with `tbd conductor stop \(name)`"
        case .noWorktree(let name): "Conductor has no worktree: \(name)"
        }
    }
}
