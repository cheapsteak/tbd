# Foreign worktree sweep

A user-land script, `scripts/sweep-foreign-worktrees.sh`, that reports git
worktrees created outside TBD and removes the ones that are provably finished.
No daemon code, no migration, no flag. Upstream issue: #920.

## Problem

Git worktrees created outside TBD — by another agent tool in its own
directories, or by hand — have no lifecycle. TBD's archive flow, `tbd gc` and
OrphanGC only see worktrees TBD created or Claude Code agent worktrees under
`<repo>/.claude/worktrees/`; everything else accumulates until someone notices
the disk.

Field evidence from one fleet machine: 77 such worktrees. 33 of them had a
merged PR and a clean tree. Of those 33, 18 had HEAD contained in the merged
PR's head commit, so every commit in them is already in the PR that merged; 10
had HEAD moved past it, meaning someone kept working after the merge.

The second group matters as much as the first. A worktree whose HEAD moved past
its merged PR may hold the start of follow-up work, and it looks identical to a
finished one if all you check is "has a merged PR".

## Placement: user-land, not a compiled collector

The obvious home is a fourth OrphanGC collector. It is not used, for the reason
in the root `CLAUDE.md` rule "Compile only what user-land cannot do well" and its
long form, [`docs/theory-placement.md`](../theory-placement.md).

"Merged PR + clean tree + HEAD contained in the PR head + idle 24 hours means
safe to delete" is a theory, not a fact. Two reasonable projects can disagree
with it: one keeps scratch branches alive after merge on purpose, another treats
ignored files (local `.env`, build caches) as worth keeping, another has no
GitHub at all. Compiled, that theory changes by rebuild and release and ships as
a default to every TBD user. As a script it changes by editing a file, and it
runs only when an operator invokes it.

Nothing about the job needs the daemon. It is neither per-event across a fleet
nor a liveness attestation nor an integrity-of-record concern: it reads
`git worktree list`, asks `gh` one question per candidate, and calls
`git worktree remove`. If field use shows the theory holds and an always-on
sweep is wanted, capability can migrate inward later, one piece at a time.

## Named reconciler

This script is the reconciler for linked git worktrees that no other sweep
owns: listed by a repo TBD knows about, not managed by TBD, and not an OrphanGC
agent worktree. It creates no durable resource it does not also account for:
its salvage directories are operator-owned records under TBD's config dir,
removed by hand, and its `refs/salvage/*` refs exist precisely to outlive the
worktree they protect.

## Discovery

- **Repos** – every repo TBD has registered (`tbd repo list --json`), plus each
  `--repo <path>`. A `--repo` value must be exactly a git toplevel; anything
  else is an error and nothing runs. Registered repos that fail the same test
  (for example, missing on disk) are skipped with a log line. Repos sharing one
  git common dir are walked once.
- **Worktrees** – a path is a candidate only because `git worktree list
  --porcelain` listed it. The script never globs. A directory that merely holds
  worktrees, such as `<home>/tbd/worktrees/wt-12345/`, is not a git toplevel,
  so it is rejected both as `--repo` and as `--salvage-remove`, and nothing
  inside it is touched.
- **Exclusions** – the repo's main worktree (git lists it first); every
  worktree TBD manages, in any status, per `tbd worktree list --json` and
  `--status archived`; and OrphanGC's own `<repo>/.claude/worktrees/agent-*`
  and `wf_*`, reported as `KEEP orphan-gc-owned` so the two sweeps never share a
  resource. If TBD cannot be asked for its worktree list, the script refuses to
  run rather than guess.

## Auto tier

A candidate is `AUTO` only when every condition holds. Anything uncertain is
`KEEP`, with the reason on the report line.

- **Not locked** – a worktree locked with `git worktree lock` is never
  auto-removed.
- **A merged PR contains HEAD** – the PR is found with `gh pr list --state
  merged --head <branch>`, or for a detached HEAD with `gh pr list --state
  merged --search <sha>`. Containment is `git merge-base --is-ancestor HEAD
  <headRefOid>`. When the PR's head object is not present locally the script
  tries one fetch of it; if it is still absent, or `gh` is missing or fails, the
  verdict is `KEEP`.
- **Clean tree** – `git status --porcelain` is empty once the single untracked
  entry `?? .context/` is ignored. That directory is per-worktree agent notes,
  salvaged before removal. Status runs with `--no-optional-locks` so a report
  run never refreshes the index and defeats the idle test of the run after it.
- **No live process** – one `lsof -d cwd,txt` pass; a candidate is kept when any
  process has its cwd, its executable or a mapped binary under the path. Paths
  are canonicalized on both sides, so macOS `/tmp` and `/private/tmp` compare
  equal. If `lsof` is unavailable every candidate is kept.
- **Idle** – no file in the worktree, and neither the worktree's gitdir `HEAD`
  nor its `index`, modified within `--idle-hours` (default 24). An unreadable
  tree counts as recently touched.

A candidate with a merged PR whose head does not contain HEAD is reported
`FOLLOW-UP` — possible follow-up work — and is never removed.

The default run is a report, one line per candidate: `AUTO <reason> <path>`,
`KEEP <reason> <path>` or `FOLLOW-UP <reason> <path>`. `--apply` removes `AUTO`
candidates only. Each removal first copies `.context/`, if present, into
`<salvage-root>/<YYYYMMDD>/<name>/.context`, and a failed copy blocks the
removal. Removal is `git worktree remove --force --force <path>` run from the
owning repo. Ignored files in the worktree (dependency installs, build output,
local env files) go with it; a project that wants those kept runs the operator
tier instead, or does not use `--apply`.

## Operator tier

`--salvage-remove <path>` takes exactly one explicit path, which must be a
git-listed, non-main worktree that TBD does not manage. Without `--apply` it
prints what it would salvage and does nothing. With `--apply` it runs these
steps in order, and the removal happens only if every earlier step succeeded:

1. `INFO.txt` – path, owning repo, branch or `DETACHED`, HEAD sha, last commit
   date and subject.
2. `refs/salvage/<name>-<YYYYMMDD>` pointing at HEAD, created in the owning
   repo and never overwritten (a later run suffixes `-2`, `-3`, …). Commits that
   live on no branch survive the removal through this ref.
3. `uncommitted.patch` – `git diff HEAD --binary`, omitted when empty.
4. `untracked.tar.gz` – the files from `git ls-files --others
   --exclude-standard`, outside `.context/`. Their total is capped by
   `--untracked-cap-mb` (default 300). Over the cap the script writes
   `untracked-files.txt` instead and aborts the removal; the operator re-runs
   with a higher cap, or passes `--allow-untracked-loss`, the only way past the
   cap.
5. A copy of `.context/`.
6. `git worktree remove --force --force <path>` from the owning repo.

The operator tier refuses outright when a live process has its cwd or a binary
under the path. It removes a locked worktree, since naming one explicitly is the
operator's decision.

The salvage root is `--salvage-dir`, or `${TBD_HOME:-$HOME/tbd}/salvage` by
default; entries are `<root>/<YYYYMMDD>/<name>`, and an existing entry is never
written into — a new one is suffixed instead.

There is no `rm -rf` fallback anywhere. If `git worktree remove` fails, the
worktree stays and the failure is reported.

## Testing

`scripts/sweep-foreign-worktrees.test.sh` builds real repos with real linked
worktrees under one `mktemp -d` root and fakes `tbd`, `gh`, `lsof` and the PR
head fetch behind env seams. Shims for the real tools sit first on `PATH` and
fail loudly, and `SWEEP_FW_REQUIRE_SEAMS=1` makes the script refuse to run with
a seam unset. It runs in CI with the other script harnesses and needs git and
`jq`, no build.

## Rejected alternatives

- **A compiled OrphanGC collector** – encodes a disputable deletion theory as
  a shipped default and changes only by release; see Placement above.
- **A remote-branch or "unpushed commits" check** – deliberately absent. Merge
  queues squash, so the commits in a worktree are often on no remote branch even
  when their content merged; an "unpushed" test reports finished work as at
  risk, and a "branch deleted on the remote" test says nothing about whether the
  content landed. Containment in the merged PR's own head commit answers the
  question that matters directly.
- **Globbing known tool directories** – a glob finds directories, not
  worktrees, and cannot tell a worktree from a directory that holds worktrees.
  Asking git is the only source that cannot mistake one for the other.
- **An `rm -rf` fallback when `git worktree remove` fails** – a failure there
  is information (a locked tree, a permission problem, a path git does not own),
  and deleting through it would destroy exactly the cases the checks exist for.
- **Adopting candidates into TBD automatically** – adoption (`tbd worktree
  adopt`) changes what the TBD UI shows and is a separate decision; this script
  only reports and removes. An adoption UI stays open under #920.
