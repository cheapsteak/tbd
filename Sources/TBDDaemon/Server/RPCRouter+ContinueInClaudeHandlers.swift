import Foundation
import os
import TBDShared

private let continueInClaudeLogger = Logger(
    subsystem: "com.tbd.daemon", category: "continue-in-claude")

private struct CodexRolloutFingerprint: Sendable, Equatable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modifiedAt: Date

    static func read(path: String) throws -> Self {
        guard (path as NSString).isAbsolutePath else {
            throw ContinueInClaudeError(
                "The Codex rollout path is not absolute.")
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let attributes = try FileManager.default.attributesOfItem(atPath: standardized)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: standardized),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modifiedAt = attributes[.modificationDate] as? Date else {
            throw ContinueInClaudeError(
                "The Codex rollout is missing, unreadable, or not a regular file: \(standardized)")
        }
        return Self(
            path: standardized,
            device: device,
            inode: inode,
            size: size,
            modifiedAt: modifiedAt)
    }
}

private struct ContinueInClaudeError: LocalizedError, Sendable {
    let message: String
    let code: RPCErrorCode?

    init(_ message: String, code: RPCErrorCode? = nil) {
        self.message = message
        self.code = code
    }

    var errorDescription: String? { message }
}

private struct PreparedContinueInClaude: Sendable {
    let source: Terminal
    let sourceSnapshot: TerminalContinueInClaudeSnapshot
    let rolloutFingerprint: CodexRolloutFingerprint
    let worktree: LocalWorktree
    let profileID: UUID?
    let freshClaudeSessionID: String
    let claudeCommand: String
    let claudeEnv: [String: String]
    let claudeSensitiveEnv: [String: String]
    let codexCommand: String
    let codexEnv: [String: String]
    let codexSensitiveEnv: [String: String]
    let cols: Int
    let rows: Int
}

extension RPCRouter {
    func handleTerminalContinueInClaude(
        _ paramsData: Data, actor: ActuationActor? = nil
    ) async throws -> RPCResponse {
        let params = try decoder.decode(
            TerminalContinueInClaudeParams.self, from: paramsData)

        let prepared: PreparedContinueInClaude
        do {
            prepared = try await prepareContinueInClaude(params)
        } catch let error as ContinueInClaudeError {
            return RPCResponse(error: error.message, code: error.code?.rawValue)
        } catch {
            return RPCResponse(error: "Could not prepare Continue in Claude: \(error.localizedDescription)")
        }

        let actuationID = try await beginActuation(
            .terminalContinueInClaude,
            actor: actor,
            target: .local(
                worktree: prepared.source.worktreeID,
                terminal: prepared.source.id),
            agent: TerminalKind.claude.rawValue,
            profile: prepared.profileID?.uuidString)

        let response: RPCResponse
        do {
            response = try await tmux.withWorktreeServerLock(
                db: db,
                worktreeID: prepared.worktree.id,
                allowedStatuses: [prepared.worktree.status]
            ) { currentWorktree in
                try await self.performContinueInClaude(
                    prepared, currentWorktree: currentWorktree)
            }
        } catch let error as ContinueInClaudeError {
            response = RPCResponse(error: error.message, code: error.code?.rawValue)
        } catch {
            response = RPCResponse(error: "Continue in Claude failed: \(error.localizedDescription)")
        }

        if response.success {
            await finishActuation(actuationID, .dispatched)
        } else {
            await finishActuation(
                actuationID, .transportFailed,
                error: response.error ?? "Continue in Claude failed")
        }
        return response
    }

    private func prepareContinueInClaude(
        _ params: TerminalContinueInClaudeParams
    ) async throws -> PreparedContinueInClaude {
        guard let source = try await db.terminals.get(id: params.sourceTerminalID) else {
            throw ContinueInClaudeError(
                "Terminal not found: \(params.sourceTerminalID)")
        }
        guard source.kind == .codex else {
            throw ContinueInClaudeError(
                "Continue in Claude requires a Codex terminal.",
                code: .terminalWrongProvider)
        }
        guard source.transport == .tmux else {
            throw ContinueInClaudeError(
                "Terminal \(source.id) runs on the pty-holder transport, which has no tmux window to replace. Its Codex session is unchanged.")
        }
        guard !source.isParked else {
            throw ContinueInClaudeError(
                "Continue in Claude requires an awake Codex terminal.",
                code: .terminalSessionGone)
        }
        guard source.pendingSessionIncarnationID == nil else {
            throw ContinueInClaudeError(
                "Terminal \(source.id) already has a provider replacement pending.",
                code: .terminalBusy)
        }
        guard let activity = source.observedActivity,
              activity.value == .idle,
              source.activityStateOrderObservedAt != nil else {
            throw ContinueInClaudeError(
                "Wait for the current Codex turn to finish before continuing in Claude.",
                code: .terminalBusy)
        }
        guard let sourceThreadID = source.claudeSessionID,
              !sourceThreadID.isEmpty else {
            throw ContinueInClaudeError(
                "The Codex terminal has not reported a source thread ID yet.")
        }
        guard let rolloutPath = source.transcriptPath,
              !rolloutPath.isEmpty else {
            throw ContinueInClaudeError(
                "The Codex terminal has not reported a rollout path yet.")
        }
        let rolloutFingerprint = try CodexRolloutFingerprint.read(path: rolloutPath)

        guard let worktree = try await db.worktrees.getLocal(id: source.worktreeID) else {
            throw ContinueInClaudeError(
                "Worktree not found for terminal \(source.id).")
        }
        guard worktree.status == .active || worktree.status == .main else {
            throw ContinueInClaudeError(
                "Worktree is not active: \(worktree.displayName).")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
                atPath: worktree.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ContinueInClaudeError(
                "Worktree directory is missing on disk: \(worktree.path)")
        }

        let resolvedProfile: ResolvedModelProfile?
        if let profileID = params.profileID {
            do {
                resolvedProfile = try await modelProfileResolver.loadByID(profileID)
            } catch {
                throw ContinueInClaudeError(
                    "Failed to load the selected Claude profile.",
                    code: .profileMissing)
            }
            guard resolvedProfile != nil else {
                throw ContinueInClaudeError(
                    "The selected Claude profile is missing or unreadable.",
                    code: .profileMissing)
            }
        } else {
            resolvedProfile = nil
        }

        // Build and bound the deterministic packet before any process or row
        // changes. Its git-status subprocess and rollout parser are preparation
        // failures, so Codex stays untouched when either refuses.
        let packet = try await CodexContinuationPacketBuilder().build(
            rolloutPath: rolloutFingerprint.path,
            worktreePath: worktree.path)

        let codexPreparation = try CodexLaunchPreparation.prepare(
            executableResolver: codexExecutableResolver,
            homeEnsurer: codexHomeEnsurer)
        let profileFlag = codexProfileFlagResolver(codexPreparation.executablePath)

        let repo: Repo? = if let repoID = worktree.repoID {
            try await db.repos.get(id: repoID)
        } else {
            nil
        }
        let config = try? await db.config.get()
        let freshClaudeSessionID = UUID().uuidString
        let profileConfigDir = configDirManager.resolveConfigDir(for: resolvedProfile)
        await ClaudeTrustSeeder.ensureTrusted(
            worktree: worktree.worktree,
            autoTrustNonScratch: config?.autoTrustWorktrees ?? true,
            profileConfigDir: profileConfigDir)

        var claudeEnv = SystemPromptBuilder.promptLayers(
            repo: repo,
            worktree: worktree.worktree,
            scratchInstructions: config?.scratchInstructions,
            scratchRenamePrompt: config?.scratchRenamePrompt)
        claudeEnv["TBD_WORKTREE_ID"] = worktree.id.uuidString
        claudeEnv["TBD_TERMINAL_ID"] = source.id.uuidString

        let appendPrompt = SystemPromptBuilder.build(
            repo: repo,
            worktree: worktree.worktree,
            isResume: false,
            scratchInstructions: config?.scratchInstructions,
            scratchRenamePrompt: config?.scratchRenamePrompt)
        let claudeSpawn = ClaudeSpawnCommandBuilder.build(
            resumeID: nil,
            freshSessionID: freshClaudeSessionID,
            appendSystemPrompt: appendPrompt,
            initialPrompt: packet,
            profileSecret: resolvedProfile?.secret,
            profileKind: resolvedProfile?.kind,
            profileBaseURL: resolvedProfile?.baseURL,
            profileModel: resolvedProfile?.model,
            profileAwsRegion: resolvedProfile?.awsRegion,
            profileAwsProfile: resolvedProfile?.awsProfile,
            profileConfigDir: profileConfigDir,
            cmd: nil,
            shellFallback: "",
            settingsOverlayPath: ClaudeHookOverlay.resolveOverlayPath(
                fallbackModels: resolvedProfile?.fallbackModels,
                sessionKey: source.id.uuidString,
                repoSettingsJSON: ClaudeHookOverlay.repoSettingsFragment(repoID: repo?.id),
                watchDeskRole: source.watchDeskRole,
                worktreePath: worktree.path,
                profileConfigDir: profileConfigDir),
            pluginDirPath: PluginDirWriter.pluginDirPath,
            envSettingOverrides: config?.envSettingOverrides ?? [:],
            sessionName: worktree.displayName)
        let claudeSensitiveEnv = EnvOverrideResolver.merge(
            global: config?.envOverrides,
            repo: repo?.envOverrides,
            profile: resolvedProfile?.envOverrides
        ).merging(claudeSpawn.sensitiveEnv) { _, builder in builder }

        let codexEnv = [
            "TBD_WORKTREE_ID": worktree.id.uuidString,
            "TBD_TERMINAL_ID": source.id.uuidString,
            "CODEX_HOME": codexPreparation.codexHome.path,
        ]
        let codexSensitiveEnv = EnvOverrideResolver.merge(
            global: config?.envOverrides,
            repo: repo?.envOverrides,
            profile: nil
        ).merging(["DISABLE_AUTO_UPDATE": "true"]) { _, forced in forced }
        let codexCommand = CodexSpawnCommandBuilder.build(
            initialPrompt: nil,
            resumeThreadID: sourceThreadID,
            executablePath: codexPreparation.executablePath,
            profileFlag: profileFlag)

        return PreparedContinueInClaude(
            source: source,
            sourceSnapshot: TerminalContinueInClaudeSnapshot(terminal: source),
            rolloutFingerprint: rolloutFingerprint,
            worktree: worktree,
            profileID: resolvedProfile?.profileID,
            freshClaudeSessionID: freshClaudeSessionID,
            claudeCommand: claudeSpawn.command,
            claudeEnv: claudeEnv,
            claudeSensitiveEnv: claudeSensitiveEnv,
            codexCommand: codexCommand,
            codexEnv: codexEnv,
            codexSensitiveEnv: codexSensitiveEnv,
            cols: params.cols ?? TmuxManager.defaultCols,
            rows: params.rows ?? TmuxManager.defaultRows)
    }

    private func performContinueInClaude(
        _ prepared: PreparedContinueInClaude,
        currentWorktree: LocalWorktree
    ) async throws -> RPCResponse {
        guard let current = try await db.terminals.get(id: prepared.source.id),
              prepared.sourceSnapshot.matches(current),
              current.kind == .codex,
              !current.isParked,
              current.observedActivity?.value == .idle,
              try CodexRolloutFingerprint.read(
                path: prepared.rolloutFingerprint.path) == prepared.rolloutFingerprint else {
            throw ContinueInClaudeError(
                "The Codex terminal changed while Continue in Claude was being prepared.",
                code: .terminalBusy)
        }

        let destinationToken = UUID()
        guard let staged = try await db.terminals.beginContinueInClaude(
            id: current.id,
            expectedState: prepared.sourceSnapshot,
            pendingIncarnationID: destinationToken) else {
            throw ContinueInClaudeError(
                "The Codex terminal changed before replacement could begin.",
                code: .terminalBusy)
        }
        let destinationKey = ContinueInClaudeReadinessCoordinator.Key(
            terminalID: current.id, incarnationID: destinationToken)
        await continueInClaudeReadiness.arm(destinationKey)

        // This is the last read and the ownership fence immediately before the
        // first destructive act. Continue requires positive agreement for all
        // three facts: pane, window, and terminal stamp. An unstamped pane is
        // not enough authority to kill its process.
        let probe = try await tmux.paneSendProbe(
            server: currentWorktree.tmuxServer,
            paneID: staged.tmuxPaneID)
        guard case .live(let claimedTerminalID) = probe.target,
              let claimedTerminalID,
              claimedTerminalID.caseInsensitiveCompare(staged.id.uuidString) == .orderedSame,
              probe.windowID == staged.tmuxWindowID else {
            await continueInClaudeReadiness.clear(destinationKey)
            _ = try await db.terminals.abortContinueInClaudeBeforeLaunch(
                id: staged.id,
                pendingIncarnationID: destinationToken)
            throw ContinueInClaudeError(
                "The recorded Codex pane no longer belongs to terminal \(staged.id); nothing was replaced.",
                code: .terminalSessionGone)
        }

        let destinationEnv = AgentProcessEnvironment.replacement(
            base: prepared.claudeEnv,
            incarnationID: destinationToken)
        var destinationFailure: Error?
        do {
            // No graceful interrupt: this single tmux operation kills Codex
            // before it starts Claude, so the two captains never coexist.
            try await tmux.respawnWindow(
                server: currentWorktree.tmuxServer,
                windowID: staged.tmuxWindowID,
                cwd: currentWorktree.path,
                shellCommand: prepared.claudeCommand,
                env: destinationEnv,
                sensitiveEnv: prepared.claudeSensitiveEnv,
                cols: prepared.cols,
                rows: prepared.rows)
            let ready = try await continueInClaudeReadiness.wait(
                for: destinationKey,
                timeout: continueInClaudeReadinessTimeout)
            guard ready.sessionID == prepared.freshClaudeSessionID,
                  let transcriptPath = ready.transcriptPath,
                  !transcriptPath.isEmpty,
                  (transcriptPath as NSString).isAbsolutePath else {
                throw ContinueInClaudeError(
                    "Claude reported malformed replacement readiness.")
            }
            guard let updated = try await db.terminals.finalizeContinueInClaude(
                id: staged.id,
                expectedPendingIncarnationID: destinationToken,
                profileID: prepared.profileID,
                sessionID: ready.sessionID,
                transcriptPath: transcriptPath,
                observedAt: ready.observedAt) else {
                throw ContinueInClaudeError(
                    "Claude became ready but the terminal replacement could not be finalized.")
            }
            await continueInClaudeReadiness.clear(destinationKey)
            subscriptions.broadcast(delta: .terminalReplaced(updated))
            continueInClaudeLogger.info(
                "Replaced Codex with Claude in terminal \(updated.id, privacy: .public)")
            return try RPCResponse(result: updated)
        } catch {
            destinationFailure = error
        }

        await continueInClaudeReadiness.clear(destinationKey)
        let reason = destinationFailure?.localizedDescription
            ?? "the Claude destination did not become ready"
        do {
            let restored = try await restoreCodexAfterFailedContinue(
                prepared: prepared,
                currentWorktree: currentWorktree,
                failedPendingToken: destinationToken)
            subscriptions.broadcast(delta: .terminalReplaced(restored))
            throw ContinueInClaudeError(
                "Continue in Claude failed after replacement began, and Codex was restored: \(reason)")
        } catch let rollbackError as ContinueInClaudeError
            where rollbackError.message.hasPrefix("Continue in Claude failed after") {
            throw rollbackError
        } catch {
            // The row remains Codex with a pending token. Startup and hourly
            // reconciliation will retry source recovery; it never claims the
            // failed Claude destination as committed identity.
            throw ContinueInClaudeError(
                "Continue in Claude failed, and Codex recovery is pending: \(reason). Recovery error: \(error.localizedDescription)")
        }
    }

    private func restoreCodexAfterFailedContinue(
        prepared: PreparedContinueInClaude,
        currentWorktree: LocalWorktree,
        failedPendingToken: UUID
    ) async throws -> Terminal {
        let recoveryToken = UUID()
        guard let recoveryRow = try await db.terminals.rotateContinueInClaudeToCodexRecovery(
            id: prepared.source.id,
            expectedPendingIncarnationID: failedPendingToken,
            recoveryIncarnationID: recoveryToken) else {
            throw ContinueInClaudeError(
                "Could not rotate the failed destination to a Codex recovery token.")
        }
        return try await launchAndFinalizeCodexRecovery(
            row: recoveryRow,
            worktree: currentWorktree,
            recoveryToken: recoveryToken,
            command: prepared.codexCommand,
            env: prepared.codexEnv,
            sensitiveEnv: prepared.codexSensitiveEnv,
            sourceThreadID: prepared.source.claudeSessionID ?? "",
            sourceRolloutPath: prepared.rolloutFingerprint.path,
            cols: prepared.cols,
            rows: prepared.rows)
    }

    /// Retry every durable nonparked Codex+pending row. Called once after the
    /// socket begins accepting SessionStart hooks and on orphan maintenance.
    func reconcilePendingContinueInClaude() async {
        guard let candidates = try? await db.terminals.listPendingCodexContinuations()
        else { return }
        for candidate in candidates {
            do {
                try await reconcilePendingContinueInClaude(candidate)
            } catch {
                continueInClaudeLogger.warning(
                    "Pending Codex recovery for terminal \(candidate.id, privacy: .public) remains pending: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func reconcilePendingContinueInClaude(_ candidate: Terminal) async throws {
        guard let oldPendingToken = candidate.pendingSessionIncarnationID,
              let sourceThreadID = candidate.claudeSessionID,
              !sourceThreadID.isEmpty,
              let sourceRolloutPath = candidate.transcriptPath,
              !sourceRolloutPath.isEmpty else {
            throw ContinueInClaudeError("Pending Codex recovery has no source identity.")
        }
        _ = try CodexRolloutFingerprint.read(path: sourceRolloutPath)
        let codexPreparation = try CodexLaunchPreparation.prepare(
            executableResolver: codexExecutableResolver,
            homeEnsurer: codexHomeEnsurer)
        let command = CodexSpawnCommandBuilder.build(
            initialPrompt: nil,
            resumeThreadID: sourceThreadID,
            executablePath: codexPreparation.executablePath,
            profileFlag: codexProfileFlagResolver(codexPreparation.executablePath))

        guard let initialWorktree = try await db.worktrees.getLocal(
            id: candidate.worktreeID) else {
            throw ContinueInClaudeError("Pending Codex recovery worktree is missing.")
        }
        let repo: Repo? = if let repoID = initialWorktree.repoID {
            try await db.repos.get(id: repoID)
        } else {
            nil
        }
        let config = try? await db.config.get()
        let env = [
            "TBD_WORKTREE_ID": initialWorktree.id.uuidString,
            "TBD_TERMINAL_ID": candidate.id.uuidString,
            "CODEX_HOME": codexPreparation.codexHome.path,
        ]
        let sensitiveEnv = EnvOverrideResolver.merge(
            global: config?.envOverrides,
            repo: repo?.envOverrides,
            profile: nil
        ).merging(["DISABLE_AUTO_UPDATE": "true"]) { _, forced in forced }

        try await tmux.withWorktreeServerLock(
            db: db,
            worktreeID: candidate.worktreeID,
            allowedStatuses: [.active, .main]
        ) { worktree in
            guard let current = try await self.db.terminals.get(id: candidate.id),
                  current.kind == .codex,
                  !current.isParked,
                  current.pendingSessionIncarnationID == oldPendingToken else { return }
            let recoveryToken = UUID()
            guard let recoveryRow = try await self.db.terminals
                .rotateContinueInClaudeToCodexRecovery(
                    id: current.id,
                    expectedPendingIncarnationID: oldPendingToken,
                    recoveryIncarnationID: recoveryToken) else { return }
            let restored = try await self.launchAndFinalizeCodexRecovery(
                row: recoveryRow,
                worktree: worktree,
                recoveryToken: recoveryToken,
                command: command,
                env: env,
                sensitiveEnv: sensitiveEnv,
                sourceThreadID: sourceThreadID,
                sourceRolloutPath: sourceRolloutPath,
                cols: TmuxManager.defaultCols,
                rows: TmuxManager.defaultRows)
            self.subscriptions.broadcast(delta: .terminalReplaced(restored))
        }
    }

    private func launchAndFinalizeCodexRecovery(
        row: Terminal,
        worktree: LocalWorktree,
        recoveryToken: UUID,
        command: String,
        env: [String: String],
        sensitiveEnv: [String: String],
        sourceThreadID: String,
        sourceRolloutPath: String,
        cols: Int,
        rows: Int
    ) async throws -> Terminal {
        let key = ContinueInClaudeReadinessCoordinator.Key(
            terminalID: row.id, incarnationID: recoveryToken)
        await continueInClaudeReadiness.arm(key)
        defer { Task { await self.continueInClaudeReadiness.clear(key) } }

        var target = row
        let probe = try await tmux.paneSendProbe(
            server: worktree.tmuxServer,
            paneID: row.tmuxPaneID)
        let ownsRecordedWindow: Bool = {
            guard case .live(let claimedTerminalID) = probe.target,
                  let claimedTerminalID else { return false }
            return claimedTerminalID.caseInsensitiveCompare(row.id.uuidString) == .orderedSame
                && probe.windowID == row.tmuxWindowID
        }()

        if !ownsRecordedWindow {
            let staleWindowID = row.tmuxWindowID
            let mayKillStale: Bool = switch probe.target {
            case .missing, .dead: true
            case .live: false
            }
            let bootstrapWindowID = try await tmux.ensureServer(
                server: worktree.tmuxServer,
                session: "main",
                cwd: worktree.path,
                cols: cols,
                rows: rows)
            await controlMode?.enableIfGated(serverName: worktree.tmuxServer)
            let window = try await tmux.createWindow(
                server: worktree.tmuxServer,
                session: "main",
                cwd: worktree.path,
                shellCommand: "exec /usr/bin/tail -f /dev/null",
                env: env,
                cols: cols,
                rows: rows)
            guard let moved = try await db.terminals.movePendingCodexRecovery(
                id: row.id,
                expectedPendingIncarnationID: recoveryToken,
                windowID: window.windowID,
                paneID: window.paneID) else {
                try? await tmux.killWindow(
                    server: worktree.tmuxServer, windowID: window.windowID)
                throw ContinueInClaudeError(
                    "Codex recovery lost its database ownership fence.")
            }
            target = moved

            // A restarted tmux server can reuse either stale coordinate for
            // the fresh replacement. These inequalities are load-bearing: do
            // not kill the new window merely because its textual id matches.
            if mayKillStale, staleWindowID != window.windowID {
                try? await tmux.killWindow(
                    server: worktree.tmuxServer, windowID: staleWindowID)
            }
            if let bootstrapWindowID,
               !bootstrapWindowID.isEmpty,
               bootstrapWindowID != window.windowID {
                try? await tmux.killWindow(
                    server: worktree.tmuxServer, windowID: bootstrapWindowID)
            }
        }

        let recoveryEnv = AgentProcessEnvironment.replacement(
            base: env, incarnationID: recoveryToken)
        try await tmux.respawnWindow(
            server: worktree.tmuxServer,
            windowID: target.tmuxWindowID,
            cwd: worktree.path,
            shellCommand: command,
            env: recoveryEnv,
            sensitiveEnv: sensitiveEnv,
            cols: cols,
            rows: rows)
        let ready = try await continueInClaudeReadiness.wait(
            for: key, timeout: continueInClaudeReadinessTimeout)
        guard ready.sessionID == sourceThreadID else {
            throw ContinueInClaudeError(
                "The Codex recovery reported a different source thread.")
        }
        guard let restored = try await db.terminals.finalizePendingCodexRecovery(
            id: row.id,
            expectedPendingIncarnationID: recoveryToken,
            sourceThreadID: sourceThreadID,
            sourceRolloutPath: sourceRolloutPath,
            observedAt: ready.observedAt) else {
            throw ContinueInClaudeError(
                "Codex became ready but recovery could not be finalized.")
        }
        return restored
    }
}
