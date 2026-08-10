# Multiple pull requests per worktree

## Problem

A worktree can produce more than one pull request. An agent session that runs
long enough — or that dispatches subagents — opens a PR, gets it reviewed,
starts the next piece of work on a fresh branch, and opens another. TBD shows
exactly one of them.

The single-PR assumption is not merely a display limit. TBD discovers a
worktree's PR by matching the worktree's **head branch** against the viewer's
authored PRs. A subagent's PR is typically on a branch the worktree never had
checked out, so no amount of polling will find it: it is invisible by
construction, not by omission.

## What exists today

- `Worktree.prNumber` (`Int?`) records the PR a worktree was *created from*, when
  it was created from a PR row. `Worktree.prStatus` (`PRStatus?`) caches the last
  observed status. Both are single-valued, persisted on the `worktree` row
  (migrations `v34`, `v54`).
- `PRStatusManager` keys its cache `[UUID: PRStatus]` — one status per worktree.
  It resolves a stored number directly via an aliased `pullRequest(number:)`
  query, and otherwise matches the viewer-authored batch by head branch, scoped
  to the worktree's own repo.
- `PRStatusManager.apply` fires `onMergedTransition` when a worktree's status
  moves from non-merged to `.merged`. That drives auto-archive
  (`AutoArchiveOnMergeCoordinator`) and auto-hibernate
  (`AutoHibernateOnMergeCoordinator`).
- The app renders one toolbar split button (`ContentView.swift`) and one sidebar
  row indicator (`RowStatusIndicator`). The bottom status bar shows no PR
  information at all.

Matching by head branch is also ambiguous when two PRs share a head ref;
`bestNodeByRepoBranch` resolves the tie by state priority and then `createdAt`,
silently discarding the loser.

## Design

### Binding model

A **binding** is a durable, explicit statement that a PR belongs to a worktree.
Bindings live in a new table (migration `v70`):

```sql
CREATE TABLE worktree_pull_request (
  id          TEXT PRIMARY KEY,
  worktree_id TEXT NOT NULL REFERENCES worktree(id) ON DELETE CASCADE,
  host        TEXT NOT NULL DEFAULT 'github.com',
  owner       TEXT NOT NULL,
  repo        TEXT NOT NULL,
  number      INTEGER NOT NULL,
  url         TEXT NOT NULL,
  head_branch TEXT,
  base_ref    TEXT,
  pr_status   TEXT,            -- cached PRStatus JSON
  source      TEXT NOT NULL,   -- hook | branch | manual
  detached    INTEGER NOT NULL DEFAULT 0,
  bound_at    DATETIME NOT NULL,
  UNIQUE (worktree_id, host, owner, repo, number)
);
```

The `UNIQUE` constraint is the deduplication mechanism: the three discovery
sources below can all propose the same PR, and only the first insert wins. A row
already present keeps its original `source` and `bound_at`.

Per the repo's migration rule, the same commit adds the GRDB record type under
`Sources/TBDDaemon/Database/` and a `PRBinding` Codable model in
`Sources/TBDShared/Models.swift`, with every new field optional or defaulted so
existing rows and JSON still decode.

`Worktree.prNumber` keeps its present meaning — provenance for a worktree
created from a PR row — and additionally seeds a `manual`-source binding, so
that PR appears in the list like any other. Fork PRs make this load-bearing
rather than tidy: their head branch never appears in the viewer-authored batch,
so branch matching can never find them and the stored number is the only handle
that exists. Seeding runs as a poll reconciliation rather than at creation,
which covers worktrees that predate bindings and avoids the moment during
creation when the checkout does not yet exist and its repo cannot be resolved.
Because it re-runs every poll, the seed is explicitly barred from reviving a
tombstone, which a `manual` source would otherwise do.

`Worktree.prStatus` continues to be written with the **worst-state** status
among a worktree's bindings, so existing readers (`RemoteSectionView`,
`MockSeeder`, the supervision surfaces) need no change — with one exception. It
is **not** written when that worst status is `.merged`, because `hydrate`
reloads the column at daemon start as an already-merged baseline; a merge would
then never be re-observed as a transition, and an auto-archive that failed on
the first attempt could never retry. The worktree keeps its previous column
value instead. This is the same reason `PRStatusManager` has never persisted
`.merged`.

### Discovery: three sources

**Hook binding** is the primary source, and the only one that can see a
subagent's PR. `ClaudeHookOverlay` gains a `PostToolUse` entry matching `Bash`.
The hook command greps its stdin for `gh pr create` and only then pipes the
payload to `tbd pr bind --from-hook`; every other Bash call costs one `grep` and
no process spawn. The CLI reads the hook JSON, confirms `tool_input.command`
matches `gh pr create`, and extracts PR URLs from `tool_response` with

```
https://github\.com/(?!\.{1,2}/)[\w.-]+/(?!\.{1,2}/)[\w.-]+/pull/\d+
```

The lookaheads reject `.` and `..` path segments, which would otherwise parse as
an owner or repo name. Gating on the command and reading the result is what
keeps the rule narrow: a PR URL merely *mentioned* in unrelated output does not
bind.

This reads the hook's structured `tool_input` / `tool_response` JSON. It is not
TUI screen-scraping — that rule bans inferring state from a rendered terminal
screen and directs us to machine interfaces such as hook payloads, which is
exactly what this is.

**Branch matching** is the fallback, and covers what the hook cannot: Codex
sessions, plain shell sessions, and PRs that predate this feature. The existing
matcher is retained wholesale and rewritten to emit bindings with
`source = branch` rather than writing `worktree.prStatus` directly. Because
bindings are a list, a branch carrying two PRs now yields two bindings instead of
discarding one.

**Manual binding** is the escape hatch, for a PR that neither source found and
for removing one that no longer belongs. `attach` inserts a `manual` binding;
`detach` sets `detached = 1`.

Detach writes a **tombstone rather than deleting the row**. A deleted row would
be re-created by the very next poll or hook fire, so the user's decision has to
be recorded to be durable. Tombstones are excluded from every read path and from
the merge rule, and `attach` on a tombstoned PR clears the flag.

Bindings are capped at **20 non-detached rows per worktree**. On overflow, a
terminal-state binding (merged or closed) is evicted to make room; if none is
evictable the new binding is dropped and the daemon logs it. The cap bounds the
per-poll GraphQL cost of a long-lived worktree.

Reviving a tombstone by explicit attach bypasses the cap, because it clears a
flag rather than inserting a row. That is the intended precedence: the cap
exists to bound what automatic discovery may add, and an explicit user gesture
outranks it.

### Status refresh

`PRStatusManager`'s cache becomes keyed by binding rather than by worktree. The
existing `numberedPRQuery(aliases:)` already batches many PR numbers per repo
into one aliased GraphQL round trip, so N bindings in a repo cost the same one
call that N worktrees do today.

The existing discipline carries over unchanged: a transient fetch failure keeps
the previous cached status rather than guessing, direct refreshes are not
clobbered by an in-flight batch, and a cross-repo binding is cleared and the
clear persisted so startup hydration cannot resurrect it.

### Merge semantics

Auto-archive and auto-hibernate fire when **every non-detached binding is
terminal (merged or closed) and at least one is merged**.

This is the one place multi-PR support changes behavior rather than display, so
it is stated as a rule rather than left to fall out of the implementation. With a
single binding it is identical to today. With several, it will not archive a
worktree that still has an open PR on it — the failure mode is a worktree that
outlives its usefulness, which a `tbd pr detach` corrects, rather than a worktree
archived out from under live work, which loses state.

`.merged` remains unpersisted, preserving the existing recovery guarantee: a
merge observed while the daemon was down is re-observed as a transition after
restart, so a failed archive is retried rather than lost.

### UI surfaces

**Toolbar.** With one binding the control is unchanged: label `#123`, click opens
the PR in a tab, ⌘-click opens the browser, chevron holds the auto-archive and
auto-hibernate toggles. With several, the label becomes a worst-state icon plus
`N PRs` and a click opens the list; each row opens that PR, and the toggles move
below a divider in the same menu.

Worst-state ordering is: checks failing, blocked, changes requested, pending,
mergeable, draft. This preserves what the icon already means — *does anything
here need me?* — so a red dot in the toolbar carries one meaning at any count.

Two AppKit constraints govern the implementation, both already documented in
`Sources/TBDApp/CLAUDE.md`. The label is flattened to exactly one image and one
plain string, so the count belongs in the text, not in a second `Image`. And the
menu and label are materialized once, so the item's `.id(...)` key must cover the
whole binding set — every number and state, not just one status.

**Status bar.** A chip per binding — status dot plus `#123` — each opening that
PR, capped at four with a `+N` overflow chip that opens the full list. The
cluster yields width to the path label the way the branch label already does.

**Sidebar.** The row indicator takes the same worst-state rule, so sidebar and
toolbar cannot disagree.

Dropdown and chip order is **bind order**, so a row does not move under the
cursor as CI states change.

With no bindings, no control appears anywhere — there is no empty-state chip.

### CLI and skill

- `tbd pr list` — bindings for the current worktree, or `--worktree <id>`.
- `tbd pr attach <number|url>` — insert a manual binding, clearing any tombstone.
- `tbd pr detach <number|url>` — tombstone a binding.
- `tbd pr bind --from-hook` — the hook entry point; reads payload JSON on stdin.

New RPC methods `pr.bindings`, `pr.attach`, and `pr.detach` back the first three;
`pr.list` and `pr.refresh` keep their present contracts.

The `tbd` skill gains a short entry covering `list`, `attach`, and `detach`, so an
agent asked to tidy a worktree's PRs can do it without being told the commands.

## Error handling and edge cases

- **Wrong repo** — a binding whose `owner`/`repo` does not match the worktree's
  resolved repo is rejected at bind time, reusing the comparison in
  `poisonedCacheEntries`. Owner and repo compare case-insensitively.
- **Unresolvable repo** — if the worktree's own repo cannot be resolved, the
  binding is deferred rather than rejected. Absence of evidence is not evidence of
  mismatch.
- **Deleted or inaccessible PR** — the binding is retained with its last known
  status. A PR that cannot be resolved is not evidence it does not belong.
- **Force-push or branch rename** — bindings are keyed by PR number, not by
  branch, so neither affects them. `head_branch` is descriptive only.
- **Worktree archived** — `ON DELETE CASCADE` removes bindings with the worktree.
- **Every binding detached** — the live set is empty, so the worktree falls back
  to the pre-binding single-PR merge path and can auto-archive on an observed
  merge. That fallback is what still covers a worktree whose only PR was
  rejected as wrong-repo or whose seed deferred on an unresolvable repo, so it
  cannot simply be deleted. Detaching every PR to *suppress* auto-archive is
  therefore not a supported gesture; turn auto-archive off for the worktree
  instead. A known residual.
- **Enterprise hosts** — the `host` column exists and defaults to `github.com`;
  the bind regex is `github.com`-only for now, so support is additive later.

## Testing

- Hook payload parsing — a `gh pr create` command with one URL, with several, with
  none; a non-create command whose output contains a PR URL (must not bind);
  malformed JSON.
- Deduplication — the same PR proposed by hook, branch match, and manual attach
  produces one row that keeps its first `source`.
- Tombstones — a detached binding is not resurrected by a poll or by a hook fire,
  and `attach` clears it.
- Cap — the 21st binding evicts a terminal one; with none evictable the new
  binding is dropped and logged.
- Merge rule — one binding merged (fires); three bindings, one merged (does not);
  three, all terminal with one merged (fires); three, all closed and none merged
  (does not).
- Cross-repo rejection, and deferral when the repo cannot be resolved.
- Pure presentation helpers — worst-state selection across each state combination,
  label text at N of 0, 1, and many, and the status-bar chip cap.

## Why no feature flag

The repo convention is that behavior which acts without a user gesture ships
behind a default-off flag. This change ships unflagged deliberately.

The hazardous direction for auto-archive is firing **too eagerly** — that is what
destroys state. The all-resolved rule is strictly more conservative than the rule
it replaces: identical at one binding, and strictly less likely to fire at more.
Its failure mode is a worktree that lingers, which one command corrects. The
cautionary precedent that motivates the convention, `auto_hibernate_enabled`,
failed the other way: it shipped default-on and could eat typed input, and
because `ADD COLUMN ... DEFAULT` backfills every existing row, disabling it later
required a forcing migration that also erased deliberate opt-ins.

The discovery and UI halves add surfaces without removing any, and no path
deletes or mutates repository state.

## Rejected alternatives

**Hook binding alone**, mirroring Claude Desktop exactly. It is the most precise
source and produces no false attributions, but TBD is not a single-agent tool:
Codex sessions and plain shells emit no hook, and every PR opened before this
ships would be orphaned — a regression against today's branch matching.

**Branch matching alone**, extended to return every PR on the worktree's
candidate branches. Fully agent-agnostic and needing no hook change, but
structurally unable to see a PR on a branch the worktree never checked out, which
is the case that motivates the work.

**Commit-keyed discovery** via `repos/{owner}/{repo}/commits/{sha}/pulls`, which
is how the Codex CLI finds a PR for a detached HEAD. It finds PRs with neither a
hook nor a branch match, but costs an API call per commit examined and will
attach PRs that another worktree genuinely owns whenever history is shared.
Available as a later addition if the layered sources prove insufficient.

**A JSON array column on `worktree`**, matching how `prStatus` is already stored
and how Claude Desktop persists its per-session list. The smallest possible
migration, but every update rewrites the whole blob, and enumerating tracked PRs
across worktrees — which the poll does on every tick — becomes a full scan and
decode.

**Deleting on detach** instead of tombstoning. Simpler schema, but auto-discovery
re-creates the row within one poll, so the user's removal would not survive.

**Designating a primary PR** and keeping today's merge semantics on it. The
smallest behavioral change, but it archives a worktree whose primary merged while
a subagent's PR is still open — precisely the state this feature exists to make
visible.

## Prior art

Three implementations were examined directly.

- **Claude Desktop** binds at creation from the agent's own tool traffic. Its
  `GitHubPrManager` watches Bash tool output for `gh pr create` and scrapes PR
  URLs from the result, and also accepts a structured `code_change_published`
  event from the CLI where supported. Both paths call one
  `bindPrFromUrl(sessionId, url, cwd, source)`. Bindings persist as a `prs[]`
  array in a per-session JSON file, deduplicated by number and repo, capped at 20
  with terminal-state eviction, each carrying a `dismissed` flag. Live status
  comes from GitHub's own GraphQL API, batched per repo with numbered aliases —
  the same query shape `PRStatusManager` already uses. Attribution is
  demonstrably not branch-derived: an observed session held three bound PRs on
  three branches while the session's own branch was a fourth, unrelated name. The
  dropdown's visual design could not be examined; the desktop bundle contains only
  the plumbing, and the UI is served remotely.
- **vibe-kanban** stores PRs in a table keyed by unique URL with a nullable
  workspace foreign key, returning a list per workspace, and exposes an
  `attach_existing_pr` path for PRs it did not create. Its archive routine waits
  for **all** open PRs on a workspace to merge. Its summary view collapses to the
  latest PR and puts the rest one click away.
- **The Codex CLI** does not solve this: its status line recomputes a single
  `Option<PullRequest>` per render from the current directory and persists
  nothing. Its cloud backend does model a list per task, keyed to the assistant
  turn that produced each PR, but the open-source client discards that list at the
  boundary.

Two findings from the wider survey shaped decisions above. GitButler deliberately
moved *away* from storing a PR number on branch metadata toward matching a
periodically resynced cache, and keeps an archived bit per branch rather than one
per workspace — which is why bindings here are reconciled every poll rather than
trusted indefinitely. And Cursor's background agents attribute by head-branch
match, with a reported failure where two PRs sharing a head branch resolve to the
wrong one — the ambiguity that a list, rather than a tie-break, removes.
