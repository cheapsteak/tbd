-- Live remote transcript sync: tail-first loading, earlier-history loading,
-- and hint-driven background sync
-- (docs/specs/2026-09-25-remote-session-transcript-design.md § Gating).
-- No DEFAULT clause on purpose: NULL means nobody has chosen, 0/1 mean someone
-- did. The shipped default lives only in
-- Config.remoteTranscriptLiveSyncEnabledDefault.
ALTER TABLE config ADD COLUMN remote_transcript_live_sync_enabled INTEGER;
