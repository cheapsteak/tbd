# TBD

macOS native worktree + terminal manager for multi-agent Claude Code workflows.

Use the `tbd-project` skill for architecture, conventions, and file reference.

## Workflow

- Always commit after completing work. Don't wait to be asked.
- Use conventional commit messages: `feat:`, `fix:`, `docs:`, `refactor:`
- Verify your changes compile (`swift build`) before committing.
- Run `swift test` if you changed daemon or shared code.

## Critical Rules

### NEVER delete ~/.tbd/state.db
The database stores worktree display names, custom config, and notification history. Deleting it orphans tmux servers (repo UUID changes → tmux server name changes → old sessions become unreachable). If you encounter DB issues, diagnose and fix the schema/code — don't wipe the DB.

### Database migrations must update the shared model
When adding a DB column in `Sources/TBDDaemon/Database/Database.swift`:
1. Add the column with a `.defaults(to:)` value in the migration
2. Update the GRDB Record type in `Sources/TBDDaemon/Database/`
3. Update the Codable model in `Sources/TBDShared/Models.swift` — new fields MUST be optional or have a default value so existing JSON/rows still decode
4. All three changes in the same commit

Migrations use GRDB's `DatabaseMigrator`, numbered sequentially (`v1`, `v2`, `v3`...). Never modify an existing migration — always add a new one.

## Quick Reference

- **Build**: `swift build`
- **Test**: `swift test`
- **Restart**: `scripts/restart.sh`
- **Debug logs**: `/tmp/tbd-bridge.log`
