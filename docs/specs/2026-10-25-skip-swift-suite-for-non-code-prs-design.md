# Skip the Swift suite for PRs that change no Swift input

## Problem

The `test` job in `.github/workflows/test.yml` builds the Swift package and runs the whole suite on a `macos-26` runner for every pull request, whatever the PR changes. A PR that edits only a spec, a skill or a flake-fixer script still spends 10 to 13 minutes of a macOS runner, and GitHub allows five concurrent macOS jobs account-wide, so that run also delays every other PR waiting for a slot.

Such PRs are common. Of the 100 most recent merged PRs, 16 changed no file the Swift suite reads, under the rule below: specs and docs, review-gate and flake-fixer workflow changes, guardrail and skill edits, and fixes to `scripts/update.sh`.

## Decision

A small gate job decides, from the PR's changed files, whether the Swift suite can say anything about the PR. When it cannot, the `test` job is skipped. A job skipped by its own `if:` reports success to branch protection, so the required `test` check passes and the PR can merge.

The rest of the workflow is unchanged. Lint and the Linux jobs run on every PR as before.

## The gate job

A new job, `changes`, runs on `ubuntu-latest`. It checks out the PR with full history and runs `scripts/ci/swift-suite-needed.sh`, which writes `run=true` or `run=false` to `$GITHUB_OUTPUT`. It also writes a step summary that lists every changed file and what it decided for that file, so a reader can see why a PR skipped or ran.

The `test` job gains:

```yaml
needs: changes
if: ${{ !cancelled() && needs.changes.outputs.run != 'false' }}
```

Only an explicit `false` skips the suite. When the gate job fails, is skipped, or ends without writing an answer, its output is empty, the expression is true, and the suite runs. `!cancelled()` is what lets `test` run after a failed gate: without a status function in its `if:`, a job whose dependency failed is skipped, and a skipped `test` would pass the required check. The gate therefore fails closed: a broken gate costs a full run, never a missed one.

Pushes to `main` and `workflow_dispatch` runs, including the remote verification valve's, always get `run=true`; the script answers from the event name without looking at a diff. Main keeps a full run on every merge, and a dispatch always asks for the whole suite.

Every PR's `test` job now starts after the gate finishes, about 20 to 40 seconds of Linux runner start-up and checkout. That delay buys a skipped PR's whole macOS run and never occupies a macOS slot.

## The rule

The script lists the PR's changed files with `git diff --name-only --no-renames origin/<base>...HEAD`: three-dot, so it sees what the PR changed since it forked rather than everything that has landed on the base since, as the cache-policy step in the same job does; and `--no-renames`, so a rename lists both its old and its new path and each is judged on its own.

The suite is skipped only when the list is non-empty and every path on it matches one of these:

- **`docs/**`**
- **`*.md` outside `Sources/` and `Tests/`** – Markdown inside those trees still runs the suite, because a target can bundle it as a resource: `Sources/TBDApp/Resources/markdown-stylesheets.md` ships in the app. Elsewhere Markdown skips even beside a suite script, as in `scripts/ci/README.md`, since no script loads it.
- **`.claude/**`**
- **`.github/**` except `.github/workflows/test.yml`** – the workflow that runs the suite is a suite input.
- **`SessionMod/**`** – the daemon ships the copy embedded in `Sources/TBDShared/SessionModContent.swift`, and the `Session mod` job checks that the copy is current. A PR that changes the embedded copy changes `Sources/` and runs the suite.
- **`recipe/**` and `tools/**`**
- **`scripts/**` except the suite's own scripts** – the suite's own scripts are:
  - `scripts/test.sh`, `scripts/swift-safe` and everything under `scripts/ci/`, which run the suite;
  - `scripts/dsym-prune-lib.sh`, `scripts/tbd-home-fingerprint.sh` and `scripts/remote-verify.sh`, which `test.sh` loads or runs;
  - `scripts/repair-spm-workspace.sh`, which the `test` job runs;
  - `scripts/restart.sh` and `scripts/restart-*-lib.sh`. `DaemonBuildSkewTests` reads `restart.sh`, `restart.sh` loads the libraries, and `swift-safe` names `restart-build-lib.sh`.

Every other path runs the suite: `Sources/`, `Tests/`, `Package.swift`, `Package.resolved`, `Resources/`, `rust/`, and any top-level directory or file the list does not name. The list names what is safe to skip, never what is risky, so a path nobody thought about runs the suite.

The script also runs the suite whenever it cannot answer honestly:

- the base ref does not resolve;
- `git diff` fails;
- the diff is empty.

An empty diff cannot be told apart from a diff the script failed to read.

## Keeping the list true

The skip list is only as good as its list of suite scripts. If the suite comes to depend on a script nobody added, a PR that changes only that script skips the suite that would have caught it. Two checks guard against that, both in `scripts/ci/swift-suite-needed.test.sh`, which runs in the Lint job. Lint is never skipped.

**Case table.** The harness runs the script against scratch git repos and checks each answer:

- docs only → skip
- one Swift file → run
- `.github/workflows/test.yml` → run
- `scripts/restart.sh` → run
- an unused script → skip
- a Markdown file under `Sources/` → run
- a rename from `Sources/` into `docs/` → run, because only `--no-renames` lists the `Sources/` side
- an empty diff → run
- a `push` event → run
- a base ref that does not resolve → run

**Drift check.** The harness gathers every script the suite can reach:

- each script named on a line of the `test` job in `test.yml` that is not a `#` comment;
- each script named on a line of `scripts/test.sh` or `scripts/swift-safe` that is not a `#` comment;
- each `"scripts/…"` string literal in a Swift file under `Sources/` or `Tests/` that names a file that exists in the repo;
- each file that a gathered script loads with `source` or `.`, and what that file loads in turn.

A script counts as named when the line holds its full `scripts/…` path, or its bare file name, as in `source "$(dirname "${BASH_SOURCE[0]}")/dsym-prune-lib.sh"`. Names are followed one level, from the job and the two wrappers; loads are followed all the way down. Following names further reaches scripts that are mentioned only in passing: `restart.sh` names `update.sh`, and `update.sh` is not a suite input.

It fails if any script it gathers is missing from the suite's list. Today it gathers exactly the list above, apart from the `scripts/ci/` files the job does not name. A PR that makes the suite depend on a new script changes one of these referencing files, so that PR runs the suite and its Lint job fails until the script is added to the list.

The drift check cannot see a Swift test that builds a script's path from separate pieces, such as `appendingPathComponent("scripts").appendingPathComponent("x.sh")`. No test does that today: the only repo file outside `Sources/` and `Tests/` that a Swift test reads is `scripts/restart.sh`, through a string literal.

## Verification

- **The run path** – the PR that adds the gate changes `scripts/ci/` and `test.yml`, so its own CI must show `changes` answering `run=true` and the full suite running.
- **The skip path** – the first docs-only PR after it merges must show `test` as skipped and the required check as passed. The gate's step summary on that run names each file and the rule it matched.
- **The rule against history** – before merging, the script runs against the 100 most recent merged PRs. A prototype of the rule above skips 16 of them, and the script must skip the same 16. Two of those 100 PRs list more than 100 files, which `gh` truncates; both change `Sources/`, so truncation cannot turn either into a skip.

## Rejected alternatives

- **A workflow-level `paths-ignore` filter** – a workflow that a path filter skips never reports its jobs, so the required `test` check stays pending forever and the PR cannot merge without an admin.
- **A gate step inside the `test` job** – it avoids the gate job's start-up delay, but a skipped PR still waits for a macOS runner and holds one of the five slots while it checks out. The job then reports success although no test ran, where a job skipped by `if:` shows as skipped. Each later step needs its own `if:` too, and missing one runs part of the job on a PR meant to skip.
- **Skipping a script only if it is on a list of unused scripts** – it fails safe without a drift check, but every new script runs the suite until someone lists it, and nobody has a reason to. The skip would wear away over time. The drift check gets the same safety while keeping new scripts skippable.
- **Gating Lint the same way** – Lint takes about 3 minutes and runs the harnesses for the scripts this rule skips, so a scripts-only PR needs it. A docs-only Lint skip would need a second, narrower rule for little gain.
