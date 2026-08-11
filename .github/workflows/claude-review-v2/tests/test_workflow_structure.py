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

import os
import re
import subprocess
from pathlib import Path

import yaml

from validate import STALL_REPORT
from workflow_steps import (
    _WORKFLOWS_DIR,
    read_workflow,
    run_block,
    step_index,
    step_source,
)

ENSURE_MERGE_BASE_STEP = "Ensure a merge-base with the base branch"
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


# --- the merge base: repaired, pinned, and never re-derived from a ref ------
#
# Two measured ways `origin/<base>` stops having a merge base with HEAD: a fork
# PR's checkout is shallow even under `fetch-depth: 0` (PR #545), and the review
# action's own session setup re-fetches the base branch at limited depth AFTER
# every workflow guard, grafting the ref whenever the base advanced since
# checkout (PR #614, runs 31497107005 and 31504414058). The first is repairable
# here; the second is not repairable here at all, which is why the session gets
# a pinned SHA instead of a ref name. A diff against a MOVED base reports other
# merged PRs' changes as if this PR reverted them — a confident, plausible,
# entirely wrong review — so these are assertions about the gate's correctness,
# not its tidiness.


def test_the_ensure_step_repairs_at_full_depth_then_fails_closed() -> None:
    body = run_block(read_workflow(), ENSURE_MERGE_BASE_STEP)
    # One repair attempt: an explicit fetch of the base branch that actually
    # deepens. A plain fetch into a STILL-shallow repo stops at the shallow
    # boundary and adds no ancestry, so the repair needs both variants: an
    # --unshallow fetch when a boundary exists, and a plain full fetch when the
    # repo is complete but the ref is wrong.
    assert (
        'git fetch --no-tags --unshallow origin "+refs/heads/$BASE_REF:refs/remotes/origin/$BASE_REF"'
        in body
    )
    assert (
        'git fetch --no-tags origin "+refs/heads/$BASE_REF:refs/remotes/origin/$BASE_REF"'
        in body
    )
    # And a hard stop if that did not help. A warning here is what let a run
    # proceed to review a diff it could not compute.
    assert "::error::" in body
    assert "exit 1" in body
    assert "::warning::" not in body


def test_the_ensure_step_error_is_named_infrastructure_not_a_verdict() -> None:
    # A red required check that says nothing sends the author looking for a
    # defect in their own diff.
    body = run_block(read_workflow(), ENSURE_MERGE_BASE_STEP)
    error_lines = [line for line in body.splitlines() if "::error::" in line]
    assert len(error_lines) == 1
    assert "infrastructure error" in error_lines[0]
    assert "NOT a verdict" in error_lines[0]


def test_the_prepare_step_exports_the_pinned_merge_base() -> None:
    body = run_block(read_workflow(), PREPARE_STEP)
    assert "echo \"merge_base=$(jq -r '.merge_base // \"\"' skip-decision.json)\"" in body


def test_the_prompt_pins_the_merge_base_instead_of_naming_the_base_ref() -> None:
    """The discriminating structural assertion.

    `git diff origin/<base>...HEAD` is exactly the instruction that failed
    inside the session once the ref was grafted, and the model's improvised
    two-dot fallback is what produced the fabricated "partial revert" findings.
    The instruction must therefore be a SHA the prepare step resolved before the
    damage — a SHA-addressed diff walks no ancestry and cannot be corrupted by
    a graft.
    """
    prompt = step_source(read_workflow(), SESSION_STEP)
    pinned = "git diff ${{ steps.prepare.outputs.merge_base }} HEAD"
    by_ref = "git diff origin/${{ github.event.pull_request.base.ref }}...HEAD"

    assert by_ref not in prompt
    # `git diff origin/…` in ANY form: the two-dot fallback was the harmful one.
    assert "git diff origin/" not in prompt

    # Present in BOTH instruction positions: the orchestrator's own ENVIRONMENT
    # briefing, and the text it must hand each specialist. A specialist told to
    # diff by ref name reproduces the failure one level down, where the
    # orchestrator never sees it.
    environment, _, fanout = prompt.partition("STEP 1 — FAN OUT")
    assert fanout, "the fan-out prompt no longer contains a `STEP 1 — FAN OUT` section"
    assert pinned in environment
    assert pinned in fanout

    # And the prohibition is stated, not merely implied by omission.
    assert "NEVER compute the diff against" in environment
    assert "never diff against" in fanout.lower()


def test_the_prompt_tells_the_session_what_an_empty_context_file_means() -> None:
    # discussion-context.txt now leads with the PR description, so an empty file
    # means the fetch FAILED. Read as "no description exists", it would silently
    # gut the correctness lens's premise audit.
    prompt = step_source(read_workflow(), SESSION_STEP)
    assert "EMPTY file means the fetch FAILED" in prompt
    assert "title and description" in prompt


def test_the_specialist_handoff_carries_the_context_file() -> None:
    # The measured #614 failure was the orchestrator telling both specialists no
    # PR description was available. An orchestrator that composes specialist
    # prompts from the STEP 1 checklist alone reproduces that exactly, so the
    # checklist itself — not just the earlier context paragraph — must name the
    # file.
    prompt = step_source(read_workflow(), SESSION_STEP)
    _, _, fanout = prompt.partition("STEP 1 — FAN OUT")
    assert fanout, "the fan-out prompt no longer contains a `STEP 1 — FAN OUT` section"
    assert "discussion-context.txt" in fanout


def test_the_description_cannot_clear_findings() -> None:
    # The description is rewritable at any moment — including after a REJECT —
    # so the clearing power STEP 2 grants to discussion must exclude it, or an
    # author edits their way past a finding without changing a line of code.
    # The rule must reach every reader: the orchestrator's context paragraph,
    # the STEP 1 checklist the specialists are composed from, and STEP 2 where
    # the merge happens.
    prompt = step_source(read_workflow(), SESSION_STEP)
    assert "NEVER clear, downgrade, or pre-empt a finding" in prompt
    _, _, fanout = prompt.partition("STEP 1 — FAN OUT")
    assert fanout, "the fan-out prompt no longer contains a `STEP 1 — FAN OUT` section"
    assert "clear, downgrade, or pre-empt a finding" in fanout
    _, _, merge_section = prompt.partition("STEP 2 — MERGE")
    assert merge_section, "the prompt no longer contains a `STEP 2 — MERGE` section"
    assert "never downgrades or drops a finding" in merge_section


def test_a_failed_pinned_diff_has_a_verdict_visible_channel() -> None:
    # "Report it in the diagnostics section" routes the failure into collapsed
    # prose no script reads: the session then submits empty findings, and
    # validate.py computes empty findings as APPROVE — an unreviewed PR goes
    # green on the required check. The prompt must instead route the failure to
    # the infrastructure_failure key that validate.py fails closed on, and the
    # specialists must escalate rather than silently review something else.
    prompt = step_source(read_workflow(), SESSION_STEP)
    environment, _, fanout = prompt.partition("STEP 1 — FAN OUT")
    assert '{"infrastructure_failure":' in environment
    assert "empty findings array computes as APPROVE" in environment
    assert "state the failure prominently in your returned summary" in fanout


def test_the_prompt_teaches_graft_detection_for_history_checks() -> None:
    # A graft on HEAD's own ancestry (PR up to date with its base) makes
    # `git blame`/`git log <path>` stop at the boundary SILENTLY — the same
    # confident-wrong-answer class as the diff, aimed at the premise audit.
    # `cat .git/shallow` is the deterministic detector, and Bash(cat:*) is
    # already in the session's allowedTools. Like the pinned-diff rule, it must
    # appear in BOTH instruction positions: the specialists hold git log/blame
    # and run the premise audit one level down, where the orchestrator cannot
    # see a wrong conclusion form.
    prompt = step_source(read_workflow(), SESSION_STEP)
    environment, _, fanout = prompt.partition("STEP 1 — FAN OUT")
    assert fanout, "the fan-out prompt no longer contains a `STEP 1 — FAN OUT` section"
    assert "cat .git/shallow" in environment
    assert "cat .git/shallow" in fanout
    assert "WITH FULL GIT HISTORY (all branches)" not in prompt


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
    r'^\s*specialists="\$\{REVIEW_SPECIALISTS:-(?P<fallback>[^}]*)\}"\s*$',
    re.MULTILINE,
)


def _hook_specialist_fallback() -> str:
    """The hook's default specialist set — and there must be only one of it.

    The hook takes this default twice (once for an unset variable, once for a
    non-empty value that names nobody), so every occurrence is checked and they
    must agree: a second literal updated on its own is the same silent drift
    this test exists to catch.
    """
    text = HOOK_PATH.read_text(encoding="utf-8")
    fallbacks = _HOOK_FALLBACK_RE.findall(text)
    assert fallbacks, (
        f"{HOOK_PATH.name} no longer assigns "
        '`specialists="${REVIEW_SPECIALISTS:-<fallback>}"` — if the hook now '
        "learns its specialist set another way, retarget this test rather than "
        "deleting it: the drift it catches is silent"
    )
    assert len(set(fallbacks)) == 1, (
        f"{HOOK_PATH.name} spells its specialist fallback more than one way: "
        f"{sorted(set(fallbacks))}"
    )
    return fallbacks[0]


_PROMPT_FINDINGS_RE = re.compile(r"findings-(?P<name>[a-z][a-z0-9_-]*)\.json")


def test_the_session_prompt_expects_exactly_the_declared_specialist_set() -> None:
    """A FOURTH copy of the specialist set lives in the fan-out prompt.

    STEP 1 names `findings-correctness.json` and `findings-conventions.json`
    literally, as the orchestrator's stopping condition. Add a lens to
    `REVIEW_SPECIALISTS` and the orchestrator waits for two files while the
    hook waits for three — it merges and stops the moment its two land, and the
    third specialist dies with the session. Nothing else compares these
    literals to the declaration. (`findings-<name>.json`, the template spelling,
    carries no lens name and is deliberately not matched.)
    """
    names = set(_PROMPT_FINDINGS_RE.findall(step_source(read_workflow(), SESSION_STEP)))
    assert names, "the fan-out prompt names no findings-<lens>.json file at all"
    declared = set(_review_job()["env"]["REVIEW_SPECIALISTS"].split(","))
    assert names == declared


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


# --- the validate step's annotation names the cause -------------------------

# The rest of this module reads the workflow; these two cases RUN one step of
# it. A stall, a partial fan-out, a schema rejection and a broken invocation all
# surface as one red `claude-review`, and the checks page shows an operator the
# step annotation and nothing else — so whether the annotation distinguishes
# them is behavior, and behavior that only holds by inspection is one edit from
# inverting. validate.py is stubbed here on purpose: what is under test is the
# shell that carries its stderr into the annotation, not the validator (which
# test_validate.py covers directly).

STUB_PYTHON3 = """#!/bin/sh
printf '%s\\n' "$STUB_STDERR" >&2
exit "$STUB_STATUS"
"""


def _run_validate_step(
    tmp_path: Path, stderr_text: str, status: int
) -> subprocess.CompletedProcess[str]:
    bindir = tmp_path / "bin"
    bindir.mkdir(parents=True, exist_ok=True)
    stub = bindir / "python3"
    stub.write_text(STUB_PYTHON3, encoding="utf-8")
    stub.chmod(0o755)
    script = tmp_path / "step.sh"
    script.write_text(run_block(read_workflow(), VALIDATE_STEP), encoding="utf-8")
    return subprocess.run(
        # `bash -e` is how Actions runs a `run:` block that names no shell.
        ["bash", "-e", str(script)],
        cwd=tmp_path,
        env={
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "REVIEW_SPECIALISTS": "correctness,conventions",
            "STUB_STDERR": stderr_text,
            "STUB_STATUS": str(status),
        },
        capture_output=True,
        text=True,
    )


def _annotations(proc: subprocess.CompletedProcess[str]) -> list[str]:
    return [
        line[len("::error::") :]
        for line in proc.stdout.splitlines()
        if line.startswith("::error::")
    ]


def test_a_stall_and_a_rejected_diff_annotate_differently(tmp_path: Path) -> None:
    """The discriminating case: one generic sentence for every failure is what
    trains a maintainer to re-run a red required check without reading it."""
    stall = _run_validate_step(tmp_path / "a", f"error: {STALL_REPORT}", 1)
    schema = _run_validate_step(
        tmp_path / "b",
        "error: review-result.json: schema validation failed: at <root>: "
        "'disposition' is a required property",
        1,
    )
    for proc in (stall, schema):
        assert proc.returncode == 1
        assert len(_annotations(proc)) == 1
    assert "INFRASTRUCTURE" in _annotations(stall)[0]
    assert "schema validation failed" in _annotations(schema)[0]
    assert _annotations(stall) != _annotations(schema)


def test_the_last_error_line_is_the_one_annotated(tmp_path: Path) -> None:
    """validate.py prints from general to specific, and non-`error:` lines in
    between must not be mistaken for the cause."""
    proc = _run_validate_step(
        tmp_path,
        "error: no specialist findings files match 'findings-*.json'\n"
        "warning: something incidental\n"
        "error: the decisive last line",
        1,
    )
    assert _annotations(proc) == [
        "Claude review produced no valid result (missing/invalid findings or "
        "result file, or uncovered dispositions) — failing closed. Re-run the "
        "review. Cause: the decisive last line"
    ]


def test_the_step_replays_validate_stderr_into_the_log(tmp_path: Path) -> None:
    proc = _run_validate_step(tmp_path, "error: the decisive last line", 1)
    assert "error: the decisive last line" in proc.stderr


def test_a_failure_with_no_error_line_still_fails_closed(tmp_path: Path) -> None:
    """A crash or a traceback carries no `error:` line; the exit code and the
    annotation are not allowed to depend on finding one."""
    proc = _run_validate_step(tmp_path, "Traceback (most recent call last):", 1)
    assert proc.returncode == 1
    assert len(_annotations(proc)) == 1
    assert "Cause:" not in _annotations(proc)[0]


def test_a_passing_validate_annotates_nothing_and_succeeds(tmp_path: Path) -> None:
    proc = _run_validate_step(tmp_path, "", 0)
    assert proc.returncode == 0
    assert _annotations(proc) == []
