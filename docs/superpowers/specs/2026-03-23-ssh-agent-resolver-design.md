# SSH Agent Resolver

## Problem

TBD's daemon inherits `SSH_AUTH_SOCK` from its launch environment. When the macOS WindowServer crashes or the system restarts, launchd creates a new SSH agent at a new socket path. The daemon (which may survive the crash) retains the old, stale path. This breaks git commit signing in all TBD-managed terminals — happening several times per week.

Normal terminals work because they're launched fresh by the window server with the current launchd environment. TBD's tmux sessions don't get this refresh.

## Solution

A stable symlink (`~/.ssh/tbd-agent.sock`) that always points to the live SSH agent socket. TBD sets `SSH_AUTH_SOCK` to this symlink path in all tmux sessions. A background task keeps the symlink target current.

This fixes existing sessions instantly — processes resolve the symlink at use time, not at shell startup.

## Components

### `SSHAgentResolver` (new, in `TBDDaemonLib`)

A `Sendable` struct with two public methods:

```swift
public struct SSHAgentResolver: Sendable {
    /// The stable symlink path: ~/.ssh/tbd-agent.sock
    public static let symlinkPath: String

    /// Ensure the symlink points to a live SSH agent socket.
    /// Returns true if a live agent was found and the symlink was updated.
    public func resolve() async -> Bool

    /// Check if the current symlink target is reachable.
    public func isValid() -> Bool
}
```

**Probing logic in `resolve()`:**

1. Fast path: if the current symlink target responds to `ssh-add -l` (exit 0 or 1), return true — no work needed.
2. Slow path: glob `/private/tmp/com.apple.launchd.*/Listeners`, test each socket with `ssh-add -l`. Exit code 0 or 1 means live agent (exit 2 = no agent on that socket).
3. Update the symlink atomically: write to a temp path, then `rename()` over the target.
4. Return false if no live agent found among any socket.

**Process execution:** Uses `Process` with `/usr/bin/ssh-add` and arguments `["-l"]`, setting the `SSH_AUTH_SOCK` environment variable per probe. Timeout each probe at 2 seconds to avoid hanging on unresponsive sockets.

### Integration: `TmuxManager.ensureServer`

After creating a new tmux server, set the SSH agent socket in the tmux global environment:

```swift
try? await runTmux(["-L", server, "setenv", "-g", "SSH_AUTH_SOCK", SSHAgentResolver.symlinkPath])
```

This goes alongside the existing `set -g status off` and `set -g mouse on` calls.

### Integration: Daemon startup

In the daemon's startup sequence, call `resolver.resolve()` once to create/update the symlink before any tmux sessions are created.

### Integration: Periodic refresh

A background `Task` in the daemon that runs every 60 seconds:

1. Call `resolver.isValid()` (cheap — just tests the current symlink target)
2. If invalid, call `resolver.resolve()` (probes all sockets)
3. If resolved, update all active tmux servers: `tmux -L <server> setenv -g SSH_AUTH_SOCK <symlinkPath>`

The periodic task is cancellable and tied to the daemon's lifecycle.

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
- **Symlink already exists from previous run:** Overwritten atomically via `rename()`.
- **`~/.ssh/` doesn't exist:** Create it with mode 0700 before creating the symlink.

## Testing

- Unit test `SSHAgentResolver` with a mock socket (create a Unix domain socket in a temp dir, test probing logic).
- Unit test the fast path (valid symlink) vs slow path (stale symlink triggers re-probe).
- Integration: verify `tmux setenv` is called with the correct path after `ensureServer`.

## Files to create/modify

| File | Action |
|------|--------|
| `Sources/TBDDaemon/SSH/SSHAgentResolver.swift` | Create |
| `Sources/TBDDaemon/Tmux/TmuxManager.swift` | Modify — add `setenv` call in `ensureServer` |
| `Sources/TBDDaemon/main.swift` | Modify — call `resolve()` at startup |
| `Sources/TBDDaemon/Server/DaemonServer.swift` (or equivalent lifecycle owner) | Modify — add periodic refresh task |
| `Tests/TBDDaemonTests/SSHAgentResolverTests.swift` | Create |
