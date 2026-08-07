"""Behavior tests for the workflow's post/enforce shell, run as shell.

The "Post review comment and enforce verdict" step is where the pipeline's
safety-shaped ordering lives (spec §3.5): the verdict gate runs BEFORE anything
is posted, the minimize sweep runs BEFORE the post so a run can never collapse
its own review, and the REJECT exit comes AFTER the post so a rejecting review
always reaches its author. Ordering that only holds by inspection is one edit
away from inverting, so these tests extract the step's `run:` block by NAME
(workflow_steps.py — a rename fails loudly) and execute it under bash with:

- a stub `gh` on PATH that records every invocation to a log the tests assert
  ORDER on, not just outcomes, and serves canned REST/GraphQL replies,
- the step's real env block (RUNNER_TEMP, GITHUB_WORKSPACE, REPO, PR_NUMBER,
  APP_LOGIN, HEAD_PATCH_ID, BASE_REF, GH_TOKEN),
- the repository root as CWD, so the REAL render_comment.py and the REAL jq
  selector run — the impostor cases below are about that selector.

`bash -e` matches how Actions invokes a `run:` block with no `shell:` key.
Fixture repos/authors use `acme` placeholders per repo convention.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from workflow_steps import read_workflow, run_block

POST_STEP = "Post review comment and enforce verdict"
SKIP_STEP = "Enforce re-asserted verdict (review skipped)"

REPO_ROOT = Path(__file__).resolve().parents[4]
REPO = "acme/acme-tools"
PR_NUMBER = "4242"
APP_LOGIN = "acme-claude-reviewer[bot]"
PATCH_ID = "deadbeef0123"
BASE_REF = "main"
SENTINEL = "<!-- claude-review-v2 -->"

# jq does the author+sentinel selection the impostor cases exercise, so a stub
# would test the stub. ubuntu-latest (where the review-scripts-tests job runs)
# ships jq; this only skips on a workstation without it.
pytestmark = pytest.mark.skipif(
    shutil.which("jq") is None, reason="the post step selects prior comments with jq"
)


# --- the stub `gh` ----------------------------------------------------------

STUB_GH = r'''#!/usr/bin/env python3
"""Stand-in for the `gh` CLI: records every call, serves canned replies.

One JSON object per call is appended to $GH_CALL_LOG in invocation order, which
is what lets the tests assert that every minimize precedes the post and that
nothing at all is called before the verdict gate. Failures are switched on per
case with GH_FAIL_LIST / GH_FAIL_MINIMIZE / GH_FAIL_POST.
"""
import json
import os
import sys


def record(entry):
    with open(os.environ["GH_CALL_LOG"], "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry) + "\n")


def flag(name):
    return os.environ.get(name) == "1"


def value_of(argv, prefix):
    for index, item in enumerate(argv):
        if item in ("-f", "-F") and index + 1 < len(argv):
            if argv[index + 1].startswith(prefix):
                return argv[index + 1][len(prefix):]
    return None


argv = sys.argv[1:]
entry = {"argv": argv}

if argv[:1] == ["api"] and "graphql" in argv:
    entry["kind"] = "minimize"
    entry["node_id"] = value_of(argv, "id=")
    entry["ok"] = not flag("GH_FAIL_MINIMIZE")
    record(entry)
    if not entry["ok"]:
        print("stub gh: minimizeComment refused", file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps({"data": {"minimizeComment": {"minimizedComment": {"isMinimized": True}}}}))
elif argv[:1] == ["api"] and "--method" in argv and "POST" in argv:
    entry["kind"] = "post"
    body_arg = value_of(argv, "body=@") or ""
    entry["body_file"] = body_arg
    if body_arg:
        with open(body_arg, encoding="utf-8") as handle:
            entry["body"] = handle.read()
    entry["ok"] = not flag("GH_FAIL_POST")
    record(entry)
    if not entry["ok"]:
        print("stub gh: POST refused", file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps({"id": 1}))
elif argv[:1] == ["api"] and "--paginate" in argv:
    entry["kind"] = "list"
    entry["ok"] = not flag("GH_FAIL_LIST")
    record(entry)
    if not entry["ok"]:
        print("stub gh: comment listing refused", file=sys.stderr)
        raise SystemExit(1)
    with open(os.environ["GH_COMMENTS_JSON"], encoding="utf-8") as handle:
        sys.stdout.write(handle.read())
else:
    entry["kind"] = "unexpected"
    record(entry)
    print(f"stub gh: unexpected invocation {argv}", file=sys.stderr)
    raise SystemExit(2)
'''


# --- fixtures ---------------------------------------------------------------


def _comment(node_id: str, login: str, body: str) -> dict:
    return {"id": abs(hash(node_id)) % 100000, "node_id": node_id, "user": {"login": login}, "body": body}


def _prior_review(node_id: str, patch_id: str, verdict: str) -> dict:
    body = "\n".join(
        [
            SENTINEL,
            f"<!-- last-reviewed-patch-id: {patch_id} -->",
            f"<!-- last-verdict: {verdict} -->",
            "",
            "✅ Looks good.",
        ]
    )
    return _comment(node_id, APP_LOGIN, body)


# Two genuine priors, and four comments that must survive the sweep: a human
# impersonating the sentinel, the App speaking about something else, the App
# quoting the sentinel mid-body (the selector is startswith, not contains), and
# a v1 review comment from another bot.
GENUINE_PRIOR_IDS = ["NODE_prior_1", "NODE_prior_2"]
IMPOSTOR_IDS = [
    "NODE_human_wearing_the_sentinel",
    "NODE_app_without_the_sentinel",
    "NODE_app_sentinel_mid_body",
    "NODE_v1_review",
]

DEFAULT_COMMENTS = [
    _prior_review("NODE_prior_1", "1111aaaa", "APPROVE"),
    _comment(
        "NODE_human_wearing_the_sentinel",
        "acme-contributor",
        f"{SENTINEL}\nI am not the reviewer App, but my comment starts like one.",
    ),
    _comment(
        "NODE_app_without_the_sentinel",
        APP_LOGIN,
        "The reviewer App said something that is not a v2 review.",
    ),
    _prior_review("NODE_prior_2", "2222bbbb", "REJECT"),
    _comment(
        "NODE_app_sentinel_mid_body",
        APP_LOGIN,
        f"Some preamble first.\n{SENTINEL}\nSo this body does not START with it.",
    ),
    _comment("NODE_v1_review", "acme-claude-v1[bot]", "<!-- claude-review-v1 -->\nv1 said fine."),
]


def _result(**overrides: object) -> dict:
    base: dict = {
        "findings": [],
        "disposition": [],
        "comment_body": "✅ Looks good.\n\nNothing to flag in this diff.",
    }
    base.update(overrides)
    return base


# --- runner -----------------------------------------------------------------


@dataclass
class StepRun:
    returncode: int
    stdout: str
    stderr: str
    calls: list[dict] = field(default_factory=list)

    @property
    def kinds(self) -> list[str]:
        return [call["kind"] for call in self.calls]

    @property
    def minimized_ids(self) -> list[str]:
        return [call["node_id"] for call in self.calls if call["kind"] == "minimize"]

    @property
    def posted_body(self) -> str | None:
        posts = [call for call in self.calls if call["kind"] == "post"]
        return posts[-1].get("body") if posts else None

    def annotations(self, level: str = "warning") -> list[str]:
        prefix = f"::{level}::"
        return [
            line[len(prefix) :]
            for line in self.stdout.splitlines()
            if line.startswith(prefix)
        ]


def _write_stub_gh(sandbox: Path) -> Path:
    bin_dir = sandbox / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    stub = bin_dir / "gh"
    stub.write_text(STUB_GH, encoding="utf-8")
    stub.chmod(0o755)
    return bin_dir


def _run_step(
    sandbox: Path,
    step_name: str,
    step_env: dict[str, str],
    source_transform: Callable[[str], str] | None = None,
) -> StepRun:
    """Extract `step_name`'s run block and execute it in the sandbox.

    `source_transform` rewrites the EXTRACTED COPY before it runs — the one
    test that uses it needs to reach a section the earlier sections normally
    stop it from reaching. Production shell is never modified.
    """
    body = run_block(read_workflow(), step_name)
    if source_transform is not None:
        body = source_transform(body)
    script = sandbox / "step.sh"
    script.write_text(body, encoding="utf-8")
    call_log = sandbox / "gh-calls.jsonl"
    call_log.touch()  # so "no gh calls at all" reads as an empty log, not a miss
    bin_dir = _write_stub_gh(sandbox)

    env = {
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "HOME": str(sandbox),
        "GH_CALL_LOG": str(call_log),
        **step_env,
    }
    # `bash -e` is how Actions runs a `run:` block that names no shell.
    completed = subprocess.run(
        ["bash", "-e", str(script)],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
    )
    calls = [
        json.loads(line)
        for line in call_log.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    return StepRun(completed.returncode, completed.stdout, completed.stderr, calls)


def run_post_step(
    sandbox: Path,
    *,
    verdict: str | None = "APPROVE",
    result: dict | None = None,
    comments: list[dict] | None = None,
    fail_list: bool = False,
    fail_minimize: bool = False,
    fail_post: bool = False,
    patch_id: str = PATCH_ID,
    source_transform: Callable[[str], str] | None = None,
) -> StepRun:
    """Run the post/enforce step over a sandboxed workspace.

    `verdict=None` writes no verdict.txt (the session died); `result=None`
    writes no review-result.json.
    """
    workspace = sandbox / "workspace"
    workspace.mkdir(parents=True, exist_ok=True)
    runner_temp = sandbox / "runner-temp"
    runner_temp.mkdir(parents=True, exist_ok=True)

    if verdict is not None:
        (workspace / "verdict.txt").write_text(f"{verdict}\n", encoding="utf-8")
    if result is not None:
        (workspace / "review-result.json").write_text(
            json.dumps(result, indent=2), encoding="utf-8"
        )
    comments_path = sandbox / "comments.json"
    comments_path.write_text(
        json.dumps(DEFAULT_COMMENTS if comments is None else comments), encoding="utf-8"
    )

    return _run_step(
        sandbox,
        POST_STEP,
        {
            "RUNNER_TEMP": str(runner_temp),
            "GITHUB_WORKSPACE": str(workspace),
            "GH_TOKEN": "stub-token",
            "REPO": REPO,
            "PR_NUMBER": PR_NUMBER,
            "APP_LOGIN": APP_LOGIN,
            "HEAD_PATCH_ID": patch_id,
            "BASE_REF": BASE_REF,
            "GH_COMMENTS_JSON": str(comments_path),
            "GH_FAIL_LIST": "1" if fail_list else "0",
            "GH_FAIL_MINIMIZE": "1" if fail_minimize else "0",
            "GH_FAIL_POST": "1" if fail_post else "0",
        },
        source_transform=source_transform,
    )


# --- the ordering the step exists to hold -----------------------------------


def test_every_minimize_precedes_the_post(tmp_path: Path) -> None:
    # THE invariant: the comment this run is about to create is not in the set
    # it minimized, so a run can never collapse its own review. Asserted on the
    # recorded call ORDER, not on the outcome.
    run = run_post_step(tmp_path, result=_result())
    assert run.kinds == ["list", "minimize", "minimize", "post"]
    post_at = run.kinds.index("post")
    assert all(
        index < post_at
        for index, kind in enumerate(run.kinds)
        if kind == "minimize"
    )


def test_nothing_is_called_before_the_verdict_gate(tmp_path: Path) -> None:
    # A run with no trustworthy verdict must not touch the PR at all — not even
    # the read that precedes the minimize sweep.
    run = run_post_step(tmp_path, verdict=None, result=_result())
    assert run.returncode == 1
    assert run.calls == []
    # The gate is what stopped it, not an unrelated early exit — otherwise this
    # assertion would pass vacuously on a script that died before doing
    # anything at all.
    assert any("recorded no verdict file" in line for line in run.annotations("error"))


# --- normal prose -----------------------------------------------------------


def test_normal_prose_posts_once_and_exits_zero(tmp_path: Path) -> None:
    prose = "✅ Looks good.\n\nNothing to flag in this diff."
    run = run_post_step(tmp_path, result=_result(comment_body=prose))
    assert run.returncode == 0
    assert run.kinds.count("post") == 1
    body = run.posted_body
    assert body is not None
    assert body.startswith(SENTINEL)
    assert f"<!-- last-reviewed-patch-id: {PATCH_ID} -->" in body
    assert "<!-- last-verdict: APPROVE -->" in body
    assert prose in body
    assert run.annotations() == []
    assert "Minimized 2 prior v2 review comment(s) as outdated." in run.stdout


def test_only_the_apps_own_sentinel_bearing_comments_are_minimized(
    tmp_path: Path,
) -> None:
    # The selector is authorship AND a body STARTING with the sentinel. A human
    # who opens a comment with the sentinel, the App speaking about anything
    # else, the App quoting the sentinel mid-body, and another bot's v1 review
    # all survive untouched — otherwise anyone could get the App to collapse
    # arbitrary comments, or a review OF this workflow could collapse itself.
    run = run_post_step(tmp_path, result=_result())
    assert run.returncode == 0
    assert run.minimized_ids == GENUINE_PRIOR_IDS
    for impostor in IMPOSTOR_IDS:
        assert impostor not in run.minimized_ids


def test_a_pr_with_no_prior_reviews_minimizes_nothing_and_still_posts(
    tmp_path: Path,
) -> None:
    run = run_post_step(tmp_path, result=_result(), comments=[])
    assert run.returncode == 0
    assert run.kinds == ["list", "post"]
    assert "Minimized 0 prior v2 review comment(s) as outdated." in run.stdout


# --- the verdict gate -------------------------------------------------------


def test_missing_verdict_file_fails_closed_with_nothing_posted(
    tmp_path: Path,
) -> None:
    run = run_post_step(tmp_path, verdict=None, result=_result())
    assert run.returncode == 1
    assert run.calls == []
    assert any("recorded no verdict file" in line for line in run.annotations("error"))


@pytest.mark.parametrize(
    "verdict", ["", "MAYBE", "approve", "APPROVED", "APPROVE REJECT", "REJECTED"]
)
def test_an_unrecognized_verdict_fails_closed_with_nothing_posted(
    tmp_path: Path, verdict: str
) -> None:
    # Exact match after whitespace stripping — never a substring or regex, so
    # review prose can never be misread as a verdict.
    run = run_post_step(tmp_path, verdict=verdict, result=_result())
    assert run.returncode == 1
    assert run.calls == []
    assert any(
        "did not contain exactly APPROVE or REJECT" in line
        for line in run.annotations("error")
    )


TOP_GATE_MARKER = "did not contain exactly APPROVE or REJECT"


def _neuter_the_top_verdict_gate(body: str) -> str:
    """Disarm section 1's `exit 1` in the extracted copy, and nothing else.

    Turns the `exit 1` that follows the top gate's `::error::` line into a
    no-op so execution carries an invalid verdict on into sections 2-5. Raises
    when the gate's shape has moved, so this stops silently transforming
    nothing the moment it stops matching.
    """
    lines = body.split("\n")
    for index, line in enumerate(lines):
        if TOP_GATE_MARKER not in line:
            continue
        follower = lines[index + 1]
        if follower.strip() != "exit 1 ;;":
            raise AssertionError(
                "the verdict gate's `exit 1` no longer follows its ::error:: "
                f"line; found {follower.strip()!r}"
            )
        indent = " " * (len(follower) - len(follower.lstrip(" ")))
        lines[index + 1] = f"{indent}: ;;"
        return "\n".join(lines)
    raise AssertionError(
        f"no verdict-gate line matching {TOP_GATE_MARKER!r} in the post step"
    )


def test_the_final_enforce_case_fails_closed_independently(tmp_path: Path) -> None:
    # Defense in depth for section 5's `case`. A POSIX `case` whose subject
    # matches no branch falls through at status 0, so an unrecognized verdict
    # arriving at the enforce block would satisfy the merge gate in silence.
    # Section 1's gate is what keeps that unreachable today — which is also why
    # the arm cannot be exercised from the outside. So this test NEUTERS THAT
    # GATE IN THE EXTRACTED COPY ONLY (the workflow's own shell is never
    # modified) and asserts section 5 still goes red on its own.
    #
    # Deliberately independent of the top gate: this must keep passing if that
    # gate is ever removed or reworked. It asserts the backstop, not the path.
    run = run_post_step(
        tmp_path,
        verdict="MAYBE",
        result=_result(),
        source_transform=_neuter_the_top_verdict_gate,
    )
    assert run.returncode == 1
    assert any(
        "Enforcement reached an unrecognized verdict ('MAYBE')" in line
        for line in run.annotations("error")
    )
    # Section 5 is what failed the job: the run got all the way through the
    # render/minimize/post sections, so it was not the neutered gate exiting.
    assert run.kinds.count("post") == 1


def test_reject_posts_the_review_and_only_then_exits_nonzero(
    tmp_path: Path,
) -> None:
    # Both halves matter: the author must receive the review that rejects them,
    # and the job must go red.
    prose = "🧌 Changes requested\n\n- `Sources/Acme/Widget.swift:42` — bad loop"
    run = run_post_step(
        tmp_path,
        verdict="REJECT",
        result=_result(
            comment_body=prose,
            findings=[
                {
                    "id": "correctness-1",
                    "file": "Sources/Acme/Widget.swift",
                    "line": 42,
                    "severity": "HIGH",
                    "title": "the retry loop never terminates",
                }
            ],
        ),
    )
    assert run.returncode == 1
    assert run.kinds == ["list", "minimize", "minimize", "post"]
    assert run.posted_body is not None
    assert prose in run.posted_body
    assert "<!-- last-verdict: REJECT -->" in run.posted_body
    assert any("requested changes" in line for line in run.annotations("error"))


# --- best-effort halves must not mask the verdict ---------------------------


def test_minimize_failure_warns_and_still_posts(tmp_path: Path) -> None:
    # A systemic cause (the App lost the permission) fails every comment, so
    # the first failure and the final count are both annotations while the
    # comments in between stay plain log lines.
    run = run_post_step(tmp_path, result=_result(), fail_minimize=True)
    assert run.returncode == 0
    assert run.kinds == ["list", "minimize", "minimize", "post"]
    warnings = run.annotations()
    assert any("Could not minimize prior v2 review comment" in line for line in warnings)
    assert any(
        "2 could not be minimized" in line and "Minimized 0" in line
        for line in warnings
    )
    # Two failures, but not two per-comment annotations.
    assert sum("Could not minimize prior" in line for line in warnings) == 1


def test_comment_listing_failure_warns_and_still_posts(tmp_path: Path) -> None:
    run = run_post_step(tmp_path, result=_result(), fail_list=True)
    assert run.returncode == 0
    assert run.kinds == ["list", "post"]
    assert any(
        "Could not fetch PR comments to minimize" in line for line in run.annotations()
    )


def test_post_failure_warns_without_masking_an_approve(tmp_path: Path) -> None:
    run = run_post_step(tmp_path, result=_result(), fail_post=True)
    assert run.returncode == 0
    assert any(
        "Could not post the v2 review comment" in line for line in run.annotations()
    )
    assert "Review comment posted: false" in run.stdout


def test_post_failure_does_not_swallow_a_reject(tmp_path: Path) -> None:
    run = run_post_step(
        tmp_path,
        verdict="REJECT",
        result=_result(comment_body="🧌 Changes requested"),
        fail_post=True,
    )
    assert run.returncode == 1
    assert any(
        "Could not post the v2 review comment" in line for line in run.annotations()
    )
    assert any("requested changes" in line for line in run.annotations("error"))


# --- degraded bodies still reach the PR -------------------------------------


def test_blank_comment_body_posts_the_findings_fallback(tmp_path: Path) -> None:
    # A REJECT is computed from severities independently of the prose, so a run
    # can reject with nothing written to explain it. The findings fallback is
    # what the author receives instead of bare markers.
    findings = [
        {
            "id": "correctness-1",
            "file": "Sources/Acme/Widget.swift",
            "line": 42,
            "severity": "HIGH",
            "title": "the retry loop never terminates",
        }
    ]
    run = run_post_step(
        tmp_path,
        verdict="REJECT",
        result=_result(comment_body="", findings=findings),
    )
    assert run.returncode == 1
    assert run.kinds.count("post") == 1
    body = run.posted_body
    assert body is not None
    assert body.startswith(SENTINEL)
    assert "the retry loop never terminates" in body
    assert any(
        "rendered in degraded form" in line and "1 finding(s)" in line
        for line in run.annotations()
    )


def test_missing_review_result_still_posts_the_verdict_markers(
    tmp_path: Path,
) -> None:
    run = run_post_step(tmp_path, verdict="APPROVE", result=None)
    assert run.returncode == 0
    body = run.posted_body
    assert body is not None
    assert body.startswith(SENTINEL)
    assert "<!-- last-verdict: APPROVE -->" in body
    assert any("rendered in degraded form" in line for line in run.annotations())


def test_model_prose_is_posted_verbatim_through_shell_metacharacters(
    tmp_path: Path,
) -> None:
    # Model-authored prose reaches `gh` only as -F body=@file, never through a
    # shell command — including when it quotes this workflow's own sentinel,
    # which a review OF this workflow does.
    prose = "\n".join(
        [
            "🧌 Changes requested",
            "",
            f"Quoting `{SENTINEL}` here must be inert.",
            "```sh",
            "printf '%s' \"$(rm -rf /; echo `whoami` && $USER | tee 'x')\" > $OUT",
            "```",
            r"Backslashes \n \t \\ and quotes \" ' ` $ * ? [] {} | & ; < > survive.",
        ]
    )
    run = run_post_step(
        tmp_path, verdict="REJECT", result=_result(comment_body=prose)
    )
    assert run.returncode == 1
    assert run.posted_body is not None
    assert prose in run.posted_body


# --- the skip path writes nothing to the PR ---------------------------------


def run_skip_step(sandbox: Path, verdict: str) -> StepRun:
    (sandbox / "workspace").mkdir(parents=True, exist_ok=True)
    (sandbox / "comments.json").write_text("[]", encoding="utf-8")
    return _run_step(
        sandbox,
        SKIP_STEP,
        {
            "VERDICT": verdict,
            "GH_COMMENTS_JSON": str(sandbox / "comments.json"),
        },
    )


@pytest.mark.parametrize(
    ("verdict", "expected_code"),
    [("APPROVE", 0), ("REJECT", 1), ("", 1), ("MAYBE", 1)],
)
def test_the_skip_path_re_asserts_the_verdict_and_touches_nothing(
    tmp_path: Path, verdict: str, expected_code: int
) -> None:
    # The prior review is still the current review of an unchanged diff, so the
    # skip path posts no comment and minimizes none (spec §3.5).
    run = run_skip_step(tmp_path, verdict)
    assert run.returncode == expected_code
    assert run.calls == []
