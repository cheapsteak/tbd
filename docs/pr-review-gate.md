# Claude PR review merge gate

`main` requires the `claude-review` status check to pass before a PR can merge
(alongside `test` and `Lint`). The check is produced by
[`.github/workflows/claude-code-review.yml`](../.github/workflows/claude-code-review.yml).

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
3. **Verdict.** The reviewer writes a single token — exactly `APPROVE` or `REJECT`
   — to `claude-verdict.txt`. A `Stop` hook
   ([`claude-review-hooks/verdict-gate.sh`](../.github/workflows/claude-review-hooks/verdict-gate.sh))
   refuses to end the review session until that file holds a clean token, so
   free-form review prose can never be misread as a verdict. The job then enforces
   it with an exact string match: `APPROVE` passes, `REJECT` blocks the merge, and
   anything else (missing / malformed / killed session) fails closed.

The verdict file is deleted after checkout, before the review runs, so a PR cannot
pre-commit `claude-verdict.txt=APPROVE` to approve itself.

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
  always runs `Bash`. Restoring `claude-review-hooks/` from base does not prevent
  this: the action merges the `settings:` input into `~/.claude/settings.json` (the
  *user* layer, lowest priority) rather than passing `--settings`, and hooks merge
  additively across layers — so the base-branch Stop hook cannot displace or
  suppress a project-layer hook the branch adds.
- **`CLAUDE.md`.** Every tracked `CLAUDE.md` is auto-loaded as instructions and is
  branch-controlled, against an allowlist that includes `Bash(gh api:*)`.

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

## Operational notes

- The gate is **fail-closed on infrastructure**: if the Anthropic API is down or
  `CLAUDE_CODE_OAUTH_TOKEN` expires, trusted PRs block until it recovers. An admin
  can temporarily drop `claude-review` from the required contexts to override.
- Reviews post as a **dedicated GitHub App whose slug contains "claude"** (e.g.
  `tbd-claude-reviewer[bot]`), minted per run via `actions/create-github-app-token`
  from the `CLAUDE_REVIEWER_APP_ID` / `CLAUDE_REVIEWER_APP_PRIVATE_KEY` secrets. This
  is required for **sticky comments** to work: the action's sticky-comment matcher
  (`create-initial.ts`) only recognizes its own prior comment when the author id is
  the Claude App *or* the author is a `Bot` whose login contains `claude` — and has
  no config input to change that. A plain `GITHUB_TOKEN` (`github-actions[bot]`)
  matches neither, so it posts a new comment every run. We can't use the OIDC→Claude
  App token because that exchange 401s under `pull_request_target`
  (anthropics/claude-code-action#1017), hence the dedicated App.
- The gate is a **status check**, not a required-approval count. (The App's approval
  *could* count toward required reviews if we ever want that, but the verdict-file
  status check is what enforces High/Medium blocking today.)
