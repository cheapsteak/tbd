"""Stub-API end-to-end test of the claude-review-v2 session contract.

Runs the REAL `claude` CLI headless against the stub model API
(stub_server.py), in a throwaway sandboxed project, and asserts the actual
session contract from docs/specs/2026-08-03-pr-review-fanout-design.md §4:

- the CLI executes scripted tool_use turns (writes the specialist findings file
  and review-result.json) rather than silently retrying,
- the real Stop hook (hooks/stop-hook.sh) lets the session end once
  review-result.json exists and parses — and does not wedge it,
- the real validate.py accepts the written files and computes the verdict.

Zero tokens, fully deterministic. Skipped when no `claude` binary is on PATH,
so CI without the toolchain cannot flake.

Isolation notes (hard-won, keep in sync with the spec):
- Sandbox via HOME + CLAUDE_CONFIG_DIR, NOT --settings: --settings layers on
  top of the runner's real global config and leaks it into the test.
- <config>/.claude.json must pre-accept the trust dialog — an untrusted project
  silently SKIPS project-settings hooks, and the Stop hook is the test subject.
- The env is built from scratch (PATH passthrough only), which also keeps the
  host's proxy variables away from the 127.0.0.1 stub.
- TMPDIR is redirected into the sandbox: the Stop hook persists its nudge
  counter under ${TMPDIR:-/tmp}, and a stale counter from a previous run would
  let the hook give up early.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stub_server import StubServer, ToolCall, Turn, loop_advanced  # noqa: E402

_PIPELINE_DIR = Path(__file__).resolve().parents[2]  # .github/workflows/claude-review-v2
_STOP_HOOK = _PIPELINE_DIR / "hooks" / "stop-hook.sh"
_VALIDATE = _PIPELINE_DIR / "validate.py"

_MINOR_FINDING = {
    "id": "correctness-1",
    "file": "Sources/AcmeGreeter.swift",
    "line": 2,
    "severity": "MINOR",
    "title": "Greeting string is hardcoded",
    "body": "AcmeGreeter always greets 'acme'; consider taking the name as a parameter.",
    "confidence": 0.6,
}

_FINDINGS_DOC = {"specialist": "correctness", "findings": [_MINOR_FINDING]}

_RESULT_DOC = {
    "findings": [_MINOR_FINDING],
    "disposition": [{"id": "correctness-1", "action": "kept"}],
    "comment_body": "One MINOR finding on AcmeGreeter.swift; nothing blocking.",
}


def _git(project: Path, *args: str) -> None:
    subprocess.run(
        [
            "git",
            "-c", "user.name=stub",
            "-c", "user.email=stub@acme.invalid",
            *args,
        ],
        cwd=project,
        check=True,
        capture_output=True,
        env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1"},
    )


def _make_project(sandbox: Path) -> Path:
    """A throwaway git repo wired with the REAL Stop hook via project settings."""
    project = sandbox / "project"
    hooks_dir = project / ".claude" / "hooks"
    hooks_dir.mkdir(parents=True)

    # Copy the real hook in; the settings command points at the copy. The hook
    # itself resolves review-result.json from ${CLAUDE_PROJECT_DIR:-$PWD},
    # which Claude Code sets to the project root when invoking hooks.
    shutil.copy(_STOP_HOOK, hooks_dir / "stop-hook.sh")
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
    _git(project, "init", "-q")
    _git(project, "add", "-A")
    _git(project, "commit", "-q", "-m", "initial commit")
    return project


def _write_config(sandbox: Path, project: Path) -> None:
    """Pre-accept every dialog the CLI would otherwise interactively raise.

    hasTrustDialogAccepted matters most: an untrusted project silently skips
    project-settings hooks, which would turn the Stop-hook assertion into a
    false pass.
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


def _sandbox_env(sandbox: Path, base_url: str) -> dict[str, str]:
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
        # The CLI refuses bypassPermissions as root unless it knows it is in a
        # throwaway sandbox (CI containers run as root).
        env["IS_SANDBOX"] = "1"
    return env


@pytest.mark.skipif(
    shutil.which("claude") is None,
    reason="claude CLI not on PATH; stub e2e exercises the real binary",
)
def test_session_contract_end_to_end() -> None:
    sandbox = Path(tempfile.mkdtemp(prefix="claude-review-v2-e2e-"))
    try:
        (sandbox / "tmp").mkdir()
        project = _make_project(sandbox)
        _write_config(sandbox, project)

        turns = [
            Turn(
                text="Writing the correctness specialist findings.",
                tool_calls=[
                    ToolCall(
                        "Write",
                        {
                            "file_path": str(project / "findings-correctness.json"),
                            "content": json.dumps(_FINDINGS_DOC, indent=2),
                        },
                    )
                ],
            ),
            Turn(
                text="Writing the merged review result.",
                tool_calls=[
                    ToolCall(
                        "Write",
                        {
                            "file_path": str(project / "review-result.json"),
                            "content": json.dumps(_RESULT_DOC, indent=2),
                        },
                    )
                ],
            ),
            Turn(text="E2E-DONE"),
        ]

        with StubServer(turns) as stub:
            proc = subprocess.run(
                [
                    "claude",
                    "-p",
                    "You are under test against a scripted API. Execute the "
                    "tool calls you are given and follow tool results.",
                    "--permission-mode",
                    "bypassPermissions",
                ],
                cwd=project,
                env=_sandbox_env(sandbox, stub.base_url),
                capture_output=True,
                text=True,
                timeout=240,
            )

        debug = (
            f"exit={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\n"
            f"requests={len(stub.capture.raw_bodies)} "
            f"unexpected={stub.capture.unexpected_paths}"
        )

        # (e) The Stop hook did not wedge the session: subprocess.run returning
        # at all (no TimeoutExpired) proves the session ended within budget.
        assert proc.returncode == 0, f"claude exited non-zero.\n{debug}"

        # (a) The CLI actually executed tools — not the silent-retry loop.
        assert loop_advanced(stub.capture), (
            f"CLI never sent a tool_result / retried byte-identically.\n{debug}"
        )

        # (b) Both scripted files landed in the project.
        findings_path = project / "findings-correctness.json"
        result_path = project / "review-result.json"
        assert findings_path.is_file(), f"findings file missing.\n{debug}"
        assert result_path.is_file(), f"review-result.json missing.\n{debug}"

        # (e, cont.) The run COMPLETED rather than exhausting the hook's
        # 5-nudge ceiling: the ceiling path ends the session with no parseable
        # result file, so a parsing result file distinguishes the two.
        assert json.loads(result_path.read_text(encoding="utf-8")) == _RESULT_DOC

        # (d) The stub modeled everything the CLI needed. One tolerated
        # exception, observed against claude 2.1.220: the CLI sends a
        # /api/hello connectivity preflight to the base URL and proceeds fine
        # on the 404. It is not model traffic, so the stub stays strict
        # (404 + record) and only this known preflight is excused here —
        # count_tokens or any other unmodeled call still fails the test.
        unexpected = [p for p in stub.capture.unexpected_paths if p != "/api/hello"]
        assert unexpected == [], debug

        # (c) The REAL validate.py accepts the session's output end to end.
        if importlib.util.find_spec("jsonschema") is not None:
            vproc = subprocess.run(
                [
                    sys.executable,
                    str(_VALIDATE),
                    "--specialist-files",
                    "findings-*.json",
                    "--result-file",
                    "review-result.json",
                ],
                cwd=project,
                capture_output=True,
                text=True,
                timeout=60,
            )
            assert vproc.returncode == 0, (
                f"validate.py rejected the session's files:\n"
                f"stdout:\n{vproc.stdout}\nstderr:\n{vproc.stderr}"
            )
            verdict = (project / "verdict.txt").read_text(encoding="utf-8")
            assert verdict == "APPROVE", f"expected APPROVE, got {verdict!r}"
        else:
            print(
                "note: jsonschema not installed — skipped the validate.py "
                "sub-assertion (files + Stop hook + tool loop still verified)"
            )
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)
