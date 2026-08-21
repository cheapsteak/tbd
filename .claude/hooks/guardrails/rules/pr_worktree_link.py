"""Guardrail: nudge toward a TBD worktree deep-link in the body of a new PR.

A PR opened from a TBD worktree should end its body with a link back to that
worktree, so anyone reading the PR later can reopen the session that produced
it. The recipe is not obvious: `tbd link` prints the `tbd://open?worktree=<uuid>`
form, while a PR body needs the shareable https redirector
(`Sources/TBDShared/DeepLinks.swift`), so the rule spells the whole thing out.

This rule is INFORMATIONAL ONLY: it never denies. Blocking `gh pr create` over a
missing courtesy link would be badly wrong. It only surfaces a reminder via
Decision.info, which dispatch.py emits as non-blocking `additionalContext` — the
command always proceeds.

It stays silent when the link is already in the body (inline `--body` text or a
`--body-file` target), and when the session is not under TBD at all, so a
contributor working outside TBD never sees it.
"""

from __future__ import annotations

import os
import re

from guardrails.lib.rule import Decision, Rule

# Matches `gh pr create`, tolerating global flags between `gh` and `pr` (e.g.
# `gh --repo owner/name pr create`). Deliberately conservative: a missed
# invocation costs nothing, a false positive is noise on every Bash call. The
# leading group pins `gh` to a command position (start of line, or after a
# separator), so a backticked mention inside a commit message or a heredoc
# doesn't trip the rule.
_GH_PR_CREATE = re.compile(
    r"(?:^|[\n;&|(])\s*"
    r"gh\b(?:\s+(?:--[\w-]+(?:=\S+)?|-[A-Za-z])(?:\s+[^-\s][^\s]*)?)*\s+pr\s+create\b"
)

# `--body-file <path>`, `--body-file=<path>`, `-F <path>`, `-F=<path>`.
_BODY_FILE = re.compile(r"(?:--body-file|-F)(?:=|\s+)(\S+)")

# Any of these in the body text means the deep-link is already there: the raw
# query fragment, the https redirector path, or the bare scheme.
_LINK_MARKERS = ("?worktree=", "tbd/open/", "tbd://open")

_MESSAGE = (
    "This PR is being opened from a TBD worktree, so end its body with a worktree "
    "deep-link — that is what lets the PR be traced back to the session that produced "
    "it. Recipe: get the UUID with "
    '`tbd link 2>/dev/null || tbd link "$(basename "$(git rev-parse --show-toplevel)")"`, '
    "take the `?worktree=<uuid>` portion, and make the final line of the body "
    "`[<worktree display name>](https://cheapsteak.github.io/tbd/open/?worktree=<uuid>)`. "
    "If `tbd link` fails, skip it silently. (This is informational — nothing is blocked.)"
)


def _strip_quotes(path: str) -> str:
    """Drop one layer of matching surrounding quotes from a shell word."""
    for quote in ("'", '"'):
        if len(path) >= 2 and path.startswith(quote) and path.endswith(quote):
            return path[1:-1]
    return path


def _text_has_link(text: str) -> bool:
    return any(marker in text for marker in _LINK_MARKERS)


def _body_file_has_link(command: str) -> bool:
    """True if any `--body-file`/`-F` target already contains the deep-link.

    Best-effort: a path we cannot read (missing file, permissions, a path built
    from shell expansion) returns False, so the nudge fires. Informational
    output is harmless when wrong; a swallowed reminder is the worse failure.
    """
    for raw in _BODY_FILE.findall(command):
        path = os.path.expanduser(_strip_quotes(raw))
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                if _text_has_link(handle.read()):
                    return True
        except Exception:
            continue
    return False


class PRWorktreeLinkRule(Rule):
    id = "pr-worktree-link"
    description = "Nudge toward a TBD worktree deep-link in the body of a new PR."
    tools = {"Bash"}

    def check(self, tool_input: dict, ctx: dict) -> "Decision | None":
        command = tool_input.get("command", "") or ""
        if not _GH_PR_CREATE.search(command):
            return None
        # Inline `--body`/`-b` text lives in the command string itself, so
        # scanning the raw command covers it (and any `--body-file` path that
        # happens to spell the link out too).
        if _text_has_link(command) or _body_file_has_link(command):
            return None
        if not self._under_tbd(ctx):
            return None
        return Decision.info(_MESSAGE)

    def _under_tbd(self, ctx: dict) -> bool:
        """True when this session belongs to TBD.

        The environment is read here rather than into a module-level constant so
        the check reflects the process env at call time — a module constant is
        frozen at import and cannot be overridden by tests (or by a daemon that
        set TBD_HOME after this module loaded).
        """
        if os.environ.get("TBD_WORKTREE_ID"):
            return True
        home = os.environ.get("TBD_HOME") or os.path.join(os.path.expanduser("~"), "tbd")
        worktrees_root = os.path.join(home, "worktrees") + os.sep
        cwd = (ctx.get("cwd") or "") + os.sep
        return cwd.startswith(worktrees_root)


RULES = [PRWorktreeLinkRule()]
