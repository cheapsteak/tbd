import Foundation
import TBDShared

/// Why a new session cannot be opened: no pty holder can be started for it.
///
/// Every session TBD opens runs in a pty holder, so this is the only reason the
/// spawn gate ever refuses. It is phrased for the person who asked for the
/// session — it names the missing `TBDHolder` helper and how to put it back —
/// because each caller hands it on as its own error, an RPC reply or a
/// creation failure, rather than translating it.
struct TerminalSpawnRefusal: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    let message: String

    /// The refusal when this daemon cannot start a holder: it found no
    /// `TBDHolder` beside its own binary, or it was wired with no holder
    /// registry at all. Phrased from the same fact as
    /// `TerminalTransportMigrator.holderUnspawnableRefusal`.
    static let holderUnavailable = TerminalSpawnRefusal(message:
        "The TBDHolder helper is missing beside the daemon, so no pty holder can be started and no new session can open; nothing was changed. "
        + "Reinstall TBD (for example with `tbd update`) so TBDHolder sits next to TBDDaemon, then try again.")

    var description: String { message }
    var errorDescription: String? { message }
}

/// The transport one spawn is born onto: always a pty holder.
///
/// Decided once by `decide(registry:)` and then **carried** through the spawn,
/// so a caller holding one provably holds a registry that can spawn — there is
/// no state in which the gate said yes and nothing can start the holder.
struct TerminalSpawnTransport: Sendable {
    /// The registry that runs the spawn.
    let registry: HolderRegistry

    /// **The spawn gate, for every path that creates a session row.**
    ///
    /// Every new session opens on a pty holder. The gate answers the holder
    /// when there is a registry and it can spawn, and otherwise refuses with
    /// `TerminalSpawnRefusal.holderUnavailable`. There is no fallback: a
    /// session that cannot open says why, and the caller turns the refusal into
    /// an error at its own boundary before it has changed anything.
    ///
    /// The registry is asked two different questions here. A daemon wired with
    /// no registry has nothing to spawn with at all; a daemon whose `TBDHolder`
    /// binary is missing still builds one, because adoption reaches an
    /// already-running holder through its socket and must keep working across
    /// an upgrade that moved the binary, but that registry cannot spawn.
    static func decide(
        registry: HolderRegistry?
    ) -> Result<TerminalSpawnTransport, TerminalSpawnRefusal> {
        guard let registry, registry.canSpawn else {
            return .failure(.holderUnavailable)
        }
        return .success(TerminalSpawnTransport(registry: registry))
    }
}

extension WorktreeLifecycle {
    /// **The one place a terminal is spawned and its row written.**
    ///
    /// Every spawn path — the primary terminal at worktree creation, the setup
    /// and pre-session hook tabs, restored archived sessions, the extra
    /// terminals `terminal.create` opens, `terminal.continueInCodex`,
    /// revive-from-history tabs, fork-session tabs and dev-server tabs —
    /// decides *what* to run on its own (the command, the two environments,
    /// the label and kind) and hands the result here, because what follows is
    /// the same at all of them and subtle enough that a second copy is a second
    /// thing to get wrong: the holder launch composition, the row that records
    /// the transport and the pids, the stamp `ProcessIdentityCheck` later
    /// compares, and the cleanup for a spawn whose row could not be written.
    ///
    /// - Parameters:
    ///   - env: inlined as `export K='v';` in front of the command, so it lands
    ///     after every startup file has run — where code reading
    ///     `TBD_TERMINAL_ID` from a session expects it.
    ///   - sensitiveEnv: the holder job's process environment.
    ///   - transport: the gate's answer. The holder registry travels inside it
    ///     rather than being read from `self`, because the router and the
    ///     lifecycle are wired independently — `WorktreeLifecycle` is a value
    ///     type, and a test fixture sets the router's registry alone — so the
    ///     caller's is the authoritative one.
    ///   - serverName: the declared dev server this tab runs (`server.start`),
    ///     nil for every other spawn.
    ///   - sessionIncarnationID: the incarnation a Claude spawn made with a
    ///     session-mod feature on exports (`SessionModSpawnContext`), written
    ///     into the row so its process's hooks match it. Nil for every other
    ///     spawn — shells, Codex, dev servers, forks, and Claude with every
    ///     feature off.
    ///   - claudeSpawnExtras: a Claude terminal's own plugin folders and
    ///     settings overlay, written onto the new row so later starts of its
    ///     session can reapply them. Already applied to `command` by the
    ///     caller; nil stores nothing.
    ///   - codexLaunchOptions: the options a Codex spawn's command was built
    ///     with, nil for every other spawn and for a Codex spawn with none.
    ///     Written in the same insert, so every later relaunch of Codex in this
    ///     tab can reapply them.
    func spawnTerminal(
        id: UUID,
        worktreeID: UUID,
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
        transport: TerminalSpawnTransport,
        serverName: String? = nil,
        sessionIncarnationID: UUID? = nil,
        claudeSpawnExtras: ClaudeSpawnExtras? = nil,
        codexLaunchOptions: CodexLaunchOptions? = nil
    ) async throws -> Terminal {
        let registry = transport.registry
        let holderHandle = try await registry.spawn(
            terminalID: id,
            launch: Self.holderLaunch(
                shellCommand: command,
                env: env,
                sensitiveEnv: sensitiveEnv,
                workingDirectory: workingDirectory,
                cols: cols,
                rows: rows,
                environment: registry.environment))
        do {
            return try await db.terminals.create(
                id: id,
                worktreeID: worktreeID,
                // A holder session has no tmux coordinate. The columns are NOT
                // NULL from the v1 schema, so they take the empty string — and
                // nothing may read them back: a holder row is discriminated by
                // `transport` alone. See `WorktreeLifecycle+Reconcile`'s
                // exemption.
                tmuxWindowID: "",
                tmuxPaneID: "",
                label: label,
                claudeSessionID: claudeSessionID,
                profileID: profileID,
                kind: kind,
                transport: .holder,
                holderPID: holderHandle.holderPID,
                childPID: holderHandle.childPID,
                // The identity anchor for the job just spawned. `createdAt`
                // would say the same thing today and stop being true the first
                // time this row is parked and woken, so it is recorded from the
                // start rather than only on the wake path. Off this type's
                // injected date seam, not a bare `Date()`: the stamp is
                // persisted and later compared against a process start time by
                // `ProcessIdentityCheck`, which is exactly the kind of fact a
                // test has to be able to pin end to end.
                holderChildStartedAt: now(),
                serverName: serverName,
                sessionIncarnationID: sessionIncarnationID,
                claudeSpawnExtras: claudeSpawnExtras,
                codexLaunchOptions: codexLaunchOptions
            )
        } catch {
            // Best-effort creation-time cleanup: a holder that exists with no
            // row naming it is one nothing will ever find again. That means
            // `forget` (the holder closes the pty master and winds down) and
            // then killing the job by pid, because holder death is deliberately
            // not child death.
            await registry.abandon(terminalID: id, handle: holderHandle)
            throw error
        }
    }
}
