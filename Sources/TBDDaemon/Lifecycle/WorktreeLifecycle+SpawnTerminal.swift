import Foundation
import TBDShared

/// Which transport one spawn is born onto.
///
/// Decided once, from the flag and the registry, and then **carried** through
/// the routing decision, the spawn and the row rather than re-derived at any of
/// them: the model proxy asks "is this a holder spawn?" before the command is
/// composed, and the spawn itself answers it after, so two readings of the flag
/// could disagree between the two and leave a session on a route its row does
/// not record.
///
/// The `.holder` case carries the registry that will run the spawn, so a caller
/// holding `.holder` provably holds something that can spawn — there is no
/// state in which the transport says holder and the registry is nil.
enum TerminalSpawnTransport: Sendable {
    case tmux
    case holder(HolderRegistry)

    /// **The transport gate, for every path that creates a session row.**
    ///
    /// Off is today's behavior, exactly; on puts the new session on a holder.
    /// The decision is made at spawn time and the row keeps it for life:
    /// flipping the flag must never migrate a running session, because the
    /// transport is a property of a live pty that already exists, not of a
    /// preference (spec, "Rollout" → "Granularity: spawn time only").
    ///
    /// Both halves of "can this spawn put a session on a holder" are asked
    /// here, and they are different questions. Mock mode has no registry at
    /// all; a daemon whose `TBDHolder` binary is missing has one that cannot
    /// spawn — it is still built, because adoption reaches an already-running
    /// holder through its socket and must keep working across an upgrade that
    /// moved the binary. Gating on the registry's mere presence would take the
    /// holder path with nothing able to start a holder, and the
    /// `holderExecutableUnavailable` that `spawn` then throws has nothing
    /// catching it: the whole create would fail. Either way the fallback is
    /// tmux, because a session that will not open is a worse answer than one
    /// that opens on the old transport.
    ///
    /// `config` is optional because the RPC handlers read it with `try?`: a
    /// config that could not be read is a config in which nobody chose the
    /// holder, and the fallback is the same tmux.
    static func decide(config: Config?, registry: HolderRegistry?) -> TerminalSpawnTransport {
        guard let config, config.ptyHolderEnabled,
              let registry, registry.canSpawn else { return .tmux }
        return .holder(registry)
    }

    /// The `isHolderSpawn` the model proxy's routing decision takes.
    var isHolder: Bool {
        if case .holder = self { return true }
        return false
    }
}

extension WorktreeLifecycle {
    /// **The one place a terminal is spawned and its row written, on either
    /// transport.**
    ///
    /// Every spawn path — the primary terminal at worktree creation, the setup
    /// and pre-session hook tabs, restored archived sessions, the extra
    /// terminals `terminal.create` opens, `terminal.continueInCodex`,
    /// revive-from-history tabs and fork-session tabs — decides *what* to run on
    /// its own (the command, the two environments, the label and kind) and
    /// hands the result here, because the part that
    /// diverges by transport is the same at all of them and subtle enough that
    /// a second copy is a second thing to get wrong: the holder launch
    /// composition, the row that records the transport and the pids, the stamp
    /// `ProcessIdentityCheck` later compares, the stream path that has to land
    /// in the same insert, and the two undo paths for a route nothing will
    /// ever be started against.
    ///
    /// The tmux server is the caller's to ensure, and only on the tmux
    /// transport: a holder-backed session needs no server at all, and ensuring
    /// one anyway would resurrect the very resource the transport exists to
    /// remove. The primary path memoizes that ensure because it opens several
    /// tabs and any of them may be the first to need one; the RPC handlers make
    /// it once, under the same lock they call this from.
    ///
    /// - Parameters:
    ///   - env: inlined as `export K='v';` in front of the command on both
    ///     transports, so it lands after every startup file has run — where
    ///     code reading `TBD_TERMINAL_ID` from a session expects it.
    ///   - sensitiveEnv: the spawned *process* environment — tmux's `-e`, or
    ///     the holder job's environment directly. The route's base URL rides
    ///     here and never in `env`.
    ///   - attachment: what the model proxy did with this spawn, or nil for a
    ///     spawn that never asked it — a shell or a Codex terminal. There is
    ///     deliberately no empty `Outcome` to pass instead; see
    ///     `ModelProxyRouteAttachment.Outcome`.
    ///   - modelProxySupervisor: the caller's own supervisor, passed rather than
    ///     read from `self` because the router and the lifecycle are wired
    ///     independently — `WorktreeLifecycle` is a value type, and a test
    ///     fixture sets the router's supervisor and registry alone — so the
    ///     caller's is the authoritative one. The registry travels inside
    ///     `transport` for the same reason.
    func spawnTerminal(
        id: UUID,
        worktreeID: UUID,
        tmuxServer: String,
        workingDirectory: String,
        command: String,
        env: [String: String],
        sensitiveEnv: [String: String],
        cols: Int,
        rows: Int,
        label: String?,
        claudeSessionID: String?,
        profileID: UUID?,
        kind: TerminalKind?,
        watchDeskRole: WatchDeskRole? = nil,
        transport: TerminalSpawnTransport,
        attachment: ModelProxyRouteAttachment.Outcome?,
        modelProxySupervisor: (any ModelProxyRouting)?
    ) async throws -> Terminal {
        // The two transports diverge for exactly this one spawn, and converge
        // again on the row below.
        let coordinate: (windowID: String, paneID: String)
        let holderHandle: HolderHandle?
        switch transport {
        case .holder(let registry):
            // The route, if there is one, was minted by the caller — before the
            // command was composed, because the command re-exports the
            // profile's own routing keys and would otherwise run over it. What
            // is left here is the spawn itself, and the two undo paths for a
            // route nothing will ever be started against.
            do {
                holderHandle = try await registry.spawn(
                    terminalID: id,
                    launch: Self.holderLaunch(
                        shellCommand: command,
                        env: env,
                        // The route's base URL rides `sensitiveEnv` — the job's
                        // process environment — and never `env`, which
                        // `holderLaunch` inlines as `export K='v';` in front of
                        // the command. The token IS in this job's argv all the
                        // same, because `command` carries an inline
                        // `export ANTHROPIC_BASE_URL=…` of its own, from
                        // `Outcome.builderBaseURL` — the export has to run after
                        // the shell's rc files or a `.zshrc` takes the session
                        // off its route. See that method for why `ps`
                        // visibility is not a widening of the trust boundary.
                        sensitiveEnv: sensitiveEnv,
                        workingDirectory: workingDirectory,
                        cols: cols,
                        rows: rows,
                        environment: registry.environment))
            } catch {
                // Nothing was spawned against this route and nothing ever will
                // be, so retire it from the failing call itself rather than
                // leaving a file for the sweep. By the token this attachment
                // minted, never by terminal id: this row has no other route
                // today, and a lookup would still be the wrong instruction to
                // leave behind.
                await ModelProxyRouteAttachment.retire(
                    attachment, terminalID: id, supervisor: modelProxySupervisor)
                throw error
            }
            // A holder session has no tmux coordinate. The columns are NOT NULL
            // from the v1 schema, so they take the empty string — and nothing
            // may read them back: a holder row is discriminated by `transport`
            // alone. See `WorktreeLifecycle+Reconcile`'s exemption.
            coordinate = (windowID: "", paneID: "")
        case .tmux:
            holderHandle = nil
            coordinate = try await tmux.createWindow(
                server: tmuxServer,
                session: "main",
                cwd: workingDirectory,
                shellCommand: command,
                env: env,
                sensitiveEnv: sensitiveEnv,
                cols: cols,
                rows: rows
            )
        }
        do {
            return try await db.terminals.create(
                id: id,
                worktreeID: worktreeID,
                tmuxWindowID: coordinate.windowID,
                tmuxPaneID: coordinate.paneID,
                label: label,
                claudeSessionID: claudeSessionID,
                profileID: profileID,
                kind: kind,
                watchDeskRole: watchDeskRole,
                transport: holderHandle == nil ? .tmux : .holder,
                holderPID: holderHandle?.holderPID,
                childPID: holderHandle?.childPID,
                // The identity anchor for the job just spawned. `createdAt`
                // would say the same thing today and stop being true the first
                // time this row is parked and woken, so it is recorded from the
                // start rather than only on the wake path. Off this type's
                // injected date seam, not a bare `Date()`: the stamp is
                // persisted and later compared against a process start time by
                // `ProcessIdentityCheck`, which is exactly the kind of fact a
                // test has to be able to pin end to end.
                holderChildStartedAt: holderHandle == nil ? nil : now(),
                // Stamped IN the insert, not by a follow-up `UPDATE`:
                // `TerminalReplacementSnapshot` compares this column, so a row
                // that exists without it for even one suspension can be
                // snapshotted by a concurrent caller, and a late stamp would
                // make every replacement that snapshot authorized reject.
                transcriptStreamPath: attachment?.streamPath
            )
        } catch {
            // Best-effort creation-time cleanup on both transports: a resource
            // that exists with no row naming it is one nothing will ever find
            // again. On the holder path that means `forget` (the holder closes
            // the pty master and winds down) and then killing the job by pid,
            // because holder death is deliberately not child death.
            if case .holder(let registry) = transport, let holderHandle {
                await registry.abandon(terminalID: id, handle: holderHandle)
                await ModelProxyRouteAttachment.retire(
                    attachment, terminalID: id, supervisor: modelProxySupervisor)
            } else {
                try? await tmux.killWindow(server: tmuxServer, windowID: coordinate.windowID)
            }
            throw error
        }
    }
}
