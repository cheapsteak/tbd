"""Guardrail: nudge a PR opened on top of another branch toward a GitHub stack.

A chain of dependent PRs whose bases point at one another is not a GitHub stack
until it is linked as one. Linked, it merges bottom-up through `gh stack merge`
and each PR lands on `main` as its own squash commit under its own title.
Unlinked, nothing stops it being merged top-down, each PR into its own base
branch, and every upper PR then reaches `main` folded into the bottom PR's
squash commit. Design: docs/specs/2026-10-25-pr-stack-link-design.md.

A base other than `main` is the signal. The bottom PR of a chain targets `main`
like any other PR, so nothing marks it at creation, but every PR above it fires
— including the last one opened, which is when the chain is complete and ready
to link.

INFORMATIONAL ONLY: it never denies. A chain can only be linked once its PRs
exist, and a lone PR may legitimately target another branch.

What the rule reads:

- **Bash** — every `gh pr create` the shared tokenizer in `pr_worktree_link`
  finds, so one mentioned in a heredoc body or a quoted argument does not
  count. Its base is the last `--base`/`-B`, spaced or `=`-joined, and any one
  create on another branch arms the nudge. `gh stack …` is already the native
  path and never matches.
- **MCP** — the `base` field of the GitHub MCP server's `create_pull_request`.
- **Trunk is `main`, fixed** — these guardrails run only for work on this
  repository, and reading the remote's default branch would need
  `refs/remotes/origin/HEAD`, which a clone does not always carry. A missing
  base stays silent as well: it usually means the default branch, and the rule
  does not read the `branch.<name>.gh-merge-base` setting that `gh pr create`
  also honors.
"""

from __future__ import annotations

from guardrails.lib.rule import Decision, Rule
from guardrails.rules.pr_worktree_link import (
    MCP_CREATE_PR_TOOL,
    _command_segments,
    _forge_create_tool,
    _is_mcp_create,
    _last_flag_value,
    _mcp_text,
    _split_heredoc_bodies,
)

_TRUNK = "main"
_BASE_FLAGS = ("--base", "-B")

_MESSAGE = (
    "[pr-stack-link] This PR's base is another branch, so it belongs to a stack. "
    "Link the chain as a GitHub stack so it merges bottom-up, each PR as its own "
    "commit on main:\n"
    "1. Once every PR in the chain is open, link it bottom first: "
    "`gh stack link <bottom> … <top>` (PR numbers, URLs or branch names).\n"
    "2. Without the gh-stack extension, make the same call through the API: "
    '`gh api -X POST -H "X-GitHub-Api-Version: 2026-03-10" repos/{owner}/{repo}/stacks '
    "--input - <<< '{\"pull_requests\":[<bottom>, …, <top>]}'`.\n"
    "3. If neither can reach GitHub, ask a human to run `gh stack link`. "
    "Do not leave linking to chance.\n"
    "4. Dispatch the test workflow for each upper PR "
    "(`gh workflow run test.yml --ref <branch> -f scope=full`): a PR based on "
    "another branch gets no test run on push.\n"
    "5. Merge with `gh stack merge <top> --squash`, or bottom-up one PR at a time; "
    "never top-down, because a PR merged into the branch below it reaches main "
    "only inside the bottom PR's squash commit.\n"
    "The `stacked-prs` skill covers restacking and the rest. "
    "(This is informational — nothing is blocked.)"
)


def _off_trunk(base) -> bool:
    """True when `base` names a branch other than trunk; None or "" is trunk."""
    return bool(base) and base != _TRUNK


class PRStackLinkRule(Rule):
    id = "pr-stack-link"
    description = "Nudge a PR opened on top of another branch toward linking a GitHub stack."
    tools = {"Bash", MCP_CREATE_PR_TOOL}

    def check(self, tool_input: dict, ctx: dict) -> "Decision | None":
        if _is_mcp_create(ctx):
            bases = [_mcp_text(tool_input, "base")]
        else:
            command = tool_input.get("command", "") or ""
            if "pr" not in command or "create" not in command:
                return None
            command_text, _ = _split_heredoc_bodies(command)
            bases = [
                _last_flag_value(words, _BASE_FLAGS)
                for words in _command_segments(command_text)
                if _forge_create_tool(words) == "gh"
            ]
        if any(_off_trunk(base) for base in bases):
            return Decision.info(_MESSAGE)
        return None


RULES = [PRStackLinkRule()]
