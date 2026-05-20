# Shared Claude state across TBD profiles

**Date:** 2026-05-20
**Status:** Design (follow-up to `2026-05-19-alternate-profiles-redesign-design.md`)

## Problem

The original alt-profiles redesign (PR #177, merged 2026-05-19) gives every
non-bedrock profile its own isolated `CLAUDE_CONFIG_DIR` at
`~/tbd/profiles/<uuid>/claude/`. Claude Code reads **everything** from that
directory — not just credentials. So the new isolated profile dirs start
empty and silently miss every customization the user installed in
`~/.claude/`.

Three real problems fall out of that:

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

3. **Plugins, skills, agents, commands, hooks, and user-global
   instructions are missing under alt-profiles.** Anything in `~/.claude/`
   that customizes how `claude` behaves — `plugins/`, `skills/`, `agents/`,
   `commands/`, `hooks/`, `CLAUDE.md`, `settings.json` — is invisible to a
   spawn whose `CLAUDE_CONFIG_DIR` points elsewhere. Under an alt-profile,
   `claude` is a much barer tool than what the user spawns natively.

The user's actual mental model is: "conversations and customizations are
mine; profiles are who pays." The current design over-isolates — it isolates
everything, not just credentials.

## Goal

Make alt-profile dirs **thin overlays on `~/.claude/`**: every customization
slot mirrors the host via symlinks; only the per-profile identity slot
(`.claude.json` plus per-path Keychain auth) is owned by the profile. Resume
works regardless of which profile spawned the session — including
pre-redesign sessions in `~/.claude/projects/` — and every alt-profile sees
the same plugins, skills, agents, commands, hooks, and user instructions as
native `claude`.

## Out of scope

- Locking against simultaneous resume of the same session in two panes (a
  pre-existing footgun; not introduced by this change).
- Surfacing a swap-time warning that resuming under a different profile sends
  the prior transcript to the target account (UX polish, separate change).
- Cross-worktree session visibility — sessions stay scoped to a working
  directory by claude's native project-hash design, which we are not changing.
- Per-profile **differences** in plugins / skills / instructions / settings.
  Today's mental model is "customizations are mine; profiles are who pays" —
  so all profiles share. If per-profile customization becomes a need later, a
  layered-overlay design (similar to TBD's existing `--settings` flag) can be
  added without breaking this one.

## Approach

**Make `~/.claude/` the canonical store for every shared slot, and symlink
each slot from every TBD profile dir into it.** No data movement; the host's
existing state is the single source of truth. Auth isolation is preserved
because Claude Code keys its macOS Keychain entry on the *path* of
`CLAUDE_CONFIG_DIR`, not on what's inside it.

```
~/.claude/                              ← canonical (real, untouched)
├── projects/                           ← every spawn writes here
├── plugins/                            ← user-installed plugins
├── skills/                             ← user skills
├── agents/                             ← user agents
├── commands/                           ← slash commands
├── hooks/                              ← hooks dir
├── CLAUDE.md                           ← user-global instructions
├── settings.json                       ← user settings
├── .claude.json                        ← (host's own onboarding state)
└── .credentials.json | Keychain        ← host auth

~/tbd/profiles/<uuid-A>/claude/         ← TBD profile A (isolated CONFIG_DIR)
├── .claude.json                        ← REAL (per-profile)
├── projects     -> ~/.claude/projects/
├── plugins      -> ~/.claude/plugins/
├── skills       -> ~/.claude/skills/
├── agents       -> ~/.claude/agents/
├── commands     -> ~/.claude/commands/
├── hooks        -> ~/.claude/hooks/
├── CLAUDE.md    -> ~/.claude/CLAUDE.md
├── settings.json -> ~/.claude/settings.json
└── (Keychain entry keyed on this path) ← per-profile auth
```

### What gets mirrored

| Slot | Mirror? | Why |
|---|---|---|
| `projects/` | Yes (with merge-migration) | Session transcripts; unified history |
| `plugins/` | Yes | User-installed plugins |
| `skills/` | Yes | User skills |
| `agents/` | Yes | User agents |
| `commands/` | Yes | Slash commands |
| `hooks/` | Yes | Hook scripts |
| `CLAUDE.md` | Yes | User-global instructions |
| `settings.json` | Yes (with `apiKeyHelper` caveat below) | Model prefs, MCP servers, hook config |
| `.claude.json` | **No** | Per-profile: onboarding flag + `customApiKeyResponses` |
| `.credentials.json` / Keychain | **No** | Per-profile auth (Keychain entry keyed on `CLAUDE_CONFIG_DIR` path hash) |

### The `apiKeyHelper` caveat

If the user's `~/.claude/settings.json` defines an `apiKeyHelper` (a script
that supplies an API key), it will resolve identically under every TBD
profile because settings.json is shared. Claude Code's auth-precedence order
puts `apiKeyHelper` (#4) **above** `CLAUDE_CODE_OAUTH_TOKEN` (#5) but
**below** `ANTHROPIC_API_KEY` (#3).

- **API-key profiles**: TBD already injects `ANTHROPIC_API_KEY`, which beats
  `apiKeyHelper` — no effect.
- **OAuth profiles**: `apiKeyHelper` would supply its key and override the
  profile's intended subscription auth. Effectively all oauth profiles would
  resolve to the apiKeyHelper's identity → defeats per-profile auth.

Most users do not use `apiKeyHelper`. We document this as a known limitation:
"if you use `apiKeyHelper` in settings.json, oauth profiles will use the
helper's key rather than the profile's `/login` session." A future
refinement could shadow `apiKeyHelper` out of the symlinked settings via a
TBD-managed overlay, but it is not needed for v1.

### Why host-canonical (not the inverse)

We considered the inverse: keep a TBD-owned shared store at
`~/tbd/sessions/` (or similar) and replace `~/.claude/` slots with symlinks
to it. Host-canonical is strictly better:

| | host-canonical (chosen) | TBD-owned shared store |
|---|---|---|
| Pre-redesign sessions accessible on first restart | Immediately | Only after migration |
| User's existing plugins/skills/CLAUDE.md immediately visible | Yes | Only after migration |
| Migration step needed | None | Move `~/.claude/*` slots → shared store |
| Risk of migration failure | None | Real (partial move) |
| `~/.claude/` itself | Untouched (still a real dir) | Several slots become symlinks |
| Reversibility | `rm <profile>/claude/<slot>` | Undo a move + a symlink |
| Backup of `~/.claude/` captures TBD-profile artifacts | Yes | No |

The only thing the TBD-owned variant preserves that host-canonical doesn't is
the ability to keep TBD-profile state logically separate from host state —
but that's the exact thing we want to remove.

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

The other mirrored slots (`plugins/`, `skills/`, etc.) are read-heavy and
written rarely (when the user installs a plugin or edits a skill). Concurrent
writes from multiple `claude` processes are not expected; the host claude and
TBD profiles all read the same content.

### Billing classification

Unchanged. `CLAUDE_CONFIG_DIR` still points at a non-default path per profile,
the delivered credential is still a per-profile `/login` OAuth blob, and the
2026-06-15 Agent-SDK reclassification is determined at the API request layer
(by credential type and request shape), not by client filesystem layout.

## Acceptance criteria

### shared-claude-projects.AC1: profile dirs mirror host slots via symlinks

The mirror list is:
`projects`, `plugins`, `skills`, `agents`, `commands`, `hooks`, `CLAUDE.md`,
`settings.json` — all resolved relative to an injectable host-base directory
(default `~/.claude/`).

- **AC1.1 Success:** For each slot present in `<host-base>/`, after
  `ensureOAuthDir(forProfileID:)` runs against a fresh profile UUID,
  `<profile-dir>/claude/<slot>` exists as a symbolic link whose destination
  resolves to `<host-base>/<slot>`.
- **AC1.2 Success:** Same property after `ensureAPIKeyDir(forProfileID:apiKey:)`.
- **AC1.3 Success:** A slot that does **not** exist in `<host-base>/` does
  **not** cause a symlink to be created for it. (No `<profile-dir>/claude/skills`
  if `<host-base>/skills` is missing.)

### shared-claude-projects.AC2: idempotent

- **AC2.1 Success:** Calling `ensureOAuthDir` / `ensureAPIKeyDir` a second time
  for the same profile leaves every existing slot symlink (and its target) in
  place and does not error.

### shared-claude-projects.AC3: migrate pre-existing `projects/` content; respect other slots

- **AC3.1 Success:** If `<profile-dir>/claude/projects` already exists as a
  *real directory* (e.g. created between PR #177 merging and this follow-up
  shipping), its contents are merged into `<host-base>/projects/` before being
  replaced by the symlink.
- **AC3.2 Success:** A `<host-base>/projects/<cwd-hash>/<id>.jsonl` that
  already existed before the migration is NOT overwritten — collisions skip
  rather than clobber.
- **AC3.3 Success:** For *non-projects* slots, if `<profile-dir>/claude/<slot>`
  already exists as a real file or non-empty real directory, it is **left in
  place** (we do not silently move user content out of profile dirs) and the
  symlink for that slot is **not** created. An empty real directory may be
  removed and replaced with the symlink. A symlink pointing at the wrong
  target is left alone with a log warning.

### shared-claude-projects.AC4: profile deletion preserves host state

- **AC4.1 Success:** Deleting a profile via `handleModelProfileDelete` removes
  the profile directory but leaves every file under `<host-base>/` untouched
  — including `projects/`, `plugins/`, `skills/`, etc. (Relies on macOS
  `FileManager.removeItem(at:)` not following symlinks; lock it in with a
  test that seeds a sentinel under at least two different host slots.)

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
5. **No per-profile customization** in the mirrored slots. Every TBD profile
   sees the same plugins/skills/CLAUDE.md/settings.json as native `claude`.
   If "personal claude has skill X, work claude doesn't" becomes a real need,
   it requires a layered-overlay design — not in scope here.
6. **`apiKeyHelper` in `settings.json` defeats per-profile auth for oauth
   profiles.** See the "`apiKeyHelper` caveat" section above. Document this
   limitation; revisit if it bites.

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
