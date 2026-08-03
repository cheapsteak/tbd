"""Stub-API e2e: two PARALLEL Task specialists under one headless session.

De-risks the spec's §7 open question (do parallel specialists fit one headless
session?) with the real `claude` CLI: the orchestrator spawns the two real
specialist roles in ONE assistant message, each subagent writes its findings
file, and the orchestrator writes review-result.json covering both.

Because the racing subagents make request order nondeterministic, the stub
runs in content-keyed routing mode (role sentinels; see
stub_server.first_message_text).

Empirical CLI behavior this scenario is built around (observed on 2.1.220):
Task tool_results return IMMEDIATELY as "Async agent launched" metadata — the
subagents run in the background and their completions arrive later as
system-notification turns, whose count varies run to run. The scripted
orchestrator therefore relies on the stub's STUB-TERMINAL overflow to absorb
the variable notification tail, and the parallelism assertion reads the
capture's per-route timestamps rather than assuming any global order.
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

_ROLES = ["correctness", "conventions"]


def _result_doc() -> dict:
    return {
        "findings": [harness.minor_finding(role) for role in _ROLES],
        "disposition": [{"id": f"{role}-1", "action": "kept"} for role in _ROLES],
        "comment_body": "Two MINOR findings from the specialist fan-out; nothing blocking.",
    }


@pytest.mark.skipif(
    shutil.which("claude") is None,
    reason="claude CLI not on PATH; stub e2e exercises the real binary",
)
def test_parallel_fanout_end_to_end() -> None:
    sandbox = Path(tempfile.mkdtemp(prefix="claude-review-v2-fanout-"))
    try:
        project = harness.make_sandbox(sandbox)

        orchestrator_turns = [
            Turn(
                text="Fanning out to two specialists in parallel.",
                tool_calls=[harness.task_call(role, project) for role in _ROLES],
            ),
            Turn(
                text="All specialists reported; writing the merged result.",
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
            Turn(text="FANOUT-DONE"),
        ]
        role_turns = {
            harness.sentinel(role): harness.specialist_turns(role, project)
            for role in _ROLES
        }

        with StubServer(orchestrator_turns, role_turns=role_turns) as stub:
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

        cap = stub.capture
        debug = (
            f"exit={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\n"
            f"routes={cap.routes}\nunexpected={cap.unexpected_paths}"
        )

        assert proc.returncode == 0, f"claude exited non-zero.\n{debug}"
        assert loop_advanced(cap), f"tool loop never advanced.\n{debug}"

        # All three files landed.
        for name in [f"findings-{role}.json" for role in _ROLES] + ["review-result.json"]:
            assert (project / name).is_file(), f"{name} missing.\n{debug}"
        assert json.loads(
            (project / "review-result.json").read_text(encoding="utf-8")
        ) == _result_doc()

        # Full parallelism: every role conversed (2 requests: Write, then its
        # tool_result), and the two conversations OVERLAPPED — every role's
        # first request arrived before any role finished. A sequential runner
        # (role B starts after role A completes) fails this.
        per_role_times: dict[str, list[float]] = {}
        for route, ts in zip(cap.routes, cap.timestamps):
            if route is not None:
                per_role_times.setdefault(route, []).append(ts)
        assert sorted(per_role_times) == sorted(role_turns), (
            f"expected both roles to converse.\n{debug}"
        )
        for role_sentinel, times in per_role_times.items():
            assert len(times) == 2, (
                f"{role_sentinel}: expected exactly 2 requests, got {len(times)}.\n{debug}"
            )
        latest_start = max(times[0] for times in per_role_times.values())
        earliest_finish = min(times[-1] for times in per_role_times.values())
        assert latest_start < earliest_finish, (
            "role conversations did not overlap — subagents ran sequentially?\n"
            f"starts/finishes={per_role_times}\n{debug}"
        )

        # Zero silent retries: no two request bodies byte-identical, anywhere.
        assert len(set(cap.raw_bodies)) == len(cap.raw_bodies), (
            f"byte-identical request bodies observed (silent-retry signature).\n{debug}"
        )

        # The session never tried to stop early: the Stop hook never blocked.
        assert harness.nudge_count(sandbox) == 0, (
            f"Stop hook nudged {harness.nudge_count(sandbox)} time(s).\n{debug}"
        )

        assert harness.tolerated_unexpected_paths(cap.unexpected_paths) == [], debug

        # The REAL validate.py, with the specialist-completeness check.
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
                    ",".join(_ROLES),
                ],
                cwd=project,
                capture_output=True,
                text=True,
                timeout=60,
            )
            assert vproc.returncode == 0, (
                f"validate.py rejected the fan-out output:\n"
                f"stdout:\n{vproc.stdout}\nstderr:\n{vproc.stderr}"
            )
            assert (project / "verdict.txt").read_text(encoding="utf-8") == "APPROVE"
        else:
            print("note: jsonschema not installed — validate.py sub-assertion skipped")
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)
