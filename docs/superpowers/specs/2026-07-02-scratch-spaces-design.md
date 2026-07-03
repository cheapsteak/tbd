# Scratch Spaces — repo-less Claude/Codex sessions

**Date:** 2026-07-02
**Status:** Approved design, pre-implementation

## Problem

Every TBD session today lives under `Repo → Worktree → Terminal`. There is no
place to talk to Claude or Codex outside a repo context — e.g. to bootstrap a
brand-new project (which has no repo yet) or to hold a general-purpose chat
that belongs to no codebase. Starting that conversation inside an unrelated
project's worktree pollutes both contexts.

## Goals

- A "Scratch" area in the sidebar holding repo-less workspaces, each with its
  own folder and Claude/Codex/shell terminals.
- Serves both use cases: persistent general-purpose chat spaces, and
  incubators for new projects.
- Agent-driven promotion: when a scratch project takes shape, Claude moves it
  to a permanent location and registers it as a real TBD repo
  (move-on-promote). No promotion UI.
- Scratch spaces are excluded from all repo-driven behavior (PR polling,
  reconcile, merge flows) **by construction**, not by remembered guards.

## Non-goals

- No new window/tab UI; scratch lives in the existing sidebar.
- No migration of live terminals across tmux servers at promotion time.
- No UI-driven promotion flow.
- Scratch spaces are not git repos and get no git affordances until promoted.

## Approach decision

Three approaches were considered:

- **A — synthetic "Scratch" pseudo-repo row**: smallest diff, but scratch is
  *included by default* in every repo-driven behavior (each needs an opt-out
  guard, forever), and `state.db` carries a permanent fake `Repo` row.
- **B — nullable `Worktree.repoID` (chosen)**: scratch spaces are `Worktree`
  rows with `repoID = nil`. Excluded-by-default polarity; the compiler forces
  an explicit decision at every daemon site that resolves the repo; no false
  rows in persistent state.
- **C — hidden anchor git repo**: rejected. Nested-git confusion lands exactly
  on the bootstrap path, and promotion would require detaching worktrees from
  the anchor.

`Worktree` already stretches beyond "a git worktree" (the `.main` row is a
plain directory), so B extends an existing precedent: a Worktree is a
directory TBD manages terminals in, with *optional* git parentage.

## 1. Data model & migration

- `Worktree.repoID: UUID?` in `Sources/TBDShared/Models.swift`. Scratch-ness
  is derived — `var isScratch: Bool { repoID == nil }` — no separate `kind`
  column that could disagree with the FK.
- Regular statuses apply to scratch rows (`.active`, `.archived` unused for
  now; `.main` never applies).
- `branch` stays non-optional and holds `""` for scratch rows; the UI hides
  it. (Deliberate compromise: making `branch` optional would double call-site
  churn with no behavioral gain.)
- `promotedToRepoID: UUID?` on `Worktree` (nil except for promoted scratch
  rows — see §5.1).
- Migration (house 3-file rule, one commit):
  1. New sequential `vN` migration rebuilds `worktrees` to drop the
     `NOT NULL` on `repo_id` and adds the nullable `promoted_to_repo_id`
     column (SQLite table-rebuild via GRDB).
  2. `WorktreeRecord.repoID` becomes optional
     (`Sources/TBDDaemon/Database/WorktreeStore.swift`).
  3. `Models.swift` field becomes `UUID?` — old JSON/rows still decode.
- Every daemon site doing `db.repos.get(id: worktree.repoID)` stops compiling;
  each gets an explicit nil decision (this audit is the point of approach B).
  App-side `repos.first(where: { $0.id == worktree.repoID })` comparisons keep
  compiling and correctly no-match for scratch.

## 2. Scratch space lifecycle

- **Location:** `~/tbd/scratch/<name>` via a new `TBDConstants.scratchDir`
  (honors `TBD_HOME`). Created as a plain empty directory — no `git init`.
- **Naming:** same `YYYYMMDD-adjective-animal` generator as worktrees;
  display name renameable through the existing rename flow.
- **tmux:** one shared server for all scratch spaces, named via the existing
  per-repo derivation with the scratch base dir in the repo-path role
  (`TmuxManager.serverName(forRepoPath: scratchDir)`), stored in
  `worktree.tmuxServer` as usual.
- **RPC:** new `scratch.create` method (mkdir + insert row + `StateDelta`
  broadcast). Deliberately not overloading `worktree.create`, which is
  entangled with `git worktree add` phases.
- **CLI:** `tbd scratch new [--name <n>]`, `tbd scratch list`,
  `tbd scratch promote <dest-path>` (§5).
- **Deletion:** closes terminals, moves the folder to Trash (never `rm -rf`),
  deletes the row. No archive machinery — there is no branch to preserve;
  Claude transcripts survive on disk as today.
- **Reconcile/recovery:** repo reconcile never sees scratch rows (it walks
  repos). Startup recreates `~/tbd/scratch/` if missing; a space whose dir is
  missing is flagged the same way missing worktrees are today.

## 3. Terminal spawning in a scratch space

`terminal.create` operates on the worktree row exactly as today (path,
tmuxServer, `TBD_WORKTREE_ID`). Where the handler currently resolves the
repo, `repoID == nil` means:

- **System prompt:** `SystemPromptBuilder.promptLayers(repo: nil, worktree:)`
  substitutes a scratch layer (content in §5.3) for the repo layer.
- **Model profiles:** `modelProfileResolver.resolve(repoID: nil)` → global
  default profile.
- **Env overrides:** scopes collapse to `global < profile` (no repo scope).
- **Claude instrumentation unchanged:** plugin dir (`tbd` skill), settings
  overlay hooks, session-event relay all apply to scratch sessions.
- **Codex:** no change — Codex sessions already share one global
  `CODEX_HOME` (per-repo isolation was removed by the 2026-05-22 codex
  global-home redesign), and scratch sessions use it the same way.

## 4. Sidebar & UI

- The Scratch section is **synthesized client-side** from
  `worktrees.filter { $0.repoID == nil }` — no repo row backs it. Pinned at
  the top of the sidebar, titled "Scratch", with a `+ New scratch space`
  affordance.
- **Setting:** `showScratchSection` (app-side, default **on**). Gates
  presentation only: turning it off hides the section; existing spaces and
  live terminals keep running.
- Rows reuse `WorktreeRowView`. Repo-derived affordances (branch label, PR
  icon, merge/archive menu items) disappear because the repo lookup returns
  nil — verify this falls out naturally before adding special cases.
- Context menu: new Claude/Codex/shell terminal, rename, reveal in Finder,
  a "Promote…" hint that explains the agent-driven flow, and delete.
- Jump menu, notes, and notifications work unchanged (keyed off
  `worktreeID`).

## 5. Promotion (agent-driven, move-on-promote)

### 5.1 `tbd scratch promote <dest-path> [--display-name <name>]`

The single real mechanism, run by Claude from inside a scratch session:

1. Validate: cwd is a scratch space; dest does not exist; the scratch dir is
   a git repo (the agent must have `git init`-ed and committed) — clear error
   otherwise, nothing moved.
2. Move the folder to dest. Same-volume rename keeps the running session's
   cwd valid (inode-based). Cross-volume dest is allowed with a warning that
   running processes may lose their cwd.
3. Run the existing `repo.add` path on the new location (creates the Repo
   row + its synthetic main worktree, reconciles, broadcasts). The repo's
   display name is resolved in priority order:
   1. `--display-name <name>` if given;
   2. the scratch space's display name, if the user renamed it from its
      auto-generated default (reuse the same default-name detection the
      `stop-rename-check` hook uses);
   3. the destination folder name (`repo.add`'s existing behavior).
4. Mark the scratch row **promoted**: store a pointer to the new repo
   (`promotedToRepoID: UUID?` on `Worktree`, nil for everything else). The
   row remains; its live terminals keep working on the scratch tmux server
   until closed. Sidebar shows "→ promoted to <repo>". Deleting a promoted
   row removes only the row (the folder already moved).

This deliberately avoids migrating live terminals to the new repo's tmux
server.

### 5.2 `repo.add` guard

`repo.add` rejects any path under `~/tbd/scratch/` with an error directing to
`tbd scratch promote`. Prevents the unguided path from creating a repo that
lives inside TBD's scratch area.

### 5.3 The nudge

- The scratch system-prompt layer and a section in the bundled `tbd` skill
  explain: this is a scratch space; when the project takes shape, offer the
  user promotion via `tbd scratch promote` (Claude asks the user for the
  destination path).
- A guardrail rule in the existing PreToolUse hook framework fires on
  `git init` inside a scratch workspace and injects a reminder to consider
  offering promotion. It informs; it never blocks.

## 6. Error handling

- Scratch name collision on create → regenerate name.
- `~/tbd/scratch/` missing at startup → recreate; individual space dir
  missing → flag as missing (existing worktree pattern).
- Promote with no git repo / dirty validation failure → CLI error, no move.
- Deletion always goes to Trash.

## 7. Testing

Per the gated-branch rule (a test per branch of any new toggle):

- Migration: old rows decode; nil `repoID` round-trips; existing worktrees
  unaffected.
- `terminal.create` on a nil-repo worktree: default profile resolved,
  global-only env scopes, scratch prompt layer present, repo layer absent.
- PR poller and reconcile provably never touch scratch rows.
- `repo.add` rejects paths under the scratch dir.
- `scratch promote`: happy path (move + repo.add + promoted marker), and
  no-git failure leaves everything untouched.
- Promote display-name priority: explicit flag wins; renamed scratch space
  inherits its display name; still-default scratch name falls back to the
  destination folder name.
- `showScratchSection` on/off: section renders/hides; spaces and terminals
  intact in both states.
- All tests isolate via `TBD_HOME` / injection seams per CLAUDE.md.

## Open follow-ups (explicitly out of scope)

- Archiving (vs deleting) scratch spaces.
- Converting a promoted scratch row's live terminals into terminals of the
  new repo's main worktree.
- UI-driven promotion.
