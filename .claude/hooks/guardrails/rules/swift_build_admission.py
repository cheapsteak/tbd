"""Require local SwiftPM compilation to use the shared admission governor."""

from __future__ import annotations

import os
import re
import shlex

from guardrails.lib.rule import Decision, Rule


_COMPILE_SUBCOMMANDS = {"build", "package", "run", "test"}
_DISPLAY_COMMANDS = {"awk", "cat", "echo", "grep", "printf", "rg", "sed"}
_SHELL_COMMANDS = {"bash", "dash", "sh", "zsh"}
_BOUNDARIES = {"&", "&&", "(", ")", ";", "|", "||"}
_MAX_NESTED_SHELL_DEPTH = 4
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


def _nested_shell_payloads(segment: list[str]):
    for shell_index, token in enumerate(segment[:-1]):
        if os.path.basename(token) not in _SHELL_COMMANDS:
            continue
        for option_index in range(shell_index + 1, len(segment) - 1):
            option = segment[option_index]
            if not option.startswith("-"):
                break
            if "c" in option[1:]:
                yield segment[option_index + 1]
                break


def _command_substitution_payloads(token: str):
    start = 0
    while True:
        opening = token.find("$(", start)
        if opening < 0:
            break
        depth = 1
        cursor = opening + 2
        while cursor < len(token) and depth:
            if token.startswith("$(", cursor):
                depth += 1
                cursor += 2
                continue
            if token[cursor] == ")":
                depth -= 1
                if depth == 0:
                    yield token[opening + 2 : cursor]
                    start = cursor + 1
                    break
            cursor += 1
        else:
            break
    yield from re.findall(r"`([^`]*)`", token)


def _contains_raw_swift_compile(segment: list[str], depth: int = 0) -> bool:
    if depth < _MAX_NESTED_SHELL_DEPTH:
        for token in segment:
            for payload in _command_substitution_payloads(token):
                if _command_contains_raw_swift_compile(payload, depth + 1):
                    return True
        for payload in _nested_shell_payloads(segment):
            if _command_contains_raw_swift_compile(payload, depth + 1):
                return True
    if segment and os.path.basename(segment[0]) in _DISPLAY_COMMANDS:
        return False
    for index, token in enumerate(segment[:-1]):
        if os.path.basename(token) != "swift":
            continue
        if segment[index + 1] in _COMPILE_SUBCOMMANDS:
            return True
    return False


def _command_contains_raw_swift_compile(command: str, depth: int = 0) -> bool:
    if depth < _MAX_NESTED_SHELL_DEPTH:
        for payload in _command_substitution_payloads(command):
            if _command_contains_raw_swift_compile(payload, depth + 1):
                return True
    return any(
        _contains_raw_swift_compile(segment, depth) for segment in _segments(command)
    )


class SwiftBuildAdmissionRule(Rule):
    id = "swift-build-admission"
    description = (
        "Require Swift build/test/run/package commands to use scripts/swift-safe "
        "for a machine-global build slot and bounded compiler jobs."
    )
    tools = {"Bash"}

    def check(self, tool_input: dict, _ctx: dict):
        command = tool_input.get("command", "") or ""
        if _command_contains_raw_swift_compile(command):
            return Decision.deny(_DENY_REASON)
        return None


RULES = [SwiftBuildAdmissionRule()]
