# Flake autofix: a nightly bot that finds flaky tests and opens fix PRs

**Date:** 2026-10-07
**Status:** Approved design, pending implementation
**Builds on:** [`2026-07-24-test-hardening-design.md`](2026-07-24-test-hardening-design.md) (§7 quarantine and retry metrics, §9 the nightly workflow)

## 1. Problem

Flaky tests go unnoticed, because the usual response to a red run erases the
evidence. A PR author whose `test.yml` run fails on a test they did not touch
reruns it; the rerun passes; the run's final conclusion is green, and nothing
records that a test failed on unchanged code. The failure is real data about
the suite, and the rerun discards it.

`HolderLockTests.lockIsReacquirableAfterRelease` shows the cost. Over a month it
failed five times on four PR branches (runs 34018400172, 34169604463,
35900096974, 37514131685, 37517751216). No issue was filed, and it was found and
fixed by hand in PR #960. Three of those five runs were rerun to green on the
same commit — attempt 1 failed, a later attempt passed — and those three sat on
three distinct branches. A detector that read rerun-erased failures would have
flagged the test on the day the second of them landed.

The nightly stress loop catches some flakes, but its reporting cannot carry
them:

- **One arm reports everything to one issue.** The whole-fast-pass arm
  (`FastPassWhole` in `scripts/nightly-flake-stress.sh`) failed on all 67 nights
  it reported, and every failure went to #503 regardless of which test failed.
  Unrelated flakes piled into one thread that nobody could act on. #503 is now
  closed and split into #961 (GitManagerTimeout) and #962 (the whole-fast-pass
  catch-all), and PR #963 repoints the nightly at them — but a catch-all issue
  is still a catch-all.
- **The report undercounts.** Failure signatures are grepped from console
  output and capped at the first 12 detail lines in sort order, so a night with
  many failing tests names only the alphabetically first few.

Both problems have the same root: failures are recorded per *run* or per
*arm*, and the unit anyone can act on is the *test*.

## 2. Goals and non-goals

**Goals**

- Record every flaky-test failure per test, from structured results, in a place
  that outlives the 7-day artifact retention: one GitHub issue per test that
  qualifies, and one shared watchlist issue for the tests that have not yet.
- Count both sources of evidence: nightly stress failures and rerun-erased
  failures in PR and `main` CI.
- Once a test crosses a threshold, attempt a fix automatically: one attempt per
  night, verified by a script, delivered as a PR a human reviews and merges.
- Spend at most one macOS runner at a time, off-peak.

**Non-goals**

- **Auto-merge.** The bot never merges. A human merges every bot PR, after the
  normal `claude-review` gate.
- **Fixing CI or the tooling that judges it.** Two different mechanisms keep
  the bot out of these, and they block different things:
  - **Workflows** – the App that pushes has no `workflows` permission, so
    GitHub rejects any push that touches `.github/workflows/`, including the
    review gate under `.github/workflows/claude-review-v2/`. That block is
    mechanical: such a candidate never reaches a branch.
  - **Verdict tooling** – the files the verdict depends on (§6.4 lists them)
    can be edited and pushed, but a candidate that touches any of them is
    never promoted. Its PR stays a draft, with a note saying a human must
    judge it.

  Every other file, test or production code, is the bot's to change.
- **Proving a flake is fixed.** No stress run can do that; §6.5 states the
  limit.
- **Replacing the nightly stress loop or the quarantine audit.** The bot reads
  their output; it does not change what they measure.

## 3. Overview

Six components, each with one job:

1. **Ledger** (`scripts/flake-ledger.py`) – reads structured test results from
   the nightly and from CI, and maintains one issue per flaky test, plus one
   watchlist issue for tests below the threshold. Deterministic; no model
   involved.
2. **Picker** (`scripts/flake-pick.py`) – chooses tonight's target from the
   ledger, or none.
3. **Fixer session** – `anthropics/claude-code-action` on a macOS runner,
   diagnosing and changing the code for one test.
4. **Verifier** (`scripts/flake-verify.sh`) – runs a pre-fix baseline on
   `main`, which picks the stress scope (the test alone or its whole CI pass),
   then stress-runs the candidate tree at that scope and returns a verdict. Its
   verdict, not the session's claim, decides whether the PR may become ready.
5. **PR driver** (`scripts/flake-pr.sh`) – pushes the branch, opens the draft
   PR, records the verdict, comments on the issue, and later marks the PR ready.
6. **Branch reclaimer** – removes `flakefix/*` branches no open PR uses.

They run in one new workflow, `.github/workflows/flake-fixer.yml`, as five
jobs:

- **`ledger`** (ubuntu) – runs when the nightly workflow completes
  (`workflow_run`), and on `workflow_dispatch` with `job: ledger`. Runs the
  reclaimer when `FLAKE_FIXER_ENABLED` is on (§10, §11), then the ledger.
- **`ledger-notice`** (ubuntu) – runs after `ledger` when it failed, in either
  ledger mode, and posts the tracking-issue note (§8). It is the only job
  whose token may write issues.
- **`fix`** (macos-26) – scheduled once a night at 06:00 UTC, and on
  `workflow_dispatch` with `job: fix` and an optional issue number. Runs the
  picker, the
  baseline, the fixer session, and the verifier. It holds no write credential
  (§6.1) and writes nothing to GitHub; its result is an artifact.
- **`publish`** (ubuntu) – runs after `fix`, in a separate job that never runs
  a model. Mints the App token and runs the PR driver's open step: the push,
  the draft PR, the verdict status, and every issue comment an attempt makes.
- **`promote`** (ubuntu) – runs when a `test.yml` run completes
  (`workflow_run`) and when the bot sets `flakefix/stress` = `success`
  (`status`). Runs the PR driver's promote step for `flakefix/*` branches.

The workflow's `workflow_dispatch` takes a required `job` input, a choice of
`ledger` or `fix`, and an optional `issue` number that only `fix` reads. Each
job's job-level `if:` selects it by trigger and, on dispatch, by `job`, so one
workflow file serves both manual paths.

One attempt runs at a time, from pick to publish. A run that can start `fix`
– the schedule, or a dispatch of `fix` – holds a whole-run concurrency lock,
without cancel-in-progress; every other run gets a group of its own. The lock
belongs to the run rather than to a job because the picker learns that a test
is taken only from what `publish` writes, the open PR and the attempt record
(§5): a second `fix` that started while the first run's `publish` was pending
could pick the same test. GitHub cancels a pending run when a newer one queues
in the same group; such a run has started no job and recorded nothing. A
scheduled run's work is the newer run's too, because it picks afresh. A
dispatch that named an issue is lost: that issue is not attempted, and the
cancelled run in the Actions list is the only trace, so a human dispatches one
issue at a time and re-dispatches a cancelled one. Neither `fix` nor `publish` has a job-level group, since a group a
`publish` queued in would be one where a pending `publish` could be cancelled
and record nothing.

06:00 UTC falls in the US night, and the `fix` job's 240-minute timeout (§9)
ends it by 10:00, before the nightly's 11:00 schedule. GitHub starts scheduled runs late
when it is busy – the last five nightlies started between 15:00 and 19:30 UTC –
so a delayed `fix` run can still overlap the nightly; that costs a second of
the five macOS slots, not a failure.

The `fix` job reads the ledger as the most recent `ledger` run left it. That
run follows the nightly's completion, which over the same five nights fell
between 15:45 and 19:40 UTC, so the ledger the `fix` job reads is 10 to 14
hours old. The worst-case latency from a test crossing the threshold to an
attempt, setting aside other tests ranked ahead of it (§5):

- **Crossed by a nightly failure** – the `ledger` run that follows that nightly
  records it, and the next 06:00 `fix` run attempts it: up to about 14 hours
  after the nightly completes.
- **Crossed by a rerun-erased CI failure** – a rerun that lands just after a
  `ledger` run waits for the next one, a day or more later, and then for 06:00:
  about a day and a half, 39 hours at the measured completion times.

## 4. Detection and the ledger

### 4.1 Sources

The ledger reads two sources, both as structured per-test results. It never
greps console output: console text is what produced the 12-line truncation and
the sort-order undercount in §1.

- **The nightly stress loop.** `nightly-flake-stress.sh` gains an
  `--xunit-dir DIR` option that passes `--xunit-output` to each iteration's
  `scripts/test.sh` invocation, and the nightly workflow uploads the directory
  as a `nightly-xunit` artifact with `retention-days: 7`. Every failing `<testcase>` in it is one
  failure of that test on that night. This is what splits the whole-fast-pass
  arm's catch-all: each test it fails gets its own count and its own issue. The
  existing per-target report and its issue comment are unchanged.
- **Rerun-erased CI failures.** A `test.yml` run qualifies when its attempt 1
  concluded `failure` and a later attempt on the same run concluded `success`.
  Same run means same commit, so the failure happened on code that then passed:
  that is the definition of a flake, and it is the signal a rerun erases. The
  ledger reads attempt 1's `xunit-results` artifact. GitHub keeps every
  attempt's artifacts under the same name on the same run, and the API does not
  label them by attempt, so the ledger assigns each artifact to the attempt
  whose time window (`run_started_at` of that attempt up to the next attempt's)
  contains its `created_at`. Runs 37514131685 and 37517751216 each list two
  `xunit-results` artifacts, one per attempt.

  The `retry-metrics` artifact adds one more signal: a `.flaky` test whose
  record says `passedOnRetry` failed on that run even though the run was green.
  The ledger counts those as failures too.

The ledger excludes:

- **Runs from forks.** Failure messages come from the code under test, and a
  fork's code is untrusted; those messages later reach the fixer session's
  prompt (§6.1). Only runs whose head repository is this repository count.
- **Runs on `flakefix/*` branches.** Those branches change the test under
  study, so their failures describe the bot's candidate, not the suite.
- **Failures with no `<testcase>` to attribute** – a build failure, a cancelled
  run, a timed-out job. They say nothing about any one test.
- **`FlakyQuarantineSelfTests/retriesUntilPass()`**, which passes on retry by
  design. This is the same single exclusion the quarantine audit makes, for the
  same reason (`Tests/CLAUDE.md`, "Quarantine").

### 4.2 Test identity

A test's ID is `<xunit classname>/<xunit name>`, for example
`TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()`. The two
sources spell a test the same way only when its suite is top-level, so the
ledger normalizes the `retry-metrics` form into the xunit form.

- **xunit** – Swift Testing writes the module and every enclosing suite, joined
  by `.`, as `classname`, and the function name as `name`. A test in a nested
  suite reads `classname="TBDDaemonTests.TBDHomeSerialized.ActuationLogSpawnWiringTests"`.
  Each CI pass writes two files, `xunit-<pass>.xml` for XCTest cases and
  `xunit-<pass>-swift-testing.xml` for Swift Testing cases; the ledger reads
  every XML file in the artifact. XCTest names carry no `()`, and the same
  `<classname>/<name>` rule applies to them.
- **`retry-metrics`** – `RetryMetrics.stableID` in
  `Tests/TestSupport/FlakyTestSupport.swift` joins the module and the *first*
  name component with `.`, then appends each remaining component after a `/`.
  For a top-level suite that equals the xunit form; for a nested one it does
  not: the test above would be recorded as
  `TBDDaemonTests.TBDHomeSerialized/ActuationLogSpawnWiringTests/<name>`.
- **Normalization** – split a `testID` on `/`; the last segment is the name,
  and the segments before it, joined with `.`, are the classname. A `testID`
  with no `/` is a test outside any suite: everything up to the first `.` is
  the classname (module names contain no `.`) and the rest is the name. Swift
  type and function names cannot contain `/`, so the split is unambiguous.

Evidence, from `test.yml` run 37679063383: the one `retry-metrics` record,
`TBDDaemonTests.FlakyQuarantineSelfTests/retriesUntilPass()`, matches its xunit
`<testcase>` exactly, and the xunit files carry nested classnames such as the
one above. No `.flaky` test sits in a nested suite today, so the nested
`testID` form is read from `stableID` rather than from a recorded sample; the
ledger's harness pins both forms (§13).

### 4.3 Occurrences and the threshold

Each failure becomes an **occurrence** with a key that names where it happened:

- `night:<UTC date>` for a nightly failure;
- `branch:<head branch>` for a rerun-erased failure on any branch except
  `main`;
- `main:<UTC date>` for a rerun-erased failure on `main`. `main` is one branch
  that runs every day, so each day counts once.

A test's failures are grouped into **episodes**. The first episode starts at
its first recorded failure; a new one starts at each recurrence after a merged
fix (§4.4). A test **qualifies** for a fix attempt when either:

- its current episode's failures span two or more distinct occurrence keys, in
  any mix. One night and one PR branch qualify; two failures on the same night
  or the same branch do not. The rule is meant to separate a test that fails in
  different places from one bad run; or
- its current episode is a recurrence. One failure on a commit that contains a
  recorded fix (§4.4) is enough, because it shows that fix did not hold.

### 4.4 The issue

Every recorded failure is kept on an issue, because CI keeps the xunit
artifacts for only 7 days: a failure recorded nowhere else would be lost
before a second one arrived to meet the threshold. But one issue per first
failure floods a public repository – a report-only run on 2026-10-08 planned
123 new issues, of which 15 qualified; most of the rest were whole suites that
failed in one bad run. So a test gets an issue of its own only once it
qualifies (§4.3), and until then its history lives on the **watchlist**
(below), one issue shared by every such test. A test that already has an
issue – one the ledger opened, or a human's it adopted – keeps recording there
whether or not it qualifies.

A test's own issue has three parts:

- **Title** – `Flaky test: <test ID>`, exact. The title is the lookup key.
- **Label** – `flaky`. The ledger creates the label if it is missing.
- **Ledger comment** – one comment, authored by the bot's own identity (below)
  and marked with a hidden sentinel (`<!-- flake-ledger v1 -->`), which the
  ledger edits in place every run. It holds, readable by a human: the failure count, the distinct
  nights and branches, each failure's run link and attempt, the failure
  signature (the xunit `<failure>` message, first lines), each failure's
  episode, and the outcome of each bot PR. It also holds the same data as a
  JSON block inside an HTML comment, which is the ledger's own state. The
  `ledger` job is its only writer. The ledger never edits the issue body or any
  human comment.
- **Attempt comment** – one comment, marked `<!-- flakefix-attempts v1 -->`,
  created at the first attempt and edited in place after. The `publish` job is
  its only writer (§7). It holds one entry per attempt, human-readable and as a
  JSON block, recording the facts known when `fix` ends (below).

**The watchlist** is one issue, titled `Flake watchlist` and labelled
`flake-watchlist` – its own label, never `flaky`, so neither the per-test
lookup below nor the picker (§5) ever reads it as a test's issue. It holds every
test that has failed in the last 30 days, has no issue of its own, and does not
qualify, and, until a run confirms its history on its new issue, a test that
just qualified (below).
The ledger finds it by label and authorship: the oldest issue under the label
that the bot itself opened, open or closed. An issue under the label opened by
anyone else is not the watchlist, and the summary lists it. When no bot-opened
issue carries the label, the ledger searches for the exact title among the
bot's issues before concluding there is none, and puts the label back on one it
finds, so a label removed by hand does not abandon the history. If none exists
the ledger creates it, once, the first time a test needs it. If two bot-opened
ones exist, it uses the oldest and leaves the other unread, and the summary
lists both.

Its state is in bot comments marked `<!-- flake-watchlist v1 -->`, each
holding, for each of its tests, a line for a human and the same state a
ledger comment holds – failures with their merge keys and occurrence keys,
folded counts, the window's folded merge keys – in one JSON block. Each entry
is degraded as a ledger comment is, signatures first, then folding the oldest
failures with their merge keys kept for the read window, to a budget that lets
it fit in a comment alone. GitHub refuses a comment over 65,536 characters, so
the ledger splits the watchlist across as many comments as it needs, each kept
under the same 60,000 it keeps a ledger comment under:

- **Placement** – a test stays in the comment it is in. A test new to the
  watchlist joins the first comment with room for it, else the last. A comment
  that grows past the limit hands its last tests, in test-ID order, to the
  next comment, and the last one overflows into a new comment, so tests only
  ever move forward.
- **Write order** – new comments first, then existing ones from the last to
  the first. Every test that moves is written to its new comment before its
  old one drops it, so a run that dies midway leaves a test in two comments,
  never in none. The next read merges the two and keeps the test in the later
  comment, which the forward-only moves make its new home. The merge keeps the
  fuller copy and adds the other's failures that are newer than anything the
  fuller one folded into a count, by merge key, so a failure one copy folded
  after its key aged out is never counted twice. The same merge brings a
  watchlist entry into an issue's ledger.
- **Reuse** – a comment left empty is edited to say so and reused, never
  deleted, and new tests fill the first comment with room, so emptied comments
  take new entries before any new comment is opened.
- **Trust** – only the bot's own comments are state, as for ledger comments
  (below). A bot comment that does not parse – a hand edit, say – is skipped:
  the run reads the watchlist from the bot's other comments, lists the broken
  one in the summary, and never writes it, so it stays exactly as it was for a
  human to inspect, fix, or delete. Entries go to the bot's readable comments
  and, past those, to new ones. A test whose history only the broken comment
  held starts a fresh entry when it next fails, and a test with an issue of its
  own records there as usual. One hand edit therefore costs the history that
  comment held, never the run: holding the whole watchlist until a human
  repaired the comment would stop every sub-threshold test from being
  recorded meanwhile, while what the skip loses is at most one place's history
  per test, below the threshold by definition. If a human repairs the comment,
  the next read finds a test in two comments and merges them, as for a run
  that died midway (above).

**Aging out.** An entry whose newest failure is 30 days old leaves the
watchlist (`WATCHLIST_AGE_OUT_DAYS` in `scripts/flake_lib.py`), and the
summary lists it. The newest failure counts folded ones: folding keeps each
count's latest time, so an entry degraded to counts alone ages from its real
last failure. A test that fails after its entry aged out starts a fresh entry,
with no memory of the old one; a flake that quiet is a fresh observation, and
without aging the watchlist would grow with every test ID that ever failed
once, renamed and deleted tests included. An entry bound for an issue of its
own is not aged: one whose test has an issue, whose `.flaky(issue:)` issue
serves it alone, or that qualifies and so is waiting for its issue to be
created. Each is waiting to be confirmed on that issue (below).

**Leaving the watchlist.** When a watchlisted test fails in a second distinct
place it qualifies, and the ledger opens its issue, seeded with the full
history from its watchlist entry. The ledger writes the watchlist before any
issue (§8), so in that run the test stays on the watchlist, its entry updated
with the run's failures. A later run that reads the issue's ledger comment
already holding every failure the entry holds – merged by merge key, as two
copies of an entry are – drops the entry. Until then every run plans the
test, whether or not it failed again, and searches for its issue by title
first, so an issue whose create failed is created again, once, even after the
failures that qualified it have left the read window. A create that fails
every time keeps every run red, which is the signal for a human (§8). A test leaves the watchlist only once
its history is on its own issue: if the issue's create or comment write fails,
the entry still holds everything, and the next run finds the issue (by its
`flaky` label, or by title) or creates it again, seeded from the entry. Aging
out is the only other way off the watchlist.

The exact-title search (step 1 below) runs for a test's first failure and,
once it is on the watchlist, only in a run where its recorded and new
failures span two places and so may qualify: a test that stays on the
watchlist creates nothing, and searching every watched test every run would
spend GitHub's search limit for nothing.

**Who records each attempt outcome.** Every outcome the picker (§5) depends
on is written as structured state by a job that runs no model, so the picker
never has to read prose to decide. Each comment has exactly one writing job, so
no two jobs ever edit the same comment:

- **`publish`** appends an entry to the attempt comment for every `fix` run
  that picked a target, with the `fix` run's ID and start time, the `main` SHA,
  the session's notes, and one outcome:
  - `aborted` – the job ended before producing a candidate artifact (§8),
    or a fixer session failed and left no commit, which the entry marks
    `session_failed` because nothing reached the verifier, or `main` moved
    during the run and the verified candidate could not be replayed onto it
    (§7), which the entry marks `publish_raced`;
  - `no-diff` – a session that finished made no commits;
  - `push-refused` – GitHub rejected the push (§8);
  - `pr-opened` – with the PR number, the scope, `N`, the false-pass
    probability or `unknown`, whether the evidence was weak (§6.5), whether a
    protected file was touched, and the verdict (`pass` or `fail`).
- **`ledger`** records what happens to each PR afterwards. Every run it reads
  each `pr-opened` entry whose PR it has not yet seen close, asks GitHub for
  that PR's state, and writes `merged` with the merge commit SHA, or
  `closed-unmerged`, into the ledger comment. GitHub's PR state is the record
  here, not any event, so a missed webhook or a failed run costs one day of
  latency and nothing else.

Promotion writes no state: whether a PR is ready is GitHub's own PR state, and
nothing the picker decides depends on it.

**Only the bot's own comments are state.** Both comments, and the watchlist's
comments, are written with the
`tbd-flake-fixer` App token – the `ledger` job mints it too, for every issue
write – so their author is the App's bot account, `tbd-flake-fixer[bot]`. A
reader accepts a comment as ledger or attempt state only if it carries the
sentinel **and** its `user.login` is exactly that login with `user.type` =
`Bot`. GitHub reserves the `[bot]` suffix for Apps (a person's login cannot
contain `[`), so nobody else can author a comment under that name. The jobs
that mint the token check that the action's `app-slug` output plus `[bot]`
equals the login; the readers without a token – the picker, in the read-only
`fix` job – use the same login from one constant in `scripts/flake_lib.py`. A
comment with a sentinel and any other author is ignored, and the `ledger`
job's summary lists it so a human can see the attempt. Any number of such
forgeries changes nothing the bot reads.

The issues – each test's own and the watchlist – are the ledger's only durable
store, because the artifacts it reads expire. Their retention differs, and each sets a read window:

- **`xunit-results`** (`test.yml`) – `retention-days: 7`. The ledger reads
  `test.yml` runs created in the last 7 days. A run whose rerun comes more than
  7 days after its attempt 1 has lost attempt 1's results and is not counted.
- **`retry-metrics`** (`test.yml`) – no `retention-days`, so the repository
  default applies, 90 days today. The ledger still reads only the same 7-day
  window of runs: the issues already hold anything older, and one window for
  both `test.yml` artifacts means a run's two sources are always read together.
- **`nightly-xunit`** (nightly) – `retention-days: 7`, set by this design. The
  ledger reads nightly runs created in the last 7 days.

Every run rereads its whole window and merges by run ID and attempt, so
processing a run twice changes nothing, and up to six missed `ledger` runs lose
nothing.

**Finding the issue for a test**, in order:

1. An issue whose title matches exactly, open or closed.
2. A `.flaky(issue: N)` trait on that test in `Tests/` – the quarantine audit's
   `inventory` subcommand already lists these – when issue N belongs to this
   test alone. Issue N is then the test's issue: the ledger adds the `flaky`
   label and its comment, and leaves the title alone.
3. Otherwise, once the test qualifies, the ledger creates one, seeded from
   the test's watchlist entry. Until it qualifies the test stays on the
   watchlist.

**Matching an inventory row to a test.** An inventory row carries the file,
the function name without its parameter list, and the issue – no suite. The
ledger matches a row to a test ID when the row's file is the test's file (from
the test's `retry-metrics` records, which carry the repo-relative file and run
whenever a `.flaky` test runs in CI) and the row's function name is the ID's
name up to its `(`. A row that matches no recorded test, or two – the same
function name in two suites of one file – is skipped and listed in the job
summary; the test then falls through to step 3.

**Issue N belongs to this test alone** when exactly one inventory row names
it and it carries no bot ledger comment for a different test ID. Otherwise –
several tests' traits name N, N already holds another test's ledger, or N is a
suite-level issue such as the nightly stress targets' #961 – the ledger opens a
separate per-test issue once the test qualifies, and links N from it: two tests
are two flakes. Until then the test's watchlist entry carries the link. The
per-test issue is the one everything keys on: the `flakefix/issue-<N>` branch
name, the one-open-PR rule (§5), the ledger and attempt comments, and the
PR's `Fixes #N`. The shared issue gets nothing beyond the link.

**Closed issues: recurrence or not.** What a new failure does to a closed
issue depends on how it was closed. The ledger reads the issue's latest
`ClosedEvent` through the GraphQL API: its `stateReason`, and its `closer`,
which GitHub sets to the commit or the merged pull request that closed it.

- **Closed as completed, with a closer** – a fix landed, whether the bot's PR
  or a human's PR or commit. The **fix commit** is the closer commit, or the
  closer PR's merge commit. A merged bot PR whose `Fixes #N` was removed from
  its body leaves the issue open with no closer; its `merged` attempt record
  (above) supplies the fix commit instead.
- **Closed as not planned, or as completed with no closer** – no fix is on
  record. The issue **stays closed**: the ledger never reopens it, and the
  picker never selects a closed issue. The ledger still records new failures
  in its comment, so the history is there if a human reopens it.

**A failure after a fix commit** counts as a **recurrence** only if the
failing run's commit contains the fix: the ledger asks GitHub's compare API
whether the fix commit is an ancestor of the run's head SHA. A failure on a
commit without the fix – a branch cut before the fix and never rebased, or a
rerun of an old commit – is recorded in the history as `pre-fix` and otherwise
ignored: it neither reopens the issue nor counts toward anything. For a
pull-request run the check uses the branch's head SHA, while `test.yml`
actually tested a merge with the base branch, so a branch that has not been
rebased since the fix is treated as pre-fix even if the tested merge contained
it. That errs toward missing a recurrence rather than inventing one.

A recurrence reopens the issue, with a comment linking the failure and the fix,
and starts a new episode (§4.3), which makes the test eligible again (§5). The
brief lists the fix as a prior attempt that did not hold. Recurrence after a
fix is exactly the evidence a human needs to see.

**Worked example: PR #960.** Under this design the first failure of
`TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()` puts it on
the watchlist, and the second distinct branch qualifies it and opens its
issue, carrying both failures. Suppose a human's PR #960
carries `Fixes #<that issue>`: merging it closes the issue as completed, with
#960 as the closer and its merge commit as the fix commit. A later failure on a
branch cut before #960 and not rebased is `pre-fix` and changes nothing. A
failure on a commit that contains #960's merge commit reopens the issue,
starts episode 2, and makes the test eligible that night, with #960 in the
brief as the fix that did not hold. Had a human instead closed the issue as not
planned, the same failure would be recorded in the ledger comment and the
issue would stay closed. Had #960 not referenced the issue at all, the issue
would stay open with no fix on record, and the bot could pick it; a human
closing it by hand, as completed with no closer, ends that.

The ledger posts nothing besides its one comment per issue, the reopen
comment above, and the watchlist's comments. A new failure updates the ledger
comment; it never adds a second one.

The ledger writes the watchlist first, then each test's issue, and paces its
writes at one issue's writes, or one watchlist comment, every three seconds,
under GitHub's limit on content creation. §8 says what a failed write does.

### 4.5 Report-only mode

With the ledger flag off (§10), the ledger computes everything and writes it to
the job summary instead of to issues. That lets its counts be checked against
the issues humans have filed before it writes anything public. The summary
leads with two counts – the per-test issues the run would open, and the tests
on the watchlist – and then lists each test with where its failures go: its
issue, a new issue, or the watchlist, and for a test promoted this run, that
it stays on the watchlist until a run reads its history on the issue. It also
lists the entries aged off the watchlist and any watchlist comment skipped as
unparsable. In write mode, an issue write that failed is listed after the
plan (§8).

Report-only mode mints no App token and writes no flake issue, but a red
`ledger` run is still reported: the failure note to the tracking issue (§8)
posts in either mode. Without the App token it posts with the workflow's job
token (`github.token`), so it appears as `github-actions[bot]`. A report-only
soak whose job fails every night would otherwise fail unnoticed, which is the
one outcome the soak exists to rule out. That comment is the only issue write
the job token makes.

## 5. Picking a target

The picker reads the open and closed `flaky` issues' ledger comments and the
list of open PRs, and chooses at most one test. It never selects the
watchlist: it lists only `flaky` issues, and an issue that also carries the
`flake-watchlist` label is refused by name, on the schedule and on dispatch,
so a mislabelled watchlist is never a target. A test on the watchlist does not
qualify and has no issue to pick. A test is **eligible** when:

- it qualifies (§4.3);
- its issue is open;
- no open PR has head branch `flakefix/issue-<N>` for its issue N – which caps
  the bot at one open PR per test;
- its issue does not carry the `flakefix-skip` label, a human's way to keep the
  bot off a test;
- its last attempt in the current episode, if there is one, allows another,
  by the outcome recorded for it (§4.4):
  - `aborted`, `no-diff`, `push-refused`, or `closed-unmerged` – eligible only
    once the ledger has recorded a failure after that attempt's start. Without
    that condition the bot would retry the same test every night on the same
    evidence;
  - `aborted` marked `session_failed` – eligible at once: an outage, an
    expired token, or a crashed session says nothing about the test, so
    waiting for a new failure would only lock the test out. Once: if the
    attempt before it was also a session failure, with no failure recorded
    after that one's start, the test waits for a new failure like any other
    abort. A session that ran out of turns or time also counts as failed, and
    the same bound keeps one that does so on every try from holding every
    night's slot;
  - `aborted` marked `publish_raced` – eligible at once, under the same
    once-bound, counted together with `session_failed` aborts: `publish` lost
    a verified candidate to `main` moving during the run (§7), which says
    nothing about the test;
  - `pr-opened` with no close recorded yet – not eligible; the open-PR check
    above also covers it;
  - `merged` – not eligible within that episode. A recurrence (§4.4) starts a
    new episode with no attempts in it, and the test is eligible at once.

Among eligible tests the picker takes the one with the most failures, then the
most recent failure, then the lowest issue number. It writes a brief for the
session: the test ID, file and line, the issue number, the current episode's
occurrences with run links, the failure signatures, and every prior attempt
with its outcome, including a rename or retirement of the target it made
(§6.4). A merged PR is listed as a prior fix that did not hold, with
its link and the session notes its attempt entry recorded, so the session
starts from what was already tried. The brief ends with the **flaky list**:
the test ID and issue number of every other open `flaky` issue whose ledger
comment the bot wrote, the watchlist excluded. It is what a session checks a
coverage claim against (§6.1): a test on it is no coverage another test can
lean on. The brief is built only from the ledger's
structured data, read only from the bot's own comments (§4.4). No human-written
text reaches it: not issue comments, not the issue body or title, not PR
bodies, and not a sentinel comment someone else posted, because anyone can
comment on a public issue and the session runs with a shell. The failure
signatures are xunit messages from same-repository runs (§4.1), and the
session notes in prior attempts are the bot's own sessions' output, recorded
by `publish`.

`workflow_dispatch` may name an issue directly. The picker then skips the
ranking, the threshold, and the re-eligibility rule, but still requires that
the issue exists and is open, carries the `flaky` label, has a ledger comment
from the bot's own login whose JSON block parses and names a test ID, and has
no open bot PR. The brief
comes from that ledger comment, as on the schedule. An issue that fails any of
these is refused, and the job ends red naming the condition.

## 6. Fixing and verifying

### 6.1 The fixer session

The `fix` job checks `main` out twice, at one SHA, into two trees:

- **The session tree** – the job's primary checkout, at the workspace root
  (`$GITHUB_WORKSPACE`). `actions/cache/restore` restores the SwiftPM build
  cache read-only (the nightly's precedent) to the paths it was saved from,
  which are relative to the workspace root, so only this tree can use it. It
  builds, so the session starts warm. The session works only here.
- **The verification tree** – a second, separate checkout under
  `$RUNNER_TEMP`, outside the workspace, which the session is never pointed at. It builds from cold, and the baseline
  (§6.3) and every verifier run (§6.4) happen in it.

The job then starts `claude-code-action` in the session tree with the brief and
the rules below. The session runs on the macOS runner itself, so it can build,
run the test through `scripts/test.sh --filter`, and stress it while it
diagnoses.

**Both sessions run on Opus** (`--model claude-opus-5-5`), not the action's
default model. A fix here is judged on whether it keeps the test testing what
it was written to test, and the evidence is that the default model can miss
that: PR #1018 (run 37928079031), on the default model in about three
minutes and 16 and 13 turns, fixed #989 by swapping the clock a
`ClockTestSupportTests` self-test drives from `TestClock` to
`EventDrivenTestClock`, so the self-test of `TestClock` stopped testing
`TestClock`, and it claimed a sibling still covered the behaviour without
noticing that the sibling was itself flaky (#990). The model is named once,
as an output of the step that lays the attempt out, and both sessions read it
from there: a step output taken before session 1 is one no session can
rewrite, where an `env` value could be changed by session 1 through
`$GITHUB_ENV` before session 2's inputs are read.

**Every session leaves a transcript.** Both session steps set
`show_full_output: true`, so the session's messages and tool results go to
the step log. The runner masks only registered secrets there –
`CLAUDE_CODE_OAUTH_TOKEN`, the job token, and the runtime tokens it issues –
and the action's own documentation warns that full output can expose any
other secret a tool prints. The session's environment holds no other secret
(§6.1's credential list), so this is accepted for the reasoning it makes
visible. The action also
writes the whole session to `claude-execution-output.json` in `$RUNNER_TEMP`
when the session ends and names it in its `execution_file` output; an
artifact is not masked the way a log is, so a step after each session, run
whatever the attempt's outcome once that session's End step has ended its
processes, and in the recorded environment (§6.4), copies
that file and only that file – at the action's own path, a regular file, never
a symlink – into `flakefix-transcripts/session-<i>.json`, with every
credential-shaped string redacted: Anthropic keys and OAuth tokens
(`sk-ant-…`), GitHub tokens of every prefix (`ghs_…`, `github_pat_…`), and
JWTs such as the Actions runtime token. Before anything else, even with no
file to keep, it removes from the transcript directory anything that is not a
regular file and redacts every file in it again, so a symlink or an
unredacted file session 2 left there is not uploaded; the upload leaves out
hidden files. It runs main's verifier copy, checked
against its fingerprint first, and removes the original, so session 2's
transcript can never be session 1's left behind. A transcript that cannot be
kept says why in the job summary and never fails the job; one whose session
ended in an aborted End step is not kept at all. The `fix` job
uploads the directory as the `flakefix-transcripts` artifact. A transcript
holds repository content and this repository's CI output, and the repository
is public, so nothing in it is private beyond the credentials redacted. A
session that times out leaves no file – the action writes it when the session
ends – and its log is then the only record. The transcript is for a human
reading why a fix took the shape it did; nothing in the bot reads it back.

**The session holds no repository write credential**, by these mechanisms
rather than by instruction:

- **A read-only job token.** The `fix` job's `permissions:` block grants only
  `contents: read`, `issues: read`, `pull-requests: read` and `actions: read`,
  so its `GITHUB_TOKEN` cannot write. It grants no `id-token: write`.
- **No credential left in the checkout.** `actions/checkout` runs with
  `persist-credentials: false`, so `.git/config` carries no token for the
  session's shell to find or use.
- **An explicit token for the action.** `claude-code-action` receives that
  read-only `GITHUB_TOKEN` as `github_token`. The OIDC-exchange failure
  CLAUDE.md records is specific to `pull_request_target`; on `schedule` and
  `workflow_dispatch` the exchange would succeed and hand the session the
  Claude App's installation token, which can write. Passing `github_token`
  explicitly, with `id-token: write` withheld, means the exchange is never
  attempted and could not succeed if it were. The rule is the same as the
  review workflow's for a different reason: always pass `github_token`.
- **No App token on the runner.** The `tbd-flake-fixer` App token is minted
  only in the ubuntu jobs that never start a model – `ledger`, `publish`, and
  `promote` – and `publish` runs on a different runner after `fix` has ended. It never exists in the session's
  environment, on its disk, or in its process table.

The session's outputs are local: commits on the working branch, and a notes
file (`flakefix-notes.md`) with its diagnosis, what it changed and why, and any
reproduction rate it measured, labelled as session-reported. After the
verifier runs, the `fix` job uploads the candidate – a `git bundle` of its
commits on top of `main` – with the notes, the baseline, and the verdict, as
the `flakefix-candidate` artifact. `publish` reads that artifact and makes
every write.

**`CLAUDE_CODE_OAUTH_TOKEN` is reachable from the session's shell**, because
the action needs it in the environment to reach the model, and this is
accepted. It grants model usage, not repository writes; the review workflow
already holds the same secret. The residual risk is exfiltration: a session
steered by hostile input could send the token off the runner, and the cost
would be model usage billed to it until the secret is rotated. The mitigations
narrow that without closing it:

- **Little hostile input reaches the prompt.** The brief is built only from
  the ledger's structured data, from same-repository runs (§4.1, §5); human
  comments are never copied in.
- **A restricted tool list.** `--allowedTools` permits the build and test
  scripts, local `git` commands, and file reading and editing, and leaves out
  `WebFetch`, `WebSearch`, and network commands such as `curl`.

That list is a permission control inside the session, not a network sandbox: a
permitted command such as `scripts/test.sh` runs repository code the session
can edit, so a determined session can still reach the network. The design
accepts that because the token grants nothing beyond model access and can be
rotated.

The bot may change any file, test or production code, using its judgement – a
flake can be a real bug in the code under test. Workflows and the verdict
tooling are the two exceptions §2 states: GitHub rejects a push that touches
`.github/workflows/`, because the App has no `workflows` permission, and a
candidate that touches a protected file (§6.4) is never promoted. Both are
enforced by mechanism, not by prompt instruction.

The session prompt states the rules from `Tests/CLAUDE.md`, and the spec
restates them here because they are the review criteria for every bot PR:

- **No blanket retries.** Retrying a test body or a step is not a fix.
- **Bounded waits go through `pollUntilTrue`**, with deadlines from
  `TestDeadlines`; no hand-written poll loops and no literal deadlines in
  fast-pass targets.
- **Never raise a deadline as the fix.** A longer timeout hides the race and
  taxes every genuinely wedged test.
- **`.flaky(issue:)` quarantine only where `Tests/CLAUDE.md` allows it** – a
  tier-2 test, never tier 1 or tier 3, never on a test that reports from an
  escaping `Task` – and only with the test's own issue number.
- **The kill hazards.** Kill by captured PID or own process tree, never by name
  pattern or process group.
- **Run tests through `scripts/test.sh`**, never bare `swift test`.
- **Assertion hygiene** – assert contracts, not incidents; no wall-clock
  freshness windows; timeouts report observed state.

Three more rules keep a fix from making a test pass by no longer testing what
it was written to test. They are review criteria too, and the prompt states
them:

- **A test of test infrastructure tests that infrastructure.** When the
  target belongs to a suite that tests a test helper – a `*SelfTests` suite,
  `ClockTestSupportTests`, a test of a clock, a poller, or a fixture – the
  helper is the code under test, and the fix must keep exercising it. Swapping
  the thing under test for a different helper turns the test green while the
  helper it existed for goes untested.
- **A coverage claim names its test.** Notes that say something remains
  covered elsewhere must name that test, in the xunit form, and say it was
  checked against the brief's flaky list (§5). A test on that list is not
  coverage anything can lean on.
- **A name says what the test checks.** A fix that makes the test check
  something its name no longer describes renames it, which is preferred over
  keeping a misleading name; moving or retiring the test follows the same
  rule. The session declares it in its notes, on a line of its own –
  `RENAMED: <old test ID> -> <new test ID>` or `RETIRED: <old test ID> —
  <reason>` – and the verifier and the PR treat it as §6.4 and §7 say. PR
  #1018 is the evidence that an honest rename needs a way through: its first
  try renamed the test to describe what it now checked, every iteration then
  failed on the target's absence from the xunit output, and the second try
  restored the old name on a test that no longer checked what that name said.
  A verifier that fails every absent target teaches a session to hide a
  rename.

### 6.2 Stress scope

A flake fails either on its own or only among neighbours. PR #960's test failed
only when a parallel suite forked; stressed alone, it would likely have passed
every time. So the verifier stresses at one of two scopes, and the pre-fix
baseline (§6.3) chooses which:

- **Test scope** – the target test alone. Used when the baseline reproduced
  the failure with the test alone (at least one failing iteration of 20).
- **Pass scope** – the whole CI pass the test runs in. Used when the baseline
  showed 0 failures for the test alone, which suggests the flake needs its
  neighbours. The pass is the one `test.yml` runs the test in, with the same
  filter, parallelism, and executed-test floor.

How many iterations each scope runs, `N`, is sized from the baseline (§6.3)
and capped by the time budget (§9).

`test.yml` runs four test steps, each through `scripts/ci/watched-test-pass.sh`.
Their filters partition the package with no gap and no overlap:

- **Fast pass 1a** – `--parallel --filter '^TBDDaemonTests\.[A-O]'`, floor
  1200: the `TBDDaemonTests` suites whose names start with `A` through `O`.
- **Fast pass 1b** – `--parallel --filter '^TBDDaemonTests\.' --skip
  '^TBDDaemonTests\.[A-O]'`, floor 1500: the rest of `TBDDaemonTests`.
- **Fast pass 2** – `--parallel --skip '^(TBDDaemonTests|TBDDaemonLiveTests)\.'`,
  floor 1900: every other target.
- **Quiet pass** – `--no-parallel --filter '^TBDDaemonLiveTests\.'`, floor 35:
  the tier-3 live suites, serially, on an otherwise idle machine. The verifier
  runs it the same way, without induced load (§6.4).

A test ID maps to its pass by applying those same regexes to the form
SwiftPM's `--filter` and `--skip` actually match, not to the xunit classname.
That form is the `retry-metrics` one (§4.2): the module and the first name
component joined by `.`, the rest by `/` – `TBDDaemonTests.TBDHomeSerialized/SomeSuite/test()`
for a nested suite, `TBDDaemonTests.nilPreferredKeepsOrder()` for a test
outside any suite. The difference matters: that suite-less test's xunit
classname is plain `TBDDaemonTests`, which `^TBDDaemonTests\.` does not match,
yet CI runs it in pass 1b, because its filter form starts `TBDDaemonTests.n`.
The first character after `TBDDaemonTests.` decides between 1a and 1b, so a
nested suite falls in 1b with its `TBDHomeSerialized` parent, exactly as CI
places it. `TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()`,
the #960 test, is in fast pass 2. `--pass-of` (§6.4) holds the four filters,
parallelism flags, and floors as data, and its harness checks that data
against the `watched-test-pass.sh` invocations in `test.yml`, so a change to a
CI pass that the verifier does not follow fails the `plans-guard` job. The verifier
omits only CI's `--fingerprint`, which guards the developer's home directories
and does not change which tests run or how.

The scope is fixed for the whole attempt: both tries are judged at the scope the
baseline chose.

### 6.3 The pre-fix baseline

Before the session starts, the verifier runs the target test alone for 20
iterations on `main`, in the verification tree (§6.1), with the same
retry-metrics wiring as a verifier run (§6.4). It runs at test scope, so under
induced load, whichever CI pass the target belongs to (§6.4). Each iteration is
classified:

- **Reproduction** – the target test failed in the xunit output; or the target
  is quarantined with `.flaky` on `main` and its record says `passedOnRetry`
  or `failed`, since a retry the quarantine absorbed is still a reproduction;
  or the iteration was killed at its deadline after the build finished and the
  target started. At test scope the target is the only test running, so a hang
  there is the target's own.
- **Clean** – the target executed and passed, with no retry.
- **Excluded** – the iteration says nothing about the target: the build
  failed, the harness errored, the target never executed (below the floor of
  1), or the retry-metrics wiring failed (§6.4). Excluded iterations count in
  neither the numerator nor the denominator of `p`.

If more than 2 of the 20 iterations are excluded, the baseline is not measuring
the test, and the attempt aborts before the session starts: the job ends red,
and `publish` records `aborted` (§4.4). The baseline does two jobs:

- **It chooses the scope** (§6.2) **and sizes `N`** (below).
- **It is the "before" for the PR.** The result goes into the brief, so the
  session starts with a reproduction or knows it lacks one, and into the PR, so
  the reviewer can read before and after side by side. When the baseline shows
  0 of 20, the PR says the test-alone regime did not reproduce the flake and
  that the pre-fix rate at pass scope was not measured; the ledger's counts are
  then the only "before".

The baseline never runs at pass scope: a warm fast-pass iteration takes about 3
minutes (§9), so 20 of them would take an hour, more than the two verifier
runs it sizes together.

**Sizing `N` from the baseline.** The baseline's failure rate on `main` is
`p = f / v`, where `f` is its reproductions and `v` its non-excluded
iterations (18 to 20). A candidate that changed
nothing would still pass `N` clean iterations with probability `(1 - p)^N`,
the **false-pass probability**. The verifier picks the smallest `N` that holds
it under 5%:

    N = ceil(ln(0.05) / ln(1 - p))

then raises it to at least 20, the baseline's own count, and lowers it to at
most the test-scope cap (§9). Pass scope has no `p` and runs its cap (below).
For example, `p = 0.05` (1 failure in 20) gives `N = 59`; `p = 0.15` gives 19,
raised to 20; a test that failed every valid iteration has no defined `N` and
runs 20.
`N` is computed once, after the baseline, and both tries use it.

Three cases follow:

- **Test scope, bound reached** – `N` fits under the cap. The verdict carries
  the false-pass probability `(1 - p)^N`, which is under 5%. With the §9
  figures the test-scope cap is 45, which any `p` of 0.065 or more fits under:
  a baseline with two or more reproductions (`p` of at least 0.1, `N` of at
  most 29) reaches the bound.
- **Test scope, bound not reached** – the cap is below the computed `N`. With
  the §9 figures this is a baseline with exactly one reproduction: `p` is
  1/20, 1/19, or 1/18, whose `N` is 59, 56, or 53. The verifier runs the cap,
  and the evidence is **weak** (§6.5): the actual false-pass probability
  `(1 - p)^N` is 5% or more – at 45 iterations, 9.9%, 8.8%, or 7.6%.
- **Pass scope** – the baseline saw 0 failures, so there is no measured `p` to
  size from, and the baseline never runs at pass scope to get one. The
  verifier runs the pass-scope cap and states the bound as **unknown**. The
  ledger's own record is not used as a stand-in for `p`: it comes from a
  different regime (CI runs without induced load), its numerator misses
  every failure that was never rerun to green, and it has no clean count of
  the runs in which the test executed. A rate built from it would look like a
  bound without being one. So the evidence is **weak** (§6.5), the bound is
  stated as unknown and, for scale, the PR gives what the cap's `N` would allow
  against `p = 0.05` and `p = 0.15`.

`p` from 20 iterations is a point estimate. A test whose true rate is lower
than measured is more likely to slip through than the stated probability says.
The stated figure is the false-pass probability at the measured rate, not a
confidence bound, and the PR says so.

### 6.4 The verifier

The verifier decides whether a candidate may become a ready PR. It is a script;
the session's own account of its results is recorded but never consulted.

`nightly-flake-stress.sh` gains two ad-hoc target modes:

- **`--test <ID>`** – a filter that matches exactly that test, with an
  executed-test floor of 1. It converts the ledger's ID back to the filter
  form (§6.2), escapes it as a regex, and anchors it as `^<form>(/|$)`: the
  start anchor stops a match inside a longer ID, and the trailing group stops
  `testFoo` from also matching `testFooBar` while still allowing a trailing
  source-location component.
- **`--pass-of <ID>`** – the filter, parallelism, and floor of the CI pass that
  contains the test, as §6.2 lists them, with an execution deadline sized from
  that pass's measured duration, first-iteration warm-up included.

Both keep everything else the harness already does – the outer per-iteration
deadline, the remote-verification valve forced off, and the verdict built from
the summary line, the floor, and the exit code together. Load follows the
scope:

- **`--pass-of`, the quiet pass** – runs **without** induced load. The quiet
  pass exists to run the tier-3 live suites serially on an idle machine, so
  loading it would test a regime CI never runs them in.
- **`--pass-of`, a fast pass** – runs under induced CPU load, with spinners
  captured by PID.
- **`--test`** – runs under induced load whichever pass the test belongs to,
  a tier-3 live test included. Test scope takes the test out of its pass, so
  its CI regime is not what it reproduces; load is what lets a timing flake
  show alone. The baseline (§6.3) runs this way too.

A caller's `--no-load` turns load off in every mode; the verifier never
passes it.

The verifier runs the chosen mode on the candidate tree and passes only when all
of these hold, at that scope:

- every iteration completed – a wedged or truncated iteration, or one below its
  floor, fails the run;
- every iteration's xunit output shows the target test executed and passed – a
  deleted, renamed, or disabled test cannot pass by running nothing, and a
  declared rename or retirement (below) is never a pass either;
- every iteration's retry-metrics ledger is present and readable, and shows the
  target never needed a retry, by the rule below.

**The retry check.** `.flaky` writes a record only when
`TBD_RETRY_METRICS_PATH` is set, and nothing in the nightly sets it, so the
verifier sets it itself. For each iteration, at both scopes and in the
baseline, it:

1. creates an empty file at a fresh per-iteration path and exports that path
   as `TBD_RETRY_METRICS_PATH` to the iteration's `scripts/test.sh` run.
   Pre-creating the file matters: the writer opens it only on the first record
   (`O_CREAT` on append), so without it "no `.flaky` test ran" and "the
   variable never reached the test process" would both leave no file;
2. after the iteration, fails the verdict if that file is missing or cannot be
   read, if any line fails to parse as a record, or if the iteration's output
   contains the writer's `warning: retry metrics disabled` line, which it
   prints when an open or write fails;
3. reads the target's records, matched by the normalized ID (§4.2).

Which records the target must have depends on whether it carries `.flaky` in
the verification tree, as the quarantine audit's `inventory` subcommand reports
it:

- **Quarantined target** – the writer records every execution, clean
  first-try passes included, so each iteration must hold at least one record
  for the target (one per test case), and every one must say
  `passedFirstTry`. No record, or any `passedOnRetry` or `failed`, fails the
  verdict. A fix that added `.flaky` therefore cannot pass on retries the
  quarantine hides.
- **Unquarantined target** – the target writes no records, so none is
  expected, and an empty file is a pass for this check. A record for the
  target here means the inventory and the build disagree, and fails the
  verdict.

Records for other tests are ignored, except that they prove the wiring
reached the test process: at pass scope 1a, `FlakyQuarantineSelfTests`
always writes one.

**A renamed, moved, or retired target.** A fix may rightly rename the target
so its name says what it now checks, move it to another suite, or retire it
(§6.1). The target is then absent from the xunit output, and absence alone
cannot tell an honest rename from a candidate that silently broke discovery
or deleted the test. So the verifier honors a change to the target only when
both of these hold, checked after the candidate is applied and before the
stress run:

- **The session declared it.** Its notes hold exactly one line for the target,
  `RENAMED: <old test ID> -> <new test ID>` or `RETIRED: <old test ID> —
  <reason>`, the IDs in the xunit form; a bullet and backticks around an ID
  are allowed. Lines for other tests are ignored; two different declarations
  for the target are not honored. The notes are read without following a
  symlink.
- **The diff bears it out.** Read from `git diff -U0` of the candidate under
  `Tests/`, with each revision's type declarations from `git grep`. The old
  side: the diff takes the old test's function declaration out of a file
  that declared its innermost suite on the base – a same-named function in
  another suite's file, or a commented-out line, proves nothing – or, for a
  rename that keeps the function's name, the old suite is declared nowhere in
  its module afterwards (a renamed suite). Removing a suite extension while
  the function stays is never enough. The new side, for a rename: the new
  function's declaration goes into a file that declares the new suite
  afterwards, or the renamed suite is declared in a file that held the old
  one. A retirement needs the old side's function removal. Two suites in one
  file with a same-named function are told apart by no part of this; a human
  reading the draft is the backstop there, as for everything a rename or
  retirement leaves.

What follows:

- **A rename** is stressed under the new ID, with the same scope and the
  adaptive `N` the baseline planned for the old one, and with the retry check
  keyed to whether the candidate quarantines the new ID. The verdict is
  judged on the new ID exactly as on the old: absent, failing, or retried, it
  fails, and a second try may follow. Clean, the candidate is **not eligible
  for ready** rather than passing: a human must judge whether the renamed test
  still covers what the old one did.
- **A retirement** stress-runs nothing, and the verdict claims no stress
  result: it is not eligible for ready, with no iterations, no `N`, and no
  false-pass probability. The PR's own `test.yml` run is the only build check
  it gets.
- **An undeclared absence, or a declaration the diff does not bear out,**
  changes nothing: the old ID is stressed, is absent, and fails the verdict.
  The failing lines a second try reads say how to declare a change, or why the
  declaration was not honored.

The change, when honored, is part of `verdict.json`, which the packaging step
sums (below), so `publish` reads it from the artifact it checks.

At pass scope the verdict is about the target test. Another test failing in the
same iteration does not fail the candidate: a pass of thousands of tests under
induced load carries other flakes the candidate does not claim to fix. The PR
lists those failures so the reviewer sees them.

**The candidate is judged in a clean tree.** The verifier never runs tests in
the session tree. It bundles the session's commits (`git bundle`, the same
bundle `publish` pushes), checks that they descend from the `main` SHA both
trees started at, and resets the verification tree to that `main` SHA plus
those commits. Anything the session left uncommitted, untracked, or written
into the session tree's `.build/` is not part of what is judged, and what is
judged is exactly what gets pushed. Each try's verifier run resets the
verification tree the same way and rebuilds incrementally.

The verifier's own scripts – `scripts/flake-verify.sh`,
`scripts/nightly-flake-stress.sh`, and `scripts/nightly-quarantine-audit.sh`,
whose `inventory` decides whether the target is quarantined – run from a copy
of `main`'s, taken from the verification tree before the session starts, never
from the candidate's. The same copy supplies the test runner: the verifier
invokes `main`'s `scripts/test.sh` and `scripts/swift-safe` with the
verification tree as the working directory, so the candidate's tests run
through the runner `main` ships, not one the candidate edited. That keeps the
verifier's logic out of the candidate's reach, but not everything the verdict
depends on: the candidate's tests are compiled from its own package manifest,
and the PR's `test.yml` run – which promotion requires green (§7) –
executes the candidate's copies of the CI test scripts. So the verifier checks
the candidate's diff against `main` for a **protected list**, every file on the
verdict's path:

- **The stress and verifier scripts** – `scripts/nightly-flake-stress.sh`,
  `scripts/nightly-quarantine-audit.sh`, `scripts/flake_lib.py`, and every
  `scripts/flake-*` file.
  The verifier runs `main`'s copies of these, so a candidate's edit to them
  cannot change this verdict; they are protected because a merged edit would
  change every later one.
- **The test runner chain** – `scripts/test.sh`, `scripts/swift-safe`, and the
  scripts `scripts/test.sh` calls: `scripts/remote-verify.sh` and
  `scripts/tbd-home-fingerprint.sh`. The verifier runs `main`'s copies; the
  PR's `test.yml` runs the candidate's.
- **CI's test-step scripts** – everything under `scripts/ci/`, which includes
  `watched-test-pass.sh` (each pass's verdict and floor check) and
  `first-party-wipe-needed.sh`, plus `scripts/repair-spm-workspace.sh`.
- **The retry-metrics writer** – `Tests/TestSupport/FlakyTestSupport.swift`,
  which writes the `passedOnRetry` records the verifier reads.
- **The package definition** – `Package.swift` and `Package.resolved`, which
  decide what is built, which test targets exist, and which dependency and
  plugin code runs during the build.
- **The build directories** – `.build/` and `.swiftpm/`. Both are gitignored,
  so a tracked file under them was forced in, and checking it out would write
  over the verification tree's warm build, which the verifier keeps between
  runs. The verifier refuses to apply such a candidate at all, before touching
  the tree. The refusal is the candidate's own failure, like one that does not
  build: the try fails with that reason and the paths listed as protected,
  and a second try may follow. The entries here make sure nothing carrying
  one could reach a passing verdict another way.

The diff is read NUL-separated, so every name arrives verbatim, and matched
ignoring case, because the runner's filesystem folds case. A name that is not
printable ASCII is treated as protected: the filesystem may normalize Unicode,
so no glob can say which file it really is. Failing closed costs at most a
draft that a human reads. The build-directory refusal does not fail closed:
its patterns are ASCII, which no normalization produces from other
characters, so a non-ASCII name elsewhere is applied and then flagged here.

A candidate that touches any protected file is "not eligible for ready"
whatever the stress result. The bot may still have changed it for a good
reason, so the PR is opened as usual and stays a draft, and its body names the
protected files touched and says a human must judge the change.

The verifier runs on the runner the session used, as the same user, so every
file on that runner and every variable a later step inherits is within the
session's reach. The job therefore carries what the verifier relies on across
each session as a step output taken before the session starts, which no
session can rewrite, and checks the runner against it afterwards:

- **Leftover processes are ended by PID, never by name.** Immediately before
  each session starts, the job records the full process list. After the
  session ends, it lists processes again and sends `SIGTERM`, then `SIGKILL`,
  to every PID that is new since the snapshot, except the current step's own
  ancestry. A process the session detached is new by PID however it renamed or
  re-parented itself, so the snapshot catches it where a tree walk would not.
  The kill runs from a private copy of the verifier's scripts, checked against
  their fingerprint first, and every check below runs after it, once nothing
  of the session is left to undo an edit.
- **The verifier's scripts are checked, not trusted.** The copy of `main`'s
  scripts is fingerprinted before session 1 – every path, file content and
  symlink target – and checked again after each session.
- **So is the verification tree.** The verifier runs that tree's `git` and
  its build, so a hook or an `fsmonitor` command in its `.git/config`, or a
  replaced product in its `.build`, would speak for the candidate. Before each
  session the job takes a digest of the whole tree – checkout, `.git` and
  `.build` – over every path, file content, symlink target and permission bit,
  and after the session it takes the digest again. Checking rather than
  re-creating the tree keeps its warm `.build`: a fresh clone gives every
  source a new modification time, and SwiftPM then rebuilds from cold, about
  19.5 minutes (§9) against the 5-minute rebuild allowance `B` inside an
  allotment. The digest is cheap by comparison; it took 3.5 seconds over a
  4.4 GB `.build` on a development machine.
- **The verifier's environment is the one recorded before session 1.** A
  session can append to `$GITHUB_ENV` and `$GITHUB_PATH`, and the runner hands
  both to every later step: `BASH_ENV`, `PYTHONPATH`, `DYLD_*`, a `PATH` entry
  ahead of `git`, or new values for the job's own paths. So the job records
  its environment as a step output just before session 1, pinning `git` to no
  global or system config, and every later `run:` step runs under `bash -p`,
  which reads no `BASH_ENV` or `ENV` and imports no exported function, then
  re-runs itself under `env -i` with only the variables its own `env:` sets
  and the record. `env -i` rather than `unset`, because an entry such as
  `BASH_FUNC_x%%` is no shell variable, so `unset` cannot remove it, and every
  child `bash` would import it. A path a `with:` or `working-directory:` names
  comes from the `runner.temp` context, never from `env`. The verifier's own
  Python – the judge and the digest – runs isolated (`-I -S`), so no `PYTHON*`
  variable or site directory reaches it.
- **The artifact is checked against what was packaged.** The upload is a
  `uses:` step, which still runs in the environment a session left. So the
  packaging step sums every file `publish` reads – the outcome, the bundle,
  its head, the verdict and its report, the baseline numbers, the notes –
  into a job output, and `publish` discards an artifact that does not match
  and records the attempt `aborted`, saying the artifact did not match.
- **Try 1's output is digested before session 2.** When session 2 makes no
  commit, try 1's verdict stands (§6.6). It is used only if it matches, byte
  for byte, the digest taken before session 2 started, and it is removed after
  session 2 either way, so a verdict session 2 wrote there is never read.

If any check fails, or a new PID is still alive after the kill, the attempt
aborts and `publish` records `aborted`. These checks keep the session's working
state, processes and environment out of the verdict, and the verifier's own
scripts and tree unchanged. They are best-effort against a session that shares
the runner and its user: they close the cheap paths, not every path. They do
not stop a session that replaces tools elsewhere on the runner before it ends
– a Homebrew binary such as `python3` or `bash`, a Python site directory that
the test runner's Python still reads, a `launchd` job – or that uses the
runner's passwordless `sudo`. Nor do they cover the candidate's own tests,
which run during the stress loop as the same user; those are in the diff a
human reviews. That is why the verdict alone never promotes: the PR's own `test.yml`
run on a fresh runner must also be green (§7), and a human reviews and merges.

### 6.5 What a clean run means

The stress harness's header already states the limit, and the PR repeats it: a
clean run is one sample from a gentler regime than the one many of these flakes
appear in, not proof of a fix. CI runners have about four idle cores; the
regime #503 characterised was a load average near 150 on 12 shared cores. Pass
scope restores the population a test normally runs among, but only for as
many iterations as the budget allows. The human reviewer and the ledger carry
the rest: a test that fails again after its fix reopens its issue (§4.4).

The sizing in §6.3 makes the filter's strength explicit rather than fixed. At
test scope it is a stated false-pass probability, normally under 5%. At pass
scope it is weak, and the spec does not pretend otherwise: with today's cap of
5, a candidate that changed nothing passes with probability 0.77 against a
flake with `p = 0.05` and 0.44 against one with `p = 0.15`.

**Evidence is weak** when the false-pass probability is 5% or more, or unknown.

**Decision: a weak-evidence candidate whose runs are clean is still promoted
to ready.** This was a deliberate human decision, not an oversight. Reviewers
weigh the evidence against the diff; the bot does not hold the PR in draft on
their behalf. A fix that removes a race by construction needs little stress
evidence, and one that only adjusts timing needs a lot, and only a reader of
the diff can tell which it is. Holding weak PRs in draft would strand every
pass-scope fix, because pass scope never reaches the bound within the budget.
§14 records the rejected alternative. What the design guarantees instead is
that weak evidence cannot be missed:

- **The commit status** – `flakefix/stress` = `success` is described as "no
  failure observed in N runs", with `N` filled in and never "fixed". For weak
  evidence the description continues "; weak evidence: a no-op would pass X%
  of the time", or "; weak evidence: bound unknown".
- **A label** – `publish` adds `flakefix-weak-evidence` to the PR, creating
  the label if it is missing.
- **The PR body leads with the numbers** – its first lines, above the
  template's sections, give the scope, the baseline, `p`, `N`, the cap, and
  the false-pass probability or "unknown", stated as weak.

A strong-evidence PR carries the same numbers in its body, below the summary.

### 6.6 Two tries

An attempt allows two tries:

1. The session works and stops. If it produced no commits, the attempt ends: no
   PR, and `publish` comments on the issue with the session's notes.
2. The verifier runs. If it passes, the attempt goes to §7.
3. If it fails, a second session starts on the same branch, with the first
   session's notes and the verifier's iteration log.
4. The verifier runs again, at the same scope and the same `N`. Pass or fail, the attempt goes
   to §7, which opens the PR either way and marks it eligible for ready only on
   a pass. If the second session made no new commit, the candidate is the
   first try's, and so is its verdict: it is not stressed again, because a
   chance pass would only overwrite a failure already observed.

## 7. PR lifecycle

All PR, branch, and issue writes an attempt makes use a token minted for a new
GitHub App, `tbd-flake-fixer`, and only in the `ledger`, `publish`, and
`promote` jobs, none of which runs a model. A PR opened with the default `GITHUB_TOKEN` triggers no
workflows, so neither `test.yml` nor `claude-review` would ever run on it. The
reviewer App is read-focused by design and stays that way.

Transitions, each owned by the PR driver:

- **Open.** In the `publish` job, from the `flakefix-candidate` artifact
  (§6.1), the driver pushes branch
  `flakefix/issue-<N>` and opens a **draft** PR. The body follows the PR
  template's fix variant and records the test ID, `Fixes #N`, the session's
  diagnosis, the pre-fix baseline, the stress scope and why the baseline chose
  it, the stress result (iterations, failures, core count, spinner count, and
  `load1m` as observed), any other tests that failed at pass scope, and the
  §6.5 limit in one sentence. For weak evidence the numbers lead the body and
  the PR gets the `flakefix-weak-evidence` label (§6.5). A candidate that
  renamed or retired its target (§6.4) gets the `flakefix-needs-human` label,
  created if missing and put on before the status is set, whatever its stress
  result, and its body leads with "The target test was renamed; a human must
  judge whether coverage is preserved." (or "retired"), naming the new ID, or
  the session's reason for a retirement, sanitized like the notes; a
  retirement's body carries no numbers line, since nothing was stressed. The
  driver then
  records the attempt in the attempt comment (§4.4). The push happens once per
  attempt, after
  verification, so the PR's CI runs once on the final candidate rather than
  once per try.
- **Replay at publish.** GitHub refuses the App's push of a branch whose
  `.github/workflows/` files differ from `main`'s, whoever's commits made the
  difference: the App has no `workflows` permission, and a candidate built
  on a `main` that has since changed a workflow reads to GitHub as a
  workflow edit. Run 37879620449 is the evidence: `fix` started from
  `main` at `cda5eab3a`, #952 merged while it ran and changed
  `.github/workflows/`, and GitHub refused a candidate that touched one
  test file ("refusing to allow a GitHub App to create or update workflow
  `.github/workflows/test.yml` without `workflows` permission"). So before
  pushing, the driver fetches `main`. When the candidate leaves the run's
  base's `.github/workflows/` files as they were – judged on its tree, not
  on which files its commits list, because GitHub judges the tree pushed –
  and `main`'s workflow files differ from the base, it replays the candidate's commits onto `main` as it is now –
  cherry-picked in order, keeping each commit's author, committer, and
  message, plus git's `(cherry picked from commit <sha>)` line naming the
  original – and pushes the replay. When the workflow files did not move,
  the candidate is pushed as it is, whatever else `main` gained. A replay
  that does not apply pushes nothing and records `aborted`, marked
  `publish_raced`, with git's reason (§5, §8); so does a failure to fetch
  `main` or to set the replay up, which says nothing about the test either.
  A candidate that changes `.github/workflows/` is never replayed: no replay
  makes its push acceptable (§8).

  The replayed commit is the one the PR carries, so it is the **pushed
  SHA** for everything after the push: the `flakefix/stress` status goes on
  it, and promotion requires it to be the PR's head with its own Test run
  green on it, exactly as for a candidate pushed as it is. The stress
  verdict was measured on the original base, so the status description and
  the PR body both say "stress-checked on `<old base>`; replayed onto main
  `<new base>` because main's workflow files changed during the run", and
  the attempt entry's notes record it. The PR's own CI on the replayed
  commits is the check that the replay still builds and passes; the
  verifier's stress run is not repeated. A re-run of `publish` that finds
  the PR open on a replay of its candidate reuses it, as it reuses a PR on
  the candidate itself. The tip's `(cherry picked from commit …)` line only
  locates the base the replay was made on: the driver replays the
  candidate onto that base again and reuses the PR only if the result is
  the PR's head exactly. A replay keeps every author, committer, and date,
  so it is reproducible, and a head anyone amended – message intact or not
  – is someone else's work, never stamped with the bot's status.
- **Record the verdict.** On a verifier pass, the driver sets a commit status
  `flakefix/stress` = `success` on the pushed SHA, described as "no failure
  observed in N runs", followed by the weak-evidence clause when the evidence
  is weak (§6.5), then the replay note when the candidate was replayed. The
  description is composed whole and then cut once at GitHub's 140
  characters, so the cut falls on the replay note, which the PR body carries whole, and never
  on the weak-evidence clause `promote` reads back. On a fail, it sets `failure`
  and comments on the issue with the iteration log's failing lines and the
  session's notes. A candidate that touches a protected file (§6.4) also gets
  `failure`, whatever its stress result, with a status description naming the
  files, and its PR body says a human must judge the change. So does a
  candidate that renamed or retired its target, with a description saying
  which – "target test renamed; no failure observed in N runs under its new
  ID", or "target test retired; nothing was stress-run" – and a failed stress
  run under the new ID gets the ordinary failure description. Either way the
  draft stays open for a human to read, finish, or close.
- **Promote.** Promotion needs two facts that arrive in either order: the
  PR's own `test.yml` run passing, and the bot's `flakefix/stress` status. The
  `promote` job therefore has two triggers, and whichever lands last
  promotes; the earlier one finds its partner missing and skips:
  - **A `test.yml` completion** (`workflow_run`) on a `flakefix/issue-<N>`
    branch of this repository, from a `pull_request` run that concluded
    `success`. The usual order: `publish` sets the status seconds after
    opening the PR, long before its CI finishes.
  - **A `flakefix/stress` = `success` status** (`status`) on any commit.
    This covers a status that lands after the PR's run completed – a re-run
    `publish`, say. `publish` sets the status with the App token, which is
    what lets it start a workflow at all; a status set with `GITHUB_TOKEN`
    would start none. A status names a commit, not a PR, so `promote` finds
    the one open PR from this repository on a `flakefix/issue-<N>` branch
    whose head is that commit, and skips when there is none, or more than
    one. The job does not pre-filter on the event's `branches` list: GitHub
    caps that list at 10 branches, so a commit on more could hide its
    `flakefix/issue-<N>` branch and the status would be dropped silently,
    while the lookup from the commit is exact and costs one runner for a
    status the bot sets at most once per attempt. GitHub offers no filter
    on `status`, so every commit status in the repository starts a run of
    the workflow; for any other context, every job is skipped without a
    runner. Those runs must not crowd the `ledger` job's look-back for its
    previous conclusion (§8), so that look-back counts only runs a `ledger`
    trigger started.

  Either way, `promote` marks the PR ready for review only if all of these
  hold for the head SHA: the newest of the PR's own (`pull_request`)
  `test.yml` runs on that SHA, on its branch and from this repository, has
  completed with `success`; the SHA carries `flakefix/stress` = `success`
  (the newest such status the bot set on it); and the SHA is still the PR's
  head; and the PR does not carry `flakefix-needs-human`, which only a
  renamed or retired target puts on it (§6.4), so such a PR is never readied
  by the bot, whatever statuses it gathers. Under the Test trigger, the run that started `promote` enters that
  list as its own event describes it, because the runs listing may not yet
  show it completed; a newer run in the listing, such as a re-run still
  going, still decides. A human push to the branch moves the head to an unverified SHA, so
  the bot never promotes over a human's work. The PR must also still be the
  bot's open draft from this repository, and none of its changed files, read
  from GitHub and matched against `main`'s protected list (§6.4), may be
  protected – a check independent of the one the verifier made.

  **A human's return to draft is a hold.** A human who converts the PR back
  to draft is holding it, and the bot never overrides that: `promote` reads
  the PR's timeline and skips when any `convert_to_draft` event was made by
  anyone but the bot. Without this, a later `test.yml` re-run at the same
  head would promote it again. The hold lasts as long as the PR is a draft;
  a human releases it by marking the PR ready, after which the bot has
  nothing left to do. The signal is the gesture a human already makes, so
  there is no label or command to learn; the bot's own returns to draft
  (the undo below) are told apart by their author, `tbd-flake-fixer[bot]`.

  A weak-evidence PR is promoted like any other (§6.5); if it lacks the
  `flakefix-weak-evidence` label, because `publish` died before adding it,
  `promote` adds it first. GitHub's ready takes no expected head, so
  `promote` reads the head again after it; if a push landed in between, it
  returns the PR to draft and goes red. Promotion uses the App token,
  because a `ready_for_review` event raised by `GITHUB_TOKEN` would not
  start `claude-review`.
- **Review.** `claude-review` skips drafts and runs on `ready_for_review`, so
  the gate judges the PR once it is ready, like any other. The review action
  refuses non-human actors by default, so the gate's workflow names this App,
  and only this App, in the action's `allowed_bots` input.
- **Merge or close.** A human does either. `Fixes #N` closes the issue on
  merge. The next `ledger` run records `merged` or `closed-unmerged` from the
  PR's state (§4.4). A recurrence on a commit containing the fix reopens the
  issue and makes the test eligible again; a PR closed unmerged makes it
  ineligible until it fails again (§5).

  **A merged rename or retirement** closes the old ID's issue like any fix,
  and the attempt entry records the change – `target_change` `renamed` with
  `renamed_to`, or `retired` – so the issue's attempt comment and every later
  brief name it. The ledger keys every issue by test ID, and nothing in it
  is confused by the change: the old ID can no longer fail on a commit
  holding the fix, so its issue is never reopened as a recurrence, and a
  failure of the old ID on a commit without the fix is `pre-fix` as usual. A
  renamed test that flakes again is a new test to the ledger: it starts on
  the watchlist and earns its own issue at the threshold, rather than
  reopening the old one, so a recurrence after a rename takes two places to
  surface where it would otherwise take one. When the renamed test still
  carries the old test's `.flaky(issue: N)` trait, N already holds the old
  ID's ledger, so the new ID gets its own issue linking N (§4.4).

## 8. Failure handling

- **The ledger cannot read or write GitHub.** A failed read fails closed: the
  ledger exits non-zero and writes nothing that run. So does a failed label or
  watchlist write, which comes before any issue write, because the watchlist is
  the only record of a sub-threshold test's history. A failed write to one
  test's issue does not stop the others: the ledger lists it in the summary,
  goes on to the next issue, and exits non-zero once every write was tried, so
  one bad issue neither hides behind a green run nor holds back every test
  after it. The exception is an answer that fails every write after it – 401
  for a bad or expired token, 429 or a 403 whose message names a rate limit –
  which stops the issue writes there, listing the rest apart as not tried,
  because writing on through a rate limit only prolongs it. Any other 403, a
  locked issue's say, concerns that issue alone. A failed write after a create names
  the number GitHub gave the new issue. A test promoted off the watchlist is still on it until a later run
  reads its history on the issue (§4.4), so a failed issue write loses
  nothing. Two answers are definite rather
  than missing, and do not fail the run: GitHub saying that an issue a
  `.flaky(issue:)` trait names does not exist (404, or 410 for a deleted
  issue), and saying that a failing run's head commit does not exist. A test
  whose trait names a missing issue gets an issue of its own, and the summary
  lists the number: a mistyped trait then shows as a second public issue
  beside the real one rather than as a test nobody tracks. A compare that
  answers 404 is followed by a lookup of the fix commit alone. If the fix
  commit exists, the failing head is what is gone, and only that failure goes
  unrecorded, listed in the summary. If the fix commit is gone, every later
  failure of the test would be unplaceable, so the run fails closed. It never posts a partial ledger
  comment and never comments about its own failure on a flake issue. Writes are
  per issue and idempotent, so a run that dies midway, or skips a failed
  issue, leaves the other issues correct and the next run converges. The job going red is the signal; on the
  first red run after a green one the job posts one comment to the nightly
  tracking issue, #519 (`TRACKING_ISSUE` in `nightly.yml`), and nothing on
  later consecutive reds. "After a green one" comes from GitHub, not from
  stored state: a job that runs when `ledger` fails, `ledger-notice`, asks the
  Actions API for the conclusion of the `ledger` job in the most recent earlier
  run of this workflow whose `ledger` job finished, and posts only if that
  conclusion was `success` or there is no such run. That earlier run need not
  have completed: its own `ledger-notice` job may still be running, and the
  next run's `ledger` job, queued behind it, can fail first. A re-run attempt
  first reads its own previous attempt's `ledger` job, so re-running a red run
  does not post a second note for one streak.

  The note posts in report-only mode too (§4.5). Its token is the App token
  when the ledger flag is on, the mint succeeds, and the App's login checks out
  (§4.4); otherwise – report-only mode, a mint that failed, or a token from the
  wrong App – it is the workflow's job token, and the comment says so. The job
  token writes no other issue: `ledger-notice` is the only job whose token may
  write issues, and the `ledger` job's token can only read them.
- **The picker cannot read the ledger.** No attempt that night. The `fix` job
  ends red without starting a session.
- **The build fails before the session starts.** No attempt; the job ends red.
  `main` is expected to build, so this is a CI problem, not a flake.
- **The session fails** – it errors, times out, or exhausts its turns, or
  never gets going (an expired token, an API outage). Its step continues on
  error, so the job reads each session step's own outcome and the action's
  reported conclusion. Whatever commits a failed session made still go to the
  verifier. With none, the attempt is not `no-diff`: it is recorded `aborted`,
  marked `session_failed`, with a reason naming the session and how it
  failed, and the picker may retry the test the next night (§5). Whatever the
  outcome – a failed second session leaves the first try's candidate – the
  `fix` job ends red after uploading its artifact, so an outage shows. An
  action that reports no conclusion counts as failed, so a change to its
  outputs shows the same way.
- **The candidate does not build.** The verifier fails it like any other
  failing stress run, and the second try gets the build log.
- **The stress run fails on both tries.** The draft PR stays open with
  `flakefix/stress` = `failure`, and the issue gets the notes.
- **The candidate touches a protected file** (§6.4). The PR opens as a draft
  with `flakefix/stress` = `failure` and a note naming the files; nothing
  promotes it, and a human decides.
- **The `fix` job dies before uploading its artifact**, or aborts on its
  baseline (§6.3). `publish` runs regardless (`if: always()` once the picker
  chose a target), finds no candidate, pushes nothing, and records `aborted`
  in the attempt comment, so the picker waits for a new failure before trying
  that test again.
- **`main`'s workflow files change while `fix` runs.** `publish` replays the
  candidate onto `main` before pushing (§7). A replay that does not apply
  – `main` changed the lines the candidate changed – pushes nothing and
  records `aborted`, marked `publish_raced`, and the picker may try the
  test again the next night (§5). The run stays green: the attempt is
  recorded, and the next one starts from the new `main`.
- **The push is refused as a workflow change, though the candidate changes
  no workflow file.** `main` moved again between the fetch and the push.
  Such a refusal is never read as the fix needing a workflow change: the
  driver fetches `main` again and judges it afresh: it replays onto it if
  its workflow files moved from the base, and otherwise pushes the
  candidate itself – never a replay onto a `main` that has since moved on,
  and no PR claims a replay that never happened. A
  second refusal pushes nothing, records `aborted`, marked `publish_raced`,
  with GitHub's message, and ends the run red so a human sees it.
- **The push is rejected** for any other reason. A candidate that changes
  `.github/workflows/`, refused with GitHub's workflow-permission
  text, opens no PR, records `push-refused`, and its issue gets a comment
  saying the fix appears to need a workflow change, which is a human's job.
  Any other rejection records `push-refused` too, says it was not a workflow
  change, and ends the run red.
- **CI fails on the PR.** The PR stays a draft; nothing promotes it.

## 9. Cost and slots

The account allows five concurrent macOS jobs, shared by every workflow.

- **The `fix` job** holds one macOS slot, scheduled at 06:00 UTC, with a
  240-minute timeout that ends it by 10:00, before the nightly's 11:00
  schedule (§3 covers a delayed start).

  The figures below were measured on CI, in
  [run 37686691741](https://github.com/cheapsteak/tbd/actions/runs/37686691741),
  on a 3-core macOS runner building with 2 jobs:
  - **Cold build** – 1167 seconds. An earlier cache-miss CI run paid 1250
    seconds for the same compile in its first test step.
  - **Build after a cache restore** – 761 seconds. That run did not copy
    `test.yml`'s "Restore source mtimes from git commit times" step, so
    SwiftPM likely saw every source as changed and rebuilt much of what the
    cache held. The `fix` job copies that step, before its cache restore, for
    both trees; the 761 seconds is the ceiling until a run with it is
    measured.
  - **A test-alone iteration** – 17 to 25 seconds.
  - **Fast pass 2 at pass scope, under induced load** – 340 seconds for the
    first iteration, then 171 seconds for each warm one.
  - **Incremental rebuild after a one-line test edit** – 26 seconds. The
    iterations after it took 279 seconds and then 164: a rebuild brings the
    first-iteration warm-up back, about 115 to 170 seconds of it.
  - **Fast passes 1a and 1b, and the quiet pass** – not measured. The caps
    below use fast pass 2's figures for every pass. A 1a or 1b iteration may
    be slower; if a run overruns its allotment, the verifier step's timeout
    ends it and the
    attempt fails closed, and that run's iteration times are the measurement
    that resets the constants. The quiet pass's healthy CI run takes about 2
    minutes (117 seconds of tests), without induced load (§6.4).

  Pass 2 is noisy under load. In one pass-2 iteration with 3 spinners,
  several unrelated tests hit the 240-second per-test time limit and the
  iteration failed for real. That is why the verdict at pass scope counts
  only the target test (§6.4): a candidate is not failed by its neighbours'
  flakes.

  The job's fixed costs, as ceilings:
  - session-tree build from a restored cache – 15 minutes (761 seconds
    measured);
  - verification-tree cold build – 22 minutes (1167 and 1250 seconds
    measured);
  - pre-fix baseline, 20 test-alone iterations – 10 minutes (20 × 25
    seconds is 8.3);
  - two sessions, capped at 60 minutes each – 120 minutes. The cap holds on
    Opus (§6.1) without change: Opus takes longer per turn than the default
    model, but the one measured session, PR #1018's on the default model,
    used about 3 minutes and 16 turns, so even several times slower per turn
    is far inside 60 minutes. A session that would run longer – the turn
    limit is 300 – is ended by the step's timeout and fails as §8 says;
    it does not move the budget;
  - checkouts, ending the session's processes, the verification tree's
    digest before and after each session (§6.4), the bundle, keeping the
    transcripts, the artifact uploads, and API calls – 20 minutes (not
    measured on CI; one digest of a 4.4 GB `.build` took 3.5 seconds on a
    development machine).

  That is 187 minutes, which leaves 53 of the 240-minute timeout for the two
  verifier runs: an allotment `R` of 24 minutes each, with 5 to spare. The
  push and PR writes happen in `publish`, outside this budget. Every session
  minute comes out of the verifier runs, so the 60-minute session cap is what
  holds `R` to 24.

  Each scope's cap on `N` (§6.3) is what fits in one allotment:

      cap = floor((R - B - W) / t)

  where `B` is the verifier's incremental rebuild of the candidate, `W` is the
  extra time a run's first iteration takes, and `t` is a warm iteration's
  time. `B` is 5 minutes: 26 seconds were measured for a one-line test edit,
  and a fix to a module that more targets import rebuilds more. These are
  named constants in the verifier, so new measurements change the caps by
  editing one line each:
  - **Test scope** – `t` = 25 seconds, the slowest test-alone iteration, and
    `W` = 0: (24 − 5 − 0) minutes is 1140 seconds, and 1140 / 25 = 45.6, so
    the cap is 45.
  - **Pass scope** – `t` = 171 seconds and `W` = 169 seconds (the first
    iteration's 340 less a warm one's 171, the larger of the two warm-ups
    measured): (1140 − 169) / 171 = 5.68, so the cap is 5.

  The worst case, with both tries running their full allotment, is the 187
  minutes of fixed cost plus 2 × 24, which is 235 minutes, 5 under the
  timeout. A full run inside one allotment costs 5 + 45 × 25 s = 23.75 minutes
  at test scope, and 5 + 2.82 + 5 × 2.85 = 22.1 minutes at pass scope.
- **The PR's own CI** draws the same two macOS jobs as any PR's `test.yml` run,
  once per attempt and so at most once a night.
- **The `ledger`, `publish`, and `promote` jobs** run on ubuntu and cost no
  macOS slot.
- **Model usage** is one attempt a night, at most two sessions, on Opus,
  authenticated with the existing `CLAUDE_CODE_OAUTH_TOKEN` that the review
  workflow uses.

## 10. Rollout

The bot acts without a user gesture and writes to the repository, so it ships
off. The daemon is not involved, so the flags are repository variables read by
the workflow rather than `config` columns. Unset or any value other than `true`
means off.

- **`FLAKE_LEDGER_ENABLED`** – the `ledger` job writes issues. Off, it runs in
  report-only mode (§4.5).
- **`FLAKE_FIXER_ENABLED`** – the `fix` job runs on its schedule, `publish`
  and `promote` act, and the `ledger` job runs the branch reclaimer (§11). The
  flag is read in job-level `if:` conditions (`vars.FLAKE_FIXER_ENABLED ==
  'true'`), so with it off `fix`, `publish`, and `promote` are skipped without
  starting a runner, and the reclaimer step's own `if:` skips it; the ledger
  itself still runs under its own flag. `workflow_dispatch` of `fix` also
  requires it. The reclaimer sits under this
  flag because only the fixer creates `flakefix/*` branches.

**The fixer requires the ledger.** With `FLAKE_FIXER_ENABLED` on and
`FLAKE_LEDGER_ENABLED` off, the issues hold no ledger comments the fixer can
trust – report-only mode writes none, and any it finds would be stale – so the
`fix` job refuses to start. This one case is deliberately not a job-level
`if:`, because a skipped job is easy to miss: the job starts, and its first
step writes a job summary line saying the fixer is on but the ledger is off
and naming `FLAKE_LEDGER_ENABLED`, then ends the job red before the picker
runs, on the schedule and on `workflow_dispatch` alike. `promote` is unaffected: it judges PRs the fixer
already opened, from their commit statuses and CI, not from the ledger.

Every job's `if:` also requires that the workflow is running in this
repository (`github.repository`), not a fork, so a fork that copied the
variables cannot run them.

**Enable for the soak** with `gh variable set FLAKE_LEDGER_ENABLED --body true`
and, later, `gh variable set FLAKE_FIXER_ENABLED --body true`; delete a variable
to turn its half off.

**Soak and graduation:**

1. **Report-only ledger, one week.** Compare the job summary against issues
   humans filed for the same period, including the `HolderLockTests` case.
2. **Ledger on.** Watch the issues it opens for duplicates, wrong test IDs, and
   noise.
3. **Fixer by hand.** With `FLAKE_FIXER_ENABLED` on, dispatch `fix` against
   chosen issues before relying on the schedule.
4. **Fixer on schedule.** Graduation is earned when the bot has opened at least
   five PRs, a human has merged at least three of them without rewriting the
   fix, none broke a `Tests/CLAUDE.md` rule that review had to catch, and no
   ledger or reclaimer defect turned up. Graduation changes the workflow so
   unset means on, and later deletes the variable checks.

## 11. Durable resources and their reconciler

The bot creates three kinds of durable external resource. Per CLAUDE.md, each
names who reclaims its orphans:

- **Branches** live under one prefix, `flakefix/issue-<N>`, and the issue
  number makes the branch name unique per test. The repository deletes a head
  branch when its PR merges. The **branch reclaimer**, run at the start of
  every `ledger` job while `FLAKE_FIXER_ENABLED` is on, deletes every other `flakefix/*` branch that has no open PR,
  sparing one whose commit is under a day old or that a workflow run is still
  using. That covers PRs closed unmerged and a `publish` job that died between
  the push and opening the PR. It follows `scripts/sweep-preflight-refs.sh`, whose
  live-run and age guards address the same push-to-use window; the
  implementation should generalize that script with a prefix argument rather
  than copy it.
- **PRs** are capped at one open per test (§5). An abandoned draft is visible,
  owned by its issue, and closed by a human; closing it hands its branch to the
  reclaimer.
- **Issues** are one per qualifying test, found by exact title before any
  create (§4.4), and the `ledger` job runs under a concurrency group so two runs
  cannot race to create the same one. Issues are records, not leaks; humans
  close them.
- **The watchlist issue** is one fixed resource: found by its label and the
  bot's authorship before any create, created once, and reused for every
  sub-threshold test. Its comments are edited in place; one left empty is
  reused rather than deleted, so their number is the most the watchlist has
  ever needed, and entries age out after 30 days without a failure, so that
  most is bounded by a month of first-time flakes, not by every test ID that
  ever failed (§4.4). A bot comment that does not parse is left in place for a
  human, never deleted; it stays one comment.

Five more things the bot creates need no reclaimer, each for a stated reason:

- **The `flakefix-candidate` artifact** is uploaded with `retention-days: 7`.
  `publish` consumes it within minutes; the week is for a human reading a
  failed attempt. GitHub deletes it on expiry.
- **The `flakefix-transcripts` artifact** (§6.1) is uploaded with
  `retention-days: 14`: nothing in the bot reads it, and the two weeks are
  for a human reviewing a PR or a failed attempt after the fact, which can
  take longer than the candidate's week. GitHub deletes it on expiry. The
  `claude-execution-output.json` each session leaves in `$RUNNER_TEMP` is
  removed when it is kept, and the runner itself is discarded with the job.
- **Labels** – `flaky`, `flake-watchlist`, `flakefix-skip`,
  `flakefix-weak-evidence`, and `flakefix-needs-human` – are a fixed set of
  five names, created once if missing and reused after. Their
  number cannot grow with use, so nothing accumulates.
- **Commit statuses** (`flakefix/stress`) are one per pushed SHA per attempt,
  immutable metadata on that commit with no separate lifetime. They are
  bounded by the number of attempts, at most one a night, and become
  unreachable with the commit when its branch is reclaimed.
- **Comments** – one ledger comment and one attempt comment per issue, each
  edited in place, plus a reopen comment per recurrence and the attempt
  comments `publish` posts, and one note on the tracking issue per streak of
  red `ledger` runs (§8). They live on issues, which are records (above).

## 12. Placement

This behavior lives in CI scripts and a workflow, which change by editing a
file. The placement battery from `docs/theory-placement.md` agrees:

- **Two reasonable projects** could pick a different threshold, a different
  iteration count, or no bot at all – all theories, and all held in editable
  scripts.
- **The tunable numbers** – two occurrences, 20 baseline iterations, the 5%
  false-pass target, the minimum `N` of 20, the per-run allotment and the
  timing constants behind each cap, one attempt a night, two tries – are named
  constants in those scripts, not compiled constants.
- **Nothing compiles.** The daemon, the app, and the CLI do not change. The only
  code changes outside the new scripts are in test tooling (the stress
  harness's `--xunit-dir`, `--test`, and `--pass-of` options).

## 13. Testing

Each script follows the repository's harness pattern: the logic that decides
is a pure function of input files, proven against fixtures with no network, and
its `*.test.sh` harness runs in the ubuntu `plans-guard` job beside
`nightly-flake-stress.test.sh`, except the bash 3.2 harness below. GitHub access goes through a `gh` stand-in
supplied by environment variable, as `nightly-quarantine-audit.sh` does with
`AUDIT_GH_CMD`.

- **`flake-ledger.test.sh`** – xunit fixtures with failing, passing, and
  skipped test cases; a run with two attempts and two same-named artifacts,
  assigned by timestamp; fork runs, `flakefix/*` runs, and the self-test ID,
  all excluded; runs and artifacts outside the 7-day read window ignored;
  both xunit files of a pass read; `merged` and `closed-unmerged` recorded from
  PR state, and recorded once; the fix commit taken from a `ClosedEvent` whose
  closer is a commit, one whose closer is a merged PR (the bot's and a
  human's), and a `merged` attempt record on an issue left open; a post-fix
  failure whose commit contains the fix commit (recurrence: reopen, new
  episode) and one whose commit does not (`pre-fix`: no reopen, not counted);
  an issue closed as not planned, and one closed as completed with no closer,
  each of which records the new failure and stays closed; a recurrence
  qualifying on one occurrence key; a forged ledger comment and a forged
  attempt comment – the right sentinel under a human login, and under a
  look-alike login without `[bot]` – each ignored and listed in the summary;
  inventory matching by file and function name, and a function name shared by
  two suites in one file, skipped and listed; a `.flaky(issue: N)` that N
  serves alone (adopted), one N shared by two tests' traits, one N already
  holding another test's ledger, and a suite-level N, each getting its own
  per-test issue that links N; test-ID normalization for a top-level suite
  (identical forms), a nested suite (`Module.Outer/Inner/test()` becomes
  `Module.Outer.Inner/test()`), and a test outside any suite;
  occurrence keys and the threshold at one and two keys; issue
  lookup by title, by `.flaky` trait, and by creation;
  the same run processed twice with no change; an API error that leaves the
  ledger unwritten; a trait issue that answers 404 (the run
  green, a 502 still red), and one that answers 410, each giving the test a
  fresh issue that links nothing; a compare that answers 404 with the fix
  commit present (that failure dropped, the test still planned), with the fix
  commit gone (red), and a compare that answers 500 (red); a title search that reads every page, fails closed on an incomplete
  answer, and keeps a quote or an overlong title from breaking the phrase; and
  expired or never-uploaded artifacts, each listed in the summary. The
  watchlist: a test below the threshold goes on the watchlist and gets no
  issue; a second place opens its issue seeded with the watchlist's history
  and keeps the entry, updated, that run, in write mode writing the watchlist
  before the issue, and the next run, reading the issue's ledger comment
  holding that history, drops the entry; an issue found without its ledger
  comment, and one whose ledger comment lacks a watched failure, each seeded
  from the watchlist with the entry kept; a qualifying entry whose issue was
  never created, searched for and created again with no new failure and not
  aged; an entry whose trait issue serves it alone, not aged; a failed issue
  write listed while the next issue is still written, ending the run red, a
  401, a 429 or a rate-limit 403 stopping the issue writes there with the
  rest listed as not tried, a locked issue's 403 not, a failed write after a
  create naming the new issue, and a failed watchlist write stopping the run
  before any issue; an entry with no failure in 30 days aged out against an
  injected now and listed, exactly 30 days aged and a second less kept, one
  folded to counts aging from its latest folded failure, one whose test has
  an issue not aged,
  and an aged-out test that fails again starting a fresh entry; folding
  keeping a count's latest failure time; an existing per-test issue below the threshold keeps
  recording there; a forged watchlist comment and a watchlist issue opened by
  someone else, each ignored and listed; a missing watchlist created once and
  not again; two watchlists, the oldest used and both listed; the report's
  counts of issues to open and tests watched; and a watchlist too big for one
  comment, split under the body limit with every test held once, a new test
  touching only the last comment, and a test moved by an overflow written to
  its new comment before its old one; a test left in two comments, kept in
  the later; a new test filling an emptied comment first; an unparsable
  watchlist comment, skipped, listed, and never written, with a test it may
  have held starting a fresh entry in a readable or new comment and a test
  with an issue still recorded there; a watchlist whose label was removed, found by title and
  relabelled; and a watched test title-searched only when it may qualify.
- **`flake-pick.test.sh`** – each eligibility condition on its own, both sides;
  the tie-break order; the re-eligibility rule after each recorded outcome
  (`aborted`, `no-diff`, `push-refused`, `closed-unmerged`, open `pr-opened`,
  `merged`), with and without a later failure; a `session_failed` abort,
  retried at once, and two in a row with no failure between, which wait; a
  `publish_raced` abort, retried at once, and one after a `session_failed`
  abort with no failure between, which waits; a recurrence after `merged`
  that makes the test eligible at once with the merged PR in the brief; a dispatched
  issue refused for each missing condition (closed, no `flaky` label, the
  `flake-watchlist` label, no ledger comment, a ledger comment from a login other than the bot's, an unparsable
  JSON block, an open bot PR); a closed issue, never picked whatever its
  failures; a brief built from fixtures that also hold human comments and
  forged sentinel comments, none of whose text appears in it; the brief's
  flaky list, which names another open `flaky` issue's test with its number
  and leaves out the target, the watchlist, a closed issue, and a test only a
  forged ledger names, and says "None." when empty; an earlier attempt's
  rename, named in the brief; and the refusal
  to start with the fixer flag on and the ledger flag off.
- **`flake-verify.test.sh`** – scope selection from a baseline with one
  failure and with none; baseline classification of a target failure, a
  deadline kill after the target started (both reproductions), and a build
  failure, a harness error, and an unexecuted target (excluded from `p`); the
  abort at 3 exclusions and not at 2; `N` sizing for `p` = 0.1 (29), 0.15 (raised to 20),
  1.0 (20), `p` = 0.05, whose 59 exceeds the cap (capped at 45, with the
  false-pass probability in the verdict), and pass scope (the cap, bound
  unknown); a
  baseline iteration of a quarantined target whose record says
  `passedOnRetry`, counted as a failure; the retry check with a missing
  metrics file, an unreadable one, an unparsable line, the writer's disabled
  warning in the output, a quarantined target with no record, a quarantined
  target with a `passedOnRetry` record, and an unquarantined target with an
  empty file, which passes; the clean tree, where an uncommitted change in the
  session tree is not judged and a bundle that does not descend from the start
  SHA is refused; leftover processes, where a PID new since the pre-session
  snapshot is killed, a PID in the snapshot is left alone, and a new PID that
  survives the kill aborts the attempt; the test runner taken from `main`'s
  copy even when the candidate edited `scripts/test.sh`; and the judge over synthetic iteration logs and xunit
  files at both scopes: a pass; a failing iteration; a wedged iteration; a test
  absent from the xunit output; a `passedOnRetry` record; another test failing
  at pass scope while the target passes; and a diff touching a protected file,
  one case per entry in the protected list, each marked not eligible for ready
  even with a clean stress run; a protected name holding a quote and a
  non-ASCII byte, a non-ASCII name outside every glob, and a protected name in
  another case, each flagged; a candidate that force-adds a file under
  `.build/`, refused before the warm build is touched and judged a failure
  with that reason; and a non-ASCII name elsewhere, which is applied. A
  renamed or retired target, over throwaway repositories: a declared rename
  the diff bears out, stressed under the new ID; a renamed suite, which is a
  rename; a declared rename that keeps the old test beside the new one, not
  honored and saying why; a rename with no declaration, which changes
  nothing; a declared retirement that removes the function, which stresses
  nothing; one that removes only a suite extension and keeps the function,
  not honored; a retirement whose only removal is a same-named function in
  another suite's file, or a commented-out line, not honored; a move into
  another suite's file, renamed or keeping its name, honored; a rename that
  only drops a suite extension while the target stays, not honored; two
  declarations for the target, a declaration for another
  test, and a new ID not in the xunit form, none honored; and a notes file
  that is a symlink, or missing, which declares nothing. A `target-change`
  that failed and left an empty change file still gets its harness-error
  verdict. The judge with a
  change: a clean rename under its new ID, not eligible for ready, and the
  same iterations without the change failing on the absent old ID; a rename
  whose new ID never ran, failed; a retirement, not eligible, claiming no
  iterations, `N`, or result; an absent target with no honored change,
  failed, its failing lines saying how to declare one or why a declaration
  was not honored; and a change file naming another test, malformed. The
  transcript keeper: a kept transcript with an OAuth token, a GitHub token,
  and a JWT each redacted, the count reported, and the original removed; a
  path other than the action's own, a symlink at the action's path, and no
  file at all, each keeping nothing; and a planted symlink in the transcript
  directory, removed, and an unredacted file there redacted again, even when
  there is no execution file to keep.
- **`flake-ledger.test.sh`** also covers the tracking-issue rule: a red run
  after a green `ledger` job posts to #519, a red run after a red one does
  not, and a red first-ever run does; a re-run attempt reads its own earlier
  attempt, and an earlier run still in progress counts; runs a commit status
  started do not use up the look-back's bound; a note posted with the
  job token says so; and the workflow runs `ledger-notice` whatever the ledger flag, falls
  back to the job token when the App token is missing, and grants
  `issues: write` to no other job.
- **`flake-pr.test.sh`** – promotion's conditions (§7), each failing alone,
  under the Test trigger, and under the status trigger the conditions that
  trigger adds or reaches differently (the Test run, the hold, the PR's
  resolution); a head that moved after verification; a status that
  lands after the PR's Test run (promoted) and one that lands while the run
  is still going (skipped, under either trigger); a newer red Test run over
  an older green one; a Test run that is not the PR's own – a `push` run,
  another branch's, a fork's, another workflow's – each not counted; a
  status whose commit heads no open bot PR (closed, another head, a fork,
  another branch name) or two of them, each skipped cleanly; a human's
  return to draft, which holds the PR under either trigger, and the bot's
  own, which does not; the job's `if:` naming both triggers and the
  status's context and state, and not filtering on the status's capped
  branch list; a Test-triggered promote whose run the runs
  listing still shows in progress, or does not list, which promotes; the
  attempt entry `publish` writes for
  each outcome, including `aborted` when no artifact exists, and a failed
  session with no commit packaged as `aborted` marked `session_failed`,
  never as `no-diff`; a weak-evidence
  candidate, which gets the status clause, the label, and numbers at the top
  of the body, and still promotes when clean; a strong one, which gets none of
  those; and the open step for a candidate that
  touched a protected file, which records `failure` and names the files.
  A candidate that renamed its target: a draft whose status is `failure`
  saying so, labelled `flakefix-needs-human` before the status is set, whose
  body leads with the coverage note and names the new ID, recorded with the
  rename beside its stress verdict; one that retired its target: the same
  label and note, the session's reason defused, no numbers line, and no
  stress verdict recorded; a rename whose stress failed, still labelled, and
  a plain failure, not; and a PR carrying `flakefix-needs-human`, never
  promoted under either trigger with every other condition met. The
  workflow: both sessions on the model the layout step names, never through
  `env`; both with `show_full_output: true`; a Keep step after each End
  session step that checks the verifier copy's fingerprint and keeps only
  the action's execution file; the `flakefix-transcripts` upload for 14 days;
  each Stress step stressing the ID `target-change` names, and each Judge
  step reading it. The session prompt states the three rules of §6.1 that
  keep a test testing what it tests, in the declaration format the verifier
  parses.
  Replay at publish, against a pre-receive hook that refuses a branch
  whose workflow files differ from `main`'s, as GitHub does: `main` moving
  without a workflow change, which pushes the candidate as it is; `main`'s
  workflows moving under a candidate that touches none, which pushes a
  replay on the new `main` that keeps the author and names the original
  commit, sets the status on the replay with the replay note in it and in
  the body, and is accepted on the first push; a replay that conflicts,
  recorded `aborted` and `publish_raced` with nothing pushed; a workflow
  refusal of a candidate that touches no workflow file, retried once and
  then recorded `aborted` and `publish_raced`, red, never `push-refused`,
  and one the retry clears, which opens the PR on the replay; a candidate
  that touches a workflow file, pushed once as it is and recorded
  `push-refused`; a fetch of `main` that fails, recorded `aborted` and
  `publish_raced`; a refusal with `main`'s workflows unmoved, re-pushed as
  it is with no replay note, and one during which `main` reverted its
  workflow change, which pushes the candidate itself rather than the
  earlier replay; and a re-run that finds its PR open on the
  replay, which reuses it, and on a replay a human amended, which it
  leaves alone.
- **`nightly-flake-stress.test.sh`** gains cases for `--test` (floor 1; the
  filter built from a top-level, a nested, and a suite-less ID, escaped and
  anchored, and not matching a test whose name extends the target's),
  `--pass-of`, and `--xunit-dir`. The `--pass-of` cases map a test ID from
  each of the four passes – including suites starting with `A`, `O`, and `P`,
  a nested suite, the suite-less `TBDDaemonTests.nilPreferredKeepsOrder()`
  (pass 1b), and `TBDSharedTests.HolderLockTests/lockIsReacquirableAfterRelease()`
  (pass 2) – check that `--pass-of` for the quiet pass starts no load
  spinners while a fast pass and `--test`, a live-suite test included, start
  them, and check the pass table against the
  `watched-test-pass.sh` invocations parsed from `test.yml`, so a fixture
  `test.yml` with a changed filter or floor makes the check fail.
- **`flake-bash32.test.sh`** – the one harness outside `plans-guard`: it runs
  in the macOS `lint` job, because the `fix` job's steps run under macOS's
  `/bin/bash`, GNU bash 3.2, which Linux does not have, and bash 5 parses and
  runs constructs 3.2 refuses. Over every macOS `run:` script in the workflow
  and every shell script those steps run, it checks `bash -n` under 3.2; a
  `case` inside `$( … )` or a process substitution whose patterns lack the
  leading `(`, which 3.2 ends at the first pattern's `)` and parses only when
  it runs, so `-n` cannot see it; constructs 3.2 lacks (associative arrays,
  `mapfile`, case conversion, `|&`, `;&`, and the like); and an array that can
  be empty expanded without a guard under `set -u`, which 3.2 reads as
  unbound – a site that cannot be reached empty carries a `# non-empty:`
  comment saying why. It runs the environment record, the preamble that
  restores it, and the packaging step under 3.2. A script that a macOS step,
  or a script it checks, runs and that it does not check fails it, and under
  `$CI` it fails rather than skips without a bash 3.2.

Every harness must prove it can fail: each case that expects a finding runs
against a fixture that contains one.

## 14. Rejected alternatives

- **A session on Linux, with CI as its feedback loop.** A Linux runner cannot
  build this macOS Swift package, so every try would wait on a full CI round
  trip for its only signal. The session could not run the failing test, stress
  it, or check a hypothesis cheaply, and fixes made blind are worse fixes.
- **Running on a developer machine.** The development machine is short of
  resources already, as the `scripts/swift-safe` build queue shows, and a bot
  there runs only while the machine is awake. A scheduled CI runner is
  available every night and isolated from the developer's work.
- **Letting the session judge its own result.** A model's report that the test
  "now passes" is a claim. The verifier makes the decision from xunit output and
  exit codes, which the session cannot change.
- **Always stressing at pass scope.** It reproduces neighbour-dependent
  flakes, but a warm pass iteration costs about 3 minutes where a test-alone
  one costs under half a minute, so the budget buys 5 pass iterations against
  45 test-alone ones. Test scope is the better instrument whenever the test fails alone,
  and the baseline shows when it does.
- **A fixed iteration count.** One `N` for every test is too many for a test
  that fails often and far too few for one that fails rarely: 20 clean
  iterations let a no-op through about a third of the time against a 5%
  flake. Sizing `N` from the measured rate spends the budget where the
  evidence needs it, and states what it bought.
- **Keeping weak-evidence PRs as drafts.** Holding a clean PR in draft until
  the evidence is strong sounds safer, but at pass scope the evidence is never
  strong within the budget, so every neighbour-dependent fix would wait on a
  human to notice and promote it by hand – the drafts would pile up unread.
  The reviewer is better placed than the bot to weigh a weak run against the
  diff: a change that removes a race by construction needs little stress
  evidence, and one that only adjusts timing needs a lot. So the bot promotes a
  clean PR and makes the weakness impossible to miss – in the status, a label,
  and the first lines of the body – rather than deciding for the reviewer.
- **Auto-merging a verified PR.** A clean stress run cannot prove a fix (§6.5),
  and a fix can change production code. A human merge is the backstop.
