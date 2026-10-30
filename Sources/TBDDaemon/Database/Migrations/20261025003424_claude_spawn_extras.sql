-- The Claude spawn values a terminal's starter passed — a settings overlay and
-- plugin folders — kept so every later start of that session applies them too
-- (docs/specs/2026-10-24-terminal-plugin-dirs-design.md, "What TBD stores").
--
-- Each column holds one JSON object,
-- {"claudeSettingsOverlay": <string>, "pluginDirs": [<path>, ...]}, with a key
-- omitted when it was not passed. The worktree column holds a map from Claude
-- session id to that object, written beside archivedClaudeSessions at archive
-- and cleared with it on revive. The history column is copied from the
-- terminal row when the terminal closes. No DEFAULT: every row written before
-- these columns has nothing stored, which is NULL.
ALTER TABLE terminal ADD COLUMN claude_spawn_extras TEXT;
ALTER TABLE terminal_history ADD COLUMN claudeSpawnExtras TEXT;
ALTER TABLE worktree ADD COLUMN archivedClaudeSpawnExtras TEXT;
