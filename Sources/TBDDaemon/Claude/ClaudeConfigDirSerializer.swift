import Foundation

/// Serializes work that reads and rewrites one Claude config directory's
/// `.claude.json`, so a completions probe can never overlap a folder-trust seed
/// on the same file.
///
/// **Four writers, and the contract is every writer of
/// `<configDir>/.claude.json` — not merely the two this lane was introduced
/// for.** A lane that half the writers ignore orders nothing.
///
/// - `ClaudeTrustSeeder` does a read-merge-write to pre-accept the folder-trust
///   dialog.
/// - The completions probe starts Claude Code itself, which — measured on
///   2.1.261 — writes first-run metadata and a backup into a fresh config
///   directory, and rewrote an existing project entry (keeping the trust key,
///   dropping an onboarding key).
/// - `ClaudeProfileConfigDirManager.ensureAPIKeyDir` read-merge-writes the
///   file to add an API-key approval, preserving unknown top-level keys.
/// - `ClaudeProfileConfigDirManager.ensureOAuthDir` writes a minimal file when
///   one does not already exist — a check and a write that must be one
///   critical section, or a probe creating the file in between turns the check
///   into an overwrite.
///
/// Two last-writer-wins rewrites of one file can lose the trust key, and a
/// worktree whose trust key is gone stalls on a dialog no TBD mechanism can see
/// or dismiss.
///
/// **The two `ensure*Dir` writers take the lane around their `.claude.json`
/// section only.** Creating the directory and ensuring the host mirror symlinks
/// touch a different set of paths, so they stay outside; and neither lane body
/// anywhere calls `resolveConfigDir`, which is what keeps this non-reentrant
/// lane from deadlocking against itself.
///
/// **A chained-`Task` lane rather than an actor method, and that distinction is
/// load-bearing.** `ClaudeTrustSeeder.TrustSeedWriter.seed` is atomic because it
/// never suspends, so the actor's serial execution covers its whole
/// read-through-rename window. A probe *does* suspend — it spawns a process and
/// awaits it — so an actor would let a seed run inside it. This is the shape
/// `TerminalSendSerializer` already uses per terminal, keyed by config directory
/// instead.
///
/// Per directory, not global: two profiles are two files, and making every probe
/// queue behind an unrelated worktree's trust seed would buy nothing.
///
/// **What this does NOT cover**, exactly as the seeder's own doc comment says: an
/// ambient Claude Code process writing the same file. That is a different OS
/// process; in-process serialization cannot order against it, and no file lock is
/// taken.
actor ClaudeConfigDirSerializer {
    /// The daemon's one lane table. Both callers reach it through this, because
    /// two tables would serialize two disjoint sets and order neither against
    /// the other.
    static let shared = ClaudeConfigDirSerializer()

    private var lanes: [String: Task<Void, Never>] = [:]

    /// Run `body` once everything already queued for `configDir` has finished.
    /// Returns what `body` returned and rethrows what it threw.
    func run<T: Sendable>(
        configDir: String, _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let predecessor = lanes[configDir]
        let task = Task<T, Error> { [predecessor] in
            await predecessor?.value
            return try await body()
        }
        // The lane's tail erases both the value and the failure: a body that
        // threw still released the file, so its successor must run rather than
        // inherit its error. Awaiting `.result` never rethrows and never cancels.
        let tail = Task<Void, Never> { _ = await task.result }
        lanes[configDir] = tail
        Task { [weak self] in
            await tail.value
            await self?.removeIfTail(configDir: configDir, task: tail)
        }
        return try await task.value
    }

    private func removeIfTail(configDir: String, task: Task<Void, Never>) {
        if lanes[configDir] == task {
            lanes[configDir] = nil
        }
    }

    /// Test-only inspection: number of directories with a live lane.
    var trackedDirectoryCount: Int { lanes.count }
}
