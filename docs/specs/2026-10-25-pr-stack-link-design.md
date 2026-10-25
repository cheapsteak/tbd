# Stacked-PR linking nudge

## Problem

A chain of dependent PRs whose bases point at one another is not a GitHub stack until it is linked as one. Linked, the chain merges bottom-up through `gh stack merge` or the web UI, and each PR lands on `main` as its own squash commit under its own title. Unlinked, nothing stops the chain being merged top-down, each PR into its own base branch. Every upper PR then reaches `main` folded into the bottom PR's squash commit, under the bottom PR's title, and its own title survives only in that commit's body.

Field evidence: a three-PR chain was opened through the GitHub MCP server's `create_pull_request` tool, each upper PR based on the branch below it, and never linked. It was merged top-down, each PR into its base, and two `feat:` PRs reached `main` inside one `refactor:` commit.

The repo already documents the stack feature in the `stacked-prs` skill, and the root `CLAUDE.md` points to it. Nothing surfaces it when it matters: the moment an agent opens a PR on top of another branch.

The same chain shows a wider gap. Every PR guardrail matches only the `Bash` tool. A PR opened through the MCP tool, which is the route cloud sessions take, reaches none of them, so the `pr-user-story` and `pr-worktree-link` nudges are skipped there as well.

## Decision

Three changes, all informational. None blocks a call.

- **A new guardrail rule, `pr-stack-link`** – nudges toward linking the chain natively whenever a PR is opened with a base other than `main`.
- **The two existing PR rules also read the MCP tool** – `pr-user-story` and `pr-worktree-link` judge an MCP-created PR exactly as they judge a `gh pr create`.
- **The `stacked-prs` skill gains two passages** – a copy-pasteable `gh api` form of the create-stack call, and the reason a stack is never merged PR by PR.

The rules live under `.claude/hooks/guardrails/`, the repo's user-land enforcement layer. They remind agents working on this repository and change nothing compiled.

## When `pr-stack-link` fires

It fires when a call opens a PR whose base is a branch other than `main`:

- **Bash** – a `gh pr create` whose last `--base` or `-B` value, in either the spaced or the `=` form, names a branch other than `main`. Detection reuses the `gh pr create` tokenizer in `pr_worktree_link.py`, so a `gh pr create` that appears only inside a heredoc body or a quoted argument does not count, and each create in a chained command is judged on its own.
- **MCP** – a `create_pull_request` call whose `base` field names a branch other than `main`.

It stays silent when the base is `main` or absent, since an absent base resolves to the default branch. `gh stack link` and the other `gh stack` subcommands are already the native path and are never matched.

**Trunk is `main`, fixed.** These guardrails run only for work on this repository, and `main` is the branch its protection rules guard. Reading the remote's default branch instead would need `refs/remotes/origin/HEAD`, which a clone does not always carry.

An upper PR is the reliable signal. The bottom PR of a chain targets `main` like any other PR, so nothing distinguishes it at creation time. But every PR above it fires the nudge, and so does the last one opened, which is when the chain is complete and ready to link.

## What the nudge says

The reminder states that the PR being opened belongs to a stack, then gives the steps in order:

1. **Link the chain once every PR in it is open, bottom first.** `gh stack link <bottom> … <top>` takes PR numbers, URLs or branch names.
2. **Without the `gh-stack` extension, make the same call through `gh api`.** It is a `POST` to `repos/{owner}/{repo}/stacks` with the `X-GitHub-Api-Version: 2026-03-10` header and a body of `{"pull_requests":[<bottom>, …, <top>]}`.
3. **When neither can reach GitHub, ask a human to run `gh stack link`.** Linking must not be left to chance.
4. **Dispatch the test workflow for each upper PR.** A PR based on another branch gets no test run on push.
5. **Merge the stack with `gh stack merge <top> --squash`, never PR by PR.** Merging PR by PR is what folds the upper PRs into the bottom one's commit.

It closes by pointing to the `stacked-prs` skill for restacking and the remaining detail, and says that nothing was blocked.

## The MCP tool

The GitHub MCP server exposes PR creation as `create_pull_request`. Its input carries `owner`, `repo`, `title`, `body`, `head` and `base`. Under a server registered as `github`, which is the name the cloud environment uses, the tool reaches hooks as `mcp__github__create_pull_request`.

- **Settings** – `.claude/settings.json` gains one `PreToolUse` matcher for `mcp__github__create_pull_request`, pointing at the same `dispatch.py`. This is the exception the guardrails README already allows for a tool with no matcher yet.
- **Rules** – each of the three rules adds that name to its `tools` set. The dispatcher matches tool names exactly, so no dispatcher change is needed.
- **Other server names are not matched.** A GitHub MCP server registered under a different name keeps reaching no PR rule. For informational rules, a miss costs one reminder.

## The existing rules on the MCP tool

Each rule already separates detection from judgement, so the MCP input feeds the same judgement directly. No logic is copied.

- **`pr-user-story`** – reads `title` and `body` from the call. A missing or empty title cannot be judged for exemption, so the rule stays silent, as it does for a `gh pr create` without `--title`.
- **`pr-worktree-link`** – reads `body` from the call, and stays silent outside TBD exactly as it does for Bash.

## The skill

`.claude/skills/stacked-prs/SKILL.md` gains:

- **Under "Create or link a stack"** – the `gh api` invocation that creates a stack from PR numbers, written out in full so an agent can paste it.
- **Under "Merge in one go"** – one sentence on why a stack is never merged PR by PR: each merge lands in the PR's base branch, so every upper PR reaches `main` inside the bottom PR's squash commit.

The guardrails README lists `pr-stack-link` beside the other rules.

## Testing

Unit tests under `.claude/hooks/guardrails/tests/`, stdlib `unittest` like the rest:

- **`pr-stack-link`, Bash** – `--base feat-a`, `--base=feat-a` and `-B feat-a` fire. `--base main` and no base stay silent. A `gh pr create --base feat-a` inside a heredoc body or a quoted argument stays silent. In a chained command with two creates, one non-`main` base is enough to fire. `gh stack link 1 2 3` stays silent.
- **`pr-stack-link`, MCP** – a `base` of `feat-a` fires. A `base` of `main`, and a missing `base`, stay silent.
- **`pr-user-story`, MCP** – a `feat:` title whose body has no story fires. An exempt title stays silent, and so does a body with a filled story.
- **`pr-worktree-link`, MCP** – under TBD, a body without the deep-link fires and a body with it stays silent. Outside TBD, it stays silent.
- **Dispatch** – an MCP payload reaches the rules that list the tool, and no others.

`python3 dispatch.py --self-test` must pass. The `lint` CI job runs it.

## Rejected alternatives

- **Blocking until the chain is linked** – a chain can only be linked once its PRs exist, so a block at creation would have to send the agent to `gh stack link <branches>` instead. That strands an agent without the extension, and it also blocks a lone PR that legitimately targets another branch. The other PR rules are informational for the same reason.
- **Nudging on every PR creation** – it would also reach the bottom PR, but most PRs are not stacked, and a reminder that fires on every PR stops being read.
- **Nudging after the PR is created** – a `PostToolUse` reminder could quote the new PR's number, so the link command would be ready to paste. It needs a second hook event and parsing of each tool's output, a lot of machinery for a reminder the agent can already act on.
- **A CI check that flags an unlinked PR based on another branch** – it would catch PRs opened in the web UI and by other agents. But linking a stack fires no PR event, so the check would stay red after the chain is linked until the next push.
- **A merge-time nudge** – once the chain is linked, both the web UI and `gh stack merge` merge it as a stack, so linking at creation is the lever. `gh pr merge <number>` does not name the base, so a merge-time rule would need a network lookup inside the hook or would fire on every merge.
