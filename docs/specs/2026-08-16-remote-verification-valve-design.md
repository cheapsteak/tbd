# Remote verification valve: sending queued test runs to CI instead of waiting

Every build and test run on this machine passes through `scripts/swift-safe`, a
machine-global admission lock that admits one run at a time so forty agent
worktrees cannot start forty compiler swarms at once. The lock does its job. The
cost is that everyone else waits, and on a busy machine the wait has no ceiling.

This design adds an overflow path. A lane that has queued for the local slot
longer than a threshold, and whose tree is clean, verifies its commit on GitHub
instead — and leaves the local queue. The local slot is unchanged; nothing is
killed; a lane that cannot go remote waits exactly as it does today.

## What the queue actually holds

Two snapshots of live contention, taken minutes apart on a working afternoon:

- Holder running `swift test`, with three lanes queued behind it — one
  `swift-safe build` and two `swift test --filter …` runs.
- Holder running `swift test`, with two `swift test --filter …` lanes queued.

Of the seven lanes across both snapshots, six were **verification**: their entire
output is a pass/fail verdict, and nothing they produce needs to exist on this
disk. The seventh was a build whose artifact someone would run.

That distinction is the whole design. A build has two possible purposes, and only
one of them is tied to this machine:

- **An artifact you are going to run** — `scripts/restart.sh` builds `TBDApp` and
  `TBDDaemon` and launches them. The binary is the point, it must land on this
  disk, and it can never move.
- **A verdict** — "do the tests pass?" The compile is a means. The only thing
  that comes back is one bit, and it can be computed anywhere.

The queue is dominated by the second kind. Both queued lanes in the second
snapshot were `--filter`ed runs, which is the worst case for staying local:
`--filter` selects which tests execute *after* the whole package compiles, so
each was paying a full package build to run a handful of tests.

Narrowed runs are the common case rather than an edge one, and the valve has to
serve them. Four of the five queued test lanes across both snapshots narrowed the
suite, `scripts/git-hooks/pre-push` runs with `--skip`, and the nightly stress
harness passes a filter — a valve that declined a narrowed run would decline
almost every real caller.

## Why fairness alone does not fix this

Ordering the queue is worth doing and is not designed here. It does not
shorten the queue either. Four lanes needing five minutes each leave the fourth waiting
fifteen minutes however scrupulously they are ordered.

The valve removes lanes instead. In the first snapshot, three of the four would
have left and the one real build would have started immediately.

## Capacity, and why the valve is deliberately narrow

GitHub bills nothing for standard runners on a public repository. A recent
`test.yml` run reports `MACOS: total_ms: 0` across both of its macOS jobs, so
minutes are not the constraint.

Concurrency is. GitHub caps **five concurrent macOS jobs** per account on the
Free, Pro and Team plans — only Enterprise raises it, and the cap is shared
across every repository the account owns. `test.yml` spends two macOS jobs per
run, so the account sustains roughly **two concurrent runs** before everything
else queues on GitHub's side.

That ceiling decides the shape of this design. The valve is a pressure release
sized at about two lanes, not a new home for the fleet. Most verification stays
local, and the local queue keeps mattering.

Observed round-trip, measured across `test.yml` runs and their macOS jobs:

| | p50 | p90 | max |
|---|---|---|---|
| Remote run, end to end (n=14) | 591s | 853s | 1910s |
| Runner pickup delay (n=16 jobs) | 2s | 3s | 3s |

Remote is slow in absolute terms — roughly ten minutes — and a warm incremental
local run beats it easily. The trade is not speed but a ceiling: local is fast
when uncontended and unbounded when it is not, with 30-minute lock timeouts and,
in one measured session, a lane that waited over two hours across five attempts.
Remote's worst observed run is 32 minutes.

If the two macOS jobs per run are ever consolidated into one, the same account
allowance sustains five concurrent runs instead of two. That is the cheapest
capacity available and it is independent of everything else here.

## The mechanism

Two admission pools, both local, both `flock`-based. Every contender runs on the
same laptop, so a local file arbitrates remote capacity authoritatively — this is
not a distributed consensus problem.

- **The local build slot** — one ticket, `~/tbd/runtime/swift-build.lock`,
  unchanged from today.
- **Remote dispatch slots** — N tickets (N=2), each held for the lifetime of the
  remote run it authorizes.

A lane queues for the local slot as it does now. Once it has waited **T seconds
(T=300) without ever acquiring**, it attempts a remote ticket:

- **Ticket acquired and preconditions met** — it stops waiting locally, pushes,
  dispatches, waits for the verdict, and reports.
- **Otherwise** — it keeps waiting locally, exactly as today.

The threshold measures queue time, never run time. That choice matters more than
its value:

- **Nothing is wasted.** A lane that has never acquired the slot has compiled
  nothing, so there is no build to kill and no work to discard.
- **The threshold is meaningful.** Run time conflates waiting with compiling, and
  a solo compile ranges from seconds when warm to many minutes when cold — there
  is no defensible number. Queue time has no legitimate variance: every second
  spent queued is a second of nothing.
- **The exit path already exists.** `_acquire` abandons a wait and returns
  without starting a build when its requester dies. Crossing T is a second reason
  to take that same path.

Because forty lanes run one uniform rule, the second pool is what prevents a
stampede. Without it, every queued lane would dispatch at once into a queue two
runs wide that TBD cannot observe, prioritize, or abandon.

**T is sized against remote capacity, not against impatience.** Sampling the
lock every two seconds for two hours of ordinary fleet activity recorded 110
queueing episodes with a peak wait of 84s at the median, 268s at p90, and 1790s
at the maximum — a lane riding the lock's own timeout out. Remote sustains
roughly two concurrent runs of about ten minutes, so about twelve runs an hour.
Trip rates follow from the episode distribution: T=60 trips 28 times an hour and
oversubscribes the valve more than twofold, T=180 trips 14, and T=300 trips
between four and five. A lane that trips, finds no ticket, and returns to the
local queue has spent its trip for nothing, so a threshold below capacity buys
churn rather than relief. T=300 also selects the right episodes: it ignores the
median wait entirely and fires on the tail this valve exists for.

## Returning the verdict

A red run must tell the lane what failed, or the valve makes agents worse at
their job rather than faster.

The remote job writes machine-readable results and uploads them as an artifact.
`swift-test` supports `--xunit-output <path>`, which emits xUnit XML, and
`--experimental-xunit-message-failure`, which puts failure messages in it. On a
failure the local side downloads that artifact and renders it in the shape a
local run would have printed.

**The artifact holds several files, not one.** Each of the run's test passes
writes its own, and SwiftPM may split a single pass again between its XCTest and
Swift Testing writers, so the reader globs and merges whatever arrived. Fewer
files than passes is normal rather than an error: a run that died early produces
only what it reached.

**A passing remote run must also state how many tests ran.** Six places decide
whether a run is trustworthy by grepping its output for `Test run with N tests` —
the pre-push hook, the nightly stress judge, and three floors in `test.yml` —
because a suite that compiles and runs nothing otherwise reports success. A
remote verdict that omits the line is read as a truncated run and rejected, so
the driver sums the `tests=` populations across the merged results and prints it
in that exact wording.

The count is never invented. A pass whose results are missing, unreadable, or
silent about their population refuses rather than emitting a number, because six
floor checks would take that number as evidence. The cost of refusing is one
local re-run.

## A narrowed caller reads the verdict differently

The remote run is always the whole suite, so a caller that narrowed its own run
with `--filter` or `--skip` did not ask the question the remote answered. One
half of that mismatch is free and the other is not, and the asymmetry is what
lets narrowed runs use the valve at all:

- **A green whole-suite verdict is sound for a narrowed caller.** If every test
  passes, every subset of them passes. The count reported is the whole suite's,
  which clears a narrowed caller's floor because that floor is a minimum and the
  whole suite is a superset of what the caller asked for.
- **A red whole-suite verdict says nothing about the caller's subset.** The
  failures may lie entirely outside it. Adopting that verdict would report
  failures the caller deliberately excluded as its own result, so a narrowed run
  that comes back red is re-run locally to get its true answer.

The cost lands only on red, and only for narrowed callers: the remote round trip
is spent and then the local run happens anyway. On a tree whose whole suite is
reliably green this is rare; on a tree where it is not, a narrowed lane degrades
toward always running locally, which is where it started.

Passing the caller's narrowing arguments through to the dispatch would remove the
mismatch and make a red verdict directly usable. That input must be allowlisted
and delivered through the environment rather than interpolated into a workflow's
`run:` block, since a dispatch input is attacker-influenced text.

**Scraping the job log is rejected, on evidence.** A single failed `test.yml` run
produces **5.3 MB across 32,228 lines** — far past what any agent can read — in
which each line carries a job/step/timestamp prefix and ANSI codes, several
parallel test passes interleave, and compiler diagnostics print source context
that looks exactly like test output. Two extraction passes over a real failed log
both produced wrong answers: one surfaced a deliberate known-issue self-test
rather than the failure, and one matched 22 lines that were `#require is
redundant` compiler warnings displaying source context, not failures at all. The
repo's existing extractor, `failing_tests_from` in
`scripts/nightly-flake-stress.sh`, greps for the same markers; it is correct
against clean local `swift test` output and does not survive a CI log.

An extractor that silently reports the wrong failure is worse than no extractor.
Structured output costs kilobytes, needs no regex archaeology, and does not break
when a compiler changes how it renders a warning.

## Preconditions, and no silent fallback

The valve refuses and stays local, naming the condition, when the tree is dirty,
`gh` is unauthenticated, or no ref can be pushed. It never falls back silently: a
quiet fallback reintroduces the long stall at the moment it is least visible.

The dirty-tree stop is a semantic requirement, not a convenience.
`scripts/test.sh` runs against the working tree, uncommitted edits included;
GitHub can only test what was pushed. A green remote result on a dirty tree is a
false statement about the code in hand. Squash merge absorbs the cost of
committing more often, so the constraint is cheap here.

## Which ref gets pushed

The valve pushes the commit to `preflight/<branch>` and never to the branch
itself. That rule is unconditional, and the namespace is enforced at the one
function that moves a ref, so no upstream choice can publish a branch.

Three separate hazards make the branch unpushable, and the first two are why the
rule takes no exceptions:

- **A push to `main` is admitted.** `main` never has an open PR, so any rule of
  the form "push the branch when no PR exists" resolves to `main` on `main` and
  fast-forwards it. Branch protection does not stop this: `enforce_admins` is
  false and there are no push restrictions, so the owner's push lands, firing the
  `push: branches:[main]` CI and the Pages deploy with commits nobody reviewed.
- **It bypasses the gate that called it.** `scripts/git-hooks/pre-push` runs the
  suite to decide whether a push may proceed. A valve that publishes the branch
  during that run has already shipped the commits, whatever verdict follows.
- **A bare branch has no reconciler.** Refs under `preflight/` are swept; a
  branch pushed to `origin` without a user gesture is not, which is the shape
  behind this repo's largest measured leak.

Pushing an inert ref also keeps the review gate quiet. A push to a branch with an
open PR fires `pull_request_target: synchronize` and runs the claude-review
fan-out on every iteration; GitHub minutes are free, but Claude quota is not, and
it is the only metered resource in this loop.

Because every pushable ref is a throwaway in a swept namespace, the push is
always a force-push, and the driver additionally refuses outright when the
current branch is the repository's default.

`test.yml` gains a `workflow_dispatch` trigger. It has none otherwise, so nothing
can ask for a run on demand.

## Placement and flag

Everything here lives in user-land — `scripts/`, plus the workflow file. No
daemon change, no `config` column. Per the placement rule in `CLAUDE.md`, the
daemon compiles only what user-land cannot do well, and a wrapper script deciding
where to run a build is squarely user-land.

The valve ships behind an environment flag that defaults to off, so an unset
environment behaves exactly as today. It acts without a user gesture and pushes
refs, which is what the default-off rule exists for. Graduation is a change to
the default once the soak shows the routing behaves.

## Who reclaims the orphans

- **Remote dispatch tickets** — `flock`, released by the kernel when the process
  exits by any means. Self-reclaiming, on the same footing as the build slot; no
  sweep required and no marker to leak. A hand-rolled occupancy file would
  reintroduce the stale-marker problem this repo has already paid for.
- **Inert refs** — a genuine new durable resource, and the one thing here that
  needs a named sweep. They are deleted when the PR closes, with a periodic pass
  reclaiming any the close path missed. Because a ref now exists whether or not a
  PR does, that pass spares anything under an hour old rather than reclaiming on
  PR state alone, so a sweep cannot delete a ref a live run is about to check out.
  The age it can observe is the commit's date, which bounds the ref's age from
  below — a young commit implies a young ref, though an old commit re-pushed today
  is not spared. The sweep reads the namespace into `FETCH_HEAD`, creating no
  local ref of its own to reclaim, and keeps any ref it cannot date.
- **A dispatched run whose requester dies** — deliberately not reclaimed. It is
  free, self-terminating, and bounded at the observed 32-minute worst case, which
  makes it categorically different from a lock holder that blocks others without
  limit. Cancelling on abandonment is best-effort at exactly the moment the
  requester is gone, and it buys back a slot that would have freed itself.

## What this does not do

- **It does not order the local queue**, and that queue is measurably unfair.
  Across two hours, 52 of 99 handoffs went to a lane while another that had
  already waited at least 30 seconds was still queued; the worst passed over a
  lane 24 minutes into its wait, and one worktree was jumped at 21, 22 and 24
  minutes in the same stretch. The lock is memoryless, so seniority buys
  nothing. Fairness needs its own design. This valve relieves only the tail it
  fires on — at T=300, four or five episodes an hour out of roughly fifty-five —
  so most of that unfairness survives it, and the two changes are complementary
  rather than alternatives.
- **It does not move artifact builds.** `restart.sh` and anything else whose
  output is a binary someone runs stays local permanently.
- **It does not help a dirty tree**, which is a common state for the lane most
  likely to be starving.

## Testing

`scripts/swift-safe` and `scripts/test.sh` carry mutation-checked harnesses that
drive the real scripts against synthetic homes with a stub compiler, run in
seconds, and touch no real store. New behavior joins them on the same terms:
every guard gets a case, and every case is mutation-checked by weakening the
guard and confirming the verdict flips.

The routing decision is exercised without the network. Both admission pools are
ordinary lock files, so a test takes the tickets itself and asserts what the lane
does. Cases to cover: a lane that acquires locally before T never consults the
valve; a lane past T with a free ticket routes remote; a lane past T with the
tickets held keeps waiting; each precondition refuses and stays local, naming
itself; and the flag off leaves every path identical to today.

## Rejected alternatives

- **Kill the local run past a threshold, then dispatch.** Pays both costs
  serially — the threshold elapses, then the remote round-trip — and discards
  real compile work. Thresholding queue time instead achieves the intent with
  neither cost.
- **Route on local occupancy alone.** "The slot is busy, so go remote" ignores
  the two-run ceiling and stampedes. Remote congestion is real and independent:
  at one measured moment the local queue held one waiter while GitHub held three
  queued runs and one running.
- **Priority classes for interactive work.** Which worktree is interactive
  changes with whoever is looking at it. A uniform rule is both simpler and what
  `CLAUDE.md` requires — features and defaults must generalize rather than encode
  one workflow.
- **A daemon-mediated queue.** The daemon is built by this very wrapper, so a
  build path that depends on it cannot bootstrap, and builds must keep working
  while it is down.
