---
name: stacked-prs
description: Create, link, restack, or merge a chain of dependent pull requests using GitHub's stacked-PRs feature. Use when a change is too big for one PR, when a PR must land on top of another unmerged PR, or when merging such a chain.
---

# Stacked PRs

Sessions in this repo have rediscovered GitHub's stack feature and its API several times; this skill is the single place that records it.

## When to use

- A change is large enough that reviewers want it split, but the parts depend on each other.
- A branch must build on another branch whose PR is still open.
- You are merging, restacking, or dissolving an existing chain.

Not for independent PRs. Two PRs that both branch off `main` are not a stack.

## The model

A stack is an ordered list of open PRs in one repository: the bottom PR targets trunk, and each PR above targets the branch below it. Merging bottom-up merges one PR at a time; merging a mid-stack PR merges everything below it too and re-targets the PRs above at trunk. Branch protection is evaluated on *every* PR in the stack against the bottom PR's base, so every member needs its own green checks and approval.

Public preview. Same-repo branches only — no forks.

## Create or link a stack

Preferred: link existing PRs, bottom first. Needs no local tracking, so TBD's worktree-per-branch layout works fine.

```
gh extension install github/gh-stack          # one-time
gh stack link 101 102 103                     # PR numbers, URLs, or branch names
gh stack link 42 104                          # first arg = stack number: append to top
gh stack view --json                          # requires the current branch to be in the stack
gh stack unstack 42                           # dissolve
```

Branch arguments are pushed and get PRs created with the chaining already correct. `gh stack init/add/submit/sync/rebase/push` are the locally-tracked variant; skip them unless one worktree holds the whole chain.

REST equivalents (all need `-H "X-GitHub-Api-Version: 2026-03-10"`):

- `GET /repos/{owner}/{repo}/stacks` — list; `?pull_request=N` filters to the stack containing PR N
- `GET /repos/{owner}/{repo}/stacks/{number}` — one stack: `{number, base:{ref}, open, pull_requests:[{number, head:{ref,sha}, base:{ref}, state, merged_at, draft}]}`
- `POST /repos/{owner}/{repo}/stacks` with `{"pull_requests":[101,102,103]}` — create, bottom first
- `POST /repos/{owner}/{repo}/stacks/{number}/add` — append to the top
- `POST /repos/{owner}/{repo}/stacks/{number}/unstack` — remove unmerged PRs; the stack dissolves when empty

```
gh api -H "X-GitHub-Api-Version: 2026-03-10" repos/{owner}/{repo}/stacks/826
```

GraphQL reads the same shape through `PullRequest.stack` and `PullRequest.stackEntry`:

```
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){
  repository(owner:$o,name:$r){ pullRequest(number:$n){
    stack { number size baseRefName
      entries(first:20){ nodes { position pullRequest { number baseRefName } } } } } }
}' -f o={owner} -f r={repo} -F n=101
```

The merge is a `stackMerge` mutation, but its input type is not exposed by introspection. Use `gh stack merge`; that is the supported path.

## Keep it green

1. **Dispatch tests for upper PRs.** `.github/workflows/test.yml` runs on `pull_request` only for PRs based on `main`, so a PR whose base is another branch gets no test run on push. Dispatch it: `gh workflow run test.yml --ref <branch> -f scope=full`. The resulting check runs land on the head SHA and do satisfy main's required checks (`claude-review`, `test`, `Lint`), even though `gh pr checks` will not list them. Confirm with `gh api repos/{owner}/{repo}/commits/<sha>/check-runs`.
2. **`claude-review` needs nothing extra.** It is `pull_request_target` with no branch filter, so it fires for every PR in the stack.
3. **Every PR needs its own approval.** The stack merge bypasses nothing.
4. **Restack after a lower branch changes.** `git rebase --onto <newLower> <oldLower>` on each branch above, bottom-up, then `git push --force-with-lease`. With local tracking, `gh stack sync` does it.
5. **Pull trunk into the bottom PR with `gh pr update-branch <bottom>`** — it makes a merge commit and never rewrites the bottom branch — then restack upward.

## Merge in one go

```
gh stack merge <stackNumber|prNumber> --squash --yes
```

Atomic and all-or-nothing up to the PR you name: if any member cannot merge, none do. This repo is squash-only, so always `--squash`. If the base has a merge queue, the stack is queued instead of merged directly. `delete_branch_on_merge` is on, so merged branches disappear on their own.

## Gotchas

1. Exit code 9 from `gh stack` means the feature is not enabled for that repo or account.
2. `gh stack view` needs the current branch to be in the stack; `link` adds no local tracking, so read the stack over the API or by number instead.
3. `gh stack link` never removes PRs — re-listing a shorter set does not truncate the stack. Use `unstack`.
4. Order matters: arguments are bottom-to-top, and a wrong order rewrites PR bases.
5. Keep the chain linear. A branch with two children is not a stack and cannot be linked as one.
6. Never force-push the bottom branch after `gh pr update-branch` — you would drop the merge commit.
7. Merging a mid-stack PR silently merges everything below it. Name the PR you actually mean.
8. Forks are unsupported; every branch must live in `{owner}/{repo}`.
9. Every PR body still ends with the worktree deep-link and the session line (see CLAUDE.md).
