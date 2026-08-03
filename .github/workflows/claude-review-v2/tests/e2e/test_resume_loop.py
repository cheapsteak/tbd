"""Stub-API e2e: the between-invocation retry loop (`claude -p --resume`).

One scenario, two invocations of the real CLI against fresh stubs, one shared
sandbox (same HOME/CLAUDE_CONFIG_DIR/TMPDIR/project — the session transcript
on disk is what carries state across the process boundary):

  Invocation 1: the orchestrator fans out to a fast and a SLOW specialist
  (stub delays the slow role's first response), then stalls — end_turn after
  end_turn without writing review-result.json — until the real Stop hook burns
  its 5-nudge ceiling and gives up. Asserts three empirically-established CLI
  behaviors (2.1.220):
    - the hook ceiling terminates a non-compliant session (bounded, no wedge),
    - the CLI does NOT kill pending background subagents at session end — it
      blocks exit until they finish, so the slow specialist's file still lands,
    - session_id is available from `--output-format json`.

  Between invocations: harness.reset_nudge_counter — REQUIRED. The counter
  lives in TMPDIR, not session state, so a resumed session would inherit the
  burned-out counter and the hook would allow its very first stop attempt.

  Invocation 2: `--resume <session_id>` with a corrective prompt pointing at
  the on-disk findings-*.json (the findings CONTENT is not in the
  orchestrator's transcript — Task returns only launch metadata, and the
  specialists' work lives in their own subagent transcripts). Asserts resume
  works in the sandbox, continues the SAME session id, carries invocation-1
  history, and that the result file + validate.py complete the contract.
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
from stub_server import StubServer, ToolCall, Turn  # noqa: E402

_FAST_ROLE = "correctness"
_SLOW_ROLE = "conventions"
# Long enough that the nudge burn (~0.5s) demonstrably finishes first, short
# enough to keep the suite quick.
_SLOW_DELAY_SECONDS = 3.0


def _result_doc() -> dict:
    return {
        "findings": [harness.minor_finding(_FAST_ROLE), harness.minor_finding(_SLOW_ROLE)],
        "disposition": [
            {"id": f"{_FAST_ROLE}-1", "action": "kept"},
            {"id": f"{_SLOW_ROLE}-1", "action": "kept"},
        ],
        "comment_body": "Findings merged across the resume boundary; nothing blocking.",
    }


def _run_claude(args: list[str], project: Path, sandbox: Path, base_url: str):
    return subprocess.run(
        args,
        cwd=project,
        env=harness.sandbox_env(sandbox, base_url),
        capture_output=True,
        text=True,
        timeout=240,
    )


@pytest.mark.skipif(
    shutil.which("claude") is None,
    reason="claude CLI not on PATH; stub e2e exercises the real binary",
)
def test_resume_loop_end_to_end() -> None:
    sandbox = Path(tempfile.mkdtemp(prefix="claude-review-v2-resume-"))
    try:
        project = harness.make_sandbox(sandbox)
        prompt = (
            "You are under test against a scripted API. Execute the tool "
            "calls you are given and follow tool results."
        )

        # ---- invocation 1: fan out, then stall to the hook ceiling ----------
        inv1_turns = [
            Turn(
                text="Fanning out to a fast and a slow specialist.",
                tool_calls=[
                    harness.task_call(_FAST_ROLE, project),
                    harness.task_call(_SLOW_ROLE, project),
                ],
            ),
            # Everything from here on is end_turn (this turn, then the stub's
            # STUB-TERMINAL overflow), so every hook nudge is answered with
            # another stop attempt until the 5-nudge ceiling gives up.
            Turn(text="EARLY-STOP-ATTEMPT"),
        ]
        role_turns = {
            harness.sentinel(_FAST_ROLE): harness.specialist_turns(_FAST_ROLE, project),
            harness.sentinel(_SLOW_ROLE): harness.specialist_turns(_SLOW_ROLE, project),
        }
        with StubServer(
            inv1_turns,
            role_turns=role_turns,
            role_delays={harness.sentinel(_SLOW_ROLE): _SLOW_DELAY_SECONDS},
        ) as stub1:
            proc1 = _run_claude(
                ["claude", "-p", "--output-format", "json", prompt,
                 "--permission-mode", "bypassPermissions"],
                project, sandbox, stub1.base_url,
            )

        debug1 = (
            f"exit={proc1.returncode}\nstdout:\n{proc1.stdout}\n"
            f"stderr:\n{proc1.stderr}\nroutes={stub1.capture.routes}"
        )
        assert proc1.returncode == 0, f"invocation 1 exited non-zero.\n{debug1}"

        out1 = json.loads(proc1.stdout)
        session_id = out1.get("session_id")
        assert session_id, f"no session_id in --output-format json.\n{debug1}"

        # The hook burned to its ceiling and the session ended result-less.
        assert harness.nudge_count(sandbox) == 5, (
            f"expected the full 5-nudge burn, got {harness.nudge_count(sandbox)}.\n{debug1}"
        )
        assert not (project / "review-result.json").is_file(), debug1

        # The CLI waited for the pending slow specialist at exit: its delayed
        # response was consumed (no client disconnect) and its file landed
        # even though the session loop had long since been allowed to stop.
        assert (project / f"findings-{_FAST_ROLE}.json").is_file(), debug1
        assert (project / f"findings-{_SLOW_ROLE}.json").is_file(), (
            f"slow specialist's file missing — CLI no longer waits for pending "
            f"background subagents at exit?\n{debug1}"
        )
        assert stub1.capture.client_disconnects == [], debug1

        # ---- between invocations: the counter reset is load-bearing --------
        harness.reset_nudge_counter(sandbox)

        # ---- invocation 2: resume with a corrective prompt ------------------
        corrective = (
            "The specialist findings are already on disk in findings-*.json. "
            "Write review-result.json now, covering them with dispositions."
        )
        inv2_turns = [
            Turn(
                text="Writing the merged result from the on-disk findings.",
                tool_calls=[
                    ToolCall(
                        "Write",
                        {
                            "file_path": str(project / "review-result.json"),
                            "content": json.dumps(_result_doc(), indent=2),
                        },
                    )
                ],
            ),
            Turn(text="RESUME-DONE"),
        ]
        with StubServer(inv2_turns) as stub2:
            proc2 = _run_claude(
                ["claude", "-p", "--resume", session_id, corrective,
                 "--output-format", "json", "--permission-mode", "bypassPermissions"],
                project, sandbox, stub2.base_url,
            )

        debug2 = (
            f"exit={proc2.returncode}\nstdout:\n{proc2.stdout}\n"
            f"stderr:\n{proc2.stderr}\nroutes={stub2.capture.routes}"
        )
        assert proc2.returncode == 0, f"invocation 2 exited non-zero.\n{debug2}"

        # Same-session semantics: --resume continues the session id (no fork),
        # and the session transcript was found under the sandboxed
        # CLAUDE_CONFIG_DIR (projects/<munged-cwd>/<session-id>.jsonl).
        out2 = json.loads(proc2.stdout)
        assert out2.get("session_id") == session_id, debug2
        transcripts = list((sandbox / "config" / "projects").rglob(f"{session_id}.jsonl"))
        assert transcripts, f"no session transcript under CLAUDE_CONFIG_DIR.\n{debug2}"

        # Invocation-1 history reached the resumed model: the fan-out's role
        # sentinel appears in the resumed request bodies (inside the historic
        # Task tool_use blocks).
        resumed_history = b"".join(stub2.capture.raw_bodies)
        assert harness.sentinel(_FAST_ROLE).encode() in resumed_history, (
            f"round-1 history absent from the resumed session.\n{debug2}"
        )

        # The contract completes across the process boundary.
        result_path = project / "review-result.json"
        assert result_path.is_file(), debug2
        assert json.loads(result_path.read_text(encoding="utf-8")) == _result_doc()

        if importlib.util.find_spec("jsonschema") is not None:
            vproc = subprocess.run(
                [
                    sys.executable,
                    str(harness.VALIDATE),
                    "--specialist-files",
                    "findings-*.json",
                    "--result-file",
                    "review-result.json",
                    "--expected-specialists",
                    f"{_FAST_ROLE},{_SLOW_ROLE}",
                ],
                cwd=project,
                capture_output=True,
                text=True,
                timeout=60,
            )
            assert vproc.returncode == 0, (
                f"validate.py rejected the resumed output:\n"
                f"stdout:\n{vproc.stdout}\nstderr:\n{vproc.stderr}"
            )
            assert (project / "verdict.txt").read_text(encoding="utf-8") == "APPROVE"
        else:
            print("note: jsonschema not installed — validate.py sub-assertion skipped")
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)
