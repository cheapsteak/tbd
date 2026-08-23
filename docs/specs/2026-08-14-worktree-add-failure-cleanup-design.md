# Worktree-add failure classification and gated branch cleanup

`git worktree add -b <branch> <path> <base>` creates the branch before it
finishes its work, so any failure after that point leaves the branch standing.
This document records how TBD decides whether such a failure is worth retrying,
and how it withdraws a branch its own failed attempt created.

Both mechanisms live in `WorktreeLifecycle`, and both are reached only from an
explicit user gesture — an RPC-triggered create or revive. Neither runs from a
sweep, a timer, or any background pass.

## Why this exists

A stale `.git/config.lock` made every `git worktree add` in one repo fail after
git had created the branch. Each attempt left a `tbd/<name>` behind, and the
leak then masked its own cause: the next attempt reused the same name, failed on
the collision the first attempt had just manufactured, and reported *that* as
the error. The user saw "the folder or branch may already exist" for a stuck
lock file.

Two properties were missing. A failed operation did not withdraw what it
created, and the retry logic could not tell a cause a retry might fix from one
it could not.

## Failure classification

`WorktreeAddFailureKind` sorts a failed `worktree add` into what could still
help:

- **`baseUnresolvable`** — the base ref did not resolve. The *other* base branch
  may; the two-base loop exists for exactly this.
- **`nameCollision`** — the branch name, the path, or the checkout is taken.
  Base-independent, so further bases are pointless and only a fresh name helps.
- **`repoLevel`** — a corrupt repo, no disk, or an ambiguous base ref. A fresh
  name cannot help, so that leg is skipped. The *other base* is still tried
  because the refs resolve independently. For example, a local branch literally
  named `origin/<default>` can make the remote spelling ambiguous while the
  plain local `<default>` ref still resolves.
- **`gitUnusable`** — a timeout or spawn failure, i.e. not a `GitError` at all.
  Fails immediately. This is the one cause where a further attempt has a real
  cost — another full `GitManager.commandTimeout` — rather than a real chance.

### Unknown means stop, not retry

Recognized-recoverable stderr shapes are a narrow whitelist; everything else is
`repoLevel` and fails fast carrying git's own words.

The justification is an asymmetry. Misreading a recoverable cause as fatal costs
one attempt and surfaces a true error message. Misreading a fatal cause as
recoverable costs a leaked branch *per attempt* and buries the real error under
a collision of our own making — which is the bug this design exists to remove.

A consequence worth stating, because it is what makes the design safe to leave
alone: a future git version, or a phrasing nobody catalogued, can only ever
narrow what we retry. It cannot silently re-enable blind retrying.

The classifier reads `GitError.stderr`, so every git subprocess runs under
`LC_ALL=C`/`LANG=C` merged onto the inherited environment. Merged rather than
replaced — a bare dictionary would strip `PATH`, `HOME` and `SSH_AUTH_SOCK` from
every git call the daemon makes.

## Gated branch cleanup

A failed attempt removes its directory, prunes any worktree registration git
recorded, and deletes the branch it created. This is the first code in TBD that
deletes a local branch.

Deletion is governed by four gates. **Each closes a distinct way of being
wrong**, and that is the rule for changing the set: a fifth gate must name a
fifth failure mode, and a gate that cannot name one is decoration.

1. **Pre-existence.** A probe taken before the attempt positively answered
   "absent". Kept as a tri-state, so a probe that *failed* blocks deletion — not
   knowing is not the same as knowing it was absent.
2. **Git's own refusal.** Git said it refused because the name was taken. This
   is what closes the window between the probe and the attempt, where something
   else could have created the branch.
3. **Existence now.** The branch is actually there to delete.
4. **Tip match.** It points at the SHA this attempt would have written. Each
   call site knows that value: the base tip sampled *before* the attempt for the
   fresh-create legs, the remote ref's tip for a tracking checkout, the archived
   SHA for a revive, and for the fork-PR leg the fetched tip read once the fetch
   reports success.

Gates 1, 3 and 4 fail toward keeping the branch: a probe that did not answer, an
unresolvable expected SHA, an unreadable current tip and a mismatched one each
return before `branch -D`, and the reason is logged. Gate 2 is the exception,
covered below.

Beneath the gates, deletion uses `git branch -D` rather than plumbing
`update-ref -d`, because git itself refuses to delete a branch a live worktree
has checked out. Plumbing would not.

Legs that check out a branch the *caller* owns create nothing and delete
nothing. There the deleting helper is kept structurally off the code path rather
than called with a safe argument, so no single edit sits between the code and
data loss.

### The abstention, and why it needed a fourth gate

Gate 2 answers `false` both when git did not refuse and when its wording was not
recognized. `false` permits deletion, so an unrecognized refusal is an
**abstention, not a finding** — the one place in the design where an unknown
does not by itself mean "keep". Gate 4 exists to cover that: it depends on ref
content rather than message text, so a phrasing nobody catalogued cannot on its
own authorize a deletion.

## Rejected: surface leaked branches for manual cleanup

TBD could refuse to delete anything and instead report leaked branches for a
human to remove.

This is close to what we already had. The leaked branches were visible in `git
branch` the entire time, and one repo still reached 2,804 local branches against
109 live worktrees — a 374 KB `.git/config` rewritten in full on every `worktree
add`, which is what made the original lock failure plausible. Reporting a leak
more loudly does not fix a leak nobody acts on, and it would ship the bug while
adding a reporting surface to maintain.

Auto-deletion also restores an ordinary property rather than adding a capability:
the create either produces a worktree or leaves the repo as it found it.

## What would show this is wrong

Two triggers, and the second matters more than it looks.

1. **A branch deleted that TBD did not create.** Any such report flips
   auto-deletion to surface-only. The gates are designed so this should be
   unreachable without an external actor inside a sub-second window.
2. **The keep-reason log firing routinely in normal use.** That would mean the
   gates are abstaining on ordinary cleanups — the leak quietly returned while
   the code looks safe *precisely because* it never deletes anything. This is
   the failure that resembles success, and it is invisible without watching for
   it.

## Residual risk

An external actor that creates a branch of the same name from the *same base*
inside the probe-to-attempt window produces a tip identical to ours, so gate 4
passes. The window is narrowed, not eliminated.

`RepoSerializer` narrows who can be inside that window, but it covers two of the
three entry points rather than all of them. `handleWorktreeCreate` and
`handleWorktreeReviveConversationFresh` run their lifecycle calls inside
`repoSerializer.submit(repoID:)`, so for those two no second TBD-initiated
attempt on the same repo can be in flight. `handleWorktreeRevive` calls
`beginReviveWorktree` directly and unserialized — deliberately, so an RPC
connection is never held for the length of a `preSession` hook — and that path
reaches the same gated deletion. **The gates, not serialization, are what
constrain the delete.** On the revive path the possible occupants of the window
therefore include another TBD create in the same repo, alongside a human or
another tool acting on the repo directly.

Serializing that handler too is a known follow-up. It would change the
concurrency behavior of a path whose non-blocking shape is load-bearing, so it
belongs to a change of its own rather than to the gates described here.

On the fork-PR leg the branch is created by fetching `refs/pull/<n>/head` rather
than by `-b`. That refspec is deliberately unforced, so git refuses a colliding
update instead of overwriting it and gate 2 has a refusal to read. A colliding
branch the pull head *already contains* still fast-forwards rather than being
refused: no commits are lost, but the ref moves, which is why a free name is
chosen before the fetch rather than relying on git to refuse.

## Why no flag

Per `CLAUDE.md`, large or risky new behavior ships behind a default-off flag,
and "deletes or mutates persisted state" is an independently-sufficient trigger.

The rule targets behavior that acts on its own — a sweep, a timer, anything
"auto-". This deletion is neither autonomous nor a capability a user gains: it
is the withdrawal half of an operation TBD already performs, reached only from
an explicit create or revive. Default-off would ship the leak still open, since
the flag's "off" state is the bug.

The hazard a soak would surface is also the status quo: every gate but the
abstention in gate 2 fails toward keeping the branch, and keeping it reproduces
today's visible, recoverable leak.
