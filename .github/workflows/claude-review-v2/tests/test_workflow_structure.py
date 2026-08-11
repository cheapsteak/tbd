"""Structural assertions on the v2 review workflow's step graph.

Two properties here are positional rather than behavioral, so a shell harness
cannot see them and only the workflow's own shape can:

- the pipeline directory is re-restored from the base branch AFTER the review
  session and BEFORE the steps that compute and publish the verdict. The
  session holds an unrestricted Write tool, so validate.py (which computes the
  verdict) and render_comment.py (which builds text posted verbatim to a public
  PR) must be re-established after that window closes.
- both restores materialize the same tree, because the second reads the SHA the
  first resolved and recorded rather than FETCH_HEAD, which a later fetch moves.

Every lookup is by exact step NAME, so renaming a step fails loudly.
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml

from workflow_steps import (
    _WORKFLOWS_DIR,
    read_workflow,
    run_block,
    step_index,
    step_source,
)

RESTORE_STEP = "Restore the review pipeline from the base branch"
RE_RESTORE_STEP = "Re-restore the review pipeline from the base branch"
SESSION_STEP = "Run Claude Code Review v2 (fan-out session)"
VALIDATE_STEP = "Validate review result (schemas, disposition coverage, verdict)"
POST_STEP = "Post review comment and enforce verdict"
PREPARE_STEP = "Prepare (skip decision + discussion context)"

PIPELINE_DIR = ".github/workflows/claude-review-v2"


def _condition(step_name: str) -> str:
    source = step_source(read_workflow(), step_name)
    match = re.search(r"^\s*if: (.+?)\s*$", source, re.MULTILINE)
    assert match is not None, f"step {step_name!r} has no `if:` condition"
    return match.group(1)


# --- the re-restore closes the session-writable window ----------------------


def test_the_pipeline_is_re_restored_between_the_session_and_the_verdict() -> None:
    text = read_workflow()
    assert (
        step_index(text, RESTORE_STEP)
        < step_index(text, PREPARE_STEP)
        < step_index(text, SESSION_STEP)
        < step_index(text, RE_RESTORE_STEP)
        < step_index(text, VALIDATE_STEP)
        < step_index(text, POST_STEP)
    )


def test_both_restores_use_the_same_pinned_base_sha() -> None:
    text = read_workflow()
    first = run_block(text, RESTORE_STEP)
    second = run_block(text, RE_RESTORE_STEP)
    # The first resolves FETCH_HEAD once and records it; the second reads that
    # output. FETCH_HEAD itself must not appear in the second — it is a ref a
    # later fetch rewrites, so restoring from it proves nothing about sameness.
    assert 'base_sha="$(git rev-parse FETCH_HEAD)"' in first
    assert 'echo "base_sha=$base_sha" >> "$GITHUB_OUTPUT"' in first
    assert "FETCH_HEAD" not in second
    assert "$BASE_SHA" in second
    assert (
        "BASE_SHA: ${{ steps.restore-pipeline.outputs.base_sha }}"
        in step_source(text, RE_RESTORE_STEP)
    )
    assert "id: restore-pipeline" in step_source(text, RESTORE_STEP)


def test_the_re_restore_is_gated_exactly_like_the_step_it_protects() -> None:
    # Deliberately not `always()`: a failed session step skips the validate and
    # post steps too, so no consumer of the directory ever reads a
    # session-written copy.
    assert _condition(RE_RESTORE_STEP) == _condition(VALIDATE_STEP)
    assert "always()" not in _condition(RE_RESTORE_STEP)


def test_the_re_restore_touches_only_the_pipeline_directory() -> None:
    # The session's outputs (review-result.json, findings-*.json) and
    # prepare.py's (skip-decision.json, discussion-context.txt) all live in the
    # workspace ROOT, so re-restoring must not reach outside this one path.
    body = run_block(read_workflow(), RE_RESTORE_STEP)
    removals = re.findall(r"^\s*rm .*$", body, re.MULTILINE)
    assert removals == [f'rm -rf "$GITHUB_WORKSPACE/{PIPELINE_DIR}"']
    checkouts = re.findall(r"^\s*git checkout .*$", body, re.MULTILINE)
    assert checkouts == [f'git checkout "$BASE_SHA" -- {PIPELINE_DIR}']


# --- the session is told what the restore did to its checkout ---------------


def test_the_session_prompt_explains_the_restored_directory() -> None:
    # Without this the reviewer reads BASE content for those paths and reviews
    # code that is not in the PR — silently, on exactly the PRs that change the
    # review pipeline.
    prompt = step_source(read_workflow(), SESSION_STEP)
    assert PIPELINE_DIR in prompt
    assert "restores `.github/workflows/claude-review-v2/` from the base branch" in prompt
    assert "git show HEAD:<path>" in prompt


# --- exactly one job may be named `claude-review` ---------------------------

# Branch protection matches a required check by JOB NAME, not by workflow file.
# Two jobs sharing the name would both report into the required `claude-review`
# context and which one the gate reads becomes a race. The whole promotion rests
# on this, and it is asserted as load-bearing in four prose places (this
# workflow's banner, CLAUDE.md, docs/pr-review-gate.md, design spec §5) — none of
# which a future edit has to read. Splitting the reviewer into
# claude-code-review.yml + claude-code-review-legacy.yml is what created the
# collision risk, so it is checked here rather than left to review vigilance.
#
# DEFENSE IN DEPTH, NOT A GATE. The job that runs this suite ("Review scripts
# tests") is not among main's required contexts — those are `test`, `Lint` and
# `claude-review` — so a PR that reintroduces a colliding job goes red here and
# stays mergeable. This test makes the breakage visible and named; it does not
# stop it. Making it stop anything means adding this job to the required list.


def _load(path: Path) -> dict:
    """One workflow file, parsed by a real YAML loader.

    The rest of this module reads the workflow as TEXT on purpose — it asserts
    on step order and on verbatim shell, which a load discards. The two
    properties below are the opposite case: they ask what GitHub itself would
    see, and every way a hand-rolled pattern can be evaded (a job key indented
    differently, a quoted key, a flow mapping) is a way a colliding job passes
    the check while still registering as a second job. A parser is the only
    thing that closes that gap, so this suite is the one place the pipeline's
    test deps grow past the stdlib.
    """
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def _job_names(path: Path) -> list[str]:
    """Every name a job in this workflow can report under.

    Both the key and any job-level `name:` override matter: GitHub reports a
    job under its `name:` when one is set, and under its key otherwise — so a
    `name: claude-review` override on a differently-keyed job collides just as
    hard.
    """
    jobs = _load(path).get("jobs") or {}
    names: list[str] = []
    for key, body in jobs.items():
        names.append(str(key))
        if isinstance(body, dict) and body.get("name") is not None:
            names.append(str(body["name"]))
    return names


def _triggers(path: Path) -> list[str]:
    """The workflow's `on:` events, however the key spells them.

    YAML 1.1 reads a bare `on` as the boolean `True`, which is why the key is
    looked up both ways; `on:` also accepts a bare string and a list, not only
    the mapping this repo happens to write.
    """
    document = _load(path)
    events = document["on"] if "on" in document else document.get(True)
    if isinstance(events, str):
        return [events]
    if isinstance(events, list):
        return [str(event) for event in events]
    if isinstance(events, dict):
        return [str(event) for event in events]
    return []


def test_exactly_one_job_across_all_workflows_is_named_claude_review() -> None:
    # Both suffixes: GitHub runs `.yaml` workflows too, so globbing only `.yml`
    # would leave the same blind spot the parser just closed.
    workflows = sorted(
        path
        for suffix in ("*.yml", "*.yaml")
        for path in _WORKFLOWS_DIR.glob(suffix)
    )
    owners = [path for path in workflows if "claude-review" in _job_names(path)]
    assert owners == [_WORKFLOWS_DIR / "claude-code-review.yml"], (
        "exactly one job named `claude-review` may exist across .github/workflows "
        f"— the required check matches by job name; found: {[p.name for p in owners]}"
    )
    # The glob has to have looked at something: an empty or mis-rooted sweep
    # would satisfy an `owners ==` assertion just as happily if the one expected
    # file were the only thing it ever found.
    assert len(workflows) > 1, f"workflow sweep found only {workflows}"


def test_the_legacy_reviewer_keeps_a_distinct_job_name() -> None:
    names = _job_names(_WORKFLOWS_DIR / "claude-code-review-legacy.yml")
    assert "claude-review" not in names
    assert "claude-review-legacy" in names


def test_the_legacy_reviewer_stays_dispatch_only() -> None:
    # A PR trigger here would run two full model reviews per push — the cost
    # retiring it removed — and its job would report a second check besides.
    assert _triggers(_WORKFLOWS_DIR / "claude-code-review-legacy.yml") == [
        "workflow_dispatch"
    ]


# --- liveness wiring --------------------------------------------------------


def _review_job() -> dict:
    data = yaml.safe_load(read_workflow())
    return data["jobs"]["claude-review"]


def test_the_review_job_carries_an_outer_timeout() -> None:
    """Without one, a wedged session runs to GitHub's 6-hour cap while the
    author waits for a check that never reports."""
    assert _review_job()["timeout-minutes"] == 45


def test_the_specialist_set_is_declared_once_at_job_level() -> None:
    assert _review_job()["env"]["REVIEW_SPECIALISTS"] == "correctness,conventions"


def test_validate_reads_the_specialist_set_from_that_declaration() -> None:
    """The hook and the validator must agree about which lenses to expect. A
    second literal is how they silently drift apart."""
    body = run_block(read_workflow(), VALIDATE_STEP)
    assert "REVIEW_SPECIALISTS" in body
    assert "'correctness,conventions'" not in body


HOOK_PATH = _WORKFLOWS_DIR / "claude-review-v2" / "hooks" / "stop-hook.sh"

_HOOK_FALLBACK_RE = re.compile(
    r'^specialists="\$\{REVIEW_SPECIALISTS:-(?P<fallback>[^}]*)\}"\s*$',
    re.MULTILINE,
)


def _hook_specialist_fallback() -> str:
    text = HOOK_PATH.read_text(encoding="utf-8")
    match = _HOOK_FALLBACK_RE.search(text)
    assert match is not None, (
        f"{HOOK_PATH.name} no longer assigns "
        '`specialists="${REVIEW_SPECIALISTS:-<fallback>}"` — if the hook now '
        "learns its specialist set another way, retarget this test rather than "
        "deleting it: the drift it catches is silent"
    )
    return match.group("fallback")


def test_the_hook_fallback_matches_the_declared_specialist_set() -> None:
    """The hook's `:-` default is a second copy of the specialist set.

    It exists so the hook still holds a session open when the environment
    variable is absent, which means it is exercised precisely when nobody is
    watching. Add a third lens to `REVIEW_SPECIALISTS` and the stale fallback
    keeps waiting for two files: the hook stops holding once the two it knows
    about land, the third specialist is killed with the session, and the
    fallback's whole job — surviving a missing variable — is what makes the
    resulting gap invisible. Nothing else compares the two literals.
    """
    assert _hook_specialist_fallback() == _review_job()["env"]["REVIEW_SPECIALISTS"]
