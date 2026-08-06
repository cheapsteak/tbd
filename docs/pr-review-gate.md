# Claude PR review merge gate

`main` requires the `claude-review` status check to pass before a PR can merge
(alongside `test` and `Lint`). The check is produced by the `claude-review` job in
[`.github/workflows/claude-code-review.yml`](../.github/workflows/claude-code-review.yml),
which runs the specialist fan-out pipeline described in
[`docs/specs/2026-08-03-pr-review-fanout-design.md`](specs/2026-08-03-pr-review-fanout-design.md):
deterministic script bookends around one model session that fans out to two
specialist subagents.

**Branch protection matches a required check by job NAME, not by workflow file.**
Exactly one job across `.github/workflows/` may therefore be named `claude-review`;
a second one would report into the same required context. That is why the retired
single-session reviewer, kept as a restoration source in
[`claude-code-review-legacy.yml`](../.github/workflows/claude-code-review-legacy.yml),
names its job `claude-review-legacy` and triggers only on `workflow_dispatch`.
Dispatching it reviews nothing — see [below](#the-legacy-single-session-workflow) for
why, and for what reviving it actually takes.

## How a PR is gated

1. **Trigger.** The workflow runs on `pull_request_target`, so it executes in the
   base-repo context with repository secrets — the only way a public repo can run
   a token-bearing review on a fork PR. It fires for same-repo and fork PRs alike.
2. **Trust gate (per-step).** A PR is *trusted* when the branch was pushed to this
   repo, or the author has **push access** to it (`admin` / `maintain` / `write`
   from `GET /repos/{owner}/{repo}/collaborators/{user}/permission`). Only trusted
   PRs have their head checked out and reviewed. An **untrusted fork** never has
   its code checked out or executed, and it produces a **failing** `claude-review`
   check (not a skipped one that would silently satisfy the required gate). To get
   an untrusted fork reviewed, a maintainer pushes the branch to this repo.

   The gate deliberately checks *effective permission*, not the PR's
   `author_association`. `COLLABORATOR` is handed to anyone invited to collaborate
   at **any** level — read-only and triage included — and `MEMBER` would cover every
   org member if this repo ever moved under an org. Because a trusted author gets
   their branch's tooling executed next to the review secrets (see below), the gate
   must admit only people who could already push a branch here and run this workflow
   directly. Two implementation notes: on a **public** repo the endpoint returns
   `read` for a total stranger rather than 404, so `read` and `none` are both
   untrusted; and the probe runs on every event (its result is ignored for same-repo
   PRs) so each run logs the permission it resolved. A failed probe is untrusted for
   forks and harmless for same-repo branches. The default `GITHUB_TOKEN` reads this
   endpoint with only `contents: read` — verified in Actions — so the reviewer App
   token is still minted after the gate rather than before it.
3. **Skip decision.** `prepare.py` computes the head diff's patch-id and reads the
   markers off the newest prior review comment. When they match, the run re-asserts
   the recorded verdict as its own check result and spends no review; otherwise it
   runs the full pipeline. A missing or unreadable prior comment fails toward a full
   review, never toward a skip.
4. **Review.** One model session orchestrates two specialist subagents
   (`correctness`, `conventions`). Each specialist writes a schema-validated
   `findings-<name>.json`; the orchestrator merges them into `review-result.json`
   with a per-finding disposition list and the review comment's prose. The session
   holds **no GitHub write tool** — it posts nothing.
5. **Verdict.** `validate.py`, not the model, computes the verdict: it
   schema-validates the findings and the merged result, checks the disposition list
   accounts for every specialist finding id, and writes `REJECT` to `verdict.txt`
   iff any HIGH or MEDIUM finding survives the merge, otherwise `APPROVE`. A `Stop`
   hook
   ([`claude-review-v2/hooks/stop-hook.sh`](../.github/workflows/claude-review-v2/hooks/stop-hook.sh))
   refuses to end the session until `review-result.json` exists and parses. The job
   then enforces the verdict with an exact string match: `APPROVE` passes, `REJECT`
   blocks the merge, and anything else (missing / malformed / killed session) fails
   closed.

Every file the pipeline reads back out of the workspace — `review-result.json`,
`verdict.txt`, `skip-decision.json`, `discussion-context.txt`, `findings-*.json` —
is deleted after checkout, before anything runs, so a PR cannot pre-commit a forged
`verdict.txt=APPROVE` or a skip decision and approve itself.

## Trusted fork PRs need `allow-unsafe-pr-checkout`

`actions/checkout` v7.0.0 added a hard refusal to check out a fork PR head under
`pull_request_target` (and `workflow_run`), and **backported it to the floating
`v4` tag in v4.4.0 on 2026-07-20** — so a workflow pinned to `actions/checkout@v4`
picked up the breaking change without any edit. Its condition is purely
`event_name` plus `head.repo != base.repo`; it has no view of the author-trust step
that precedes it. The result was that *every* fork PR — including a
`COLLABORATOR`'s — failed the required `claude-review` check at checkout (PR #545).

The checkout step therefore sets `allow-unsafe-pr-checkout: true`. Because that
step is already gated on `trusted == true`, the opt-in restores exactly the
pre-v4.4.0 behavior and adds no new exposure: untrusted fork code still never
reaches the checkout.

### A fork PR checkout is shallow even with `fetch-depth: 0`

`fetch-depth: 0` does **not** give a fork PR full history. The head SHA is not
reachable from any base-repo branch, so `actions/checkout` fetches that commit on
its own and the clone stays shallow — `origin/<base>` ends up holding a single
commit with no common ancestor with `HEAD`. Measured on PR #545, the first fork PR
through this gate:

```
git rev-parse --is-shallow-repository   -> true
git log --oneline origin/main | wc -l   -> 1
git diff origin/main...HEAD             -> fatal: no merge base
```

The reviewer degrades quietly rather than failing: it falls back to `gh pr diff`,
which still produces a diff but loses `git log` and `git blame` — precisely what
the premise-audit instructions in the prompt rely on. Same-repo PRs were never
affected, which is why this went unnoticed until the gate started admitting forks.

The **Ensure a merge-base with the base branch** step repairs it, running
`git fetch --unshallow origin` when (and only when) the clone is shallow —
`--unshallow` errors on a complete repo. It then logs the resolved merge base, or
emits a `::warning::` if there still isn't one, so a future regression reports
itself instead of silently degrading the review again. Don't remove that step on
the assumption `fetch-depth: 0` covers it; it doesn't, and the failure is invisible
in the review output.

### What a trusted author's branch can execute

The opt-in is only defensible because of the push-access gate above, so it is worth
being explicit that "we never build the PR" does **not** mean "we never run its
code." The review job runs on `ubuntu-latest` and never invokes `swift build`, but
the checked-out tree still reaches three execution paths:

- **`.mcp.json`.** `claude-code-action` unconditionally sets
  `enableAllProjectMcpServers = true` when it writes its settings file, so MCP
  servers declared in a repo-root `.mcp.json` are launched at startup with no
  approval step. A branch that adds one gets arbitrary command execution directly.
- **Project hooks.** `.claude/settings.json` is tracked here and registers a
  `PreToolUse` hook running `.claude/hooks/guardrails/dispatch.py` on every `Bash`
  and `Skill` call. Both files come from the checked-out branch, and the reviewer
  always runs `Bash`. Restoring the pipeline directory from base does not prevent
  this: the action merges the `settings:` input into `~/.claude/settings.json` (the
  *user* layer, lowest priority) rather than passing `--settings`, and hooks merge
  additively across layers — so the base-branch Stop hook cannot displace or
  suppress a project-layer hook the branch adds.
- **`CLAUDE.md`.** Every tracked `CLAUDE.md` is auto-loaded as instructions and is
  branch-controlled, against an allowlist that carries read-only `gh` and `git`
  subcommands plus `Read`/`Write`/`Glob`/`Grep`/`Task`.

The job holds `CLAUDE_CODE_OAUTH_TOKEN`, the minted reviewer App token, and
default-branch cache scope. The accepted residual risk is therefore precisely: an
author who already has push access can run code beside those secrets — which they
could equally do by pushing a branch. Anyone below push access cannot reach any of
it. Keep that equivalence intact when editing the trust step; it is the entire
argument for the opt-in.

**Land changes to this workflow from a branch in this repo, never from a fork.**
Under `pull_request_target` the workflow config is read from the *base* branch, so
a fork PR that fixes the review workflow is still reviewed by the unfixed version
and blocks itself. (Same root cause as the trigger-change bootstrap gap above.)

## Changing the workflow's trigger needs an admin merge

GitHub picks the workflow version to run from different refs per event: a
`pull_request` event reads the config from the **PR head**, while a
`pull_request_target` event reads it from the **base branch**. A PR that changes
the *trigger event itself* therefore matches neither the old nor the new trigger
and gets no `claude-review` run — which leaves the required check unreported and
the PR blocked. That is a one-time bootstrap gap: land such a PR with an admin
merge, after which every subsequent PR is gated normally.

## Reading a review comment

The gate's comment behavior is worth knowing before you read a reviewed PR:

- **One comment per review, posted by the workflow.** The review session holds
  no GitHub write tool at all. It writes `review-result.json`; the workflow
  renders that file's `comment_body` into a comment body and posts it. Nothing
  is edited in place, so each review of each diff stays on the record as its own
  comment.
- **Each comment carries its own machine-read state.** Three leading HTML
  comments — a `<!-- claude-review-v2 -->` sentinel plus the reviewed patch-id
  and the computed verdict — sit above the prose. The next run reads its skip
  decision off the newest such comment, so there is no separate state comment to
  keep in sync. **The sentinel's literal text is live state and must not be
  renamed**: it is matched verbatim by `prepare.py` and by the workflow's `jq`
  selectors, and it is already stamped into the review comments on every open PR,
  so changing it orphans them — priors stop being collapsed and skip decisions
  read no prior state.
- **Earlier reviews are collapsed as outdated.** Before posting, the run
  minimizes every earlier sentinel-led comment of its own (GitHub's
  `minimizeComment`, classifier `OUTDATED`). History collapses instead of piling
  up. Minimizing happens before the post, which is what makes it impossible for
  a run to collapse the review it is about to publish.
- **The pipeline scripts are the base branch's, never the PR's.** The workflow
  restores `.github/workflows/claude-review-v2/` from the base branch before the
  review session and again after it, from the same recorded base SHA, so the
  scripts that compute the verdict and render the posted comment are base
  content no matter what the PR committed or the session wrote. Two consequences
  when you review a PR that changes that directory: the check exercises the
  *base* scripts, so a fix to them proves itself only after merge, and the
  session sees base content on disk (its prompt says so, and points it at
  `git show HEAD:<path>` for the PR's version).
- **A skipped review writes nothing.** When the diff's patch-id matches the last
  reviewed one, the run posts no comment and minimizes none — the prior review
  is still the current review of an unchanged diff — and re-asserts the recorded
  verdict as its own check result.

## The legacy single-session workflow

[`claude-code-review-legacy.yml`](../.github/workflows/claude-code-review-legacy.yml)
holds the single-session reviewer the fan-out pipeline replaced: one session that
covered every concern in one pass and typed its own `APPROVE`/`REJECT` into
`claude-verdict.txt`, gated by the Stop hook in
[`claude-review-hooks/`](../.github/workflows/claude-review-hooks/).

**It is a restoration source, not a fallback you can run.** Dispatching it reviews
nothing: outside a PR event every `github.event.pull_request.*` expression is empty, so
the author-trust step probes permissions for an empty login, fails, and the run exits at
the fork gate with a misleading "this PR is from a fork" error before any review logic
runs. Reviving it means re-adding a `pull_request_target:` trigger and renaming the job
back — a deliberate edit and merge. Keeping the file means that edit is small and
reviewable instead of a reconstruction from git history.

Two things keep it inert until then:

- Its only trigger is `workflow_dispatch`, so no PR event starts it. Running two
  full model reviews per PR is exactly the cost retiring it removed.
- Its job is named `claude-review-legacy`, so it cannot report into the required
  `claude-review` context.

Because dispatch runs against a branch rather than a PR, a hand-triggered run has no
`github.event.pull_request` and reviews nothing — treat it as a diagnostic of the
workflow itself. Delete the file once the fan-out gate has held across enough real
PRs that nobody would reach back for it, or as soon as it stops working: a
restoration source that has quietly rotted is worse than none.

## Operational notes

- The gate is **fail-closed on infrastructure**: if the Anthropic API is down or
  `CLAUDE_CODE_OAUTH_TOKEN` expires, trusted PRs block until it recovers. An admin
  can temporarily drop `claude-review` from the required contexts to override.
- Reviews post as a **dedicated GitHub App whose slug contains "claude"** (e.g.
  `tbd-claude-reviewer[bot]`), minted per run via `actions/create-github-app-token`
  from the `CLAUDE_REVIEWER_APP_ID` / `CLAUDE_REVIEWER_APP_PRIVATE_KEY` secrets. The
  App is the gate's **stable comment-author identity**: the fetch, minimize, and post
  steps all select prior reviews by *this login plus the sentinel*, so a comment
  posted under any other identity is invisible to the next run's skip decision. We
  can't use the OIDC→Claude App token because that exchange 401s under
  `pull_request_target` (anthropics/claude-code-action#1017), and a plain
  `GITHUB_TOKEN` posts as `github-actions[bot]`, which collides with every other
  workflow's comments. (The legacy workflow needs the same App for a different
  reason: the action's sticky-comment matcher in `create-initial.ts` recognizes its
  own prior comment only when the author is the Claude App or a `Bot` whose login
  contains `claude`, and has no config input to change that.)
- The gate is a **status check**, not a required-approval count. (The App's approval
  *could* count toward required reviews if we ever want that, but the computed
  verdict is what enforces High/Medium blocking today.)
- **A green `claude-review` can predate the workflow that would produce it now.**
  Branch protection has `strict: false` — PRs need not be up to date with `main` — and
  a `pull_request_target` check does not re-run because the base branch's workflow
  changed. So a PR already open when this file changes keeps whatever verdict it
  already has, from whatever the workflow was then. The check name is the same and the
  green tick looks identical, which is the whole problem. After any change to what the
  gate *does*, push to (or re-run the check on) an open PR before merging it if you
  want the current pipeline's opinion rather than the one it happened to get.
