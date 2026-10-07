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
  that outlives the 7-day artifact retention: one GitHub issue per test.
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
   the nightly and from CI, and maintains one issue per flaky test. Deterministic;
   no model involved.
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

They run in one new workflow, `.github/workflows/flake-fixer.yml`, as four
jobs:

- **`ledger`** (ubuntu) – runs when the nightly workflow completes
  (`workflow_run`), and on `workflow_dispatch`. Runs the reclaimer when
  `FLAKE_FIXER_ENABLED` is on (§10, §11), then the ledger.
- **`fix`** (macos-26) – scheduled once a night at 05:00 UTC, and on
  `workflow_dispatch` with an optional issue number. Runs the picker, the
  baseline, the fixer session, and the verifier. It holds no write credential
  (§6.1) and writes nothing to GitHub; its result is an artifact.
- **`publish`** (ubuntu) – runs after `fix`, in a separate job that never runs
  a model. Mints the App token and runs the PR driver's open step: the push,
  the draft PR, the verdict status, and every issue comment an attempt makes.
- **`promote`** (ubuntu) – runs when a `test.yml` run completes
  (`workflow_run`). Runs the PR driver's promote step for `flakefix/*` branches.

05:00 UTC falls in the US night, and the `fix` job's timeout (§9) ends it by
10:00, before the nightly's 11:00 schedule. GitHub starts scheduled runs late
when it is busy – the last five nightlies started between 15:00 and 19:30 UTC –
so a delayed `fix` run can still overlap the nightly; that costs a second of
the five macOS slots, not a failure.

The `fix` job reads the ledger as the most recent `ledger` run left it. That
run follows the nightly's completion, which over the same five nights fell
between 15:45 and 19:40 UTC, so the ledger the `fix` job reads is 9 to 14
hours old. The worst-case latency from a test crossing the threshold to an
attempt, setting aside other tests ranked ahead of it (§5):

- **Crossed by a nightly failure** – the `ledger` run that follows that nightly
  records it, and the next 05:00 `fix` run attempts it: up to about 13 hours
  after the nightly completes.
- **Crossed by a rerun-erased CI failure** – a rerun that lands just after a
  `ledger` run waits for the next one, a day or more later, and then for 05:00:
  about a day and a half, 38 hours at the measured completion times.

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
`TBDDaemonTests.HolderLockTests/lockIsReacquirableAfterRelease()`. That is the
format the `retry-metrics` ledger already uses for `testID`, so a test seen in
both sources has one key.

### 4.3 Occurrences and the threshold

Each failure becomes an **occurrence** with a key that names where it happened:

- `night:<UTC date>` for a nightly failure;
- `branch:<head branch>` for a rerun-erased failure on any branch except
  `main`;
- `main:<UTC date>` for a rerun-erased failure on `main`. `main` is one branch
  that runs every day, so each day counts once.

A test **qualifies** for a fix attempt when its failures span two or more
distinct occurrence keys, in any mix. One night and one PR branch qualify; two
failures on the same night or the same branch do not. The rule is meant to
separate a test that fails in different places from one bad run.

### 4.4 The issue

Each test with at least one recorded failure has exactly one issue. The ledger
creates it at the first failure rather than at the threshold, because the issue
is where the history lives (below): CI keeps the xunit artifacts for only 7
days, so a failure recorded nowhere else would be lost before a second one
arrived to meet the threshold. The threshold gates fix attempts, not issues.
The issue has three parts:

- **Title** – `Flaky test: <test ID>`, exact. The title is the lookup key.
- **Label** – `flaky`. The ledger creates the label if it is missing.
- **Ledger comment** – one comment, authored by the workflow and marked with a
  hidden sentinel (`<!-- flake-ledger v1 -->`), which the ledger edits in place
  every run. It holds, readable by a human: the failure count, the distinct
  nights and branches, each failure's run link and attempt, the failure
  signature (the xunit `<failure>` message, first lines), and the bot's attempt
  history. It also holds the same data as a JSON block inside an HTML comment,
  which is the ledger's own state. The ledger never edits the issue body or any
  human comment.

The issue is the ledger's only durable store, because the artifacts it reads
expire. Their retention differs, and each sets a read window:

- **`xunit-results`** (`test.yml`) – `retention-days: 7`. The ledger reads
  `test.yml` runs created in the last 7 days. A run whose rerun comes more than
  7 days after its attempt 1 has lost attempt 1's results and is not counted.
- **`retry-metrics`** (`test.yml`) – no `retention-days`, so the repository
  default applies, 90 days today. The ledger still reads only the same 7-day
  window of runs: the issue already holds anything older, and one window for
  both `test.yml` artifacts means a run's two sources are always read together.
- **`nightly-xunit`** (nightly) – `retention-days: 7`, set by this design. The
  ledger reads nightly runs created in the last 7 days.

Every run rereads its whole window and merges by run ID and attempt, so
processing a run twice changes nothing, and up to six missed `ledger` runs lose
nothing.

**Finding the issue for a test**, in order:

1. An issue whose title matches exactly, open or closed.
2. A `.flaky(issue: N)` trait on that test in `Tests/` – the quarantine audit's
   `inventory` subcommand already lists these. Issue N is the test's issue: the
   ledger adds the `flaky` label and its comment, and leaves the title alone.
3. Otherwise the ledger creates one.

An issue that names a *suite* rather than one test – the nightly stress
targets' issues, such as #961 – is not reused: two tests in one suite are two
flakes. The new per-test issue links to it.

**A closed issue that gets a new failure is reopened**, with a comment linking
the failure and, when there is one, the PR that closed it. Recurrence after a
fix is exactly the evidence a human needs to see.

The ledger posts nothing besides its one comment per issue. A new failure
updates that comment; it never adds a second one.

### 4.5 Report-only mode

With the ledger flag off (§10), the ledger computes everything and writes it to
the job summary instead of to issues. That lets its counts be checked against
the issues humans have filed before it writes anything public.

## 5. Picking a target

The picker reads the open and closed `flaky` issues' ledger comments and the
list of open PRs, and chooses at most one test. A test is **eligible** when:

- it qualifies (§4.3);
- its issue is open;
- no open PR has head branch `flakefix/issue-<N>` for its issue N – which caps
  the bot at one open PR per test;
- its issue does not carry the `flakefix-skip` label, a human's way to keep the
  bot off a test;
- its last attempt, if any, ended with no open PR – no diff, or a PR a human
  closed unmerged – **and** the ledger has recorded a failure after that
  attempt. Without the second condition the bot would retry the same test every
  night on the same evidence.

Among eligible tests the picker takes the one with the most failures, then the
most recent failure, then the lowest issue number. It writes a brief for the
session: the test ID, file and line, the issue number, the occurrences with run
links, and the failure signatures. The brief is built only from the ledger's
structured data. Human comments on the issue are not copied into it, because
anyone can comment on a public issue and the session runs with a shell.

`workflow_dispatch` may name an issue directly; the picker then checks only that
the issue exists and has no open bot PR.

## 6. Fixing and verifying

### 6.1 The fixer session

The `fix` job checks out `main`, restores the SwiftPM build cache read-only (the
nightly's precedent), builds once, and starts `claude-code-action` with the
brief and the rules below. The session runs on the macOS runner itself, so it
can build, run the test through `scripts/test.sh --filter`, and stress it while
it diagnoses.

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
  only in the `publish` job, which runs on a different runner after `fix` has
  ended and never starts a model. It never exists in the session's
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

### 6.2 Stress scope

A flake fails either on its own or only among neighbours. PR #960's test failed
only when a parallel suite forked; stressed alone, it would likely have passed
every time. So the verifier stresses at one of two scopes, and the pre-fix
baseline (§6.3) chooses which:

- **Test scope** – the target test alone, **20 iterations**. Used when the
  baseline reproduced the failure with the test alone (at least one failing
  iteration of 20).
- **Pass scope** – the whole CI pass the test runs in, **3 iterations**. Used
  when the baseline showed 0 failures for the test alone, which suggests the
  flake needs its neighbours. The pass is the one `test.yml` runs the test in,
  with the same filter, parallelism, and executed-test floor. A pass iteration
  takes at most about 8 minutes once warm, and the first iteration of a run can
  take several times that (§9), which is why the count is 3.

`test.yml` runs four test steps, each through `scripts/ci/watched-test-pass.sh`.
Their filters partition the package with no gap and no overlap:

- **Fast pass 1a** – `--parallel --filter '^TBDDaemonTests\.[A-O]'`, floor
  1200: the `TBDDaemonTests` suites whose names start with `A` through `O`.
- **Fast pass 1b** – `--parallel --filter '^TBDDaemonTests\.' --skip
  '^TBDDaemonTests\.[A-O]'`, floor 1500: the rest of `TBDDaemonTests`.
- **Fast pass 2** – `--parallel --skip '^(TBDDaemonTests|TBDDaemonLiveTests)\.'`,
  floor 1900: every other target.
- **Quiet pass** – `--no-parallel --filter '^TBDDaemonLiveTests\.'`, floor 35:
  the tier-3 live suites, serially.

A test ID maps to its pass by applying those same regexes to the ID's xunit
classname, which begins `<target>.<top-level suite>` (§4.2). The first
character after `TBDDaemonTests.` decides between 1a and 1b, so a nested suite
such as `TBDDaemonTests.TBDHomeSerialized.SomeSuite` falls in 1b with its
parent, exactly as CI places it. `--pass-of` (§6.4) holds the four filters,
parallelism flags, and floors as data, and its harness checks that data
against the `watched-test-pass.sh` invocations in `test.yml`, so a change to a
CI pass that the verifier does not follow fails the `lint` job. The verifier
omits only CI's `--fingerprint`, which guards the developer's home directories
and does not change which tests run or how.

The scope is fixed for the whole attempt: both tries are judged at the scope the
baseline chose.

### 6.3 The pre-fix baseline

Before the session starts, the verifier runs the target test alone for 20
iterations on `main`. The baseline does two jobs:

- **It chooses the scope** (§6.2).
- **It is the "before" for the PR.** The result goes into the brief, so the
  session starts with a reproduction or knows it lacks one, and into the PR, so
  the reviewer can read before and after side by side. When the baseline shows
  0 of 20, the PR says the test-alone regime did not reproduce the flake and
  that the pre-fix rate at pass scope was not measured; the ledger's counts are
  then the only "before".

The baseline never runs at pass scope: three pass iterations on `main` would add
25 to 55 minutes to every attempt (§9).

### 6.4 The verifier

The verifier decides whether a candidate may become a ready PR. It is a script;
the session's own account of its results is recorded but never consulted.

`nightly-flake-stress.sh` gains two ad-hoc target modes:

- **`--test <ID>`** – a filter that matches exactly that test, with an
  executed-test floor of 1.
- **`--pass-of <ID>`** – the filter, parallelism, and floor of the CI pass that
  contains the test, as §6.2 lists them, with an execution deadline sized from
  that pass's measured duration, first-iteration warm-up included.

Both keep everything else the harness already does: induced CPU load with
spinners captured by PID, the outer per-iteration deadline, the
remote-verification valve forced off, and the verdict built from the summary
line, the floor, and the exit code together.

The verifier runs the chosen mode on the candidate tree and passes only when all
of these hold, at that scope:

- every iteration completed – a wedged or truncated iteration, or one below its
  floor, fails the run;
- every iteration's xunit output shows the target test executed and passed – a
  deleted, renamed, or disabled test cannot pass by running nothing;
- the `retry-metrics` records for the target show no `passedOnRetry` – a fix
  that added `.flaky` must not pass on retries the quarantine hides.

At pass scope the verdict is about the target test. Another test failing in the
same iteration does not fail the candidate: a pass of thousands of tests under
induced load carries other flakes the candidate does not claim to fix. The PR
lists those failures so the reviewer sees them.

The verifier runs from the job's pristine checkout of `main`, not from the
candidate's tree. That keeps the verifier's own logic out of the candidate's
reach, but not everything the verdict depends on: the candidate's tests run
through its own `scripts/test.sh` and are compiled from its own package
manifest, and the PR's `test.yml` run – which promotion requires green (§7) –
executes the candidate's copies of the CI test scripts. So the verifier checks
the candidate's diff against `main` for a **protected list**, every file on the
verdict's path:

- **The stress and verifier scripts** – `scripts/nightly-flake-stress.sh` and
  every `scripts/flake-*` file.
- **The test runner chain** – `scripts/test.sh`, `scripts/swift-safe`, and the
  scripts `scripts/test.sh` calls: `scripts/remote-verify.sh` and
  `scripts/tbd-home-fingerprint.sh`.
- **CI's test-step scripts** – everything under `scripts/ci/`, which includes
  `watched-test-pass.sh` (each pass's verdict and floor check) and
  `first-party-wipe-needed.sh`, plus `scripts/repair-spm-workspace.sh`.
- **The retry-metrics writer** – `Tests/TestSupport/FlakyTestSupport.swift`,
  which writes the `passedOnRetry` records the verifier reads.
- **The package definition** – `Package.swift` and `Package.resolved`, which
  decide what is built, which test targets exist, and which dependency and
  plugin code runs during the build.

A candidate that touches any protected file is "not eligible for ready"
whatever the stress result. The bot may still have changed it for a good
reason, so the PR is opened as usual and stays a draft, and its body names the
protected files touched and says a human must judge the change.

The verifier runs on the runner the session used. Before it starts, the job
ends the session's process tree, so the session's own processes are not running
while the candidate is judged. A process the session deliberately detached
could survive that, which is one reason the verdict alone never promotes: the
PR's own `test.yml` run on a fresh runner must also be green (§7), and a human
reviews and merges.

### 6.5 What a clean run means

The stress harness's header already states the limit, and the PR repeats it: a
clean run is one sample from a gentler regime than the one many of these flakes
appear in, not proof of a fix. CI runners have about four idle cores; the
regime #503 characterised was a load average near 150 on 12 shared cores. Pass
scope restores the population a test normally runs among, but for only three
iterations. The bar is a filter that rejects fixes which do not hold even under
modest load. The human reviewer and the ledger carry the rest: a test that fails
again after its fix reopens its issue (§4.4).

### 6.6 Two tries

An attempt allows two tries:

1. The session works and stops. If it produced no commits, the attempt ends: no
   PR, and `publish` comments on the issue with the session's notes.
2. The verifier runs. If it passes, the attempt goes to §7.
3. If it fails, a second session starts on the same branch, with the first
   session's notes and the verifier's iteration log.
4. The verifier runs again, at the same scope. Pass or fail, the attempt goes
   to §7, which opens the PR either way and marks it eligible for ready only on
   a pass.

## 7. PR lifecycle

All PR, branch, and issue writes an attempt makes use a token minted for a new
GitHub App, `tbd-flake-fixer`, and only in the `publish` and `promote` jobs,
neither of which runs a model. A PR opened with the default `GITHUB_TOKEN` triggers no
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
  §6.5 limit in one sentence. The push happens once per attempt, after
  verification, so the PR's CI runs once on the final candidate rather than
  once per try.
- **Record the verdict.** On a verifier pass, the driver sets a commit status
  `flakefix/stress` = `success` on the pushed SHA. On a fail, it sets `failure`
  and comments on the issue with the iteration log's failing lines and the
  session's notes. A candidate that touches a protected file (§6.4) also gets
  `failure`, whatever its stress result, with a status description naming the
  files, and its PR body says a human must judge the change. Either way the
  draft stays open for a human to read, finish, or close.
- **Promote.** When `test.yml` completes on a `flakefix/*` branch, the
  `promote` job marks the PR ready for review only if all of these hold for the
  run's head SHA: the run concluded `success`, the SHA carries
  `flakefix/stress` = `success`, and the SHA is still the PR's head. A human
  push to the branch moves the head to an unverified SHA, so the bot never
  promotes over a human's work. Promotion uses the App token, because a
  `ready_for_review` event raised by `GITHUB_TOKEN` would not start
  `claude-review`.
- **Review.** `claude-review` skips drafts and runs on `ready_for_review`, so
  the gate judges the PR once it is ready, like any other.
- **Merge or close.** A human does either. `Fixes #N` closes the issue on
  merge; a recurrence reopens it (§4.4). A PR closed unmerged makes the test
  ineligible until it fails again (§5).

## 8. Failure handling

- **The ledger cannot read or write GitHub.** The ledger fails closed: it exits
  non-zero and writes nothing more that run. It never posts a partial ledger
  comment and never comments about its own failure on a flake issue. Writes are
  per issue and idempotent, so a run that dies midway leaves earlier issues
  correct and the next run converges. The job going red is the signal; on the
  first red run after a green one the job posts one comment to the nightly
  tracking issue, and nothing on later consecutive reds.
- **The picker cannot read the ledger.** No attempt that night. The `fix` job
  ends red without starting a session.
- **The build fails before the session starts.** No attempt; the job ends red.
  `main` is expected to build, so this is a CI problem, not a flake.
- **The session fails** – it errors, times out, or exhausts its turns. Whatever
  commits it made still go to the verifier; with none, the attempt ends with a
  comment on the issue.
- **The candidate does not build.** The verifier fails it like any other
  failing stress run, and the second try gets the build log.
- **The stress run fails on both tries.** The draft PR stays open with
  `flakefix/stress` = `failure`, and the issue gets the notes.
- **The candidate touches a protected file** (§6.4). The PR opens as a draft
  with `flakefix/stress` = `failure` and a note naming the files; nothing
  promotes it, and a human decides.
- **The `fix` job dies before uploading its artifact.** `publish` finds no
  candidate and does nothing; nothing was pushed, so nothing is left behind.
- **The push is rejected** – most likely because the candidate touched
  `.github/workflows/`. No PR is opened; the issue gets a comment saying the fix
  appears to need a workflow change, which is a human's job.
- **CI fails on the PR.** The PR stays a draft; nothing promotes it.

## 9. Cost and slots

The account allows five concurrent macOS jobs, shared by every workflow.

- **The `fix` job** holds one macOS slot, scheduled at 05:00 UTC, with a
  300-minute timeout that ends it by 10:00, before the nightly's 11:00
  schedule (§3 covers a delayed start).

  The pass-scope figures come from the nightly's whole-fast-pass arm on
  2026-10-07. Its filter, `--parallel --skip '^TBDDaemonLiveTests\.'`, runs fast
  passes 1a, 1b, and 2 together in one process (12,164 tests) under induced
  load. Its warm iterations took about 8 minutes each; its first took about 38,
  which likely includes first-build and warm-up cost. Each fast pass the
  verifier can run is one of those three, a subset of the arm's tests, so the
  arm's figures are upper bounds for it. The quiet pass is not in the arm; its
  healthy CI run takes about 2 minutes (117 seconds of tests), so its warm
  iterations sit well inside the same bound. A pass-scope verifier run is
  therefore at most about 24 minutes warm and up to about 55 when its first
  iteration pays the warm-up.

  The worst case is an attempt at pass scope that uses both tries, with both
  verifier runs paying the warm-up. As ceilings:
  - build from a restored cache – 15 minutes;
  - pre-fix baseline, 20 test-alone iterations – 15 minutes;
  - two sessions, capped at 60 minutes each – 120 minutes;
  - two verifier runs at pass scope, up to 55 minutes each – 110 minutes.

  That totals 260 minutes and leaves 40 for checkout, the artifact upload, and
  API calls. The push and PR writes happen in `publish`, outside this budget.
  Without the warm-up the two verifier runs cost about 48 minutes and the
  attempt fits in about 200; at test scope they cost about 30 and it fits in
  about 180. The timeout stays at 300 minutes until the first implementation
  slice measures whether a verifier run on an incrementally rebuilt candidate
  pays the first-iteration warm-up. If it does not, 240 minutes covers the
  worst case and the job can start at 06:00. The test-alone iteration time
  (seconds of test plus `scripts/test.sh` and SwiftPM startup) is an estimate
  that slice measures as well.
- **The PR's own CI** draws the same two macOS jobs as any PR's `test.yml` run,
  once per attempt and so at most once a night.
- **The `ledger`, `publish`, and `promote` jobs** run on ubuntu and cost no
  macOS slot.
- **Model usage** is one attempt a night, at most two sessions, authenticated
  with the existing `CLAUDE_CODE_OAUTH_TOKEN` that the review workflow uses.

## 10. Rollout

The bot acts without a user gesture and writes to the repository, so it ships
off. The daemon is not involved, so the flags are repository variables read by
the workflow rather than `config` columns. Unset or any value other than `true`
means off.

- **`FLAKE_LEDGER_ENABLED`** – the `ledger` job writes issues. Off, it runs in
  report-only mode (§4.5).
- **`FLAKE_FIXER_ENABLED`** – the `fix` job runs on its schedule, `publish`
  and `promote` act, and the `ledger` job runs the branch reclaimer (§11). Off,
  `fix`, `publish`, and `promote` exit at their first step and the reclaimer
  step is skipped; the ledger itself still runs under its own flag.
  `workflow_dispatch` of `fix` also requires it. The reclaimer sits under this
  flag because only the fixer creates `flakefix/*` branches.

Every job also requires that the workflow is running in this repository, not a
fork, so a fork that copied the variables cannot run them.

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
- **Issues** are one per test, found by exact title before any create (§4.4),
  and the `ledger` job runs under a concurrency group so two runs cannot race to
  create the same one. Issues are records, not leaks; humans close them.

## 12. Placement

This behavior lives in CI scripts and a workflow, which change by editing a
file. The placement battery from `docs/theory-placement.md` agrees:

- **Two reasonable projects** could pick a different threshold, a different
  iteration count, or no bot at all – all theories, and all held in editable
  scripts.
- **The tunable numbers** – two occurrences, 20 test-alone iterations, 3
  pass iterations, one attempt a night, two tries – are named constants in
  those scripts, not compiled constants.
- **Nothing compiles.** The daemon, the app, and the CLI do not change. The only
  code changes outside the new scripts are in test tooling (the stress
  harness's `--xunit-dir`, `--test`, and `--pass-of` options).

## 13. Testing

Each script follows the repository's harness pattern: the logic that decides
is a pure function of input files, proven against fixtures with no network, and
its `*.test.sh` harness runs in the ubuntu step of the `lint` job beside
`nightly-flake-stress.test.sh`. GitHub access goes through a `gh` stand-in
supplied by environment variable, as `nightly-quarantine-audit.sh` does with
`AUDIT_GH_CMD`.

- **`flake-ledger.test.sh`** – xunit fixtures with failing, passing, and
  skipped test cases; a run with two attempts and two same-named artifacts,
  assigned by timestamp; fork runs, `flakefix/*` runs, and the self-test ID,
  all excluded; runs and artifacts outside the 7-day read window ignored;
  occurrence keys and the threshold at one and two keys; issue
  lookup by title, by `.flaky` trait, and by creation; a closed issue reopened;
  the same run processed twice with no change; and an API error that leaves the
  ledger unwritten.
- **`flake-pick.test.sh`** – each eligibility condition on its own, both sides;
  the tie-break order; and the re-eligibility rule after an attempt.
- **`flake-verify.test.sh`** – scope selection from a baseline with one
  failure and with none; and the judge over synthetic iteration logs and xunit
  files at both scopes: a pass; a failing iteration; a wedged iteration; a test
  absent from the xunit output; a `passedOnRetry` record; another test failing
  at pass scope while the target passes; and a diff touching a protected file,
  one case per entry in the protected list, each marked not eligible for ready
  even with a clean stress run.
- **`flake-pr.test.sh`** – promotion's three conditions, each failing alone; a
  head that moved after verification; and the open step for a candidate that
  touched a protected file, which records `failure` and names the files.
- **`nightly-flake-stress.test.sh`** gains cases for `--test` (floor 1, filter
  built from the ID), `--pass-of`, and `--xunit-dir`. The `--pass-of` cases
  map a test ID from each of the four passes – including suites starting with
  `A`, `O`, and `P`, and a nested suite – and check the pass table against the
  `watched-test-pass.sh` invocations parsed from `test.yml`, so a fixture
  `test.yml` with a changed filter or floor makes the check fail.

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
  flakes, but three pass iterations cost 25 to 55 minutes where twenty
  test-alone iterations cost minutes, and they observe the target only three
  times. Test scope is the better instrument whenever the test fails alone,
  and the baseline shows when it does.
- **Auto-merging a verified PR.** A clean stress run cannot prove a fix (§6.5),
  and a fix can change production code. A human merge is the backstop.
