# Shared Claude session store across TBD profiles

**Date:** 2026-05-20
**Status:** Design (follow-up to `2026-05-19-alternate-profiles-redesign-design.md`)

## Problem

The original alt-profiles redesign (PR #177, merged 2026-05-19) gives every
non-bedrock profile its own isolated `CLAUDE_CONFIG_DIR` at
`~/tbd/profiles/<uuid>/claude/`. Claude Code stores session transcripts at
`<CONFIG_DIR>/projects/<cwd-path-hash>/<session-uuid>.jsonl` — so transcripts
are now siloed per profile.

Two real problems fall out of that:

1. **Pre-redesign sessions become unresumable on TBD restart.** Conversations
   created before PR #177 merged were spawned without a config-dir env var, so
   their JSONL files live in `~/.claude/projects/`. After the merge, every
   restart of TBD reconciles each terminal by respawning `claude --resume <id>`
   under that terminal's profile's isolated dir — and the session isn't there.
   The terminal effectively reincarnates blank. The JSONL still exists in
   `~/.claude/projects/`, but the live terminal can't reach it. Affects every
   terminal pinned to an oauth or direct-apiKey profile.

2. **Cross-profile resume doesn't work.** A session created under profile A
   isn't visible to a `claude --resume` spawned under profile B. The user has
   to start fresh every time they want to switch which subscription pays for
   the rest of a conversation.

The user's actual mental model is: "conversations" are mine; "profiles" are who
pays. The current design over-isolates — it isolates conversations too.

## Goal

Unify session storage across all TBD profiles **and** the host's native claude
in one place, while keeping authentication, settings, and MCP config strictly
per-profile. Resume should work regardless of which profile spawned the
session, including pre-redesign sessions that live in `~/.claude/projects/`.

## Out of scope

- Locking against simultaneous resume of the same session in two panes (a
  pre-existing footgun; not introduced by this change).
- Surfacing a swap-time warning that resuming under a different profile sends
  the prior transcript to the target account (UX polish, separate change).
- Cross-worktree session visibility — sessions stay scoped to a working
  directory by claude's native project-hash design, which we are not changing.

## Approach

**Make `~/.claude/projects/` the canonical session store, and symlink each TBD
profile's `claude/projects` into it.** No data movement; the host's existing
session store is the single source of truth.

```
~/.claude/projects/                     ← canonical (real directory, untouched)
├── -Users-chang-myrepo/
│   ├── 1A2B-...jsonl                   ← created any time by any spawn
│   └── 3C4D-...jsonl

~/tbd/profiles/<uuid-A>/claude/         ← TBD profile A (isolated)
├── .claude.json                        ← per-profile
├── (Keychain entry keyed on this path) ← per-profile auth
└── projects -> ~/.claude/projects/     ← symlink (shared)

~/tbd/profiles/<uuid-B>/claude/         ← TBD profile B (isolated)
├── .claude.json                        ← per-profile
└── projects -> ~/.claude/projects/     ← same target
```

### Why host-canonical (not the inverse)

We considered the inverse: keep a TBD-owned shared store at
`~/tbd/sessions/projects/` and replace `~/.claude/projects/` with a symlink to
it. Host-canonical is strictly better:

| | host-canonical (chosen) | TBD-owned shared store |
|---|---|---|
| Pre-redesign sessions accessible on first restart | Immediately | Only after migration |
| Migration step needed | None | Move `~/.claude/projects/*` → shared store |
| Risk of migration failure | None | Real (partial move) |
| `~/.claude/projects/` itself | Untouched (still a real dir) | Becomes a symlink |
| Reversibility | `rm <profile>/claude/projects` | Undo a move + a symlink |
| Backup of `~/.claude/` captures TBD sessions | Yes | No |
| Lines of code | <20 | More |

The only thing the TBD-owned variant preserves that host-canonical doesn't is
the ability to keep TBD-profile sessions logically separate from host sessions
— but that's the exact thing we want to remove.

### Auth isolation is preserved

Claude Code keys its macOS Keychain entry on the **path** of
`CLAUDE_CONFIG_DIR`, not on its contents. `~/tbd/profiles/<id>/claude/` and
`~/.claude/` have different paths → different Keychain entries → independent
logins. Only the `projects/` subdirectory is shared.

### Concurrent-write safety

Two profiles spawning `claude` in the same cwd write to **different**
`<uuid>.jsonl` files in shared `projects/<cwd-hash>/` — no file-level collision.
The same session ID can still be corrupted if resumed in two panes simultaneously,
but that risk pre-exists and is not made worse by sharing.

### Billing classification

Unchanged. `CLAUDE_CONFIG_DIR` still points at a non-default path per profile,
the delivered credential is still a per-profile `/login` OAuth blob, and the
2026-06-15 Agent-SDK reclassification is determined at the API request layer
(by credential type and request shape), not by client filesystem layout.

## Acceptance criteria

### shared-claude-projects.AC1: profile dirs symlink into the host store

- **AC1.1 Success:** After `ensureOAuthDir(forProfileID:)` runs against a fresh
  profile UUID, `<profile-dir>/claude/projects` exists as a symbolic link whose
  destination resolves to `<host-projects>/` (default `~/.claude/projects/`,
  injectable for tests).
- **AC1.2 Success:** Same property after `ensureAPIKeyDir(forProfileID:apiKey:)`.

### shared-claude-projects.AC2: idempotent

- **AC2.1 Success:** Calling `ensureOAuthDir` / `ensureAPIKeyDir` a second time
  for the same profile leaves the existing symlink (and its target) in place
  and does not error.

### shared-claude-projects.AC3: migrate pre-existing `projects/` content

- **AC3.1 Success:** If `<profile-dir>/claude/projects` already exists as a
  *real directory* (e.g. created between PR #177 merging and this follow-up
  shipping), its contents are merged into `<host-projects>/` before being
  replaced by the symlink. Files surviving from before the migration are
  preserved on the host side.
- **AC3.2 Success:** A `<host-projects>/<cwd-hash>/<id>.jsonl` that already
  existed before the migration is NOT overwritten — collisions skip rather
  than clobber.

### shared-claude-projects.AC4: profile deletion preserves host sessions

- **AC4.1 Success:** Deleting a profile via `handleModelProfileDelete` removes
  the profile directory but leaves every file under `<host-projects>/`
  untouched. (Relies on macOS `FileManager.removeItem(at:)` not following
  symlinks; lock it in with a test.)

## Non-acceptance / known risks

1. **`rm -rf ~/.claude/projects/` now wipes every TBD-profile session in one
   sweep.** Pre-redesign, that command only wiped host sessions. Acceptable —
   it's the cost of unified history; document in the PR description so
   future-you isn't surprised.
2. **Concurrent same-session resume corrupts the JSONL.** Pre-existing footgun.
3. **Cross-account transcript exposure on swap.** Resuming a session created
   under personal OAuth under a work OAuth profile sends the prior transcript
   as context to the work account. Expected — it's the feature — but a future
   UX polish item should surface it at swap time.
4. **TBD-vs-claude.ai-vs-API-key session-format compatibility.** Worst case
   has historically been a soft failure (model not available), not data loss.
   Worth one manual cross-profile-resume test before merging.

## Compatibility / migration

- **No DB schema change.**
- **No code change at call sites** of `ensureOAuthDir` / `ensureAPIKeyDir`. The
  symlink work is internal to `ClaudeProfileConfigDirManager`.
- **First restart after this ships**: existing profile dirs whose `projects/`
  is a real directory get migrated in place; pre-redesign sessions in
  `~/.claude/projects/` become immediately visible to every TBD profile.
- **Manual rescue for any terminal that has already reincarnated blank** (i.e.
  user restarted main TBD between the PR #177 merge and this follow-up
  landing): the JSONL still exists; the new session ID on the blank terminal
  doesn't match the old session ID stored in `Terminal.claudeSessionID`. No
  automatic recovery for those — surface a "stash recovered" note if we feel
  like it, or do nothing. Worth flagging in the PR description but not
  blocking on it.
