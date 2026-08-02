"""Require local SwiftPM compilation to use the shared admission governor."""

from __future__ import annotations

import os
import shlex

from guardrails.lib.rule import Decision, Rule


_COMPILE_SUBCOMMANDS = {"build", "package", "run", "test"}
_DISPLAY_COMMANDS = {"awk", "cat", "echo", "grep", "printf", "rg", "sed"}
_BOUNDARIES = {"&", "&&", "(", ")", ";", "|", "||"}
_SAFE_RUNNER = "scripts/swift-safe"
_DENY_REASON = (
    "[swift-build-admission] Blocked raw SwiftPM compilation. Multiple TBD "
    "worktrees once launched concurrent default -j12 builds, filled 15 GB of "
    "swap, and left swift-test parents respawning killed swift-frontends. "
    "Fix: run `scripts/swift-safe <build|test|run|package> ...`; it holds one "
    "machine-global build slot and defaults compilation to two jobs."
)


def _segments(command: str) -> list[list[str]]:
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError:
        return []

    segments: list[list[str]] = [[]]
    for token in tokens:
        if token in _BOUNDARIES:
            if segments[-1]:
                segments.append([])
            continue
        segments[-1].append(token)
    return [segment for segment in segments if segment]


def _contains_raw_swift_compile(segment: list[str]) -> bool:
    if any(token.endswith(_SAFE_RUNNER) for token in segment):
        return False
    if segment and os.path.basename(segment[0]) in _DISPLAY_COMMANDS:
        return False
    for index, token in enumerate(segment[:-1]):
        if os.path.basename(token) != "swift":
            continue
        if segment[index + 1] in _COMPILE_SUBCOMMANDS:
            return True
    return False


class SwiftBuildAdmissionRule(Rule):
    id = "swift-build-admission"
    description = (
        "Require Swift build/test/run/package commands to use scripts/swift-safe "
        "for a machine-global build slot and bounded compiler jobs."
    )
    tools = {"Bash"}

    def check(self, tool_input: dict, _ctx: dict):
        command = tool_input.get("command", "") or ""
        if any(_contains_raw_swift_compile(segment) for segment in _segments(command)):
            return Decision.deny(_DENY_REASON)
        return None


RULES = [SwiftBuildAdmissionRule()]
