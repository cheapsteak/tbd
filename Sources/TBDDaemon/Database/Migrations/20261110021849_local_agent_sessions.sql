CREATE TABLE IF NOT EXISTS local_agent_session (
    id TEXT PRIMARY KEY NOT NULL,
    worktree_id TEXT NOT NULL REFERENCES worktree(id) ON DELETE CASCADE,
    terminal_id TEXT REFERENCES terminal(id) ON DELETE SET NULL,
    agent_kind TEXT NOT NULL,
    session_id TEXT NOT NULL,
    transcript_path TEXT,
    codex_launch_options TEXT,
    first_observed_at DATETIME NOT NULL,
    last_observed_at DATETIME NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_local_agent_session_identity
    ON local_agent_session(worktree_id, agent_kind, session_id);

ALTER TABLE worktree ADD COLUMN archived_agent_tabs TEXT;

-- Codex rows need rollout provenance before they can enter the catalog.
-- Surviving Claude rows already carry the accepted hook identity and path.
INSERT OR IGNORE INTO local_agent_session (
    id, worktree_id, terminal_id, agent_kind, session_id, transcript_path,
    first_observed_at, last_observed_at
)
SELECT
    printf('%s-%s-%s-%s-%s', hex(randomblob(4)), hex(randomblob(2)),
           hex(randomblob(2)), hex(randomblob(2)), hex(randomblob(6))),
    worktreeID, id, 'claude', claudeSessionID, transcriptPath,
    COALESCE(sessionOrderObservedAt, createdAt), COALESCE(sessionOrderObservedAt, createdAt)
FROM terminal
WHERE kind = 'claude' AND length(trim(claudeSessionID)) > 0
    AND length(trim(transcriptPath)) > 0
ORDER BY COALESCE(sessionOrderObservedAt, createdAt) DESC, id;
