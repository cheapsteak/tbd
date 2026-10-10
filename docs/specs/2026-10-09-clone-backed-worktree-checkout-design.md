# Clone-backed worktree checkout

## Summary

Every TBD worktree is created with `git worktree add`, which writes every
tracked file. On APFS those bytes are shared with no other checkout, so each
worktree of a large repository costs its full checkout size in real disk.
Field measurement on a repository with 24,264 tracked files found 437 MB of
tracked checkout per worktree. A block-level check (`fcntl(F_LOG2PHYS)` on the
first block of the 30 largest tracked files, compared across two worktrees)
found 0 of 30 shared. As a control, a `cp -c` copy shared its block and a plain
`cp` copy did not. Dependency installs on that machine were already clone-backed
(`uv` with `UV_LINK_MODE=clone`, pnpm), so the checkout was the dominant
per-worktree cost. On a day when an agent fleet created 33 worktrees in seven
hours, the checkouts alone came to about 17 GB.

This design creates a fresh worktree by cloning a per-repo template checkout
with `clonefile(2)` and then letting git rewrite only the files that differ
from the worktree's base. Unchanged files share the template's blocks, so a new
worktree costs metadata plus its diff from the template instead of a full
checkout. Git semantics are unchanged: each worktree still has its own branch,
HEAD and index, a clean `git status`, and its `post-checkout` hook run once with
the arguments `git worktree add` gives it.

It ships behind `clone_checkout_enabled`, default off.

**Status: proposal.** This design did not go through `/tbd-brainstorming`. Its
open choices are proposals for review, not settled decisions: the scope limited
to fresh creates, a template refresh triggered by creates rather than a timer,
GC reclaiming every template while the flag is off, and the clean-status give-up
limit of three.

## Goals

- A new worktree on an APFS volume costs, in real bytes, roughly the size of
  the files that differ between its base and the template, not the whole
  checkout.
- The worktree is indistinguishable to git and to its user from one made by
  `git worktree add`: branch, upstream (none), HEAD, its own index, a clean
  status, the same `post-checkout` invocation.
- Any failure of the new path produces the ordinary checkout, not a failed
  create. On a volume that cannot clone, behavior is today's.

## Non-goals

- Existing-branch, remote-tracking, fork-PR and revive checkouts. They keep the
  plain `git worktree add`. The fresh create from the default branch is the
  path a fleet exercises, and the others can follow once this one has soaked.
- Untracked build outputs and dependency directories. Package managers already
  have clone modes for those.
- Reclaiming space from worktrees that already exist.

## Design

### The template

Each repo gets one template under `~/tbd/repos/<repoID>/checkout-template/`:

- **`tree/`** – the tracked files of one commit, and nothing else: no `.git`,
  no untracked files.
- **`index`** – that tree's own index file.
- **`commit`** – the SHA the tree holds. Written last, so a template is only
  ever read as present once it is complete.

The template is not a git worktree. It is written through the repository's
object store with `git --git-dir=<common dir> --work-tree=tree` and
`GIT_INDEX_FILE=index`, so it never appears in `git worktree list`, holds no
HEAD, and cannot be mistaken for a worktree by reconcile or by the foreign
worktree sweep. Filters (LFS and the like) run when it is written, as for any
checkout; hooks do not.

`~/tbd` lives on the same volume as the default worktree location, which
`clonefile` requires.

### Creating a worktree

1. **`git worktree add --no-checkout --no-track <path> -b <branch> <base>`.**
   Registration, branch, HEAD and `.git` file, but no files and no index. Same
   arguments as today plus `--no-checkout`, so a refusal (branch taken, base
   unresolvable) produces the same stderr and the existing failure
   classification and cleanup apply unchanged.
2. **Clone.** `clonefile(2)` each top-level entry of `tree/` into the worktree,
   with `CLONE_NOFOLLOW` so a tracked symlink is cloned as the link. A
   directory clones as a whole hierarchy in one call.
3. **Index the clone.** `git read-tree <template commit>`, then
   `git update-index -q --refresh`. The refresh reads and hashes the cloned
   files once and records their stat data; it writes no files.
4. **Move to the base.** `git reset --hard` to HEAD. With the index refreshed,
   this is a two-way merge from the template's commit to the base: git rewrites,
   creates and deletes only the paths that differ, and leaves every other file
   — and its shared blocks — alone.
5. **Verify.** `git status --porcelain --ignored` must be empty. Nothing has
   run in the worktree yet, so any entry at all — an ignored `.DS_Store`
   included — came from the template. A template that fails this check is
   invalidated, and the next refresh rebuilds it from scratch.
6. **`post-checkout`.** `git hook run --ignore-missing post-checkout -- <null
   SHA> <HEAD> 1`, the invocation `git worktree add` makes. A failing hook fails
   the create, as it does today.

If any of steps 2–5 fails, the worktree is emptied (keeping `.git`), its index
is reset to HEAD, and `git reset --hard` writes every file: an ordinary
checkout. Step 6 still runs once. So a missing, stale or torn template, a
volume that cannot clone, or a template on another volume costs the time of a
normal checkout and never a failed create. `clonefile` failing with `ENOTSUP`
or `EXDEV` marks the repo unsupported until the daemon restarts and deletes its
template, so neither clones nor template refreshes are attempted for it again.
A template is never built on a volume that reports it cannot clone.

The same give-up applies after three clones of a repo in a row fail the status
check in step 5. A single failure is a torn template: it is invalidated, and the
next refresh rebuilds it from scratch. The same failure after every rebuild
means the repo's own checkout never reads clean (line endings, a filter that
does not round-trip), and without a limit each create would pay a full
template write and a full worktree write.

A cancelled create rethrows instead of falling back, since the cancellation
would cut the full write short too. A git timeout inside steps 2–5 falls back
like any other failure; the full write has its own bound.

### Keeping the template current

After each flagged create, the template is moved to that worktree's HEAD in the
background: `update-index --refresh` against its own index, then
`read-tree -m -u <new commit>`, which writes only the paths that changed. A
template that has drifted from its index makes the merge refuse, and the
template is rebuilt from scratch with `read-tree --reset -u`. The first flagged
create for a repo finds no template, writes in full, and builds the template
afterwards.

Because creates in a fleet start overwhelmingly from the tip of the default
branch, the template trails that tip by at most the commits between two
creates, and the per-create diff stays small.

Clones and refreshes of one repo exclude each other without waiting. A create
that finds a refresh running writes in full. A refresh that finds a clone
running is skipped, and the next create triggers another. The exclusion lives
in one process-wide actor; the status check in step 5 is the backstop for
anything outside it.

### Orphans

`OrphanGC` gains `reclaimCheckoutTemplates`, under `gcEnabled`. It removes a
template whose repo row is gone, and every template while
`clone_checkout_enabled` is off, so turning the feature off returns the space
within one sweep. A template is a cache TBD wrote and can rebuild; removing one
that a create is using costs that create a full checkout.

## Flag and rollout

- **Flag** – `clone_checkout_enabled` on the `config` row, no SQL default, so
  NULL ("never chose") stays distinct from 0. The shipped default lives in
  `Config.cloneCheckoutDefault` (`false`).
- **Enable for the soak** – `tbd config set clone-checkout on`. It is read on
  every create, so it takes effect at the next worktree with no restart.
- **Soak signal** – the `cloneCheckout` log category says, per create, whether
  it cloned (and from which template commit) or wrote in full (and why).
  Physical disk use per new worktree, measured with `df` across a batch of
  creates, is the outcome the soak is for.
- **Graduation** – flip `Config.cloneCheckoutDefault` once a soak on a large
  repository shows the per-worktree saving with no clean-status fallbacks
  beyond the expected first create, then extend the path to the other
  checkout kinds.

## Costs and risks

- **Create time.** The refresh in step 3 reads and hashes the whole checkout
  once, because `read-tree` leaves no stat data to trust. Measured on the
  22,362-file field repository, a clone-backed create took 1.2× (template at
  the base) to 2× (template 20 commits behind) as long as a plain one: 10.3 s
  against 8.6 s, and 7.1 s against 3.6 s. The `clonefile` calls themselves take
  about 2 s for the whole tree. The trade is a few seconds per create for about
  450 MB per worktree.
- **Rejected: trusting the template's stat data to skip the hash.** Seeding the
  worktree's index from the template's own index and refreshing with
  `core.checkStat=minimal` would match on mtime and size alone and hash nothing.
  But each entry would keep the template file's inode and ctime, so the user's
  first `git status` under default settings would see every entry as changed and
  hash the whole tree there instead, on the person's time rather than the
  daemon's. It would also weaken the check that makes a torn template harmless,
  from content to mtime and size.
- **One template per repo.** It costs one checkout of disk, once. It is shared
  by every worktree cloned from it, and blocks it drops in a refresh stay owned
  by the worktrees still holding them.
- **Uses git 2.36** for `git hook run` in step 6. The store reads
  `git --version` once per daemon. On an older git, or one whose version it
  cannot read, a flagged create is the plain `git worktree add` (which runs the
  hook itself) and no template is built. macOS's bundled git has been newer
  than 2.36 since 2022.
- **Sparse checkout and submodules.** A template holds the full tracked tree.
  A repository relying on per-worktree sparse checkout gets a full one under
  this flag. Submodules are left uninitialized, as `git worktree add` leaves
  them.

## Evidence

- A shell prototype of steps 1–6, run against a 26,435-file repository with
  the template 300 commits behind the base, rewrote exactly the 4,133 paths
  that differ between the two commits (added, modified or type-changed) and no
  others. The file count on disk matched `git ls-files`, so files deleted
  between the commits were removed, and `git status --porcelain --ignored` was
  empty. With the template at the base, it rewrote zero files. The
  `post-checkout` hook received `<null SHA> <HEAD> 1`, the arguments
  `git worktree add` passes. Moving the template forward 300 commits took about
  one second.
- `Tests/TBDDaemonTests/CheckoutTemplateStoreTests.swift` pins the same
  properties on a small repository, including that an unchanged file's first
  physical block (`F_LOG2PHYS`) is the template's on a volume that can clone,
  and that a stray file in the template triggers the full-checkout fallback.
