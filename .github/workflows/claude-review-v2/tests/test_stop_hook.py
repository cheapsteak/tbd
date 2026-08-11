"""Behavioral tests for the claude-review-v2 Stop hook.

The hook decides whether the review session may end. Its bug was a
CONFLATION: a nudge budget meant for a model that WON'T write the result
also expired against a model that CAN'T yet, because its specialists were
still running. So the discriminating assertion in this module is on the
COUNTER, not on "did it block" — a test that only checks for a block passes
against the broken hook.

Every case also re-asserts the hook's fail-safe contract: exit code 0. A
hook that exits non-zero wedges the session, and allowing a stop is never a
gate bypass because validate.py fails closed downstream.
"""

from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path

import pytest

HOOK = (
    Path(__file__).resolve().parent.parent / "hooks" / "stop-hook.sh"
)

COUNT_FILE = "claude-review-v2-block-count"
START_FILE = "claude-review-v2-hold-started"


def _run(
    project_dir: Path,
    state_dir: Path,
    specialists: str | None = "correctness,conventions",
    stdin: str = '{"stop_hook_active": true}',
) -> subprocess.CompletedProcess[str]:
    env = {
        "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
        "CLAUDE_PROJECT_DIR": str(project_dir),
        "TMPDIR": str(state_dir),
    }
    if specialists is not None:
        env["REVIEW_SPECIALISTS"] = specialists
    return subprocess.run(
        ["bash", str(HOOK)],
        input=stdin,
        env=env,
        capture_output=True,
        text=True,
        timeout=30,
    )


def _decision(proc: subprocess.CompletedProcess[str]) -> dict | None:
    out = proc.stdout.strip()
    return json.loads(out) if out else None


def _count(state_dir: Path) -> int:
    path = state_dir / COUNT_FILE
    return int(path.read_text()) if path.exists() else 0


def _write_findings(project_dir: Path, name: str) -> None:
    (project_dir / f"findings-{name}.json").write_text(
        json.dumps({"specialist": name, "findings": []})
    )


def _write_result(project_dir: Path) -> None:
    (project_dir / "review-result.json").write_text(
        json.dumps({"findings": [], "disposition": [], "comment_body": "ok"})
    )


@pytest.fixture()
def dirs(tmp_path: Path) -> tuple[Path, Path]:
    project = tmp_path / "workspace"
    state = tmp_path / "state"
    project.mkdir()
    state.mkdir()
    return project, state


# --- the allow path is unchanged -------------------------------------------


def test_parseable_result_file_allows_the_stop(dirs: tuple[Path, Path]) -> None:
    project, state = dirs
    _write_result(project)
    proc = _run(project, state)
    assert proc.returncode == 0
    assert _decision(proc) is None


# --- state 1: specialists still running -> UNCOUNTED hold ------------------


def test_missing_findings_blocks_without_consuming_the_budget(
    dirs: tuple[Path, Path],
) -> None:
    project, state = dirs
    for _ in range(8):  # more than max_blocks=5
        proc = _run(project, state)
        assert proc.returncode == 0
        assert _decision(proc)["decision"] == "block"
    # THE discriminating assertion: the nudge budget was never touched.
    assert _count(state) == 0


def test_one_findings_file_present_still_counts_as_pending(
    dirs: tuple[Path, Path],
) -> None:
    project, state = dirs
    _write_findings(project, "correctness")
    for _ in range(7):
        assert _run(project, state).returncode == 0
    assert _count(state) == 0


def test_hold_reason_tells_the_model_not_to_end_its_turn(
    dirs: tuple[Path, Path],
) -> None:
    project, state = dirs
    reason = _decision(_run(project, state))["reason"].lower()
    assert "still running" in reason
    assert "do not end your turn" in reason


def test_unparseable_findings_file_counts_as_pending(
    dirs: tuple[Path, Path],
) -> None:
    project, state = dirs
    _write_findings(project, "correctness")
    (project / "findings-conventions.json").write_text("{not json")
    assert _run(project, state).returncode == 0
    assert _count(state) == 0


# --- state 2: findings complete, result missing -> COUNTED nudge -----------


def test_complete_findings_without_result_consumes_the_budget(
    dirs: tuple[Path, Path],
) -> None:
    project, state = dirs
    _write_findings(project, "correctness")
    _write_findings(project, "conventions")
    proc = _run(project, state)
    assert proc.returncode == 0
    assert _decision(proc)["decision"] == "block"
    assert "review-result.json" in _decision(proc)["reason"]
    assert _count(state) == 1


def test_the_five_nudge_ceiling_still_releases_a_refusing_model(
    dirs: tuple[Path, Path],
) -> None:
    project, state = dirs
    _write_findings(project, "correctness")
    _write_findings(project, "conventions")
    for _ in range(5):
        assert _decision(_run(project, state))["decision"] == "block"
    assert _count(state) == 5
    assert _decision(_run(project, state)) is None  # released


# --- state 3: past the deadline -> release ---------------------------------


def test_past_the_hold_deadline_the_hook_gives_up(
    dirs: tuple[Path, Path],
) -> None:
    project, state = dirs
    stale = int(time.time()) - 1501  # deadline is 1500s
    (state / START_FILE).write_text(str(stale))
    proc = _run(project, state)
    assert proc.returncode == 0
    assert _decision(proc) is None


def test_inside_the_deadline_the_hook_still_holds(
    dirs: tuple[Path, Path],
) -> None:
    project, state = dirs
    (state / START_FILE).write_text(str(int(time.time()) - 1400))
    assert _decision(_run(project, state))["decision"] == "block"


def test_first_invocation_stamps_a_start_time(dirs: tuple[Path, Path]) -> None:
    project, state = dirs
    before = int(time.time())
    _run(project, state)
    stamped = int((state / START_FILE).read_text())
    assert before <= stamped <= int(time.time())


def test_the_start_stamp_is_not_rewritten_by_later_invocations(
    dirs: tuple[Path, Path],
) -> None:
    project, state = dirs
    (state / START_FILE).write_text("1000")
    _run(project, state)
    assert (state / START_FILE).read_text().strip() == "1000"


# --- fail-safe contract ----------------------------------------------------


@pytest.mark.parametrize("stdin", ["", "not json at all", "{"])
def test_malformed_stdin_never_wedges_the_session(
    dirs: tuple[Path, Path], stdin: str
) -> None:
    project, state = dirs
    assert _run(project, state, stdin=stdin).returncode == 0


def test_absent_specialist_env_falls_back_to_the_known_pair(
    dirs: tuple[Path, Path],
) -> None:
    project, state = dirs
    _write_findings(project, "correctness")
    _write_findings(project, "conventions")
    proc = _run(project, state, specialists=None)
    assert proc.returncode == 0
    assert _count(state) == 1  # counted => it knew both files were present


def test_unwritable_state_dir_never_wedges_the_session(
    dirs: tuple[Path, Path], tmp_path: Path
) -> None:
    project, _ = dirs
    unwritable = tmp_path / "ro"
    unwritable.mkdir(mode=0o500)
    assert _run(project, unwritable).returncode == 0


def test_a_broken_clock_cannot_hold_forever(dirs: tuple[Path, Path]) -> None:
    """Defensive cap: even with elapsed time stuck at zero, uncounted holds
    are bounded, so a clock failure cannot make the session unstoppable."""
    project, state = dirs
    releases = 0
    for _ in range(70):
        (state / START_FILE).write_text(str(int(time.time())))  # never ages
        if _decision(_run(project, state)) is None:
            releases += 1
            break
    assert releases == 1
