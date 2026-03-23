# SSH Agent Resolver

## Problem

TBD's daemon inherits `SSH_AUTH_SOCK` from its launch environment. When the macOS WindowServer crashes or the system restarts, launchd creates a new SSH agent at a new socket path. The daemon (which may survive the crash) retains the old, stale path. This breaks git commit signing in all TBD-managed terminals — happening several times per week.

Normal terminals work because they're launched fresh by the window server with the current launchd environment. TBD's tmux sessions don't get this refresh.

## Solution

A stable symlink (`~/.ssh/tbd-agent.sock`) that always points to the live SSH agent socket. TBD sets `SSH_AUTH_SOCK` to this symlink path in all tmux sessions. A background task keeps the symlink target current.

### How "fixes existing sessions" works

The symlink is the indirection that makes this work. Once a shell was started with `SSH_AUTH_SOCK=~/.ssh/tbd-agent.sock`, every subsequent `git commit` (or any SSH operation) resolves the symlink at connect time. When the symlink target is updated, the next git command in that shell follows the new target — no shell restart needed.

Limitation: shells that were started *before* this feature is deployed still have the old literal socket path in their env, not the symlink. Those shells won't benefit until they're restarted. This is a one-time migration cost.

## Components

### `SSHAgentResolver` (new, under `Sources/TBDDaemon/SSH/`)

A `Sendable` struct with two public methods:

```swift
public struct SSHAgentResolver: Sendable {
    /// The stable symlink path: ~/.ssh/tbd-agent.sock
    public static let symlinkPath: String

    /// Ensure the symlink points to a live SSH agent socket.
    /// Returns true if a live agent was found and the symlink was updated.
    public func resolve() async -> Bool

    /// Check if the current symlink target is reachable.
    /// Uses raw socket connect(2), not ssh-add — fast and cheap.
    public func isValid() -> Bool
}
```

**Probing logic in `resolve()`:**

1. Fast path: if the current symlink target is reachable via `connect(2)` on the Unix domain socket, return true — no work needed.
2. Slow path: glob `/private/tmp/com.apple.launchd.*/Listeners`. Filter for Unix domain sockets via `stat(2)` / `S_ISSOCK`. Cap at 10 candidates (sorted newest first by mtime) to bound probe time. Test each with `ssh-add -l`. Exit code 0 or 1 means live SSH agent (exit 2 = agent protocol not spoken on that socket). Stop at the first match.
3. Update the symlink atomically: `symlink()` to a temp path in `~/.ssh/`, then `Darwin.rename()` over the target (not `FileManager.moveItem`, which may resolve symlinks). Both paths are on the same volume, so `rename(2)` is atomic.
4. Return false if no live agent found among any socket.

**`isValid()` implementation:** Attempt `connect(2)` on the symlink path using a `AF_UNIX` socket. If it connects, the agent is alive. This avoids spawning a process and completes in microseconds.

**Process timeout for probing:** `Foundation.Process` has no built-in timeout. Wrap each probe in a `Task` that races against `Task.sleep(for: .seconds(2))`. If the sleep wins, call `process.terminate()` and skip that socket.

**Symlink directory:** If `~/.ssh/` doesn't exist, create it with mode 0700. If `~/.ssh/tbd-agent.sock` exists as a regular file or directory (not a symlink), remove it before creating the symlink.

### Integration: `TmuxManager.ensureServer`

After creating a new tmux server, set the SSH agent socket in the tmux global environment:

```swift
try? await runTmux(["-L", server, "setenv", "-g", "SSH_AUTH_SOCK", SSHAgentResolver.symlinkPath])
```

This goes alongside the existing `set -g status off` and `set -g mouse on` calls. New panes/windows created in this tmux server will inherit this env var.

### Integration: Daemon startup

In the daemon's startup sequence, call `resolver.resolve()` once to create/update the symlink before any tmux sessions are created. Also update the daemon's own process environment via `setenv("SSH_AUTH_SOCK", symlinkPath, 1)` so that any `Process` calls within the daemon (e.g., `GitManager` git operations) also use the stable symlink.

### Integration: Periodic refresh

A background `Task` in the daemon that runs every 60 seconds:

1. Call `resolver.isValid()` (cheap — raw socket connect, no process spawn)
2. If invalid, call `resolver.resolve()` (probes all sockets, ~100ms)
3. After resolving, the symlink is updated on disk. No need to re-run `tmux setenv` since the env already points to the stable symlink path — the symlink indirection handles it.

The periodic task is cancellable and tied to the daemon's lifecycle.

### Logging

Use `os.Logger` (subsystem `com.tbd.daemon`, category `SSHAgent`). Log:
- Symlink created/updated: old target → new target
- Resolve failure: no live agent found (list candidates checked)
- Periodic refresh recovery: symlink was stale, updated to new target
- Probe timeouts: which socket path timed out

## Data flow

```
launchd creates SSH agent at /private/tmp/com.apple.launchd.XXX/Listeners
                    │
    SSHAgentResolver probes and finds it
                    │
                    ▼
    ~/.ssh/tbd-agent.sock ──symlink──▶ /private/tmp/com.apple.launchd.XXX/Listeners
                    │
    tmux global env: SSH_AUTH_SOCK=~/.ssh/tbd-agent.sock
                    │
                    ▼
    shell in tmux pane reads SSH_AUTH_SOCK
                    │
                    ▼
    git commit --gpg-sign follows symlink to live agent ✓
```

## Edge cases

- **No live agent found:** `resolve()` returns false, symlink is left as-is (or not created). Git signing fails as it does today — no worse than current behavior.
- **Multiple live agents:** Take the first one that responds. In practice, only one launchd socket is the SSH agent.
- **Daemon restart:** Symlink persists on disk. On next startup, fast path likely succeeds immediately.
- **Symlink already exists from previous run:** Overwritten atomically via `rename(2)`.
- **`~/.ssh/` doesn't exist:** Create it with mode 0700 before creating the symlink.
- **`~/.ssh/tbd-agent.sock` is a regular file/directory:** Remove it before creating the symlink.
- **Pre-existing sessions (migration):** Shells started before this feature was deployed have the old literal socket path. They won't benefit from the symlink until restarted. This is expected — a one-time cost.

## Testing

- Unit test `SSHAgentResolver` probing with a mock Unix domain socket in a temp dir.
- Unit test the fast path (valid symlink → `isValid()` returns true) vs slow path (stale symlink → triggers re-probe).
- Unit test atomic symlink update (verify old symlink is replaced).
- Test timeout behavior: mock a socket that accepts connections but never responds.

## Files to create/modify

| File | Action |
|------|--------|
| `Sources/TBDDaemon/SSH/SSHAgentResolver.swift` | Create |
| `Sources/TBDDaemon/Tmux/TmuxManager.swift` | Modify — add `setenv` call in `ensureServer` |
| `Sources/TBDDaemon/main.swift` | Modify — call `resolve()` at startup, `setenv` in-process |
| `Sources/TBDDaemon/Daemon.swift` | Modify — add periodic refresh task |
| `Tests/TBDDaemonTests/SSHAgentResolverTests.swift` | Create |
