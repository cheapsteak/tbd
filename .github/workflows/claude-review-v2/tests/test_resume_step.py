"""Behavior tests for the workflow's same-session recovery shell.

The Claude action can return while background review specialists are still
running.  These tests execute the workflow step's real ``run:`` block with a
stub ``$HOME/.local/bin/claude`` and assert the lifecycle contract at the
process boundary: complete results skip recovery, incomplete results resume
the original session, and bounded exhaustion leaves the validator to fail
closed without manufacturing output.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

from workflow_steps import read_workflow, run_block

RESUME_STEP = "Resume incomplete Claude review"
REPO_ROOT = Path(__file__).resolve().parents[4]
SESSION_ID = "session-acme-4242"
COUNTER_NAME = "claude-review-v2-block-count"

STUB_CLAUDE = r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

log_path = Path(os.environ["CLAUDE_CALL_LOG"])
calls = [
    json.loads(line)
    for line in log_path.read_text(encoding="utf-8").splitlines()
    if line.strip()
]
counter = Path(os.environ["TMPDIR"]) / "claude-review-v2-block-count"
entry = {
    "argv": sys.argv[1:],
    "counter_was_reset": not counter.exists(),
}
with log_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(entry) + "\n")

# Simulate a resume consuming its full Stop-hook allowance. The next workflow
# attempt proves it resets this process-external state by removing the file.
counter.write_text("5", encoding="utf-8")

result_after = os.environ.get("CLAUDE_STUB_RESULT_AFTER")
if result_after and len(calls) + 1 >= int(result_after):
    result = {
        "findings": [],
        "disposition": [],
        "comment_body": "The resumed review completed.",
    }
    workspace = Path(os.environ["GITHUB_WORKSPACE"])
    (workspace / "review-result.json").write_text(
        json.dumps(result), encoding="utf-8"
    )

raise SystemExit(int(os.environ.get("CLAUDE_STUB_EXIT", "0")))
'''


@dataclass
class ResumeRun:
    returncode: int
    stdout: str
    stderr: str
    calls: list[dict]
    workspace: Path
    counter: Path


def _result() -> dict:
    return {
        "findings": [],
        "disposition": [],
        "comment_body": "The initial review completed.",
    }


def _run_resume_step(
    sandbox: Path,
    *,
    result: dict | None = None,
    result_after: int | None = None,
) -> ResumeRun:
    workspace = sandbox / "workspace"
    workspace.mkdir(parents=True)
    tmpdir = sandbox / "tmp"
    tmpdir.mkdir()
    counter = tmpdir / COUNTER_NAME
    counter.write_text("5", encoding="utf-8")

    if result is not None:
        (workspace / "review-result.json").write_text(
            json.dumps(result), encoding="utf-8"
        )

    claude = sandbox / ".local" / "bin" / "claude"
    claude.parent.mkdir(parents=True)
    claude.write_text(STUB_CLAUDE, encoding="utf-8")
    claude.chmod(0o755)
    call_log = sandbox / "claude-calls.jsonl"
    call_log.touch()

    script = sandbox / "resume-step.sh"
    script.write_text(run_block(read_workflow(), RESUME_STEP), encoding="utf-8")
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(sandbox),
        "TMPDIR": str(tmpdir),
        "GITHUB_WORKSPACE": str(workspace),
        "SESSION_ID": SESSION_ID,
        "CLAUDE_CODE_OAUTH_TOKEN": "stub-token",
        "CLAUDE_CALL_LOG": str(call_log),
    }
    if result_after is not None:
        env["CLAUDE_STUB_RESULT_AFTER"] = str(result_after)

    completed = subprocess.run(
        ["bash", "-e", str(script)],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
    )
    calls = [
        json.loads(line)
        for line in call_log.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    return ResumeRun(
        completed.returncode,
        completed.stdout,
        completed.stderr,
        calls,
        workspace,
        counter,
    )


def test_a_parseable_result_skips_resume(tmp_path: Path) -> None:
    run = _run_resume_step(tmp_path, result=_result())
    assert run.returncode == 0
    assert run.calls == []
    assert run.counter.read_text(encoding="utf-8") == "5"


def test_a_missing_result_resumes_the_same_session_from_on_disk_findings(
    tmp_path: Path,
) -> None:
    run = _run_resume_step(tmp_path, result_after=1)
    assert run.returncode == 0
    assert len(run.calls) == 1
    call = run.calls[0]
    assert call["counter_was_reset"] is True
    assert "--resume" in call["argv"]
    assert call["argv"][call["argv"].index("--resume") + 1] == SESSION_ID
    prompt = "\n".join(call["argv"])
    assert "findings-correctness.json" in prompt
    assert "findings-conventions.json" in prompt
    assert "Do not fabricate" in prompt
    assert "both specialists" in prompt
    assert (run.workspace / "review-result.json").is_file()


def test_resume_exhaustion_leaves_the_validator_to_fail_closed(
    tmp_path: Path,
) -> None:
    run = _run_resume_step(tmp_path)
    assert run.returncode == 0
    assert len(run.calls) == 2
    assert all(call["counter_was_reset"] is True for call in run.calls)
    assert not (run.workspace / "review-result.json").exists()
    assert "validator will fail closed" in run.stdout
