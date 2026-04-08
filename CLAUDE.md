# TBD

macOS native worktree + terminal manager for multi-agent Claude Code workflows.

Use the `tbd-project` skill for architecture, conventions, and file reference.

## Main Session Agent

The main chat session agent should not write code directly. Delegate all implementation work to suitable subagents (Agent tool). The main session focuses on planning, coordination, and reviewing subagent results.

## Workflow

- Only stage and commit files you actually changed — never commit unrelated or other agents' modifications.
- Always commit after completing work. Don't wait to be asked.
- Use conventional commit messages: `feat:`, `fix:`, `docs:`, `refactor:`
- Verify your changes compile (`swift build`) before committing.
- Run `swift test` if you changed daemon or shared code.
- When adding a branching conditional that gates behavior (feature flags, toggles, mode switches), add a test for each branch. Verify the gated behavior is off when the flag is off, and that ungated behavior still works.

### Restart must use the worktree's own script
Always run `scripts/restart.sh` (relative, from the worktree cwd), never an absolute path to the main project's copy. Using `/Users/chang/projects/tbd/scripts/restart.sh` builds and starts binaries from the main branch, leaving old worktree processes running and causing "Unknown method" RPC errors. After any restart, verify with:
```
ps aux | grep -E "\.build/debug/TBD" | grep -v grep
```
There should be exactly one `TBDDaemon` and one `TBDApp`, both from the worktree path. If stale processes exist: `pkill -f TBDDaemon; pkill -f TBDApp` then re-run `scripts/restart.sh`.

## Critical Rules

### NEVER delete ~/tbd/state.db
The database stores worktree display names, custom config, and notification history. Deleting it orphans tmux servers (repo UUID changes → tmux server name changes → old sessions become unreachable). If you encounter DB issues, diagnose and fix the schema/code — don't wipe the DB.

### Database migrations must update the shared model
When adding a DB column in `Sources/TBDDaemon/Database/Database.swift`:
1. Add the column with a `.defaults(to:)` value in the migration
2. Update the GRDB Record type in `Sources/TBDDaemon/Database/`
3. Update the Codable model in `Sources/TBDShared/Models.swift` — new fields MUST be optional or have a default value so existing JSON/rows still decode
4. All three changes in the same commit

Migrations use GRDB's `DatabaseMigrator`, numbered sequentially (`v1`, `v2`, `v3`...). Never modify an existing migration — always add a new one.

### Unbundled executable constraints
TBDApp runs as a bare SPM executable, not a `.app` bundle. APIs that require a bundle identifier will crash at runtime. Before using any Apple framework API, check whether it requires a bundle:
- `UNUserNotificationCenter.current()` — crashes without `CFBundleIdentifier`
- `NSApp.applicationIconImage` — must be set *after* `setActivationPolicy(.regular)`
- Any API that reads `Info.plist` keys — will return nil

Guard these with `Bundle.main.bundleIdentifier != nil` checks.

### NIO thread safety
All `ChannelHandlerContext` property access (`context.channel`, `context.pipeline`) must happen on the channel's event loop. Accessing from any other thread triggers a precondition crash. Always wrap in `context.eventLoop.execute { ... }` — never use `context.channel.isActive` as a pre-check outside the event loop.

### No `print()` in `Sources/`
Use `os.Logger` (`import os`) with one of the established subsystems (`com.tbd.app`, `com.tbd.daemon`) and a feature-shaped category. `.debug` is the right level for traces you'd previously have used `print()` for — they're silent by default and activated with `log stream --level debug`. Always pass an explicit `privacy:` argument on dynamic interpolations (default `.public` for this dev tool, `.private`/`.sensitive` for secrets). Full rationale and category taxonomy: [`docs/diagnostics-strategy.md`](docs/diagnostics-strategy.md).

## Quick Reference

- **Build**: `swift build`
- **Test**: `swift test`
- **Restart**: `scripts/restart.sh`
- **Diagnostics**: see [`docs/diagnostics-strategy.md`](docs/diagnostics-strategy.md). Quick recipes:
  - Stream one feature area live: `log stream --level debug --predicate 'subsystem BEGINSWITH "com.tbd" AND category == "markdown"'`
  - Replay the last 5 minutes after reproducing a bug: `log show --last 5m --level debug --predicate 'subsystem BEGINSWITH "com.tbd"'` (requires `sudo log config --subsystem com.tbd.app --mode "level:debug,persist:debug"` once per subsystem to capture `.debug` rows)
