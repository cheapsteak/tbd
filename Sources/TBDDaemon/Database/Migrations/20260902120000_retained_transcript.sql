-- Receipts for transcripts a provider has retained in its own durable store
-- (`docs/remote-provider-contract.md` § `retain <id>` / `import`, and
-- `docs/specs/2026-09-02-remote-session-delete-and-transcript-exchange-design.md`).
--
-- A key is opaque and provider-scoped, so (provider, key) is the identity;
-- everything else is what makes a key findable again by a human. Without this
-- table a key printed once is unrecoverable: nothing in the provider contract
-- lets a caller enumerate the keys it holds, so TBD's own row is the only
-- record that a retained transcript exists at all.
--
-- `expires_at` is nullable and carries no DEFAULT, because an absent value is
-- the contract's "the provider makes no claim" and must never be confused with
-- an instant somebody chose. It is likewise never read as "kept forever".
--
-- `bytes` is NOT NULL: it is how a caller detects a truncated `recall`, and a
-- row without it cannot do that job.
--
-- `origin_worktree_id` links an adopted lane, so a deleted lane's archived row
-- can offer Revive-as-reseed. `local_path` is filled in when a `recall` writes
-- the JSONL under `~/tbd/transcripts/`; it is what the GC leg reconciles files
-- against.
CREATE TABLE IF NOT EXISTS retained_transcript (
    id TEXT PRIMARY KEY NOT NULL,
    provider TEXT NOT NULL,
    key TEXT NOT NULL,
    expires_at DATETIME,
    bytes INTEGER NOT NULL,
    source_session_id TEXT,
    source_title TEXT,
    resolved_repo_id TEXT,
    origin_worktree_id TEXT,
    local_path TEXT,
    created_at DATETIME NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_retained_transcript_provider_key
    ON retained_transcript (provider, key);
