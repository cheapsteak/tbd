# TBD

macOS native worktree + terminal manager for multi-agent Claude Code workflows.

Use the `tbd-project` skill for architecture, conventions, and file reference.

## Workflow

- Always commit after completing work. Don't wait to be asked.
- Use conventional commit messages: `feat:`, `fix:`, `docs:`, `refactor:`
- Verify your changes compile (`swift build`) before committing.
- Run `swift test` if you changed daemon or shared code.

## Quick Reference

- **Build**: `swift build`
- **Test**: `swift test`
- **Restart**: `scripts/restart.sh`
- **Debug logs**: `/tmp/tbd-bridge.log`
