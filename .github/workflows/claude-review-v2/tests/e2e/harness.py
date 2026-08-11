"""Shared sandbox harness for the stub-API e2e tests.

Builds the throwaway project (git repo + the REAL Stop hook wired via project
settings) and the isolation env for running the real `claude` CLI against a
StubServer. Extracted from test_session_contract.py so every e2e scenario uses
the same, hard-won isolation rules:

- Sandbox via HOME + CLAUDE_CONFIG_DIR, NOT --settings: --settings layers on
  top of the runner's real global config and leaks it into the test. Session
  transcripts also live under CLAUDE_CONFIG_DIR (projects/<munged-cwd>/), which
  is what makes `--resume` work inside the sandbox.
- <config>/.claude.json must pre-accept the trust dialog — an untrusted project
  silently SKIPS project-settings hooks, and the Stop hook is a test subject.
- The env is built from scratch (PATH passthrough only), which also keeps the
  host's proxy variables away from the 127.0.0.1 stub.
- TMPDIR is redirected into the sandbox: the Stop hook persists its nudge
  counter under ${TMPDIR:-/tmp}/claude-review-v2-block-count, and a stale
  counter from a previous run would let the hook give up early.
- IS_SANDBOX=1 when running as root: the CLI refuses bypassPermissions as root
  unless it knows it is in a throwaway sandbox (CI containers run as root).

Not a test module — pytest does not collect it.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

PIPELINE_DIR = Path(__file__).resolve().parents[2]  # .github/workflows/claude-review-v2
STOP_HOOK = PIPELINE_DIR / "hooks" / "stop-hook.sh"
VALIDATE = PIPELINE_DIR / "validate.py"

# Where the real Stop hook persists its nudge counter, relative to $TMPDIR.
NUDGE_COUNTER_NAME = "claude-review-v2-block-count"

# Every file the hook keeps under $TMPDIR. A resume loop must clear all of
# them; see reset_nudge_counter.
HOOK_STATE_NAMES = (
    NUDGE_COUNTER_NAME,
    "claude-review-v2-hold-started",
    "claude-review-v2-hold-count",
)


def git(project: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.name=stub", "-c", "user.email=stub@acme.invalid", *args],
        cwd=project,
        check=True,
        capture_output=True,
        env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1"},
    )


def make_project(sandbox: Path) -> Path:
    """A throwaway git repo wired with the REAL Stop hook via project settings."""
    project = sandbox / "project"
    hooks_dir = project / ".claude" / "hooks"
    hooks_dir.mkdir(parents=True)

    # Copy the real hook in; the settings command points at the copy. The hook
    # itself resolves review-result.json from ${CLAUDE_PROJECT_DIR:-$PWD},
    # which Claude Code sets to the project root when invoking hooks.
    shutil.copy(STOP_HOOK, hooks_dir / "stop-hook.sh")
    settings = {
        "hooks": {
            "Stop": [
                {
                    "hooks": [
                        {
                            "type": "command",
                            "command": 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/stop-hook.sh"',
                        }
                    ]
                }
            ]
        }
    }
    (project / ".claude" / "settings.json").write_text(
        json.dumps(settings, indent=2), encoding="utf-8"
    )

    (project / "Sources").mkdir()
    (project / "Sources" / "AcmeGreeter.swift").write_text(
        'struct AcmeGreeter {\n    func greet() -> String { "hello acme" }\n}\n',
        encoding="utf-8",
    )
    git(project, "init", "-q")
    git(project, "add", "-A")
    git(project, "commit", "-q", "-m", "initial commit")
    return project


def write_config(sandbox: Path, project: Path) -> None:
    """Pre-accept every dialog the CLI would otherwise interactively raise.

    hasTrustDialogAccepted matters most: an untrusted project silently skips
    project-settings hooks, which would turn Stop-hook assertions into false
    passes.
    """
    config_dir = sandbox / "config"
    config_dir.mkdir(parents=True)
    config = {
        "hasTrustDialogAccepted": True,
        "hasCompletedOnboarding": True,
        "bypassPermissionsModeAccepted": True,
        "projects": {
            str(project): {
                "hasTrustDialogAccepted": True,
                "hasCompletedProjectOnboarding": True,
            }
        },
    }
    (config_dir / ".claude.json").write_text(json.dumps(config, indent=2), encoding="utf-8")


def make_sandbox(sandbox: Path) -> Path:
    """Populate a fresh sandbox dir; returns the project path."""
    (sandbox / "tmp").mkdir(parents=True)
    project = make_project(sandbox)
    write_config(sandbox, project)
    return project


def sandbox_env(sandbox: Path, base_url: str) -> dict[str, str]:
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(sandbox),
        "CLAUDE_CONFIG_DIR": str(sandbox / "config"),
        "ANTHROPIC_BASE_URL": base_url,
        "ANTHROPIC_API_KEY": "stub-key",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "TMPDIR": str(sandbox / "tmp"),
        "NO_PROXY": "127.0.0.1,localhost",
        "TERM": "dumb",
    }
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        env["IS_SANDBOX"] = "1"
    return env


def nudge_count(sandbox: Path) -> int:
    """Final value of the Stop hook's nudge counter (0 = it never blocked)."""
    counter = sandbox / "tmp" / NUDGE_COUNTER_NAME
    if not counter.is_file():
        return 0
    text = counter.read_text(encoding="utf-8").strip()
    return int(text) if text.isdigit() else 0


def reset_nudge_counter(sandbox: Path) -> None:
    """Between-invocation reset for resume loops — ALL THREE state files.

    They survive the process (they live in TMPDIR, not session state), and each
    stale one silently disarms a different backstop: a burned-out nudge counter
    lets the Stop hook allow the very first stop attempt, a hold counter at its
    cap does the same to the uncounted hold, and a stale start stamp puts the
    hold deadline in the past.
    """
    for name in HOOK_STATE_NAMES:
        (sandbox / "tmp" / name).unlink(missing_ok=True)


# --- shared scenario builders (fan-out + resume tests) ------------------------


def sentinel(role: str) -> str:
    """The routing sentinel carried in a specialist's Task prompt."""
    return f"ROLE-{role.upper()}"


def minor_finding(role: str) -> dict:
    return {
        "id": f"{role}-1",
        "file": "Sources/AcmeGreeter.swift",
        "line": 2,
        "severity": "MINOR",
        "title": f"Acme placeholder finding from the {role} specialist",
        "body": f"The {role} specialist notes the greeting string is hardcoded.",
        "confidence": 0.6,
    }


def findings_doc(role: str) -> dict:
    return {"specialist": role, "findings": [minor_finding(role)]}


def task_call(role: str, project: Path) -> "ToolCall":
    """A Task tool_use spawning one specialist subagent, sentinel included."""
    from stub_server import ToolCall

    prompt = (
        f"{sentinel(role)}\n"
        f"You are the {role} specialist for an acme test review. Use the Write "
        f"tool to create {project / f'findings-{role}.json'} with findings "
        "valid per findings.schema.json, then stop."
    )
    return ToolCall(
        "Task",
        {
            "subagent_type": "general-purpose",
            "description": f"{role} specialist",
            "prompt": prompt,
        },
        id=f"toolu_task_{role}",
    )


def specialist_turns(role: str, project: Path) -> list["Turn"]:
    """The specialist's scripted conversation: Write its findings, then stop.

    The closing text deliberately carries no sentinel: it flows back to the
    orchestrator inside the Task completion, and while routing keys on
    messages[0] anyway, keeping the echo surface clean costs nothing.
    """
    from stub_server import ToolCall, Turn

    return [
        Turn(
            text=f"Writing the {role} findings file.",
            tool_calls=[
                ToolCall(
                    "Write",
                    {
                        "file_path": str(project / f"findings-{role}.json"),
                        "content": json.dumps(findings_doc(role), indent=2),
                    },
                )
            ],
        ),
        Turn(text=f"The {role} specialist finished writing its findings file."),
    ]


def tolerated_unexpected_paths(paths: list[str]) -> list[str]:
    """Filter the known-benign preflight from unexpected_paths.

    Observed against claude 2.1.220: the CLI sends one GET/POST to
    <base_url>/api/hello as a connectivity preflight and proceeds fine on the
    stub's 404. It is not model traffic, so the stub stays strict (404 +
    record) and only this path is excused; anything else still fails tests.
    """
    return [path for path in paths if path != "/api/hello"]
