"""Stub-API end-to-end test of the claude-review-v2 session contract.

Runs the REAL `claude` CLI headless against the stub model API
(stub_server.py), in a throwaway sandboxed project (harness.py), and asserts
the actual session contract from docs/specs/2026-08-03-pr-review-fanout-design.md §4:

- the CLI executes scripted tool_use turns (writes the specialist findings file
  and review-result.json) rather than silently retrying,
- the real Stop hook (hooks/stop-hook.sh) lets the session end once all expected
  artifacts pass deterministic preflight — and does not wedge it,
- the real validate.py accepts the written files and computes the verdict.

Zero tokens, fully deterministic. Skipped unless the real `claude` binary and
the validator's `jsonschema` dependency are available, so every executed
scenario proves successful in-session preflight. Sandbox isolation rules
(hard-won) live in harness.py's module docstring.

This is the single-specialist baseline; the parallel fan-out and resume-loop
scenarios build on it in test_fanout_contract.py and test_resume_loop.py.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import harness  # noqa: E402
from stub_server import StubServer, ToolCall, Turn, loop_advanced  # noqa: E402

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

_REAL_CLAUDE_E2E_SKIP_REASON = harness.real_claude_e2e_skip_reason()


def test_sandbox_installs_the_real_preflight_pipeline(tmp_path: Path) -> None:
    project = harness.make_project(tmp_path)
    installed = project / ".github" / "workflows" / "claude-review-v2"

    assert (installed / "validate.py").read_bytes() == harness.VALIDATE.read_bytes()
    assert {
        path.name: path.read_bytes() for path in (installed / "schemas").iterdir()
    } == {
        path.name: path.read_bytes()
        for path in (harness.PIPELINE_DIR / "schemas").iterdir()
    }


def test_sandbox_env_declares_the_selected_specialist_set(tmp_path: Path) -> None:
    selected = harness.sandbox_env(
        tmp_path,
        "http://127.0.0.1:9999",
        expected_specialists=("correctness",),
    )
    default = harness.sandbox_env(tmp_path, "http://127.0.0.1:9999")

    assert selected["REVIEW_SPECIALISTS"] == "correctness"
    assert default["REVIEW_SPECIALISTS"] == "correctness,conventions"


def test_sandbox_env_aligns_hook_python_with_test_interpreter(
    tmp_path: Path, monkeypatch
) -> None:
    monkeypatch.setitem(harness.os.environ, "PATH", "/usr/bin:/bin")

    env = harness.sandbox_env(tmp_path, "http://127.0.0.1:9999")

    assert Path(env["PATH"].split(harness.os.pathsep)[0]) == Path(sys.executable).parent
    assert env["PATH"].endswith(f"{harness.os.pathsep}/usr/bin:/bin")
    hook_python = shutil.which("python3", path=env["PATH"])
    assert hook_python is not None
    assert Path(hook_python).resolve() == Path(sys.executable).resolve()


def test_real_claude_e2e_prerequisite_reports_missing_claude(monkeypatch) -> None:
    monkeypatch.setattr(harness.shutil, "which", lambda _name: None)

    assert harness.real_claude_e2e_skip_reason() == "claude CLI not on PATH"


def test_real_claude_e2e_prerequisite_reports_missing_jsonschema(monkeypatch) -> None:
    monkeypatch.setattr(harness.shutil, "which", lambda _name: "/usr/bin/claude")
    monkeypatch.setattr(harness.importlib.util, "find_spec", lambda _name: None)

    assert harness.real_claude_e2e_skip_reason() == "jsonschema is not importable"


def test_real_claude_e2e_prerequisite_accepts_both_dependencies(monkeypatch) -> None:
    monkeypatch.setattr(harness.shutil, "which", lambda _name: "/usr/bin/claude")
    monkeypatch.setattr(harness.importlib.util, "find_spec", lambda _name: object())

    assert harness.real_claude_e2e_skip_reason() is None


@pytest.mark.skipif(
    _REAL_CLAUDE_E2E_SKIP_REASON is not None,
    reason=_REAL_CLAUDE_E2E_SKIP_REASON or "real-Claude prerequisites available",
)
def test_session_contract_end_to_end() -> None:
    sandbox = Path(tempfile.mkdtemp(prefix="claude-review-v2-e2e-"))
    try:
        project = harness.make_sandbox(sandbox)

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
                env=harness.sandbox_env(
                    sandbox,
                    stub.base_url,
                    expected_specialists=("correctness",),
                ),
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

        # (e, cont.) The run completed through preflight rather than exhausting
        # the hook's bounded correction path.
        assert json.loads(result_path.read_text(encoding="utf-8")) == _RESULT_DOC
        assert harness.nudge_count(sandbox) == 0, (
            f"Stop hook nudged {harness.nudge_count(sandbox)} time(s).\n{debug}"
        )

        # (d) The stub modeled everything the CLI needed (the known /api/hello
        # preflight excepted — see harness.tolerated_unexpected_paths).
        unexpected = harness.tolerated_unexpected_paths(stub.capture.unexpected_paths)
        assert unexpected == [], debug

        # (c) The REAL validate.py accepts the session's output end to end.
        vproc = subprocess.run(
            [
                sys.executable,
                str(harness.VALIDATE),
                "--specialist-files",
                "findings-*.json",
                "--result-file",
                "review-result.json",
                "--expected-specialists",
                "correctness",
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
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)
