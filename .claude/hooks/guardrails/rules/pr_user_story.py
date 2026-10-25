"""Guardrail: nudge toward a `## User story` section in the body of a new feature PR.

The PR template requires a filled user-story section in every PR whose title
is not exempt (fix, docs, chore, test, ci, build, revert). This rule tells an
agent so at `gh pr create` time, so the description is right on the first
push. Design: docs/specs/2026-10-20-pr-user-story-check-design.md.

INFORMATIONAL ONLY: it never denies. A `PR user story` CI check that fails such
a PR exists but is off; the template and this nudge carry the rule.

**One rule, two callers.** The exemption and section logic is not copied here:
it is loaded by path from the CI script
(`.github/workflows/pr-user-story/check_user_story.py`), so the nudge and the
check cannot drift apart. If that file cannot be loaded, the rule has no
opinion.

**Command parsing is borrowed from `pr_worktree_link`**, which already
tokenizes `gh pr create` with heredoc and `$(…)` handling and documents every
defense. Only `gh` is considered — the CI check is built for GitHub PRs only.

What the rule reads, and how it fails:

- **Title** — the last `--title`/`-t`. With no title (`--fill`, an interactive
  prompt) or one built by a substitution, exemption cannot be judged and the
  rule stays silent.
- **Body** — the last `--body`/`-b` text, or the first window of the last
  `--body-file`/`-F` file. A body composed by heredoc (`--body "$(cat <<'EOF'`,
  or `-F - <<EOF`) is stripped out of the command by the tokenizer, so any
  heredoc text in the invocation also counts as body for every create in it —
  the same deliberate generosity `pr_worktree_link` applies.
- **Several creates in one call** — each is judged on its own; any one that
  needs a story and lacks it arms the nudge.
- **The GitHub MCP server's `create_pull_request`** — its `title` and `body`
  fields, read directly and judged by the same `_needs_story`. A missing or
  empty title stays silent, as `--fill` does.
"""

from __future__ import annotations

import importlib.util
import os
import stat

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

_REPO_ROOT = os.path.dirname(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
)
CHECK_SCRIPT = os.path.join(
    _REPO_ROOT, ".github", "workflows", "pr-user-story", "check_user_story.py"
)

_TITLE_FLAGS = ("--title", "-t")
_BODY_TEXT_FLAGS = ("--body", "-b")
_BODY_FILE_FLAGS = ("--body-file", "-F")

# The story section sits at the top of a feature body, so one bounded read
# covers it; the cap keeps a huge or odd file from stalling every Bash call.
_MAX_BODY_BYTES = 64 * 1024

_check_module = None


def _load_check():
    """The CI script as a module, loaded once; None if it cannot be loaded."""
    global _check_module
    if _check_module is None:
        try:
            spec = importlib.util.spec_from_file_location("check_user_story", CHECK_SCRIPT)
            if spec is None or spec.loader is None:
                return None
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            _check_module = module
        except Exception:
            return None
    return _check_module


def _read_body_file(path: str) -> str:
    """The head of a regular file at `path`, or "" if it cannot be read.

    Opened non-blocking and checked by descriptor, as in
    `pr_worktree_link._file_has_link`, so a fifo or device cannot hang the hook.
    """
    try:
        descriptor = os.open(os.path.expanduser(path), os.O_RDONLY | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                return ""
            return os.read(descriptor, _MAX_BODY_BYTES).decode("utf-8", errors="replace")
        finally:
            os.close(descriptor)
    except Exception:
        return ""


def _needs_story(check, title, bodies) -> bool:
    """True when a PR with this title needs a story and none of `bodies` has one.

    The judgement both tools share. A title that is None or built by a
    substitution cannot be judged for exemption, so it needs nothing. `bodies`
    is consumed lazily, so a body file is read only once the title says a story
    is needed.
    """
    if title is None or "$(" in title or "`" in title:
        return False
    if check.is_exempt(title):
        return False
    return not any(check.has_user_story(body) for body in bodies)


def _segment_bodies(words: list, heredoc_text: str):
    """Every body one `gh pr create` segment might send, read on demand."""
    yield heredoc_text
    text = _last_flag_value(words, _BODY_TEXT_FLAGS)
    if text is not None:
        yield text
    path = _last_flag_value(words, _BODY_FILE_FLAGS)
    if path is not None and path != "-":
        yield _read_body_file(path)


class PRUserStoryRule(Rule):
    id = "pr-user-story"
    description = "Nudge toward a ## User story section in the body of a new feature PR."
    tools = {"Bash", MCP_CREATE_PR_TOOL}

    def check(self, tool_input: dict, ctx: dict) -> "Decision | None":
        if _is_mcp_create(ctx):
            # An empty title is as unjudgeable as a missing one.
            title = _mcp_text(tool_input, "title") or None
            creates = [(title, [_mcp_text(tool_input, "body")])]
        else:
            command = tool_input.get("command", "") or ""
            if "pr" not in command or "create" not in command:
                return None
            command_text, heredoc_text = _split_heredoc_bodies(command)
            creates = [
                (_last_flag_value(words, _TITLE_FLAGS), _segment_bodies(words, heredoc_text))
                for words in _command_segments(command_text)
                if _forge_create_tool(words) == "gh"
            ]
        if not creates:
            return None
        check = _load_check()
        if check is None:
            return None
        if any(_needs_story(check, title, bodies) for title, bodies in creates):
            return Decision.info(
                "[pr-user-story] "
                + check.MESSAGE
                + "\n\n(This is informational — nothing is blocked. The PR "
                "template requires this section for feature PRs.)"
            )
        return None


RULES = [PRUserStoryRule()]
