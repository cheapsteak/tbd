# A named reconciler for every durable external resource

TBD's durable state does not live in TBD. Worktrees are git's, windows and
servers are tmux's, agent processes are the OS process table's, and scratchpads,
sockets and build directories are the filesystem's. None of those systems clean
up after a supervisor that dies mid-operation. This document records how TBD
defends against the orphans that follow, and the question every PR introducing a
new durable resource has to answer.

## Why this exists

Multi-step creation against an external system cannot be made transactional.
`git worktree add -b` creates the branch before it finishes its work; tmux
creates a server the moment a session is requested; a spawned agent exists from
`fork` onward. In every case the external system commits before TBD records the
intent, so a crash, a cancellation, or a partial failure in the window between
them leaves a resource that nothing owns and nothing remembers. Rollback on the
creating path narrows that window; it cannot close it, because the window
includes the death of the process that would perform the rollback.

What has actually held the line is reconciliation: a background pass that
enumerates ground truth, compares it against recorded intent, and reclaims the
difference. Three reconcilers do this work:

- **`OrphanGC`** (`Sources/TBDDaemon/GC/OrphanGC.swift`) – hourly when
  `gcEnabled` (the default), over agent worktrees, scratchpads, the deletion
  queue, and stale git registrations.
- **`AgentReaper`** (`Sources/TBDDaemon/Process/AgentReaper.swift`) – once at
  daemon start for cold recovery, then every 60 seconds, over orphaned agent
  processes.
- **`WorktreeLifecycle+Reconcile`**
  (`Sources/TBDDaemon/Lifecycle/WorktreeLifecycle+Reconcile.swift`) – at startup
  and on demand, reconciling DB rows against git worktrees and tmux windows and
  servers.

The field evidence splits cleanly along the line of what those sweeps cover.
Every unbounded leak measured in the wild sat on a resource no sweep covered:

- **2,804 local branches** in a single repo, left by `git worktree add`
  attempts that failed after git had already created the branch.
- **~7,100 dead tmux socket files** accumulated in nine days, because tmux never
  unlinks a socket when its server exits — a leak no teardown can undo, only
  fencing or sweeping.
- **~36 GiB** of abandoned agent worktrees in one incident, persisting with
  their gitignored build directories because nothing enumerated them.
- **Zombie agent processes**, which accrued silently: nothing reported them, so
  the leak was invisible until someone looked at the process table.

Meanwhile every resource a reconciler covers has stayed healthy in the field
regardless of how careful its creating path's rollback was. The asymmetry is the
whole argument. It also explains why the principle stayed implicit for so long:
each of the three reconcilers was invented on its own, after its own leak had
already been measured, so the repo accumulated three instances of a rule nobody
had written down. Writing it down is what moves the cost from "measure a leak in
the field" to "answer a question in review".

## The decision

The doctrine is a **review-time question, not a new mechanism**. No abstraction,
base protocol, or registry is introduced. A PR that introduces a new kind of
durable external resource, or a new creation path for one, must answer who
reclaims its orphans, and exactly three answers are acceptable:

- **Name the covering reconciler** — usually by extending an existing one with a
  new collector, which is the cheapest answer and the expected one.
- **State why an orphan cannot arise** — in the PR description, as an argument a
  reviewer can check.
- **Point to a committed spec that deliberately chose create-time cleanup**
  instead. [`2026-08-14-worktree-add-failure-cleanup-design.md`](2026-08-14-worktree-add-failure-cleanup-design.md)
  is the shipped precedent: it withdraws a branch its own failed `git worktree
  add` created, from the failing call itself, reached only from an explicit user
  gesture and from no sweep, timer, or background pass.

An unanswered question is a **Medium-severity** finding from the `conventions`
specialist of the PR-review gate, alongside that specialist's other CLAUDE.md
rules. The rule carries a carve-out: **routine call sites that create a resource
through a path an existing reconciler already covers are not flagged**, because
they introduce nothing new to reclaim.

The severity is deliberately Medium rather than High. The failure this prevents
is slow and recoverable — a leak that grows until someone measures it — not
corruption or data loss, and the cost of a false positive is a reviewer and an
author arguing about a resource that was already covered.

## Judging what the rule covers

The rule turns on judgment, so it needs calibration rather than a pattern to
match. Three questions decide a case.

**Is it a new kind of resource?** A new kind is a resource class that no existing
collector enumerates. If a sweep would have to learn a new place to look, or a
new shape to recognize, it is new. Examples: a new directory family under
`~/tbd`, a new git ref namespace, a new socket or pid file, a new class of
spawned process. The test is not whether the resource is novel in the abstract
but whether anything currently sweeps for it.

**Is it a new creation path?** A new path is a second piece of code that mints an
already-known kind of resource outside the helper the reconciler was written
against. The kind is covered; the path is what escapes, because reconcilers are
usually written to enumerate what one helper produces, and a second minting site
can produce instances the enumeration misses — a branch created under a naming
scheme the collector does not recognize, or a process spawned without the
metadata the reaper matches on. A new path answers the question by showing its
instances are enumerable by the existing sweep, or by extending the sweep.

**Or is it a routine call site?** A new caller of an existing worktree-create
helper, a new place that opens a session through the covered session path, a new
feature that writes into a directory family `OrphanGC` already collects — all of
these are covered already, and flagging them is the failure mode this carve-out
exists to prevent. The resource's reclaimer does not change because a new caller
appeared.

When a case sits between "new path" and "routine call site", the honest
resolution is cheap: say in the PR description which sweep enumerates the
instances this code creates. That sentence is the deliverable the rule is
actually after.

## Rejected alternatives

- **A transactional or saga abstraction.** The external systems expose no
  prepare/commit protocol to build one on, and no saga can span the death of the
  daemon that would have to run its compensations — which is precisely the
  failure that produces orphans. The repo's history is one-sided here:
  reconciliation has worked everywhere it was applied, and every hand-rolled
  rollback path eventually turned out to be missing a leg. Naming the sweeps as
  the mechanism is itself the point of this document, so the next reader who
  notices the missing abstraction finds out why it is missing instead of
  building it.
- **Mechanical enforcement by a lint rule.** "Durable external resource" has no
  syntactic signature. A rule keyed on `Process`, `git`, or filesystem calls
  would fire on every read-only invocation and every already-covered call site;
  one keyed narrowly enough to avoid that would match only the cases an author
  already knew to think about. The judgment the rule needs is exactly what a
  linter cannot supply, which is why it lives in the review gate, where a reader
  weighs it, next to the other conventions that work the same way.
- **Requiring a sweep for every durable resource.** The worktree-add cleanup
  spec is the counterexample: create-time withdrawal, reached only from an
  explicit user gesture, was the examined right answer there, and a sweep would
  have added a background actor with nothing to do. Mandating sweeps would also
  invert the rule's purpose — the goal is that the question gets answered
  explicitly, by someone who looked, not that one particular answer wins.
- **Mirroring the rule into the legacy review workflow.**
  `claude-code-review-legacy.yml` is an inert restoration source: its only
  trigger is `workflow_dispatch`, and a dispatch exits at the fork gate without
  reviewing anything, because there is no pull-request payload outside a PR
  event. A copy of the rule there would be dead text with nothing keeping it in
  step with the live prompt, and the copy that drifts is the one a future
  restoration would resurrect.

## Consequences

The review gate runs on `pull_request_target` and reads its prompts from the
base branch, so the new paragraph does not review the PR that adds it — the rule
first fires on the next PR merged after it lands. That is the ordinary behavior
of every change to this gate, not a gap to work around.

Calibration comes back through ordinary review reading. The signals worth
watching are a finding against a routine call site (the carve-out is too narrow
or is being ignored) and a leak measured in the field on a resource whose PR
passed review (the rule's coverage question was answered too loosely). Either
one is a reason to sharpen the guidance here, in the same place the judgment is
described.

## What would show this is wrong

If reviewers cannot tell a new kind from a routine call site often enough that
the finding becomes noise, the rule is miscalibrated rather than useful, and the
fix is sharper guidance or a narrower trigger. If a future leak turns up on a
resource that a reconciler *did* cover, the premise that sweeps are the
effective defense weakens, and the balance between creating-path rollback and
background reconciliation deserves rethinking on that evidence.
