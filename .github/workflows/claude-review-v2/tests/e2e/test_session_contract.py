"""Stub-API end-to-end test of the claude-review-v2 session contract.

Runs the REAL `claude` CLI headless against the stub model API
(stub_server.py), in a throwaway sandboxed project (harness.py), and asserts
the actual session contract from docs/specs/2026-08-03-pr-review-fanout-design.md §4:

- the CLI executes scripted tool_use turns (writes the specialist findings file
  and review-result.json) rather than silently retrying,
- the real Stop hook (hooks/stop-hook.sh) lets the session end once
  review-result.json exists and parses — and does not wedge it,
- the real validate.py accepts the written files and computes the verdict.

Zero tokens, fully deterministic. Skipped when no `claude` binary is on PATH,
so CI without the toolchain cannot flake. Sandbox isolation rules (hard-won)
live in harness.py's module docstring.

This is the single-specialist baseline; the parallel fan-out and resume-loop
scenarios build on it in test_fanout_contract.py and test_resume_loop.py.
"""

from __future__ import annotations

import importlib.util
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


@pytest.mark.skipif(
    shutil.which("claude") is None,
    reason="claude CLI not on PATH; stub e2e exercises the real binary",
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
                env=harness.sandbox_env(sandbox, stub.base_url),
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

        # (d) The stub modeled everything the CLI needed (the known /api/hello
        # preflight excepted — see harness.tolerated_unexpected_paths).
        unexpected = harness.tolerated_unexpected_paths(stub.capture.unexpected_paths)
        assert unexpected == [], debug

        # (c) The REAL validate.py accepts the session's output end to end.
        if importlib.util.find_spec("jsonschema") is not None:
            vproc = subprocess.run(
                [
                    sys.executable,
                    str(harness.VALIDATE),
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
