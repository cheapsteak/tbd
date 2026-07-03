"""Guardrail: nudge toward `tbd scratch promote` on `git init` in a scratch space.

A TBD scratch space (`~/tbd/scratch/<name>`) is a repo-less workspace. Running
`git init` inside one is a strong signal the project is taking shape and should
eventually be promoted to a real TBD repo via `tbd scratch promote <dest-path>`.

This rule is INFORMATIONAL ONLY: it never denies. `git init` in a scratch space
is exactly what promotion documents as the first step (init + commit, then
`tbd scratch promote`), so blocking it would break the intended workflow. The
rule only surfaces a reminder via Decision.info, which dispatch.py emits as a
non-blocking `additionalContext` — the command always proceeds.
"""

from __future__ import annotations

import os
import re

from guardrails.lib.rule import Decision, Rule

# Matches `git init`, `git -C <dir> init`, `git --git-dir=<path> init`, and
# combinations of those flags before `init` — anything of the form
# `git [-C <dir> | --flag[=value]]* init`.
_GIT_INIT = re.compile(r"\bgit\b(?:\s+(?:-C\s+\S+|--[\w-]+(?:=\S+)?))*\s+init\b")

# Match ~/tbd/scratch/ regardless of TBD_HOME override (best-effort: check both).
_SCRATCH_MARKERS = tuple(
    marker
    for marker in (
        os.path.join(os.path.expanduser("~"), "tbd", "scratch") + os.sep,
        os.path.join(os.environ.get("TBD_HOME", ""), "scratch") + os.sep
        if os.environ.get("TBD_HOME")
        else None,
    )
    if marker
)
# Fallback markers for scanning the command text itself (e.g. a compound
# `cd ~/tbd/scratch/x && git init`, where ctx's cwd is still the pre-command
# directory). Includes the unexpanded `~/tbd/scratch/` form since shell tildes
# aren't expanded before the hook sees the raw command string.
_COMMAND_MARKERS = _SCRATCH_MARKERS + ("~" + os.sep + os.path.join("tbd", "scratch") + os.sep,)

_MESSAGE = (
    "You ran `git init` inside a TBD scratch space. When this project takes "
    "shape, offer the user promotion: ask for a destination path and run "
    "`tbd scratch promote <dest-path>` from here to move the folder out and "
    "register it as a real TBD repo. (This is informational — nothing is blocked.)"
)


class ScratchGitInitRule(Rule):
    id = "scratch-git-init"
    description = "Nudge toward `tbd scratch promote` when git init runs in a scratch space."
    tools = {"Bash"}

    def check(self, tool_input: dict, ctx: dict) -> "Decision | None":
        command = tool_input.get("command", "") or ""
        if not _GIT_INIT.search(command):
            return None
        cwd = (ctx.get("cwd") or "") + os.sep
        if any(cwd.startswith(marker) for marker in _SCRATCH_MARKERS):
            return Decision.info(_MESSAGE)
        # cwd reflects the directory the command started in, not any `cd` inside
        # it, so a compound `cd ~/tbd/scratch/x && git init` run from outside the
        # scratch tree wouldn't otherwise be caught. Fire if the command text
        # itself references a scratch-space path. Still informational only.
        if any(marker in command for marker in _COMMAND_MARKERS):
            return Decision.info(_MESSAGE)
        return None


RULES = [ScratchGitInitRule()]
