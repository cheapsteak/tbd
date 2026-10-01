# PR polling on a schedule: budget-first status checks

## Summary

TBD asks GitHub about every active worktree every 30 seconds while the app is
open. On the test fleet that is about 19 `gh` processes at once per pass and
about 2,900 GitHub GraphQL points an hour, out of a budget of 5,000 that is
shared by every tool and agent using the same login. In the worst hour measured,
TBD spent 3,747 points and another tool on the same login then failed to approve
three pull requests because the budget was gone.

This document replaces the one fixed timer with a schedule. Each known PR is
checked at an interval chosen by its status and by whether anyone is working in
its worktree. Branches without a PR are checked for one on a slower schedule.
Local events (an agent pushes, a branch tip moves, the user clicks a worktree)
make a check due now. A governor keeps projected spend under a fixed share of
the budget. The expected result on the test fleet is about 375 points an hour
instead of 2,900, and a few `gh` processes a minute instead of 19 every 30
seconds.

Three human rulings shaped the design:

- **Budget first.** Laptop load from process spawns is real, but the budget is
  what broke something. The transport (`gh` subprocess versus a native HTTPS
  client) does not change in this spec.
- **No backoff by staleness.** Polling less often the longer a PR has sat
  unchanged has the wrong shape for running checks, which become more likely to
  finish as time passes. Intervals follow status, not age.
- **Closed PRs are checked only while someone is there; merged PRs leave.** A
  closed PR can be reopened, so it is checked slowly while its worktree is
  active and not at all while it is idle. Becoming active checks it at once.
  GitHub cannot reopen a merged PR, so it is never checked.

## The problem, measured

Measured on one developer machine on 2026-09-22 and 2026-09-30.

| What | Value |
|---|---|
| Repos polled | 10 |
| Active worktrees | 79 (58 in one repo) |
| Worktrees with a PR status | 48 |
| Of those, merged | 37 |
| Of those, open and not green | 8 |
| `gh` processes per pass | about 19 |
| CPU per `gh` process | about 40 ms |
| Peak memory per `gh` process | about 47 MB |
| GraphQL points per 50-branch batch query | 6 |
| GraphQL points per per-PR check query | 1 |
| Points per pass on this fleet | about 24 |
| Points per hour, app open (30 s cadence) | about 2,900 |
| Points per hour, app closed (5 min cadence) | about 300 |
| Points per hour spent by the whole login, worst hour | 3,747 |
| Budget per hour | 5,000 |

A logging wrapper around `gh` over two hours with the app open attributed about
80% of all GraphQL calls to the TBD daemon. Agent sessions waiting on their own
PRs made most of the rest, mostly as free conditional requests.

Two measurement traps worth recording so nobody repeats them:

- **`gh api rate_limit` under-reports on this account.** Its own response headers
  reported zero used immediately after a real request. Read the budget from the
  `X-RateLimit-*` headers of a real request, or from the `rateLimit` field inside
  a GraphQL query.
- **The GraphQL and REST budgets reset at different minutes.** A reading taken
  across a reset looks wrong.

## Two costs, two fixes

- **Laptop load** comes from starting processes. Only a long-lived HTTPS client
  in the daemon removes it. It saves no GitHub points.
- **GitHub budget** comes from how many questions are asked and how often. Only
  asking less, or asking cheaper questions, saves points.

This spec addresses the budget. It also reduces process spawns as a side effect,
because fewer questions means fewer processes. A native transport is a possible
later stage and is listed under rejected-for-now alternatives.

## Design

### Split "which PR?" from "what status?"

Today one pass asks two questions about every branch at once:

1. Is there a PR for this branch?
2. What is that PR's status?

These change at very different rates.

**Discovery** (question 1) applies only to branches with no known PR. The answer
changes when someone opens a PR. When an agent inside TBD opens one, the
PostToolUse hook bridge already reports it, and the PR binding coordinator
records it at once. GitHub only needs to be asked for the rare case where a PR
was opened some other way: a teammate, a bot, or the web UI. Discovery keeps
today's batch query shape, restricted to PR-less branches, on a slow interval.
It is also the reconciler for every trigger that is missed.

**Tracking** (question 2) applies to known PRs. Each is asked about by number,
using the same field selection the batch query uses today, at a cost of 1 point.
Tracking items due at the same moment in the same repo are sent together in one
aliased query.

### Intervals by status

Why these are the right shapes:

- **Checks running.** The one status where waiting longer makes a change more
  likely, not less. A CI run that usually takes 12 minutes is far more likely to
  finish at minute 11 than at minute 1. A flat, fast interval is the simple
  choice; the cost is bounded because PRs spend little of their life here.
- **Waiting on people** (checks failed, changes requested, blocked, draft, ready
  to merge). Changes when a person acts, at no predictable time. A steady
  interval.
- **Closed.** Reopening is rare but possible, and nothing downstream needs to
  notice it on time: auto-archive acts only on merged, and the chip keeps
  showing "closed" until someone returns. So a closed PR is checked on a slow
  interval while its worktree is active, and not at all while it is idle. The
  worktree becoming active makes the check due at once.
- **Merged.** GitHub does not allow reopening a merged PR. Nothing can change.
  The PR leaves the schedule. Its cached status stays, so the status-bar chip,
  auto-archive, and auto-hibernate on merge keep working.

### Activity as a multiplier

A worktree is **active** when any of these holds: a session in it reports
`working` through the Claude Code hooks; a session in it had a hook event in
the last 30 minutes; or the app refreshed it (which happens when the user
selects it) in the last 30 minutes. Hibernated sessions count as idle. Age of
the worktree is not a rule: what age stands in for is "when did someone last
touch this", and activity measures that directly.

Activity slows the waiting tier and the discovery tier for idle worktrees, and
removes closed PRs from the schedule entirely while idle. Any change from idle
to active makes the worktree's item due now. Activity never slows the
checks-running tier: an agent usually finishes, pushes, and goes
idle while CI runs, which is exactly when the status will change and exactly
what auto-archive is waiting for.

### The numbers, and how they were derived

Four inputs. Two are measured, two are judgement calls made by the owner.

**Input 1, judgement: TBD's share of the budget.** The 5,000 points an hour are
shared with agents (300 to 1,500 an hour observed) and with the user's other
tools. TBD caps itself at 1,000 points an hour, 20% of the budget. If the
remaining budget on the login drops below 1,000, TBD brakes to its slowest tiers
until the hour resets.

**Input 2, the cost formula.** For each status:

    points per hour = PRs in that status x (3600 / interval in seconds) x points per query

**Input 3, measured: how long PRs sit in each status.** From the last 100 PRs in
each of two repos, 2026-09-06 to 2026-10-01: this repo, and a large private
monorepo where the same user works.

| | This repo | Private monorepo |
|---|---|---|
| CI suite duration, median / p90 | 12 min / 26 min | 1 min / 12 min |
| Open to first review, median | 36 min | 4 min |
| Open to merged, median | 2.5 h | 4 h |
| Commits per PR, median | 3 | 2 |
| Share of a PR's life with checks running | about 10% | about 2% |

The last row is the one that matters. PRs spend almost all their time waiting on
people. The fast tier for running checks is cheap whatever it is set to; the
waiting tier drives cost.

**Input 4, judgement: target delays.** The owner chose how soon TBD should know
about each kind of change. The intervals follow.

| Status | PRs in it (test fleet) | Target delay | Interval | Points per hour |
|---|---|---|---|---|
| Checks running | about 1 | within 1 min | 60 s | 60 |
| Waiting on people, active worktree | about 9 | within 2 min | 2 min | 270 |
| Waiting on people, idle worktree | | within 6 min | 6 min | |
| Closed, active worktree | 3 | within 30 min | 30 min | 6 |
| Closed, idle worktree | | on next activity | none | 0 |
| Merged | 37 | never | none | 0 |
| Discovery, active branches | about 5 | within 10 min | 10 min | about 30 |
| Discovery, idle branches | about 26 | within 1 h | 1 h | about 10 |
| Total | | | | about 375 |
| Today, for comparison | | | 30 s for all | about 2,900 |

What those delays cost in practice: 2 minutes on the waiting tier adds an
average of 1 minute to a 36-minute review cycle, about 3%. 60 seconds on the
checks tier adds an average of 30 seconds to a 12-minute CI run, about 4%.

**Sensitivity.**

- Waiting tier at 5 min instead of 2: about 160 points an hour less.
- Waiting tier at 1 min: about 270 points an hour more.
- Five PRs with checks running at once: 300 points an hour, inside the cap.
- 50 open PRs waiting at 2 min: 1,500 points an hour. This is where the cap
  bites, and the governor stretches the tier.

At the test fleet's size the budget does not force a tight choice. The
intervals are rules, and the governor adjusts them when a fleet outgrows them.

### Triggers

A timer is a guess about when things change. Local events are better evidence.
Each of these makes one item due now. A trigger only moves a due time; it never
writes status, so the two-facts contract (the cached `PRStatus` value and the
`PRObservation` outcome of the last attempt) is untouched.

- **An agent runs `git push`.** The PostToolUse hook bridge that already
  recognizes `gh pr create` learns `git push` as well, including `git push -u
  origin <branch>` and `git push --force-with-lease`. The worktree's PR, or its
  discovery item if it has no PR, becomes due.
- **A branch tip moves.** The periodic git refresh already resolves every branch
  tip and each repo's base tip on every sweep. When a worktree's tip differs from
  the tip recorded at its last PR check, its item becomes due. This covers pushes
  made from a terminal rather than by an agent.
- **The user selects a worktree.** The app already sends a refresh on selection.
  That refresh also marks the worktree active for 30 minutes.
- **A worktree goes from idle to active** by any of the signals above. Its item
  becomes due, which is how a closed PR that was not being checked gets checked
  again.

### The scheduler

The current `PRPoller` sleeps through one gated interval and runs one pass over
everything. The new loop keeps an in-memory schedule: for each known PR, its
tier, its activity, and its next due time; for each PR-less branch, its next
discovery due time. The loop sleeps until the earliest due time, or until a
trigger wakes it, then runs everything that is due. Due tracking items in the
same repo go out in one aliased by-number query. Due discovery items go out as
today's batch query, restricted to PR-less branches.

On daemon start every item is due at once, so the first pass looks like today's,
and the schedule settles from there. Nothing about the schedule is persisted.

The scheduler takes an injected clock as its last initializer parameter,
defaulted to `ContinuousClock()`, following the repo rule for anything that
sleeps. Due times that are compared use the `Date` seam.

### Cost telemetry and the governor

Every GraphQL query adds `rateLimit { cost remaining resetAt }` to its
selection. The daemon logs the cost of each query at info level under the
`PRStatusManager` category, and keeps the most recent `remaining` and
`resetAt`.

Projected spend is the sum over scheduled items of 3600 divided by each item's
interval, times its query cost. When projected spend exceeds 1,000 points an
hour, or `remaining` is below 1,000, the governor multiplies the waiting and
discovery intervals by the smallest factor that brings projected spend back
under the cap. It never changes the checks-running interval. When `resetAt`
passes, the factor resets to 1.

### The flag

The schedule ships behind a `config` column, `pr_poll_schedule_enabled`, added
by a `.sql` migration with no `DEFAULT` clause, so unset stays a third state.
The shipped default lives in one place, `Config.prPollScheduleDefault`, and is
`false`. The GRDB record and the Codable model in `TBDShared/Models.swift`
change in the same commit as the migration, with the new field optional.

Flag off: today's `PRPoller` loop and `runPollPass` run unchanged. Flag on: the
scheduler runs instead. Both branches are tested. To enable for the soak, set
the column to 1 on the singleton `config` row. Graduation: after a soak with
cost logs showing the projected and actual spend, flip the Swift default; later,
delete the flag and the old loop.

### What does not change

- The cached `PRStatus` and `PRObservation` contract, and every consumer of it:
  the status-bar chip, auto-archive on merge, auto-hibernate on merge, and the
  merged-transition dispatcher.
- The `gh` and `glab` subprocess transports.
- The GitLab path. GitLab merge requests get the same tiers through the existing
  per-MR query; discovery on GitLab keeps its existing batch.
- The PR binding coordinator and the hook bridge's existing `gh pr create`
  handling.

### Repo rules this design touches

- **Reconcilers.** No new durable resource is created; the schedule is in
  memory. Discovery on its slow tier is the reconciler for missed triggers.
- **Injected clock.** The scheduler takes one, as above.
- **Flag on a config column with no SQL default.** As above.
- **No TUI scraping.** Activity comes from hook events and session rows, never
  from terminal text.

## Testing

- **Tier function.** `(status, active) -> interval` is a pure function with a
  case per status and per activity value, including that checks-running ignores
  activity, merged yields no interval, and closed yields an interval only when
  active.
- **Governor math.** Pure: given a schedule and a `remaining`, the stretch
  factor is what the formula says, and it is 1 when under the cap.
- **Scheduler against a fake clock.** Items fire at their due times; a trigger
  moves one item earlier without touching others; coincident items in one repo
  go out as one query; a merged result removes the item; a closed result moves it
  to the 30-minute tier while active and removes it while idle; an idle-to-active
  change makes a closed item due at once.
- **Triggers.** The hook pattern recognizes the three `git push` forms above and
  does not match `git push --help` or a `git push` inside a quoted string the
  way the existing `gh pr create` matcher already handles quoting. The git
  refresh reports a tip change exactly once per change.
- **Flag branches.** With the column NULL or 0, the old loop runs and the
  scheduler never starts. With 1, the scheduler runs and the old loop never
  starts. A pre-migration row reads NULL, not 0.
- **Cost telemetry.** The `rateLimit` field is present in every query text, and
  a parsed response updates `remaining` and `resetAt`.
- **Migration manifest.** The new `.sql` file is appended to the expected array
  in `SQLMigrationLoaderTests`.

## Rejected alternatives

### Push instead of poll

- **A GitHub webhook to a relay TBD hosts.** It is what Graphite, Linear,
  Mergify, and Claude Code's own PR subscriptions do. It needs a server someone
  pays for and operates, and installing the GitHub App needs an org admin. TBD
  is meant to be installable by anyone. Rejected as the main path.
- **`gh webhook forward`.** GitHub's own relay for local development. It is
  documented as not supported for production, allows only one person per repo
  at a time, needs repo admin, does not work on GitHub Enterprise Server, and
  the client stops after three reconnect attempts. Rejected.
- **A local webhook listener behind a tunnel,** as some session managers do.
  Needs a public URL the user operates, and the same admin rights. Rejected as
  a default; a possible optional trigger later.
- **GraphQL subscriptions, server-sent events, GitHub's first-party websocket.**
  The first does not exist; the second exists only through hosted relays; the
  third needs a browser session cookie. No local tool in a survey of the
  ecosystem receives GitHub pushes without a hosted relay.

Even tools that have push still poll for what TBD shows. Claude Code's own
coordinator prompt says it plainly: CI success and mergeability changes do not
arrive by webhook, so poll.

### Other ways to poll less

- **Exponential backoff per PR.** Common elsewhere. Rejected because it has the
  wrong shape for running checks. Status tiers replace it.
- **A learned model of CI duration,** polling more often near the expected
  finish. Deferred. The flat 60-second tier is affordable, and the daemon sees
  every running-to-finished transition, so it can learn durations later if the
  cost logs say it matters.
- **A free REST "did anything change?" probe before the GraphQL query.** A REST
  response of "not modified" costs zero points, and the REST budget is almost
  unused. Deferred to a later stage because each probe through `gh` is another
  process; it becomes cheap once the transport is native.
- **Native HTTPS transport only, keeping the 30-second batch.** Fixes laptop
  load, saves no points. Deferred to a later stage behind this one.
- **Agents read PR status from TBD instead of running `gh`.** The daemon already
  holds the answer and `tbd worktree list --json` exposes it. Worth doing, but
  agents turned out to spend far less than the daemon. Secondary.

### A separate budget

- **A GitHub App installation token for polling.** Its own budget of 5,000 to
  15,000 points. Needs an App installed per org by an admin: the same objection
  as webhooks. At most an optional override later.

## Out of scope, and one bug to fix separately

- `gh repo view` ran about four times a minute on the test machine even though
  the resolver caches its answer for fifteen minutes per checkout. Either a
  caller bypasses the cache or nil answers churn. This is a bug to diagnose and
  fix on its own, not a design choice here.
- Whether ready-to-merge PRs should also be re-checked when the repo's base
  branch moves, since that is when they can become conflicted. The git refresh
  already sees the base tip move. Deferred.
- The intervals above should be revisited after a full day of cost logs.
