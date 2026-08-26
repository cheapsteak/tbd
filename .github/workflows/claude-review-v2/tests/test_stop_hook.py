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

The hold path waits in production, because BLOCKS are what the hold is short
of: the harness overrides a Stop hook after 8 consecutive blocks and ends the
turn regardless, so the hold has to buy wall clock per block rather than
blocks per minute. Cases here drive the wait to 0 via
REVIEW_HOLD_SLEEP_SECONDS so the suite stays fast; the cases that are ABOUT
the wait set it explicitly, and one asserts the production default is still
90 seconds with no configuration.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import time
from pathlib import Path

import pytest

HOOK = (
    Path(__file__).resolve().parent.parent / "hooks" / "stop-hook.sh"
)
SETTINGS = (
    Path(__file__).resolve().parent.parent / "hooks" / "settings.json"
)

COUNT_FILE = "claude-review-v2-block-count"
START_FILE = "claude-review-v2-hold-started"
HOLD_FILE = "claude-review-v2-hold-count"

DEFAULT_PATH = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"


def _run(
    project_dir: Path,
    state_dir: Path,
    specialists: str | None = "correctness,conventions",
    stdin: str = '{"stop_hook_active": true}',
    sleep_seconds: str = "0",
    path: str = DEFAULT_PATH,
) -> subprocess.CompletedProcess[str]:
    env = {
        "PATH": path,
        "CLAUDE_PROJECT_DIR": str(project_dir),
        "TMPDIR": str(state_dir),
        "REVIEW_HOLD_SLEEP_SECONDS": sleep_seconds,
    }
    if specialists is not None:
        env["REVIEW_SPECIALISTS"] = specialists
    return subprocess.run(
        ["bash", str(HOOK)],
        input=stdin,
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
    )


def _slept(sleep_log: Path) -> int:
    """Total seconds the hook asked `sleep` for across the whole window.

    The window is spent in short polling steps so the hold can end early, so
    no single `sleep` call carries the window length — the sum does.
    """
    return sum(int(arg) for arg in sleep_log.read_text().split())


def _path_without_jq(tmp_path: Path) -> str:
    """A PATH carrying everything the hook shells out to EXCEPT jq.

    Removing the directories jq lives in would also remove `cat` and `date`,
    so the absence has to be built rather than subtracted.
    """
    bindir = tmp_path / "nojq-bin"
    bindir.mkdir(exist_ok=True)
    for tool in ("bash", "cat", "date", "tr"):
        found = shutil.which(tool)
        assert found, f"test prerequisite missing: {tool}"
        link = bindir / tool
        if not link.exists():
            link.symlink_to(found)
    assert shutil.which("jq", path=str(bindir)) is None
    return str(bindir)


def _path_with_sleep_stub(tmp_path: Path) -> tuple[str, Path]:
    """A PATH whose `sleep` records its argument and returns at once.

    The hook's wait is the one behavior a test cannot observe by waiting for
    it: the shipped default is 90 seconds, so asserting on the real wait would
    cost the suite 90 seconds per case. Recording the arguments asserts the
    same thing — how much wall clock the hook asked for — in no time at all.
    The hook spends the window in short polling steps, so the invariant is the
    SUM of what reached `sleep`, not any single call.
    """
    bindir = tmp_path / "sleepstub-bin"
    bindir.mkdir(exist_ok=True)
    for tool in ("bash", "cat", "date", "tr", "jq"):
        found = shutil.which(tool)
        assert found, f"test prerequisite missing: {tool}"
        link = bindir / tool
        if not link.exists():
            link.symlink_to(found)
    log = tmp_path / "sleep-args.log"
    log.touch()  # "sleep was never called" must read as empty, not as a miss
    stub = bindir / "sleep"
    stub.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" >> "{log}"\n')
    stub.chmod(0o755)
    return str(bindir), log


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


def test_hold_reason_forbids_polling_the_files_it_already_checks(
    dirs: tuple[Path, Path],
) -> None:
    """The sleep arithmetic assumes ONE turn per hold.

    Every tool call the model makes while waiting is another turn, so a reason
    that invites it to Read or Glob for the findings files halves the wall
    clock the turn budget buys — and buys nothing, because this hook checked
    those same files a moment earlier and will check them again on the next
    stop attempt.
    """
    reason = _decision(_run(*dirs))["reason"].lower()
    assert "do not call any tools" in reason


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


# --- the hold sleeps, so that a hold costs wall clock and not a turn -------


def test_the_pending_hold_sleeps_before_emitting_its_block(
    dirs: tuple[Path, Path],
) -> None:
    """A hold is a turn, and turns are the budget the session runs out of
    first. Sleeping inside the hook converts one turn into wall clock at no
    token cost, which is what lets the 25-minute deadline be the real bound."""
    project, state = dirs
    started = time.monotonic()
    proc = _run(project, state, sleep_seconds="2")
    elapsed = time.monotonic() - started
    assert _decision(proc)["decision"] == "block"
    assert elapsed >= 2


def test_the_production_sleep_default_needs_no_configuration() -> None:
    """90 s is the shipped default: the workflow sets no override, so the
    arithmetic in the hook's comment holds for the real job. It is the number
    that makes the harness's 8-block cap survivable — 8 x 90 s is ~12 minutes,
    past the ~10 the specialists need."""
    assert 'REVIEW_HOLD_SLEEP_SECONDS:-90}' in HOOK.read_text()


def test_the_stop_hook_command_outlives_its_own_sleep() -> None:
    """A hook killed at its declared timeout mid-wait would emit no block and
    the session would end — the exact failure the hold exists to prevent."""
    settings = json.loads(SETTINGS.read_text())
    entries = [
        cmd
        for matcher in settings["hooks"]["Stop"]
        for cmd in matcher["hooks"]
    ]
    assert entries, "no Stop hook command declared"
    for cmd in entries:
        assert cmd["timeout"] == 120
        assert cmd["timeout"] > 90  # strictly longer than the hold window


def test_the_deadline_is_checked_before_the_hook_sleeps(
    dirs: tuple[Path, Path],
) -> None:
    """Never sleep and then release: past the deadline the session is being
    let go, so the wait would buy nothing and only burn runner minutes."""
    project, state = dirs
    (state / START_FILE).write_text(str(int(time.time()) - 1501))
    started = time.monotonic()
    proc = _run(project, state, sleep_seconds="30")
    elapsed = time.monotonic() - started
    assert _decision(proc) is None
    assert elapsed < 5


def test_the_hold_cap_is_checked_before_the_hook_sleeps(
    dirs: tuple[Path, Path],
) -> None:
    project, state = dirs
    (state / HOLD_FILE).write_text("20")
    started = time.monotonic()
    proc = _run(project, state, sleep_seconds="30")
    elapsed = time.monotonic() - started
    assert _decision(proc) is None
    assert elapsed < 5


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


@pytest.mark.parametrize("nameless", [",", "   ", ",,"])
def test_a_nameless_specialist_list_still_holds(
    dirs: tuple[Path, Path], nameless: str
) -> None:
    """`:-` defaults on unset or EMPTY only, so a value that names nobody
    survives it.

    The loop then iterates over nothing, findings_pending stays 0, and the hook
    drops into the counted nudge with the hold silently disarmed — fail-OPEN,
    and invisible: the session ends early exactly as it did before this hook
    existed. validate.py raises on the same input; a Stop hook may never raise
    (it must always exit 0), so treating it as an absent variable is the
    analogue.
    """
    project, state = dirs
    proc = _run(project, state, specialists=nameless)
    assert proc.returncode == 0
    assert _decision(proc)["decision"] == "block"
    assert "still running" in _decision(proc)["reason"].lower()
    assert _count(state) == 0  # held, not nudged


@pytest.mark.parametrize("nameless", [",", "   ", ",,"])
def test_a_nameless_specialist_list_falls_back_to_the_known_pair(
    dirs: tuple[Path, Path], nameless: str
) -> None:
    """The fallback must be the declared pair, not "hold unconditionally":
    once both known files land, the session has to be able to finish."""
    project, state = dirs
    _write_findings(project, "correctness")
    _write_findings(project, "conventions")
    proc = _run(project, state, specialists=nameless)
    assert proc.returncode == 0
    assert "review-result.json" in _decision(proc)["reason"]
    assert _count(state) == 1


def test_an_unwritable_state_dir_cannot_hold_forever(
    dirs: tuple[Path, Path], tmp_path: Path
) -> None:
    """Both bounds are made of persisted state: with nowhere to persist it,
    the start stamp reads as "now" on every invocation and the hold count
    never leaves zero, so a hook that kept blocking would block forever.
    Asserting only "exit code 0" cannot see that — every path of this script
    exits 0 — so the assertion has to be that a release is actually
    observed."""
    project, _ = dirs
    unwritable = tmp_path / "ro"
    unwritable.mkdir(mode=0o500)
    releases = 0
    for _ in range(70):
        proc = _run(project, unwritable)
        assert proc.returncode == 0
        if _decision(proc) is None:
            releases += 1
            break
    assert releases == 1


# Two independent `|| exit 0` guards stand behind that release — the start-stamp
# write and the hold-counter write — and the case above cannot tell them apart:
# with the whole directory unwritable, EITHER guard alone produces the release,
# so removing one leaves the test green. Each is therefore exercised with only
# its own file unwritable, the other left working.


def _unwritable_file(path: Path) -> None:
    path.write_text("")
    path.chmod(0o444)


def test_an_unwritable_start_stamp_alone_releases(
    dirs: tuple[Path, Path],
) -> None:
    """With no persisted stamp, elapsed time reads as 0 forever, so the
    deadline is unreachable and only this guard ends the session."""
    project, state = dirs
    _unwritable_file(state / START_FILE)
    proc = _run(project, state)
    assert proc.returncode == 0
    assert _decision(proc) is None


def test_an_unwritable_hold_counter_alone_releases(
    dirs: tuple[Path, Path],
) -> None:
    """With no persisted hold count the cap is unreachable, and inside the
    deadline only this guard ends the session."""
    project, state = dirs
    _unwritable_file(state / HOLD_FILE)
    proc = _run(project, state)
    assert proc.returncode == 0
    assert _decision(proc) is None
    # The other guard is not what released this run: the stamp was writable.
    assert (state / START_FILE).exists()


# --- the wait watches, so the hold ends when the work does -----------------


def _path_with_findings_dropping_sleep(
    tmp_path: Path, project_dir: Path
) -> str:
    """A `sleep` stub that lands both findings files on its FIRST call.

    Models what the hold exists for: the specialists finish partway through a
    wait the hook has already committed to. A stub is the only way to place
    that event inside the window deterministically.
    """
    bindir = tmp_path / "landing-bin"
    bindir.mkdir(exist_ok=True)
    for tool in ("bash", "cat", "date", "tr", "jq"):
        found = shutil.which(tool)
        assert found, f"test prerequisite missing: {tool}"
        link = bindir / tool
        if not link.exists():
            link.symlink_to(found)
    payload = json.dumps({"specialist": "x", "findings": []})
    stub = bindir / "sleep"
    stub.write_text(
        "#!/bin/sh\n"
        f"for n in correctness conventions; do\n"
        f"  [ -f '{project_dir}'/findings-$n.json ] "
        f"|| printf '%s' '{payload}' > '{project_dir}'/findings-$n.json\n"
        "done\n"
    )
    stub.chmod(0o755)
    return str(bindir)


def test_findings_landing_mid_wait_end_the_wait_and_change_the_message(
    dirs: tuple[Path, Path], tmp_path: Path
) -> None:
    """The block that follows a wait must report the state AFTER it.

    A hold is one of only 8 consecutive blocks the harness allows, so a hold
    that reported its pre-wait snapshot would spend a whole further block
    telling the orchestrator to keep waiting for files already on disk. The
    discriminating assertion is on WHICH reason came back: a hook that waits
    blindly still blocks, so "did it block" passes against the bug.
    """
    project, state = dirs
    path = _path_with_findings_dropping_sleep(tmp_path, project)
    proc = _run(project, state, sleep_seconds="90", path=path)
    assert proc.returncode == 0
    reason = _decision(proc)["reason"]
    assert "review-result.json" in reason
    assert "specialist subagents are still running" not in reason
    # And it is charged to the nudge budget, which is the budget for a model
    # that now HAS everything it needs.
    assert _count(state) == 1


def test_a_result_file_landing_mid_wait_releases_the_session(
    dirs: tuple[Path, Path], tmp_path: Path
) -> None:
    """The result check at the top of the hook is up to a window stale.

    Everything the hold says after its wait rests on that file still being
    absent, so it is re-checked for the same reason the findings are. Blocking
    here would nudge the model to write a file already on disk, spending one of
    the rationed blocks — and this branch ENDS the session rather than holding
    it, so a test that only watched the findings would never see the gap.
    """
    project, state = dirs
    bindir = tmp_path / "result-bin"
    bindir.mkdir()
    for tool in ("bash", "cat", "date", "tr", "jq"):
        found = shutil.which(tool)
        assert found, f"test prerequisite missing: {tool}"
        (bindir / tool).symlink_to(found)
    payload = json.dumps({"findings": [], "disposition": [], "comment_body": "x"})
    stub = bindir / "sleep"
    stub.write_text(
        "#!/bin/sh\n"
        f"printf '%s' '{payload}' > '{project}'/review-result.json\n"
    )
    stub.chmod(0o755)
    proc = _run(project, state, sleep_seconds="90", path=str(bindir))
    assert proc.returncode == 0
    assert _decision(proc) is None
    # Not the nudge budget either: nothing was nudged.
    assert _count(state) == 0


def test_the_wait_stops_polling_once_the_findings_land(
    dirs: tuple[Path, Path], tmp_path: Path
) -> None:
    """Early exit is the point: the remaining window is not spent."""
    project, state = dirs
    path = _path_with_findings_dropping_sleep(tmp_path, project)
    log = tmp_path / "landing-sleep.log"
    stub = Path(path) / "sleep"
    stub.write_text(
        stub.read_text() + f'printf "%s\\n" "$@" >> "{log}"\n'
    )
    log.touch()
    _run(project, state, sleep_seconds="90", path=path)
    assert _slept(log) == 5  # one poll step, not the whole 90 s window


def test_a_non_numeric_sleep_override_falls_back_to_the_default(
    dirs: tuple[Path, Path], tmp_path: Path
) -> None:
    """`sleep` is handed this value and `[` compares it as an integer.

    Unclamped, a garbage override makes both complain on stderr and skips the
    wait entirely — the hold stops costing wall clock and starts costing only
    turns, which is the trade the sleep exists to reverse. Asserting on the
    argument the hook actually passes to `sleep` (recorded by a stub, so the
    green path does not spend 90 real seconds) is what makes the clamp
    observable at all.
    """
    project, state = dirs
    path, sleep_log = _path_with_sleep_stub(tmp_path)
    proc = _run(project, state, sleep_seconds="not-a-number", path=path)
    assert proc.returncode == 0
    assert _decision(proc)["decision"] == "block"
    assert proc.stderr == ""
    assert _slept(sleep_log) == 90


def test_a_numeric_sleep_override_is_passed_through(
    dirs: tuple[Path, Path], tmp_path: Path
) -> None:
    """The clamp must not swallow a legitimate override — the unit tests here
    drive the sleep to 0 through it."""
    project, state = dirs
    path, sleep_log = _path_with_sleep_stub(tmp_path)
    proc = _run(project, state, sleep_seconds="7", path=path)
    assert _decision(proc)["decision"] == "block"
    assert _slept(sleep_log) == 7


# --- jq absent: the fallback must not invent a pending review --------------


def test_a_valid_result_file_ends_the_session_without_jq(
    dirs: tuple[Path, Path], tmp_path: Path
) -> None:
    """Claiming "specialists still running" over a missing binary is a
    falsehood the orchestrator acts on — it can re-spawn duplicate
    specialists — and it holds the session for the whole deadline."""
    project, state = dirs
    _write_result(project)
    proc = _run(project, state, path=_path_without_jq(tmp_path))
    assert proc.returncode == 0
    assert _decision(proc) is None


def test_present_findings_still_reach_the_counted_nudge_without_jq(
    dirs: tuple[Path, Path], tmp_path: Path
) -> None:
    project, state = dirs
    _write_findings(project, "correctness")
    _write_findings(project, "conventions")
    proc = _run(project, state, path=_path_without_jq(tmp_path))
    assert proc.returncode == 0
    assert _decision(proc)["decision"] == "block"
    assert "review-result.json" in _decision(proc)["reason"]
    assert _count(state) == 1


def test_a_missing_findings_file_still_holds_without_jq(
    dirs: tuple[Path, Path], tmp_path: Path
) -> None:
    project, state = dirs
    _write_findings(project, "correctness")
    proc = _run(project, state, path=_path_without_jq(tmp_path))
    assert _decision(proc)["decision"] == "block"
    assert _count(state) == 0


def test_an_empty_result_file_does_not_end_the_session_without_jq(
    dirs: tuple[Path, Path], tmp_path: Path
) -> None:
    """Non-emptiness is the strongest evidence available with no parser, so
    an empty file must still read as "not written"."""
    project, state = dirs
    (project / "review-result.json").write_text("")
    proc = _run(project, state, path=_path_without_jq(tmp_path))
    assert _decision(proc)["decision"] == "block"


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
