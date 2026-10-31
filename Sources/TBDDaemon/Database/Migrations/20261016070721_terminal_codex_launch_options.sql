-- The options this tab's Codex was launched with — its model override and the
-- Codex features turned off for it — as a JSON-encoded `CodexLaunchOptions`,
-- or NULL for a tab launched with none.
--
-- Recorded at spawn, so a relaunch of Codex in the same tab (recreating a dead
-- window, or restoring Codex after a failed continue-in-Claude) starts it the
-- way the tab was started instead of on the defaults. No DEFAULT: every row
-- written before this column launched with options nobody recorded, which is
-- NULL, and a relaunch of such a row keeps today's default command.
ALTER TABLE terminal ADD COLUMN codex_launch_options TEXT;
