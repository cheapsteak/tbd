# CI layout for the phone-control parts

TBD's CI already skips its expensive Swift suite with a gate job, not a path filter. The required `test` check stays reportable because a job skipped by its own `if:` reports success, while a workflow skipped by `paths:` never reports at all. Today only three checks are required: `claude-review`, `test` and `Lint`. No workflow uses a `paths:` filter. The Swift gate runs the suite for any path it does not know, so a change under `relay/` or `phone/` would run the full macOS suite today. The proposal copies the Swift gate's pattern into one new workflow, `phone.yml`, rather than adding jobs to `test.yml`. A classifier script decides which of three parts (relay, loader, phone app) a PR touches. Each part job is skipped by its own `if:`, and one always-running aggregator job, `Phone checks`, becomes the single new required check. The Swift gate gains three narrow skip rules so relay-only and phone-only PRs stop running the Swift suite, while shared test vectors and the protocol schema still run both sides. The loader deploys from a second workflow that fires only on pushes to `main` touching `phone/loader/`. Its credential can trigger a deploy workflow in the separate org's repo, but cannot write content there. Gating `Lint` and the push-to-`main` Swift run are follow-ups, not part of this design.

Sources accessed 2026-11-07. Current-state claims cite this repo's files by `path:line`. Branch protection was read with `gh api` on the same date. Claims marked **(unverified)** could not be confirmed. The org and repo names below are `acme` placeholders.

## 1. How CI works today

### 1.1 Workflows and their triggers

- **`test.yml` ("Test")** – Runs on `pull_request` to `main`, on `push` to `main`, and on `workflow_dispatch` ([`.github/workflows/test.yml:3-23`](../../../.github/workflows/test.yml)). The dispatch trigger exists for the remote verification valve. One concurrency group per branch cancels older runs (`test.yml:25-27`). This is the only workflow that runs tests on pull requests.
- **`claude-code-review.yml`** – Produces the required `claude-review` check. It runs on `pull_request_target` (`claude-code-review.yml:21-23`). It skips only draft PRs (`claude-code-review.yml:31-37`).
- **`release.yml`** – Runs on `workflow_run` when Test completes on `main` (`release.yml:16-20`). It builds and publishes only when that Test run concluded `success` (`release.yml:45-50`). It starts with `permissions: {}` and splits a read-only build job from a write-scoped publish job (`release.yml:9-14`, `release.yml:30`).
- **`flake-fixer.yml`** – Runs on a schedule, on `workflow_run` of Nightly and Test, and on `status` events. Its `promote` job requires a Test run that concluded `success` (`flake-fixer.yml:1356-1363`). It mints GitHub App tokens and gates its jobs on repository variables such as `vars.FLAKE_LEDGER_ENABLED` (`flake-fixer.yml:151-155`).
- **`nightly.yml`**, **`preflight-cleanup.yml`**, **`claude.yml`**, **`pr-user-story.yml`**, **`claude-code-review-legacy.yml`** – Scheduled, comment-driven or dispatch-only workflows. None runs tests on a PR.

### 1.2 Jobs in `test.yml`

- **`lint` ("Lint")** – macOS, about 3 minutes, no gate (`test.yml:46-247`). It runs SwiftLint, the Rust archive stamp check, the migration lint, and the macOS-only script harnesses. It also runs the Swift gate's own harness, because "Lint is never skipped" (`test.yml:204-222`).
- **`plans-guard`** – Linux, no gate (`test.yml:249-262`).
- **`script-harnesses`** – Linux, no gate. This is the home for every bash, git or Python harness that needs no BSD tool (`test.yml:264-399`).
- **`flake-harnesses`** – Linux matrix of four harnesses, no gate (`test.yml:417-441`).
- **`review-scripts-tests`** – Linux, no gate. Its comment explains why: "No paths filter: the suite runs in seconds, and an unconditional run can never leave the check unreported" (`test.yml:456-458`).
- **`session-mod`** – Linux, no gate (`test.yml:473-502`). This is the repo's only Node job today. It pins Node 22 (`test.yml:488-490`). It checks that the TypeScript under `SessionMod/` matches the copy embedded in `Sources/TBDShared/SessionModContent.swift` (`test.yml:492-493`, generator at `scripts/gen-session-mod-content.py:2-14`).
- **`changes` ("Swift suite gate")** – Linux, about 30 seconds. It runs `scripts/ci/swift-suite-needed.sh` and exposes one output, `run` (`test.yml:519-538`).
- **`test`** – macOS, the Swift build and five test passes, 10 to 13 minutes. It has `needs: changes` and `if: ${{ !cancelled() && needs.changes.outputs.run != 'false' }}` (`test.yml:556-557`). It has no `name:`, so its check is called `test` (`test.yml:554-555`).

### 1.3 Path-based skipping that already exists

There is exactly one path-based skip, and it is a gate job, not a filter:

- **No `paths:` or `paths-ignore:` filters** – A search of `.github/workflows/` finds none. No workflow uses `dorny/paths-filter` either.
- **The Swift suite gate** – `scripts/ci/swift-suite-needed.sh` lists the PR's files with `git diff -z --name-only --no-renames origin/<base>...HEAD` (`swift-suite-needed.sh:277`). It answers `run=false` only when every path matches a skip rule (`swift-suite-needed.sh:125-165`). The skip rules are `docs/**`, `*.md` outside `Sources/` and `Tests/`, `.claude/**`, `.github/**` except `test.yml`, `SessionMod/**`, `recipe/**`, `tools/**`, and `scripts/**` except the suite's own scripts. Any path no rule names runs the suite (`swift-suite-needed.sh:163-164`).
- **The gate fails closed** – Any event other than `pull_request` runs the suite (`swift-suite-needed.sh:265-268`). So do an unresolvable base ref, a failed diff and an empty diff (`swift-suite-needed.sh:270-281`, `:235-236`). The `run=` line is written once, last.
- **The gate is pinned by a harness** – `scripts/ci/swift-suite-needed.test.sh` checks a case table against scratch repos. It also checks a drift list of every script the suite can reach. It reads the real `test.yml` to pin the `needs:`, the exact `if:`, the missing `name:`, and the `fetch-depth: 0` checkout (`swift-suite-needed.test.sh:965-998`).
- **Its spec** – [`docs/specs/2026-10-25-skip-swift-suite-for-non-code-prs-design.md`](../../specs/2026-10-25-skip-swift-suite-for-non-code-prs-design.md). It rejects a workflow-level `paths-ignore` because the required check would stay pending (spec line 111). It also rejects gating Lint (spec line 114).

## 2. Required checks

### 2.1 What is required on `main`

`gh api repos/{owner}/{repo}/branches/main/protection` returned these settings. `gh api repos/{owner}/{repo}/rules/branches/main` returned no rulesets.

- **Required status checks** – `claude-review`, `test` and `Lint`, all from the GitHub Actions app.
- **`strict`** – `false`. A PR need not be up to date with `main` before it merges.
- **Reviews** – One approving review.
- **`enforce_admins`** – `false`, which is what makes the documented admin merges possible.

Two more settings matter for the deploy design. The repository's default workflow token is read-only (`default_workflow_permissions: read`). The repository already serves a GitHub Pages site from `main`'s `docs/` folder with the legacy builder; that is the deep-link redirector. So the loader cannot share this repo's Pages site. That fits the dedicated-origin argument in [phone-clients.md §1.9](phone-clients.md).

None of the other `test.yml` jobs is required, including `session-mod`, `script-harnesses` and `plans-guard`. They report but do not block a merge.

### 2.2 How GitHub treats skipped checks

- **A workflow skipped by `paths:`, a branch filter or a commit message** – Its checks "stay in a 'Pending' state and block merging" ([GitHub Docs: Troubleshooting required status checks, "Handling skipped but required checks"](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/collaborating-on-repositories-with-code-quality-features/troubleshooting-required-status-checks)). The [workflow syntax reference](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax) repeats this under `on.<push|pull_request>.paths`.
- **A job skipped by its own `if:`** – "The job reports 'Success'" (same troubleshooting page).
- **A job whose dependency failed** – Without a status function in `if:`, GitHub adds an implicit `success()`. The job is then skipped, and a skipped job passes. `test.yml:548-552` explains this, and it is why the `test` job's `if:` starts with `!cancelled()`.
- **A job with `if: always()` in a cancelled run** – The condition "would evaluate to true and the job continues to run" ([GitHub Docs: Workflow cancellation](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-cancellation)).
- **`needs.<job_id>.result`** – "Possible values are `success`, `failure`, `cancelled`, or `skipped`" ([GitHub Docs: Contexts](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts)).

### 2.3 How this repo handles the trap

- **No required workflow has a path filter** – The `test` check is skipped by a job-level `if:` driven by the `changes` job, so it always reports (`test.yml:540-557`).
- **The gate fails closed** – Only an explicit `false` skips the suite. A failed, skipped or silent gate leaves the output empty, and `!= 'false'` then runs the suite (`test.yml:541-546`).
- **Cheap jobs stay unconditional** – `review-scripts-tests` takes no filter, so its check is never unreported (`test.yml:456-458`).
- **A skip never overwrites a red verdict** – `claude-review` skips only drafts. It drops the `labeled` trigger so that a skipped run can never replace a failing one (`claude-code-review.yml:31-37`).
- **Checks are matched by job name** – "Branch protection matches a required check by job NAME, not by workflow file", so only one job may be named `claude-review` ([`docs/pr-review-gate.md:11-16`](../../pr-review-gate.md)). The `test` job must keep its name for the same reason (`test.yml:554-555`).
- **Trigger changes need an admin merge** – A PR that changes `claude-review`'s trigger event gets no run and must be admin-merged ([`docs/pr-review-gate.md:427-436`](../../pr-review-gate.md)).

## 3. Constraints on any CI change

These come from `CLAUDE.md`, `docs/pr-review-gate.md` and the workflows themselves.

- **Never reuse a required check name** – No new job may be named `claude-review`, `test` or `Lint`. A job with one of those names would report into that context. A skipped job of that name would pass it.
- **Leave `claude-code-review.yml`'s trigger alone** – Changing it needs a one-time admin merge. The design below does not touch that file.
- **Keep the gate's wiring intact** – The Swift gate's harness pins `test.yml`'s `needs:`, `if:`, job name and checkout. A change to that wiring must also change the harness, or Lint goes red.
- **Editing `test.yml` runs the Swift suite** – The gate treats `test.yml` as a suite input (`swift-suite-needed.sh:140-141`). So does every file under `scripts/ci/` (`swift-suite-needed.sh:88`). Other files under `.github/` skip it (`swift-suite-needed.sh:142-143`).
- **Test's conclusion feeds other workflows** – Release publishes only after a green Test run on `main` (`release.yml:45-50`). The flake fixer promotes only after a green Test run (`flake-fixer.yml:1356-1363`). The remote verification valve dispatches `test.yml`, and a red non-test job makes it refuse a verdict (`scripts/remote_verify.py:46-54`). Any job added to `test.yml` joins all three.
- **Every job needs `timeout-minutes`** – The rationale is at `test.yml:29-44`.
- **Every CI script needs a harness that CI runs** – "A test file no workflow runs is worth nothing" (`test.yml:264-266`).
- **Public, multi-tenant repo** – Workflows must not hardcode the target org or repo. Use repository variables, as `flake-fixer.yml` does with `vars.*`, so a fork can deploy its own loader.
- **Banned words** – `CLAUDE.md` bans two words from code, PR text and commit messages. Workflow names, steps and comments count as code.
- **Spec first** – This layout is part of the phone-control design, so it belongs in that spec (brainstorming rule in `CLAUDE.md`). Changing the Swift gate's rule also means updating [its spec](../../specs/2026-10-25-skip-swift-suite-for-non-code-prs-design.md) so the spec still stands alone.

## 4. Design proposal

### 4.1 A separate workflow, not more jobs in `test.yml`

Put the JS parts in a new workflow, `.github/workflows/phone.yml` (name: "Phone"). Do not add them to `test.yml`. The reasons:

- **Release stays decoupled** – A red relay test on `main` would turn the Test run red. Release would then publish nothing for a commit whose Swift code is fine (`release.yml:45-50`).
- **The flake fixer and the valve stay decoupled** – Both read Test's conclusion (`flake-fixer.yml:1356-1363`, `remote_verify.py:46-54`).
- **Editing the JS CI does not run the Swift suite** – An edit to `phone.yml` falls under `.github/**`, which the Swift gate skips. An edit to `test.yml` would cost a 10 to 13 minute macOS run.
- **Separate concurrency** – Use the group `phone-${{ github.head_ref || github.ref_name }}`, not test's `test-…` group. Concurrency groups are shared across workflows, so reusing test's group expression would let the two workflows cancel each other.

Mirror `test.yml`'s triggers: `pull_request` to `main`, `push` to `main`, and `workflow_dispatch`. A push or a dispatch runs every part, as the Swift gate does for non-PR events. Set `permissions: contents: read` at the top.

### 4.2 What each part depends on

Give each part its own `package.json` and lockfile inside its own folder. Do not add a root `package.json`, `.npmrc`, `.node-version` or shared lint config. A root lockfile would make every dependency bump run every part. Any new top-level file would also run the Swift suite, because the Swift gate runs unknown paths. Pin the Node version in the workflow, as `session-mod` does (`test.yml:488-490`).

The inputs of each part (folder names are provisional):

- **Relay** – `relay/cloudflare/**`, which holds its `package.json`, lockfile, `wrangler.toml`, `tsconfig` and Vitest config.
- **Loader** – `phone/loader/**`.
- **Phone app** – `phone/app/**`, plus the committed built bundle under `Sources/` (see 4.6), plus its generator script.
- **Shared by all three parts** – `phone/test-vectors/**`, the protocol schema (for example `phone/protocol/**`), `.github/workflows/phone.yml`, and the classifier script and its harness. If the relay never reads the vectors, drop them from its set. The default is to run it.
- **Shared with Swift** – `phone/test-vectors/**` and the protocol schema. The Swift tests read both.

If the loader checks the phone app by hash, the file that holds that hash is an input to both parts. That depends on the security design, so it is open here.

### 4.3 The classifier

Add `scripts/ci/phone-parts-needed.sh`. Give it the same contract as `swift-suite-needed.sh`, and reuse its structure:

- **Same diff** – `git diff -z --name-only --no-renames origin/<base>...HEAD` over a `fetch-depth: 0` checkout. The diff must cover the whole PR, never just the last push. Otherwise a docs-only follow-up push would skip a part, and the skipped job's success would overwrite the earlier red result for that head commit. That is the hazard `claude-review` avoids (`claude-code-review.yml:31-37`).
- **Same failure rule** – For a non-PR event, an unresolvable base, a failed diff or an empty diff, every part answers `true`. All outputs (`relay=`, `loader=`, `phone_app=`) are written once, last.
- **Same direction of rules** – Name what each part can safely skip, and run on anything unknown. A part skips a path under another part's folder. It also skips known Swift or repo-only paths: `Sources/` (except the generated bundle), `Tests/`, `Package.swift`, `Package.resolved`, `rust/`, `SessionMod/`, `docs/`, `.claude/`, `recipe/`, `tools/`, `.github/` except `phone.yml`, and `scripts/` except the classifier and the bundle generator. Any other path runs every part. A new shared file therefore runs the JS tests until someone decides otherwise. This mirrors the Swift gate's rule: "The list names what is safe to skip, never what is risky" (spec line 50).
- **Same record** – A step summary lists each file and the parts it triggered.
- **A `--classify` seam and a harness** – `scripts/ci/phone-parts-needed.test.sh` should hold a case table and pin `phone.yml`'s wiring, the way `swift-suite-needed.test.sh:965-998` pins `test.yml`'s. Pin each part job's exact `if:`, the aggregator's `if: always()`, the aggregator's `name:`, and the classifier's full-history checkout.

Placement trade-off: under `scripts/ci/`, the script is a Swift suite input (`swift-suite-needed.sh:88`). An edit to the classifier would then also run the Swift suite. That is rare and fits the convention that CI decision scripts live in `scripts/ci/`. If that cost matters, put it at `scripts/phone-parts-needed.sh`, where the Swift gate already skips it.

**Why not `dorny/paths-filter`?** It is a third-party action, and its filters would sit in YAML that no harness tests. It does not write a per-file record of which rule decided each path. On push events it diffs against the previous push by default, not the base **(unverified)**. The repo already has a tested, fail-closed pattern. Apart from GitHub's own `actions/*` and Anthropic's `claude-code-action`, the repo uses one community action, `git-restore-mtime-action`, and pins it by commit SHA. If dorny is ever chosen, pin it the same way.

### 4.4 Wiring the part jobs and the aggregator

Each part job copies the `test` job's idiom (`test.yml:556-557`):

```yaml
  relay:
    name: Relay tests
    needs: changes
    if: ${{ !cancelled() && needs.changes.outputs.relay != 'false' }}
    runs-on: ubuntu-latest
    timeout-minutes: 10
```

One aggregator job is the only new required check:

```yaml
  phone-checks:
    name: Phone checks
    needs: [changes, harness, relay, loader, phone_app]
    if: ${{ always() }}
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Pass only if every part passed or was skipped by the gate
        env:
          NEEDS: ${{ toJSON(needs) }}
        run: |
          jq -e '. as $n | $n.changes.outputs as $gate
            | $n.harness.result == "success"
              and all("relay", "loader", "phone_app";
                      $n[.].result == "success"
                      or ($n[.].result == "skipped" and $gate[.] == "false"))' <<<"$NEEDS"
```

This snippet is a sketch and has not been run. Its rules are what matter:

- **A part may be skipped only when the gate said `false` for it** – A part skipped for any other reason fails the aggregator. That covers a run cancelled before the part started.
- **`always()`, not `!cancelled()`** – Elsewhere the repo uses `!cancelled()`. Here it would be wrong. A cancelled run would skip the aggregator, and a skipped aggregator reports success. With `always()` the aggregator runs in a cancelled run and fails, because a cancelled part is not `success`.
- **A broken gate costs a full run, not a red check** – If `changes` fails, its outputs are empty. Every part then runs, and the aggregator passes if they pass. The harness job catches the classifier bug itself.
- **One context for branch protection** – A fourth part later only edits `needs:`. It needs no settings change.
- **A unique name** – No other job in `.github/workflows/` may be named `Phone checks`.

The `harness` job runs `scripts/ci/phone-parts-needed.test.sh` on every run. It goes in `phone.yml` rather than `script-harnesses`, because `script-harnesses` is not required and `test.yml` edits run the Swift suite. This follows the reason the Swift gate's harness lives in Lint: it must sit in a job that always runs and blocks (`test.yml:213-216`).

What each part job runs:

- **Relay tests** – `actions/setup-node` with `cache: npm` and `cache-dependency-path: relay/cloudflare/package-lock.json`. Then `npm ci`, a type check, and `vitest run` with Cloudflare's Workers pool ([Cloudflare Docs: Vitest integration](https://developers.cloudflare.com/workers/testing/vitest-integration/)). Optionally `wrangler deploy --dry-run` to prove the Worker bundles; that step needs no credentials. Whether the Workers pool runs cleanly on `ubuntu-latest` is **(unverified)**.
- **Loader tests** – Node unit tests over `phone/loader/`. An optional Playwright WebKit smoke test can run as a second job under the same gate, so the fast tests report first. Run it on Linux: Playwright ships WebKit for Linux ([Playwright: Browsers](https://playwright.dev/docs/browsers)), and a macOS runner is one of the five scarce slots. How closely Playwright's WebKit matches iOS Safari is **(unverified)**.
- **Phone app tests** – Node unit tests over `phone/app/`. Then the freshness check: rebuild the bundle and fail if the committed copy differs, as `gen-session-mod-content.py --check` does (`test.yml:492-493`).

The Linux jobs run on every PR, so a Swift-only PR still pays for three short ones: `changes`, `harness` and `Phone checks`. That is roughly a minute of Linux time in total **(estimate, unmeasured)**. No macOS slot is used.

### 4.5 Changes to the Swift gate

Without these changes, relay-only and phone-only PRs run the full Swift suite, because no skip rule names those paths (`swift-suite-needed.sh:163-164`).

- **Add three skip rules** – `relay/**`, `phone/loader/**` and `phone/app/**`. Keep them that narrow. Never add `phone/**`: the test vectors and the protocol schema sit under `phone/` and are Swift inputs.
- **Leave shared paths unnamed** – `phone/test-vectors/**` and `phone/protocol/**` stay unlisted, so they keep running the suite by the default rule. The drift check cannot see a Swift test that builds a path from pieces (spec line 99), so this default is what keeps them covered.
- **Add harness cases** – `relay/cloudflare/src/x.ts` skips. `phone/app/src/x.js` skips. `phone/loader/index.html` skips. `phone/test-vectors/x.json` runs. The generated bundle under `Sources/` runs.
- **Update the spec's rule list** – In place, so the spec states the current rule.

This edits `scripts/ci/`, so the PR that makes it runs the Swift suite. That is intended. `test.yml` itself needs no change.

### 4.6 Where the phone app's built bundle lives

Commit the built bundle under `Sources/`, either as a SwiftPM `.copy` resource or as a generated Swift file, as `SessionModContent.swift` is. Check it for freshness in the phone app job. This mirrors the `SessionMod/` precedent, and it keeps path gating sharp:

- **A change to `phone/app` that changes the bundle** – It also changes `Sources/`, so both the Swift suite and the phone app job run. The shipped resource changed, so both should.
- **A change to `phone/app` tests or tooling only** – Only the phone app job runs.
- **It ships with no extra packaging step** – The release packager already copies every resource bundle beside the binaries (`scripts/ci/package-release.sh:45-54`).
- **Building TBD needs no Node** – The build reads only the committed file.

The other option is to concatenate the bundle from `phone/app/` with a script at build time. Then `phone/app/**` becomes a Swift build input, and it must not be on the Swift gate's skip list. That gives up the gating this report aims for.

One difference from the precedent: `session-mod` is not a required check, so a stale `SessionModContent.swift` can merge today. Because the phone app job reports into `Phone checks`, a stale phone bundle cannot. That matters because this bundle handles keys.

### 4.7 Deploying the loader

Use a second new workflow, `.github/workflows/phone-loader-deploy.yml`. It is never a required check, so a workflow-level `paths:` filter is safe here. The trap in 2.2 applies only to required checks.

```yaml
on:
  push:
    branches: [main]
    paths: ['phone/loader/**', '.github/workflows/phone-loader-deploy.yml']
  workflow_dispatch:
permissions: {}
concurrency:
  group: phone-loader-deploy
  cancel-in-progress: true
```

For pushes, GitHub decides `paths:` with a two-dot diff of the push. A push of more than 1,000 commits, or a diff that times out, always runs ([workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)). That is harmless for an idempotent deploy.

The workflow has two jobs, split by privilege as `release.yml` splits build and publish (`release.yml:9-14`):

- **`verify`** – `contents: read`. It runs the loader's tests on the pushed commit.
- **`dispatch`** – `needs: verify`, `permissions: {}`, and `environment: phone-loader`. It runs only when `vars.PHONE_LOADER_DEPLOY_ENABLED == 'true'`, which is unset by default; `flake-fixer.yml:151` is the precedent. It mints a GitHub App token with `actions/create-github-app-token`, using `owner: ${{ vars.PHONE_LOADER_OWNER }}`, `repositories: ${{ vars.PHONE_LOADER_REPO }}` and `permission-actions: write`. It then calls `gh workflow run deploy.yml --repo <owner>/<repo> -f commit=$GITHUB_SHA`.

What the separate org holds (none of it lives in this repo):

- **A GitHub App** – Owned by the separate org and installed only on the loader's repo. Its only repository permission is Actions: write, which is what the workflow dispatch endpoint needs ([GitHub Docs: Permissions required for GitHub Apps](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps)). The repository dispatch endpoint would need Contents: write instead, so the design avoids it. The minted token lasts at most one hour and is revoked when the job ends ([create-github-app-token README](https://github.com/actions/create-github-app-token)).
- **A deploy workflow in the loader repo** – `on: workflow_dispatch` with a `commit` input. It has `permissions: contents: read, pages: write, id-token: write` and `environment: github-pages`, as `actions/deploy-pages` requires ([deploy-pages README](https://github.com/actions/deploy-pages)). It checks out this public repo at `commit` with `persist-credentials: false`. It requires `commit` to be on `main`, using the check at `release.yml:74-83`. It then compares `git rev-parse "$commit:phone/loader"` with `git rev-parse origin/main:phone/loader`. If they differ, a newer loader is on its way, and the run exits without deploying. That makes out-of-order dispatches harmless. Next it writes a `version.json` with the commit and the tree hash. Finally it uploads with `actions/upload-pages-artifact` and deploys with `actions/deploy-pages`. Keep a reference copy of this workflow in this repo, for example in `phone/loader/deploy/`, so forks can copy it.

What this repo holds:

- **An environment, `phone-loader`** – Its deployment branch policy allows only `main`: "Only branches and tags that match your specified name patterns can deploy to the environment" ([GitHub Docs: Deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)). A PR branch therefore cannot reach the key. Fork PRs get no secrets anyway. Required reviewers are optional; on free plans they work only for public repositories (same page).
- **An environment secret** – The App's private key.
- **Variables** – The App ID, the target owner and repo, and the enable switch. Nothing names an org in the workflow file.

Why this shape:

- **The credential in the public repo cannot change what is served** – With Actions: write, a leaked token can only start the loader repo's deploy workflow. That workflow deploys only code that is on `main` and still current. A token with Contents: write, used to push built files into the loader repo, could publish anything to the origin that holds the phone's keys.
- **The loader repo needs no long-lived secret** – `deploy-pages` uses OIDC.
- **A schedule-only pull is fragile** – A scheduled workflow in the loader repo would need no secret here. But "in a public repository, scheduled workflows are automatically disabled when no repository activity has occurred in 60 days" ([GitHub Docs: Disabling and enabling a workflow](https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-workflow-runs/disabling-and-enabling-a-workflow)). A repo that only deploys never commits, so its schedule would go quiet.
- **Optional reconciler** – A weekly scheduled job in this repo could compare the live `version.json` tree hash with `main:phone/loader` and dispatch a deploy when they differ. This repo is active, so the 60-day rule does not bite. It matches the repo's rule that durable external resources get a named reconciler, though a deployed page is a stretch of that rule.

A PR that edits the deploy workflow cannot test the dispatch before it merges, because the environment refuses non-`main` refs. That is the intended security. Verify after merge with `workflow_dispatch`.

The relay's own deployment (`wrangler deploy`) is out of scope. If CI ever deploys it, use the same pattern: a `main`-only environment and a Cloudflare API token scoped to one account and Workers scripts only.

### 4.8 Rollout order

1. Land `phone.yml`, the classifier and its harness, the first part, and the Swift gate's new skip rules in one PR. A `pull_request` run reads the workflow from the PR itself ([`docs/pr-review-gate.md:429-431`](../../pr-review-gate.md)), so that PR exercises the new workflow. Its edit to `scripts/ci/` also runs the Swift suite, which proves the Swift gate's run path.
2. After it merges and `Phone checks` has reported on `main`, an admin adds `Phone checks` to the required contexts. Whether the context must have run once before the settings page offers it is **(unverified)**. Any open PR that has not been pushed since then has no `Phone` run. A new push, or closing and reopening the PR, starts one.
3. Land `phone-loader-deploy.yml` with the enable variable unset. Then create the App, the environment, the secret, the variables and the loader repo's deploy workflow. Set the variable and verify with `workflow_dispatch`.

No step changes `claude-code-review.yml`'s trigger, so no admin merge is needed.

### 4.9 What changes and what is new

Changes to existing things:

- **`scripts/ci/swift-suite-needed.sh`** – Three skip rules.
- **`scripts/ci/swift-suite-needed.test.sh`** – New cases.
- **`docs/specs/2026-10-25-skip-swift-suite-for-non-code-prs-design.md`** – The rule list.
- **Branch protection** – One new required context, `Phone checks`. This is a settings change, not a file.
- **Unchanged** – `test.yml`, `release.yml`, `flake-fixer.yml`, `claude-code-review.yml` and `nightly.yml`.

New things:

- **`.github/workflows/phone.yml`** – The gate, the harness, the part jobs and the aggregator.
- **`.github/workflows/phone-loader-deploy.yml`** – The verify and dispatch jobs.
- **`scripts/ci/phone-parts-needed.sh` and `.test.sh`** – The classifier and its harness.
- **A bundle generator with `--check`** – For example `scripts/gen-phone-app-bundle.py`, modeled on `scripts/gen-session-mod-content.py`.
- **Outside the repo** – The loader repo, its deploy workflow, the GitHub App, the `phone-loader` environment, its secret and the variables.

## 5. Where the Swift side's own path filters stand

- **The Swift suite is already gated** – The `test` job skips docs-only and other non-Swift PRs through the `changes` job (section 1.3). It does not run on every change.
- **But it runs for `relay/` and `phone/` today** – Unknown top-level paths run the suite (`swift-suite-needed.sh:163-164`). Section 4.5 is the in-scope fix.
- **Lint runs on every change** – Lint is required, runs on macOS and takes about 3 minutes. A relay-only or docs-only PR still spends one of the five macOS slots on it. The Swift gate's spec chose not to gate Lint (spec line 114). **Follow-up, not designed here:** a narrower gate for Lint on PRs that touch only `relay/`, `phone/loader/`, `phone/app/` or `docs/`. It would need its own always-reporting pattern, because Lint is a required context.
- **A push to `main` always runs the whole Swift suite** – By design, for every merge (`swift-suite-needed.sh:265-268`, spec line 28). After a green Test run, Release builds again on macOS. So a relay-only merge costs a full Swift run plus a release build on `main`. **Follow-up:** decide whether `main` should honor the gate for clearly non-Swift merges. That would change what Release publishes, so it needs its own spec.
- **The ungated Linux jobs** – `plans-guard`, `script-harnesses`, `flake-harnesses`, `review-scripts-tests` and `session-mod` run on every PR. They are cheap and not rationed. **Follow-up:** move `session-mod` under the same part-gate pattern, and decide whether its freshness check should be required.
- **Semantic conflicts** – `strict` is `false`, so two PRs that each pass can still combine into a red `main`. For example, one PR changes a vector and another changes the phone app. Path gating does not cause this, but it makes each PR's run narrower. The push-to-`main` run of `phone.yml` runs every part and catches it after the merge. Whether Release should also wait on Phone's `main` run is open. `workflow_run` fires per workflow, so a join would be needed **(unverified that this is worth the complexity)**.

## 6. Not verified

- Whether the Cloudflare Workers Vitest pool runs on `ubuntu-latest` without extra setup.
- How closely Playwright's Linux WebKit tracks iOS Safari.
- Whether a new required context must have reported once before branch protection settings offer it.
- The total cost of the three always-running Linux jobs; one minute is an estimate.
- The `jq` aggregator snippet in 4.4, which has not been run.
- Which JS parts actually read the shared test vectors; the default above runs all three.

## Proposed layout

In `.github/workflows/phone.yml` ("Phone"; triggers: `pull_request` to `main`, `push` to `main`, `workflow_dispatch`; concurrency group `phone-<ref>`):

- **`changes` ("Phone parts gate")** – Trigger paths: every run. It runs `scripts/ci/phone-parts-needed.sh` on Linux with `fetch-depth: 0` and outputs `relay`, `loader` and `phone_app`. Not required itself; its outputs feed `Phone checks`.
- **`harness` ("Phone parts gate harness")** – Trigger paths: every run. It runs `scripts/ci/phone-parts-needed.test.sh`, which holds the case table and pins this workflow's wiring. Reports into `Phone checks`.
- **`relay` ("Relay tests")** – Trigger paths: `relay/cloudflare/**`, `phone/test-vectors/**`, `phone/protocol/**`, `phone.yml`, the classifier and its harness, and any path the classifier does not know. It runs `npm ci`, a type check, Vitest with the Workers pool, and optionally `wrangler deploy --dry-run`, on Linux. Reports into `Phone checks`.
- **`loader` ("Loader tests")** – Trigger paths: `phone/loader/**`, plus the shared set listed for `relay`. It runs Node unit tests on Linux. Reports into `Phone checks`.
- **`loader_webkit` ("Loader WebKit smoke", optional)** – Same trigger paths as `loader`. It runs a Playwright WebKit smoke test on Linux. Reports into `Phone checks` if added.
- **`phone_app` ("Phone app tests")** – Trigger paths: `phone/app/**`, the committed bundle under `Sources/`, the bundle generator, plus the shared set. It runs Node unit tests and the bundle freshness check on Linux. Reports into `Phone checks`.
- **`phone-checks` ("Phone checks")** – Trigger paths: every run, with `if: always()`. It passes only if `harness` passed and each part either passed or was skipped because the gate said `false`. **Required**: the one new context added to branch protection.

In `.github/workflows/phone-loader-deploy.yml` (push to `main` with `paths:` filter, plus `workflow_dispatch`; never required):

- **`verify`** – Trigger paths: `phone/loader/**` and the workflow file itself, on `main` only. It runs the loader tests with `contents: read`. Not required.
- **`dispatch`** – Same trigger, after `verify`, only when `vars.PHONE_LOADER_DEPLOY_ENABLED == 'true'`. It runs in the `main`-only `phone-loader` environment. It mints an App token limited to Actions: write on the one loader repo and dispatches that repo's deploy workflow with the commit. Not required.

In the existing `.github/workflows/test.yml` (unchanged file; behavior changes through the script):

- **`changes` ("Swift suite gate")** – Trigger paths: every run. Unchanged, except that `swift-suite-needed.sh` now skips `relay/**`, `phone/loader/**` and `phone/app/**`. Not required itself; it feeds `test`.
- **`test`** – Trigger paths: everything except the skip list, so `phone/test-vectors/**`, `phone/protocol/**` and the generated bundle under `Sources/` still run it. It runs the Swift build and suite on macOS. **Required** (`test`), unchanged.
- **`lint` ("Lint")** – Trigger paths: every run, unchanged. **Required** (`Lint`). Gating it is a follow-up.
- **`claude-review`** (in `claude-code-review.yml`) – Unchanged. **Required.**
