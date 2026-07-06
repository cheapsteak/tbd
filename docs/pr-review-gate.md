# Claude PR review merge gate

`main` requires the `claude-review` status check to pass before a PR can merge
(alongside `test` and `Lint`). The check is produced by
[`.github/workflows/claude-code-review.yml`](../.github/workflows/claude-code-review.yml).

## How a PR is gated

1. **Trigger.** The workflow runs on `pull_request_target`, so it executes in the
   base-repo context with repository secrets — the only way a public repo can run
   a token-bearing review on a fork PR. It fires for same-repo and fork PRs alike.
2. **Trust gate (per-step).** A PR is *trusted* when the branch was pushed to this
   repo, or the author is an `OWNER` / `MEMBER` / `COLLABORATOR`. Only trusted PRs
   have their head checked out and reviewed. An **untrusted fork** never has its
   code checked out or executed, and it produces a **failing** `claude-review`
   check (not a skipped one that would silently satisfy the required gate). To get
   an untrusted fork reviewed, a maintainer pushes the branch to this repo.
3. **Verdict.** The reviewer writes a single token — exactly `APPROVE` or `REJECT`
   — to `claude-verdict.txt`. A `Stop` hook
   ([`claude-review-hooks/verdict-gate.sh`](../.github/workflows/claude-review-hooks/verdict-gate.sh))
   refuses to end the review session until that file holds a clean token, so
   free-form review prose can never be misread as a verdict. The job then enforces
   it with an exact string match: `APPROVE` passes, `REJECT` blocks the merge, and
   anything else (missing / malformed / killed session) fails closed.

The verdict file is deleted after checkout, before the review runs, so a PR cannot
pre-commit `claude-verdict.txt=APPROVE` to approve itself.

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
- `github-actions[bot]` approvals do not count toward required reviews, which is
  why the gate is a **status check** rather than a required-approval count.
