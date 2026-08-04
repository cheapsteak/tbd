"""Unit tests for render_comment.py — pure functions, hand-built fixtures.

No subprocess, no network: the renderer never touches either. Fixture
repos/authors use `acme` placeholders per repo convention.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from render_comment import (
    COMMENT_SENTINEL,
    SKIP_NOTE_SENTINEL,
    attribution_line,
    fallback_body,
    findings_of,
    load_result,
    main,
    marker_block,
    prose_of,
    render_review_body,
    render_skip_body,
    skip_note,
    strip_skip_notes,
)

REPO = "acme/acme-tools"
BASE_REF = "main"
PATCH_ID = "deadbeef0123"


def _finding(**overrides: object) -> dict:
    base = {
        "id": "correctness-1",
        "file": "Sources/Acme/Widget.swift",
        "line": 42,
        "severity": "HIGH",
        "title": "the retry loop never terminates",
    }
    base.update(overrides)
    return base


def _result(**overrides: object) -> dict:
    base: dict = {"findings": [], "disposition": [], "comment_body": ""}
    base.update(overrides)
    return base


def _render(result: dict | None, verdict: str = "REJECT") -> tuple[str, str | None]:
    return render_review_body(PATCH_ID, verdict, result, REPO, BASE_REF)


# --- structural invariants (every branch) -----------------------------------

_ALL_BRANCHES = {
    "normal prose": _result(comment_body="✅ Looks good.\n\nNothing to flag."),
    "blank prose with findings": _result(findings=[_finding()]),
    "blank prose without findings": _result(),
    "whitespace-only prose": _result(comment_body="   \n\t\n  "),
    "unreadable result": None,
}


@pytest.mark.parametrize("label", sorted(_ALL_BRANCHES))
def test_marker_lines_are_the_first_three_lines_in_order(label: str) -> None:
    body, _ = _render(_ALL_BRANCHES[label])
    lines = body.split("\n")
    assert lines[0] == COMMENT_SENTINEL
    assert lines[1] == f"<!-- last-reviewed-patch-id: {PATCH_ID} -->"
    assert lines[2] == "<!-- last-verdict: REJECT -->"


@pytest.mark.parametrize("label", sorted(_ALL_BRANCHES))
def test_attribution_is_always_the_last_line(label: str) -> None:
    body, _ = _render(_ALL_BRANCHES[label])
    assert body.split("\n")[-1] == attribution_line(REPO, BASE_REF)
    assert body.endswith("_")  # the attribution's own closing italic marker


@pytest.mark.parametrize("label", sorted(_ALL_BRANCHES))
def test_sections_are_separated_by_exactly_one_blank_line(label: str) -> None:
    # Spacing is the renderer's to own, in every branch: a body whose prose
    # section is absent must not leave the markers' separator and the
    # attribution's own leading blank stacked into a double gap.
    body, _ = _render(_ALL_BRANCHES[label])
    assert "\n\n\n" not in body


@pytest.mark.parametrize("label", sorted(_ALL_BRANCHES))
def test_body_starts_with_the_upsert_sentinel(label: str) -> None:
    # The workflow's upsert matches on startswith(COMMENT_SENTINEL).
    body, _ = _render(_ALL_BRANCHES[label])
    assert body.startswith(COMMENT_SENTINEL)


# --- normal prose -----------------------------------------------------------


def test_normal_prose_is_the_whole_middle_section() -> None:
    prose = "🧌 Changes requested\n\n- `Sources/Acme/Widget.swift:42` — bad loop"
    body, warning = _render(_result(comment_body=prose, findings=[_finding()]))
    assert warning is None
    assert body == "\n".join(
        [
            marker_block(PATCH_ID, "REJECT"),
            "",
            prose,
            "",
            attribution_line(REPO, BASE_REF),
        ]
    )


def test_normal_prose_wins_over_findings_rendering() -> None:
    body, warning = _render(_result(comment_body="✅ Looks good.", findings=[_finding()]))
    assert warning is None
    assert "rendered from `review-result.json`" not in body
    assert "the retry loop never terminates" not in body


def test_prose_round_trips_verbatim_through_metacharacters_and_sentinels() -> None:
    # The prose is model-authored and is never interpolated into a shell, never
    # pattern-matched, and never rewritten — including when it quotes this
    # workflow's own sentinels (a review OF this workflow does exactly that).
    prose = "\n".join(
        [
            "🧌 Changes requested",
            "",
            "The skip step must not strip by prose. Today it matches lines like",
            "> ⏭️ Review skipped — which is ordinary prose here.",
            "",
            "It should key on `" + SKIP_NOTE_SENTINEL + "` instead, not on",
            "`" + COMMENT_SENTINEL + "` either.",
            "",
            "```sh",
            "printf '%s' \"$(rm -rf /; echo `whoami` && $USER | tee 'x')\" > $OUT",
            "```",
            "",
            r"Backslashes \n \t \\ and quotes \" ' ` $ * ? [] {} | & ; < > survive.",
        ]
    )
    body, warning = _render(_result(comment_body=prose))
    assert warning is None
    assert prose in body
    # And it is bounded by exactly the markers above and the attribution below.
    assert body.index(prose) == len(marker_block(PATCH_ID, "REJECT")) + 2


# --- blank prose + findings (the fallback synthesis) ------------------------


def test_blank_prose_with_findings_renders_a_labelled_fallback() -> None:
    findings = [
        _finding(),
        _finding(
            id="conventions-1",
            file="docs/specs/2026-01-01-acme-design.md",
            line=None,
            severity="MEDIUM",
            title="spec is not referenced",
            body="The PR adds a flag with no spec.\nSee CLAUDE.md.",
        ),
    ]
    body, warning = _render(_result(findings=findings))
    assert warning is not None and "2 finding(s)" in warning
    # A lead line saying the prose was unavailable and this is machine-rendered.
    assert "no review prose" in body
    assert "rendered from `review-result.json`" in body
    assert "Computed verdict: **REJECT**." in body
    # One bullet per finding: severity, location, title, description.
    assert (
        "- **HIGH** — `Sources/Acme/Widget.swift:42` — the retry loop never terminates"
        in body
    )
    assert (
        "- **MEDIUM** — `docs/specs/2026-01-01-acme-design.md` — spec is not referenced"
        in body
    )
    assert "  The PR adds a flag with no spec.\n  See CLAUDE.md." in body


def test_fallback_omits_line_when_absent_and_survives_missing_fields() -> None:
    bullet = fallback_body([{"severity": "MINOR", "title": "nit"}], "APPROVE")
    assert "- **MINOR** — nit" in bullet
    assert fallback_body([{}], "APPROVE").splitlines()[-1] == (
        "- **UNKNOWN** — (no title recorded)"
    )


def test_fallback_ignores_non_object_findings_entries() -> None:
    body, warning = _render(_result(findings=[_finding(), "not-a-finding", 7]))
    assert warning is not None and "1 finding(s)" in warning
    assert "the retry loop never terminates" in body


def test_whitespace_only_prose_is_treated_as_blank() -> None:
    body, warning = _render(_result(comment_body=" \n\t\n ", findings=[_finding()]))
    assert warning is not None
    assert "the retry loop never terminates" in body


def test_non_string_comment_body_is_treated_as_blank() -> None:
    body, warning = _render(_result(comment_body=None, findings=[_finding()]))
    assert warning is not None
    assert "the retry loop never terminates" in body


# --- blank prose + no findings ----------------------------------------------


def test_blank_prose_without_findings_keeps_markers_plus_a_note() -> None:
    body, warning = _render(_result(), verdict="APPROVE")
    assert warning is not None and "no findings" in warning
    assert "no review prose and recorded no findings" in body
    assert "Computed verdict: **APPROVE**." in body
    assert body.split("\n") == [
        COMMENT_SENTINEL,
        f"<!-- last-reviewed-patch-id: {PATCH_ID} -->",
        "<!-- last-verdict: APPROVE -->",
        "",
        "_This run produced no review prose and recorded no findings. "
        "Computed verdict: **APPROVE**._",
        "",
        attribution_line(REPO, BASE_REF),
    ]


# --- unreadable result ------------------------------------------------------


def test_missing_result_file_degrades_with_a_warning(tmp_path: Path) -> None:
    result, warning = load_result(str(tmp_path / "nope.json"))
    assert result is None
    assert warning is not None and "could not read" in warning
    body, _ = _render(None)
    assert "could not be read" in body
    assert body.startswith(COMMENT_SENTINEL)


def test_malformed_result_file_degrades_with_a_warning(tmp_path: Path) -> None:
    path = tmp_path / "review-result.json"
    path.write_text("{not json at all", encoding="utf-8")
    result, warning = load_result(str(path))
    assert result is None
    assert warning is not None and "not valid JSON" in warning


def test_non_object_result_file_degrades_with_a_warning(tmp_path: Path) -> None:
    path = tmp_path / "review-result.json"
    path.write_text("[1, 2, 3]", encoding="utf-8")
    result, warning = load_result(str(path))
    assert result is None
    assert warning is not None and "not a JSON object" in warning


def test_prose_and_findings_accessors_tolerate_junk() -> None:
    assert prose_of(None) == ""
    assert prose_of({"comment_body": 7}) == ""
    assert findings_of(None) == []
    assert findings_of({"findings": "nope"}) == []


# --- skip note --------------------------------------------------------------


def _review_body(prose: str) -> str:
    body, _ = render_review_body(PATCH_ID, "REJECT", _result(comment_body=prose), REPO, BASE_REF)
    return body


def test_skip_note_carries_the_provenance_sentinel() -> None:
    assert SKIP_NOTE_SENTINEL in skip_note("APPROVE")


def test_skip_appends_the_note_and_keeps_markers_and_prose() -> None:
    prior = _review_body("🧌 Changes requested\n\n- fix the loop")
    body, warning = render_skip_body(prior, PATCH_ID, "REJECT", REPO, BASE_REF)
    assert warning is None
    assert body.split("\n")[:3] == prior.split("\n")[:3]
    assert "🧌 Changes requested" in body
    assert "- fix the loop" in body
    assert body.split("\n")[-1] == skip_note("REJECT")
    assert "\n\n\n" not in body


def test_repeated_skips_do_not_accumulate_notes_or_blank_lines() -> None:
    body = _review_body("✅ Looks good.")
    once, _ = render_skip_body(body, PATCH_ID, "APPROVE", REPO, BASE_REF)
    twice, _ = render_skip_body(once, PATCH_ID, "APPROVE", REPO, BASE_REF)
    thrice, _ = render_skip_body(twice, PATCH_ID, "APPROVE", REPO, BASE_REF)
    assert twice == once
    assert thrice == once
    assert once.count(SKIP_NOTE_SENTINEL) == 1


def test_prose_line_that_starts_with_the_old_skip_prefix_survives_a_skip() -> None:
    # The bug this sentinel exists to fix: the old strip matched prose by text
    # prefix, so a review DISCUSSING this workflow lost the quoted line.
    prose = "\n".join(
        [
            "🧌 Changes requested",
            "",
            "The skip step strips prior notes by matching lines like",
            "> ⏭️ Review skipped — diff unchanged since the last review.",
            "That is prose, not state.",
        ]
    )
    prior = _review_body(prose)
    body, _ = render_skip_body(prior, PATCH_ID, "REJECT", REPO, BASE_REF)
    assert prose in body
    assert body.count("> ⏭️ Review skipped") == 2  # the quoted line + the note
    # And a second skip still leaves the quoted prose line alone.
    again, _ = render_skip_body(body, PATCH_ID, "REJECT", REPO, BASE_REF)
    assert again == body


def test_legacy_trailing_skip_note_without_a_sentinel_is_replaced() -> None:
    # Comments written before the sentinel existed end with a bare note line.
    prior = _review_body("✅ Looks good.") + (
        "\n\n> ⏭️ Review skipped — diff unchanged since the last review "
        "(patch-id match). Re-asserting the recorded verdict: APPROVE."
    )
    body, _ = render_skip_body(prior, PATCH_ID, "APPROVE", REPO, BASE_REF)
    assert body.count("> ⏭️ Review skipped") == 1
    assert body.split("\n")[-1] == skip_note("APPROVE")


def test_strip_skip_notes_stops_at_the_first_non_note_trailing_line() -> None:
    body = "line one\n> ⏭️ Review skipped — quoted\nline three\n\n"
    assert strip_skip_notes(body) == "line one\n> ⏭️ Review skipped — quoted\nline three"


def test_skip_without_a_prior_comment_renders_a_fresh_body() -> None:
    body, warning = render_skip_body("", PATCH_ID, "APPROVE", REPO, BASE_REF)
    assert warning is not None and "no prior v2 comment" in warning
    assert body.split("\n") == [
        COMMENT_SENTINEL,
        f"<!-- last-reviewed-patch-id: {PATCH_ID} -->",
        "<!-- last-verdict: APPROVE -->",
        "",
        attribution_line(REPO, BASE_REF),
        "",
        skip_note("APPROVE", prior_comment_found=False),
    ]
    assert "could not be found to update" in body


def test_skip_with_a_foreign_prior_body_rebuilds_rather_than_appending() -> None:
    # Defensive: the workflow selects by sentinel, so this should be
    # unreachable — but appending our state markers' meaning to someone else's
    # comment would be worse than rebuilding our own.
    body, warning = render_skip_body(
        "somebody else's comment", PATCH_ID, "APPROVE", REPO, BASE_REF
    )
    assert warning is not None
    assert body.startswith(COMMENT_SENTINEL)
    assert "somebody else's comment" not in body


# --- main() (the I/O shell) -------------------------------------------------


def _run_main(
    monkeypatch: pytest.MonkeyPatch, argv: list[str]
) -> int:
    monkeypatch.setattr(sys, "argv", ["render_comment.py", *argv])
    return main()


def test_main_review_mode_prints_the_body_and_warns_on_stderr(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    path = tmp_path / "review-result.json"
    path.write_text(
        json.dumps(_result(comment_body="✅ Looks good.")), encoding="utf-8"
    )
    exit_code = _run_main(
        monkeypatch,
        [
            "review",
            "--patch-id", PATCH_ID,
            "--verdict", "APPROVE",
            "--repo", REPO,
            "--base-ref", BASE_REF,
            "--result-file", str(path),
        ],
    )
    captured = capsys.readouterr()
    assert exit_code == 0
    assert captured.out.startswith(COMMENT_SENTINEL)
    assert "✅ Looks good." in captured.out
    assert captured.err == ""


def test_main_review_mode_never_fails_on_a_missing_file(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    exit_code = _run_main(
        monkeypatch,
        [
            "review",
            "--patch-id", PATCH_ID,
            "--verdict", "REJECT",
            "--repo", REPO,
            "--base-ref", BASE_REF,
            "--result-file", str(tmp_path / "absent.json"),
        ],
    )
    captured = capsys.readouterr()
    assert exit_code == 0
    assert captured.out.startswith(COMMENT_SENTINEL)
    assert "<!-- last-verdict: REJECT -->" in captured.out
    assert "could not read" in captured.err


def test_main_skip_mode_round_trips_a_prior_body(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    prior = tmp_path / "prior-body.txt"
    prior.write_text(_review_body("✅ Looks good."), encoding="utf-8")
    exit_code = _run_main(
        monkeypatch,
        [
            "skip-note",
            "--patch-id", PATCH_ID,
            "--verdict", "APPROVE",
            "--repo", REPO,
            "--base-ref", BASE_REF,
            "--prior-body-file", str(prior),
        ],
    )
    captured = capsys.readouterr()
    assert exit_code == 0
    assert "✅ Looks good." in captured.out
    assert captured.out.rstrip("\n").split("\n")[-1] == skip_note("APPROVE")
    assert captured.err == ""


def test_main_skip_mode_tolerates_an_absent_prior_body_file(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    exit_code = _run_main(
        monkeypatch,
        [
            "skip-note",
            "--patch-id", PATCH_ID,
            "--verdict", "APPROVE",
            "--repo", REPO,
            "--base-ref", BASE_REF,
            "--prior-body-file", str(tmp_path / "absent.txt"),
        ],
    )
    captured = capsys.readouterr()
    assert exit_code == 0
    assert captured.out.startswith(COMMENT_SENTINEL)
    assert "no prior v2 comment" in captured.err
