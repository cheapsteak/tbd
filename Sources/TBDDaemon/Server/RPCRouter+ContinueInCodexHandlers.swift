import Foundation
import os
import TBDShared

private let continueInCodexLogger = Logger(
    subsystem: "com.tbd.daemon", category: "continue-in-codex")

private enum ContinueInCodexHandlerError: LocalizedError {
    case userFacing(String)

    var errorDescription: String? {
        switch self {
        case .userFacing(let message): return message
        }
    }
}

extension RPCRouter {
    func handleTerminalContinueInCodex(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(
            TerminalContinueInCodexParams.self, from: paramsData)

        // Complete every source and launch preflight before the app-server
        // import. Import is the first operation that can create Codex state.
        guard let source = try await db.terminals.get(id: params.terminalID) else {
            throw ContinueInCodexHandlerError.userFacing(
                "Source terminal not found: \(params.terminalID)")
        }
        let isLegacyClaude = source.kind == nil
            && source.claudeSessionID != nil
            && !source.isCodexTerminal
        guard source.kind == .claude || isLegacyClaude else {
            throw ContinueInCodexHandlerError.userFacing(
                "Continue in Codex requires a Claude terminal.")
        }
        guard let transcriptPath = source.transcriptPath,
              !transcriptPath.isEmpty else {
            throw ContinueInCodexHandlerError.userFacing(
                "The selected Claude terminal has no transcript path yet.")
        }
        guard (transcriptPath as NSString).isAbsolutePath else {
            throw ContinueInCodexHandlerError.userFacing(
                "The selected Claude terminal has an invalid transcript path.")
        }
        var transcriptIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
                atPath: transcriptPath,
                isDirectory: &transcriptIsDirectory),
              !transcriptIsDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: transcriptPath) else {
            throw ContinueInCodexHandlerError.userFacing(
                "The selected Claude transcript is missing or unreadable: \(transcriptPath)")
        }
        guard let worktree = try await db.worktrees.getLocal(id: source.worktreeID) else {
            throw ContinueInCodexHandlerError.userFacing(
                "Worktree not found for source terminal \(source.id).")
        }
        guard worktree.status == .active || worktree.status == .main else {
            throw ContinueInCodexHandlerError.userFacing(
                "Worktree is not active: \(worktree.displayName). Revive or finish creating it before continuing the session.")
        }
        var worktreeIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
                atPath: worktree.path,
                isDirectory: &worktreeIsDirectory),
              worktreeIsDirectory.boolValue else {
            throw ContinueInCodexHandlerError.userFacing(
                "Worktree directory is missing on disk: \(worktree.path)")
        }

        let preparation = try CodexLaunchPreparation.prepare(
            executableResolver: codexExecutableResolver,
            homeEnsurer: codexHomeEnsurer)
        let profileFlag = codexProfileFlagResolver(preparation.executablePath)

        let threadID = try await codexSessionImport(
            preparation.executablePath,
            preparation.codexHome,
            transcriptPath,
            worktree.path,
            nil)
        guard !threadID.isEmpty else {
            throw ContinueInCodexHandlerError.userFacing(
                "Codex imported the session but returned an empty thread ID.")
        }

        let repo: Repo?
        if let repoID = worktree.repoID {
            repo = try await db.repos.get(id: repoID)
        } else {
            repo = nil
        }
        let config = try? await db.config.get()
        let plannedTerminalID = UUID()
        let codexEnv: [String: String] = [
            "TBD_WORKTREE_ID": worktree.id.uuidString,
            "TBD_TERMINAL_ID": plannedTerminalID.uuidString,
            "CODEX_HOME": preparation.codexHome.path,
        ]
        let sensitiveEnv = EnvOverrideResolver.merge(
            global: config?.envOverrides,
            repo: repo?.envOverrides,
            profile: nil
        ).merging(["DISABLE_AUTO_UPDATE": "true"]) { _, forced in forced }
        let command = CodexSpawnCommandBuilder.build(
            initialPrompt: nil,
            resumeThreadID: threadID,
            executablePath: preparation.executablePath,
            profileFlag: profileFlag)

        // The import above created Codex state but touched no session; the
        // tmux calls below are the actuation, so the row goes here.
        let actuationID = try await beginActuation(
            .terminalContinueInCodex, actor: actor,
            target: .local(worktree: worktree.id, terminal: plannedTerminalID),
            agent: TerminalKind.codex.rawValue)

        let terminal: Terminal
        do {
            terminal = try await tmux.withWorktreeServerLock(
                db: db, worktreeID: worktree.id, allowedStatuses: [worktree.status]
            ) { currentWorktree in
                _ = try await tmux.ensureServer(
                    server: currentWorktree.tmuxServer,
                    session: "main",
                    cwd: currentWorktree.path,
                    cols: TmuxManager.defaultCols,
                    rows: TmuxManager.defaultRows)
                await self.controlMode?.enableIfGated(
                    serverName: currentWorktree.tmuxServer)
                let window = try await tmux.createWindow(
                    server: currentWorktree.tmuxServer,
                    session: "main",
                    cwd: currentWorktree.path,
                    shellCommand: command,
                    env: codexEnv,
                    sensitiveEnv: sensitiveEnv,
                    cols: TmuxManager.defaultCols,
                    rows: TmuxManager.defaultRows)
                do {
                    return try await db.terminals.create(
                        id: plannedTerminalID,
                        worktreeID: currentWorktree.id,
                        tmuxWindowID: window.windowID,
                        tmuxPaneID: window.paneID,
                        label: TerminalLabel.codex,
                        kind: .codex)
                } catch {
                    try? await tmux.killWindow(
                        server: currentWorktree.tmuxServer,
                        windowID: window.windowID)
                    throw error
                }
            }
        } catch {
            await finishActuation(actuationID, .transportFailed, error: "\(error)")
            throw error
        }

        subscriptions.broadcast(delta: .terminalCreated(TerminalDelta(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            label: terminal.label)))
        continueInCodexLogger.info(
            "Continued Claude terminal \(source.id, privacy: .public) in Codex terminal \(terminal.id, privacy: .public)")
        await finishActuation(actuationID, .dispatched)
        return try RPCResponse(result: TerminalContinueInCodexResult(
            terminalID: terminal.id,
            threadID: threadID))
    }
}
