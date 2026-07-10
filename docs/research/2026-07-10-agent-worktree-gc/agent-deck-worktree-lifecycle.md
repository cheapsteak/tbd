# agent-deck: git worktree lifecycle & cleanup (research report)

*Researched 2026-07-10, from a local checkout of `github.com/asheshgoplani/agent-deck` (v1.10.9), as prior art for TBD's disk-reclaim / agent-worktree GC work (PR #423, issue #420). Companion report: [`ecosystem-prior-art.md`](ecosystem-prior-art.md).*

Context: Claude Code's `isolation: worktree` subagents create worktrees under `<repo-root>/.claude/worktrees/agent-*` that accumulate forever (81 worktrees / ~tens of GB in one incident), because nothing links them back to the spawning session and nothing GCs them once they contain commits. This report answers how agent-deck (a tmux-based AI agent pane/worktree manager, written in Go) handles the same or analogous problems.

## 1. Where/how worktrees are created (path layout)

Worktree paths are computed by `GenerateWorktreePath` in `internal/git/git.go:343-375`. The layout is **user-configurable via a `location` setting**, not a fixed hidden dir:

- Default (`"sibling"` or empty): `<repoDir>-<sanitized-branch>` — a *sibling* of the repo, outside it (line 373).
- `"subdirectory"`: `<repoDir>/.worktrees/<branch>` (line 371).
- Custom path (contains `/` or starts with `~`): `<expanded>/<repoName>/<branch>` (line 362).
- Bare-repo-at-root: `<repoDir>/<branch>` (line 366).

Notably the **default keeps worktrees as siblings, not nested inside the repo** — the opposite of Claude Code's `<repo>/.claude/worktrees/agent-*`.

There is also a richer template path system (`internal/git/template.go:120-139`) supporting a `{session-id}` token filled by `GeneratePathID()` — an 8-char random hex — so paths can be made per-session-unique.

Creation happens through `CreateWorktree` (`git.go:379-427`), `CreateWorktreeAtStartPoint` (fork-with-state, anchors at parent HEAD, `git.go:447-467`), and multi-repo `CreateMultiRepoWorktrees` (`internal/session/multi_repo_worktree.go:18-60`). Session creation wires provenance in `cmd/agent-deck/session_cmd.go:815-973` and `cmd/agent-deck/launch_cmd.go:450-452`.

One robustness detail worth stealing: when creating a *new* branch, `CreateWorktree` (`git.go:409-418`) fetches `origin`'s default branch and roots the new branch there rather than at the caller's possibly-stale local HEAD — a fix for regression #973 (a "414-file near-miss" where a worktree was branched off an old tag).

## 2. Provenance (which session owns which worktree)

Provenance is stored **in the session record**, three fields carried on every `Instance` and persisted to the SQLite/JSON store:

- `internal/session/instance.go:145-147`: `WorktreePath`, `WorktreeRepoRoot`, `WorktreeBranch`.
- Persisted in `internal/session/storage.go:65-67` (and 743-745, 859-861).

So the ownership link is a **DB row → path mapping**, the inverse of the `.claude/worktrees` problem: agent-deck always knows which session created which worktree because it records it at creation. There is **no marker file inside the worktree**; instead git's own admin metadata (`.git/worktrees/<id>`) is used as the location-independent proof of "we created this" (see `IsLinkedWorktree`, below).

Multi-repo sessions additionally track `MultiRepoTempDir` and a list of `MultiRepoWorktrees{OriginalPath, WorktreePath, RepoRoot, Branch}` (`multi_repo_worktree.go:46-51`).

## 3. Cleanup / removal story

There are **four removal paths**, all funneling through conservative guards:

**a) Session dismiss (TUI) — `internal/ui/home.go:11300-11356`.** On delete it snapshots (under lock) whether another live session shares the worktree (#1449), then in an async closure kills tmux and calls `session.RemoveSessionWorktree(snap)`. If shared, it *skips* destructive removal and just drops the row (lines 11321-11325).

**b) The session-layer guard — `internal/session/worktree_removal.go`.** This is the heart of the safety model. `IsRemovableWorktree` (lines 26-39) permits deletion **only when ALL hold**:
1. Both `WorktreePath` and `WorktreeRepoRoot` are recorded (line 32).
2. The worktree path is **not** the original repo root — canonical/symlink-resolved compare (line 35, `canonicalPath` at 107-121 handles macOS `/var` vs `/private/var`).
3. `git.IsLinkedWorktree(wt)` confirms git itself considers it a linked worktree (line 38).

`RemoveSessionWorktreeUnlessShared` (lines 96-101) adds the "no other live session references it" guard before removal. The header comment (lines 10-25) explicitly frames this as guarding against issue #1200 — "a false positive means `os.RemoveAll` on a real repository (silent data loss)".

**c) `IsLinkedWorktree` — `git.go:550-577`** is the load-bearing check. Primary signal: `git rev-parse --absolute-git-dir` and check the parent dir is named `worktrees` (i.e. `<repo>/.git/worktrees/<id>`). Fallback for an *orphaned* linked worktree whose admin entry was already pruned: read the worktree's `.git` *file* (a linked worktree has a `.git` file `gitdir: .../worktrees/<id>`; the main tree has a `.git` *directory*) — so orphans still clean up while the original repo stays protected.

**d) `RemoveWorktree` — `git.go:584-638`.** Runs a pre-removal hook (see §4), then `git worktree remove [--force]`. If force-remove still fails (e.g. `node_modules` making the dir non-empty), it falls back to `os.RemoveAll` — but **only after two refusals**: refuses if the path is a git dir (`isGitDir`, protects submodule history), and refuses if `!IsLinkedWorktree` (lines 628-630: "better to leak a directory than to destroy the user's repo (#1200)"). Then `PruneWorktrees` to drop stale admin refs.

**e) `worktree finish` command — `cmd/agent-deck/worktree_cmd.go:482-704`.** The merge-and-cleanup path: dirty check (`HasUncommittedChanges`, line 555, overridable with `--force`), auto-detect target branch, refuse merge-into-self, confirm prompt, then merge → remove worktree → delete branch → kill tmux → remove session row. Merge failure auto-aborts (line 632). Branch delete uses git's `-d` unless `--force` (`DeleteBranch(worktreeBranch, *force)`, line 655) — so an unmerged branch is protected by git's own `-d` refusal.

**f) `worktree cleanup` command (the reaper/GC) — `worktree_cmd.go:274-479`.** This is the explicit garbage-collector. It detects two orphan classes:
- **Orphaned sessions**: `WorktreePath` set but directory missing (lines 309-316).
- **Orphaned worktrees**: exist on disk but no session points to them — built by diffing `backend.ListWorktrees()` against the set of session paths (lines 325-350).

**Dry-run by default** (`--force` to act), with a `y/N` confirm (lines 417-427). This is a manual command, not a scheduled reaper.

**g) CLI `session remove --prune-worktree` — `cmd/agent-deck/session_remove_cmd.go:205-217`.** Registry-only removal by default; `--prune-worktree` opts into the destructive path (`pruneSessionWorktree` → `RemoveWorktree(..., true)` + `PruneWorktrees`).

Safety guards summary: dirty check (finish), unmerged-branch protection (git `-d`), live-sibling-session check (#1449), reused-repo/non-linked-worktree refusal (#1200), git-dir/submodule refusal. There is **no background auto-reaper** — cleanup is either event-driven (session delete/finish) or manual (`worktree cleanup`). Session delete also offers a 30-second undo window.

## 4. Disk-space management

agent-deck does **not** itself scrub `node_modules`/`.venv`/`.build`. Instead it provides a **user-defined pre-removal hook**: `.agent-deck/worktree-destruction.sh`, discovered by `FindWorktreeDestructionScript` (`internal/git/setup.go:190-198`) and run by `RunWorktreeDestructionBeforeRemove` (`setup.go:207-224`) from inside `RemoveWorktree` *before* deletion, gated on `IsLinkedWorktree` so it never fires on the main tree. Bounded by `DefaultWorktreeDestructionTimeout = 60s` (`setup.go:188`), non-fatal on failure. This is where a user would put `rm -rf node_modules` etc.

Complementary: `.worktreeinclude` (`internal/git/worktreeinclude.go:16-22`) copies selected gitignored files *into* a new worktree (explicitly modeled on Claude Code Desktop's feature) — the create-side analog.

Separately there is log/orphan maintenance on a timer (`internal/ui/home.go:5976-6005`, `RunLogMaintenance` every 5 min) and SSH ControlMaster socket sweeping (`home.go:2662`), but these are for logs/sockets, not worktree disk.

## 5. Awareness of Claude Code's own `.claude/worktrees/agent-*`

**Yes — explicitly, and treated as foreign/hostile debris to avoid, not to manage.** Evidence:

- `.gitignore:69` lists `.claude/worktrees/` (added in PR #897 after two orphaned `agent-*` gitlinks were accidentally committed).
- `CHANGELOG.md:1194` documents PR #897: *"Two gitlinks (`.claude/worktrees/agent-a3b98724`, `.claude/worktrees/agent-af955763`) were committed without a corresponding `.gitmodules` entry — orphaned submodule references from stale Claude Code worktrees that no longer exist."*
- `internal/tmux/tmux_exec_lint_helpers_test.go:22-30` prunes `.claude` and `.claude/worktrees/` from its file walk, commenting: *"nested worktrees under `.claude/worktrees/` are transient agent checkouts of older commits and must not feed the allowlist scan."* Note it lumps `.git`, `node_modules`, `vendor`, `.worktrees`, `.claude` together as skip-dirs.
- `documentation/webui-overhaul-plan.md:77`: *"The `.claude/worktrees/agent-*` dirs in the repo are leftover from earlier today's parallel agent runs … they are cleanup debt, not concurrent implementers."*
- Claude's transcript convention (`agent-*.jsonl` sub-agent files) is filtered out in `internal/session/claude.go:623,638`, `migrate.go:99`, `global_search.go:696`.

So agent-deck **recognizes** Claude's agent worktrees exist and are cleanup debt, defensively gitignores/skips them — but it does **not** GC them. It solves the accumulation problem for *its own* worktrees by never creating them under `.claude/` and by recording provenance in its DB.

## Lessons applicable to TBD

1. **Record provenance at creation, in your store, not in the worktree.** agent-deck's whole model works because every worktree has a DB row (`WorktreePath`/`WorktreeRepoRoot`/`WorktreeBranch`). The `.claude/worktrees/agent-*` leak exists precisely because nothing records the spawning session. If TBD spawns/owns subagent worktrees, stamp session→worktree ownership in the daemon's store (or a marker file inside the worktree if creation can't be intercepted).

2. **A `worktree cleanup`-style orphan reaper is cheap and high-value.** The two-way diff (`worktree_cmd.go:325-350`) — (a) session rows whose dir is gone, (b) `git worktree list` entries with no owning session — is exactly the sweep that would have caught the 81-worktree incident. Make it dry-run-by-default. TBD could additionally reap by "no live tmux/process + branch merged/empty."

3. **Gate every destructive delete behind a location-independent "is this really a linked worktree we made" proof.** `IsLinkedWorktree` (`git.go:550-577`) — check `git rev-parse --absolute-git-dir` ends in `.git/worktrees/<id>`, with a `.git`-is-a-file fallback for orphans — is far safer than a path-prefix check, and its comments enumerate the exact data-loss bugs (#1200) it prevents. Because Claude places worktrees *inside* the repo under `.claude/worktrees/`, a naive prefix match is risky; the git-linked check is robust.

4. **Layer the safety guards** the way agent-deck does before any `os.RemoveAll`: (a) path != repo root (symlink-canonicalized), (b) git confirms linked worktree, (c) not a git/submodule dir, (d) no other live session shares it (#1449), (e) dirty/unmerged checks with explicit `--force`. Each maps to a real incident number in their history.

5. **Provide create/destroy hooks rather than hardcoding `rm -rf node_modules`.** The `.worktreeinclude` (copy-in) + `.agent-deck/worktree-destruction.sh` (pre-remove, timeout-bounded, non-fatal) pair lets users manage heavy artifacts without the tool owning that policy. The destruction hook running *before* removal while the tree still exists is the right ordering for cleanup scripts.

6. **Default worktrees to a location you fully control and can enumerate.** agent-deck defaults to *sibling* dirs and offers a `{session-id}`-templated unique path (`template.go:135`). For TBD, either keep agent worktrees out of `.claude/` (so Claude's own tooling doesn't also touch them) or, if they must live under `.claude/worktrees/agent-*`, treat every `agent-*` entry as reap-eligible once no live session references it — since Claude itself never GCs committed ones.
