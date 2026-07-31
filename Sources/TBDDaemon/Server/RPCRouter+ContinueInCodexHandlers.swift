import Foundation
import os
import TBDShared

private let continueInCodexLogger = Logger(
    subsystem: "com.tbd.daemon", category: "continue-in-codex")

extension RPCRouter {
    func handleTerminalContinueInCodex(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TerminalContinueInCodexParams.self, from: paramsData)
        let result = try await continueInCodexCoordinator.run(
            sourceTerminalID: params.sourceTerminalID,
            target: params.target
        ) { [self] in
            try await continueInCodex(params)
        }
        return try RPCResponse(result: result)
    }

    private func continueInCodex(
        _ params: TerminalContinueInCodexParams
    ) async throws -> TerminalContinueInCodexResult {
        guard params.target == .localCodex else {
            throw ContinueInCodexError.userFacing(
                "Unsupported takeover target '\(params.target.kind)'. This TBD build supports only local_codex.")
        }
        guard let source = try await db.terminals.get(id: params.sourceTerminalID) else {
            throw ContinueInCodexError.userFacing(
                "Source terminal not found: \(params.sourceTerminalID)")
        }
        let isLegacyClaude = source.kind == nil
            && source.claudeSessionID != nil
            && source.label != TerminalLabel.codex
        guard source.kind == .claude || isLegacyClaude else {
            throw ContinueInCodexError.userFacing(
                "Continue in Codex requires a Claude terminal; the selected terminal is \(source.kind?.rawValue ?? "not Claude").")
        }
        guard let sessionID = source.claudeSessionID, !sessionID.isEmpty else {
            throw ContinueInCodexError.userFacing(
                "The selected Claude terminal has no session transcript identity yet.")
        }
        guard let worktree = try await db.worktrees.get(id: source.worktreeID) else {
            throw ContinueInCodexError.userFacing(
                "Worktree not found for source terminal \(source.id).")
        }
        guard FileManager.default.fileExists(atPath: worktree.path) else {
            throw ContinueInCodexError.userFacing(
                "Worktree directory is missing on disk: \(worktree.path)")
        }

        let sourceHandoffDirectory = continueInCodexHandoffRoot?
            .appendingPathComponent(worktree.id.uuidString, isDirectory: true)
            .appendingPathComponent(source.id.uuidString, isDirectory: true)
            ?? TBDConstants.handoffDir(
                worktreeID: worktree.id, sourceTerminalID: source.id)
        let manifestURL = sourceHandoffDirectory.appendingPathComponent("target.json")
        if let existing = try await reusableCodexTarget(
            manifestURL: manifestURL,
            sourceHandoffDirectory: sourceHandoffDirectory,
            source: source,
            worktree: worktree,
            requestedTarget: params.target
        ) {
            return TerminalContinueInCodexResult(
                terminal: existing.terminal,
                handoffPath: existing.handoffPath,
                created: false,
                warnings: existing.warnings,
                capture: existing.capture,
                target: existing.target)
        }

        let sourceConfigDir: URL
        if let profileID = source.profileID {
            sourceConfigDir = configDirManager.configDirectory(forProfileID: profileID)
        } else {
            sourceConfigDir = configDirManager.ambientConfigDirectory
        }
        guard let transcriptURL = Self.resolveSwapSourceTranscript(
            transcriptPath: source.transcriptPath,
            sessionID: sessionID,
            worktreePath: worktree.path,
            sourceConfigDir: sourceConfigDir
        ) else {
            throw ContinueInCodexError.userFacing(
                "Claude transcript unavailable. TBD checked the terminal's stored transcript path and the profile-aware Claude projects directory for session \(sessionID).")
        }

        // Resolve before creating a tmux window or terminal row. An absolute
        // executable path survives the GUI daemon's minimal PATH and .zshrc.
        let codexPreparation = try CodexLaunchPreparation.prepare(
            executableResolver: codexExecutableResolver,
            homeEnsurer: codexHomeEnsurer)

        let repo: Repo?
        if let repoID = worktree.repoID {
            repo = try await db.repos.get(id: repoID)
        } else {
            repo = nil
        }
        async let status = git.statusPorcelain(worktreePath: worktree.path)
        async let commits = git.recentCommits(worktreePath: worktree.path, limit: 8)
        async let notes = handoffContext(worktree: worktree, repo: repo)
        let input = CodexHandoffInput(
            sourceTerminalID: source.id,
            sessionID: sessionID,
            transcriptURL: transcriptURL,
            worktree: worktree,
            repo: repo,
            gitStatus: (try? await status) ?? "(git status unavailable)",
            recentCommits: (try? await commits) ?? "(recent commits unavailable)",
            tbdContext: await notes)
        let handoff = try codexHandoffGenerator.generate(input)
        let handoffID = UUID()
        let handoffURL = sourceHandoffDirectory
            .appendingPathComponent(handoffID.uuidString, isDirectory: true)
            .appendingPathComponent("CODEX_HANDOFF.md", isDirectory: false)
        try CodexHandoffFiles.ensurePrivateDirectory(sourceHandoffDirectory)
        try CodexHandoffFiles.writePrivateImmutable(handoff.data, to: handoffURL)

        let plannedTerminalID = UUID()
        let warnings = Self.takeoverWarnings
        let manifest = ContinueInCodexManifest(
            sourceTerminalID: source.id,
            worktreeID: worktree.id,
            targetTerminalID: plannedTerminalID,
            handoffPath: handoffURL.path,
            warnings: warnings,
            capture: handoff.capture,
            target: params.target)
        // Persist the dedupe intent before tmux/DB mutation. A stale manifest
        // is harmless (reuse validates the mapped DB row), while writing it
        // after terminal creation could report failure despite a live target.
        try CodexHandoffFiles.writePrivate(
            try JSONEncoder().encode(manifest), to: manifestURL)
        let initialPrompt = """
        Read \(handoffURL.path) first. Read all applicable AGENTS.md and CLAUDE.md \
        files plus every skill or knowledge source they or the handoff reference. \
        Identify and honor task-claiming and closeout obligations, including \
        claim-work and closeout when present. Surface missing-reference warnings \
        and look for tracked repository equivalents; do not assume Claude-only \
        knowledge injectors have automatic Codex parity mappings. Then inspect \
        the current worktree at \(worktree.path), verify the handoff's assumptions \
        against current files and git state, and continue the work. Preserve \
        unrelated changes.
        """
        let command = CodexSpawnCommandBuilder.build(
            initialPrompt: initialPrompt,
            executablePath: codexPreparation.executablePath)
        let config = try? await db.config.get()
        let mergedOverrides = EnvOverrideResolver.merge(
            global: config?.envOverrides, repo: repo?.envOverrides, profile: nil)
            .merging(["DISABLE_AUTO_UPDATE": "true"]) { _, forced in forced }
        var env = [
            "TBD_WORKTREE_ID": worktree.id.uuidString,
            "TBD_TERMINAL_ID": plannedTerminalID.uuidString,
            "CODEX_HOME": codexPreparation.codexHome.path,
        ]
        if let color = params.colorFgBg {
            env["COLORFGBG"] = color
        }
        let cols = params.cols ?? TmuxManager.defaultCols
        let rows = params.rows ?? TmuxManager.defaultRows
        _ = try await tmux.ensureServer(
            server: worktree.tmuxServer, session: "main", cwd: worktree.path,
            cols: cols, rows: rows)
        await controlMode?.enableIfGated(serverName: worktree.tmuxServer)
        let window = try await tmux.createWindow(
            server: worktree.tmuxServer,
            session: "main",
            cwd: worktree.path,
            shellCommand: command,
            env: env,
            sensitiveEnv: mergedOverrides,
            cols: cols,
            rows: rows)
        let target: Terminal
        do {
            target = try await db.terminals.create(
                id: plannedTerminalID,
                worktreeID: worktree.id,
                tmuxWindowID: window.windowID,
                tmuxPaneID: window.paneID,
                label: TerminalLabel.codex,
                kind: .codex)
        } catch {
            try? await tmux.killWindow(
                server: worktree.tmuxServer, windowID: window.windowID)
            throw error
        }

        subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
            terminalID: target.id, worktreeID: target.worktreeID, label: target.label)))
        continueInCodexLogger.info(
            "Created Codex takeover terminal \(target.id, privacy: .public) from Claude terminal \(source.id, privacy: .public)")
        return TerminalContinueInCodexResult(
            terminal: target,
            handoffPath: handoffURL.path,
            created: true,
            warnings: warnings,
            capture: handoff.capture,
            target: params.target)
    }

    private func reusableCodexTarget(
        manifestURL: URL,
        sourceHandoffDirectory: URL,
        source: Terminal,
        worktree: Worktree,
        requestedTarget: TerminalContinueInCodexTarget
    ) async throws -> ReusableCodexTakeover? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }
        let manifest: ContinueInCodexManifest
        do {
            manifest = try JSONDecoder().decode(
                ContinueInCodexManifest.self,
                from: Data(contentsOf: manifestURL))
        } catch {
            throw ContinueInCodexError.userFacing(
                "The existing Continue in Codex mapping is unreadable. TBD left all terminals untouched; inspect \(manifestURL.path) before retrying.")
        }
        guard manifest.sourceTerminalID == source.id,
              manifest.worktreeID == worktree.id,
              (manifest.target ?? .localCodex) == requestedTarget else {
            throw ContinueInCodexError.userFacing(
                "The existing Continue in Codex mapping does not match this source, worktree, and target. TBD left all terminals untouched; inspect \(manifestURL.path) before retrying.")
        }
        guard let target = try await db.terminals.get(
            id: manifest.targetTerminalID
        ) else {
            // A manifest written before a failed tmux/DB spawn is a safe stale
            // intent. No terminal row exists to duplicate, so a retry may
            // replace the mapping with a new immutable handoff.
            return nil
        }
        guard target.worktreeID == worktree.id, target.isCodexTerminal else {
            throw ContinueInCodexError.userFacing(
                "The existing Continue in Codex mapping points to an unexpected terminal. TBD left all terminals untouched; inspect \(manifestURL.path) before retrying.")
        }
        guard await tmux.windowExists(
            server: worktree.tmuxServer, windowID: target.tmuxWindowID
        ) else {
            throw ContinueInCodexError.userFacing(
                "The existing Codex takeover terminal is no longer live. TBD did not create a duplicate; close or recreate terminal \(target.id) before retrying.")
        }
        let handoffPath = manifest.handoffPath
            ?? sourceHandoffDirectory
                .appendingPathComponent("CODEX_HANDOFF.md", isDirectory: false).path
        let sourceDirectoryPath =
            sourceHandoffDirectory.standardizedFileURL.path + "/"
        let handoffURL = URL(fileURLWithPath: handoffPath).standardizedFileURL
        guard handoffURL.path.hasPrefix(sourceDirectoryPath),
              handoffURL.lastPathComponent == "CODEX_HANDOFF.md" else {
            throw ContinueInCodexError.userFacing(
                "The existing Codex handoff path is outside its private source directory. TBD did not create a duplicate; inspect \(manifestURL.path) before retrying.")
        }
        guard FileManager.default.fileExists(atPath: handoffURL.path) else {
            throw ContinueInCodexError.userFacing(
                "The existing Codex takeover is live, but its handoff is missing. TBD did not create a duplicate; inspect \(manifestURL.path) before retrying.")
        }
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: handoffURL.path)
        let outputBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return ReusableCodexTakeover(
            terminal: target,
            handoffPath: handoffURL.path,
            warnings: manifest.warnings ?? Self.takeoverWarnings,
            capture: manifest.capture ?? TerminalContinueInCodexCaptureMetadata(
                transcriptBytesRead: 0,
                transcriptBytesRendered: 0,
                handoffBytesOutput: outputBytes,
                transcriptTailTruncated: false),
            target: manifest.target ?? .localCodex)
    }

    private static let takeoverWarnings = [
        TerminalContinueInCodexWarning(
            code: "readiness_pending",
            message: "Codex was launched, but prompt readiness is pending machine-readable SessionStart/activity hook acknowledgement."),
        TerminalContinueInCodexWarning(
            code: "bootstrap_partial_or_missing",
            message: "Repository Codex bootstrap may be partial or missing; inspect AGENTS.md, CLAUDE.md, skills, and hooks before continuing."),
        TerminalContinueInCodexWarning(
            code: "codex_skill_rewrite_broken",
            message: "Generated .Codex/skills references may be broken; verify actual .agents/skills or tracked .claude/skills equivalents."),
        TerminalContinueInCodexWarning(
            code: "skill_context_overload",
            message: "Large generated skill sets may be truncated by the Codex skill context budget."),
        TerminalContinueInCodexWarning(
            code: "bootstrap_untouched",
            message: "TBD did not stage, repair, reset, or clean repository bootstrap artifacts during takeover."),
    ]

    private func handoffContext(worktree: Worktree, repo: Repo?) async -> String {
        var sections: [String] = []
        if let instructions = repo?.customInstructions, !instructions.isEmpty {
            sections.append("### Repository instructions\n\n\(instructions)")
        }
        // Tests inject a private handoff root specifically to avoid consulting
        // the developer's live TBD_HOME. Production reads the normal
        // file-backed notepad in addition to database notes.
        if continueInCodexHandoffRoot == nil {
            let notesPath = repo.map { TBDConstants.notesPath(repoID: $0.id) }
                ?? TBDConstants.notesPath(worktreeID: worktree.id)
            if let sharedNotes = try? String(contentsOfFile: notesPath, encoding: .utf8),
               !sharedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append("### TBD notepad\n\n\(sharedNotes)")
            }
        }
        if let notes = try? await db.notes.list(worktreeID: worktree.id) {
            for note in notes where
                !note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append("### \(note.title)\n\n\(note.content)")
            }
        }
        return DeterministicCodexHandoffGenerator.utf8Prefix(
            sections.joined(separator: "\n\n"),
            maximumBytes: DeterministicCodexHandoffGenerator.maximumContextBytes)
    }
}

private struct ReusableCodexTakeover {
    let terminal: Terminal
    let handoffPath: String
    let warnings: [TerminalContinueInCodexWarning]
    let capture: TerminalContinueInCodexCaptureMetadata
    let target: TerminalContinueInCodexTarget
}

private enum ContinueInCodexError: Error, CustomStringConvertible {
    case userFacing(String)

    var description: String {
        switch self {
        case .userFacing(let message): return message
        }
    }
}
