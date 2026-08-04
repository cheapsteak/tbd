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

from workflow_steps import read_workflow, run_block, step_index, step_source

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
