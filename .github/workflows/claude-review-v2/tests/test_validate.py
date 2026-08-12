"""Unit tests for validate.py — pure functions plus schema validation on
hand-built tmp_path fixtures. No subprocess, no network."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

import validate
from validate import (
    SchemaValidationError,
    check_disposition,
    main,
    missing_specialist_report,
    missing_specialists,
    parse_expected_specialists,
    specialist_name_from_path,
    validate_findings_file,
    validate_result_file,
    verdict_from_findings,
)

# --- verdict_from_findings --------------------------------------------------


def _finding(**overrides: object) -> dict:
    base = {
        "id": "correctness-1",
        "file": "Sources/Example.swift",
        "severity": "MINOR",
        "title": "example finding",
    }
    base.update(overrides)
    return base


def test_verdict_high_rejects() -> None:
    assert verdict_from_findings([_finding(severity="HIGH")]) == "REJECT"


def test_verdict_medium_rejects() -> None:
    assert verdict_from_findings([_finding(severity="MEDIUM")]) == "REJECT"


def test_verdict_only_minor_approves() -> None:
    findings = [
        _finding(id="a-1", severity="MINOR"),
        _finding(id="a-2", severity="MINOR"),
    ]
    assert verdict_from_findings(findings) == "APPROVE"


def test_verdict_empty_approves() -> None:
    assert verdict_from_findings([]) == "APPROVE"


def test_verdict_mixed_rejects() -> None:
    findings = [_finding(severity="MINOR"), _finding(id="b-1", severity="HIGH")]
    assert verdict_from_findings(findings) == "REJECT"


@pytest.mark.parametrize("severity", ["high", "CRITICAL", "", None])
def test_verdict_unknown_severity_raises_never_approves(
    severity: str | None,
) -> None:
    # "Can't read the severity" must never be mapped to APPROVE.
    with pytest.raises(ValueError, match="unknown severity"):
        verdict_from_findings([_finding(severity=severity)])


def test_verdict_case_sensitive_lowercase_high_raises() -> None:
    with pytest.raises(ValueError):
        verdict_from_findings([_finding(severity="High")])


# --- check_disposition ------------------------------------------------------


def _entry(finding_id: str, action: str = "kept") -> dict:
    return {"id": finding_id, "action": action}


def test_disposition_full_coverage() -> None:
    ids = ["correctness-1", "concurrency-1", "conventions-1"]
    disposition = [_entry(finding_id) for finding_id in ids]
    assert check_disposition(ids, disposition) == []


def test_disposition_missing_one() -> None:
    ids = ["correctness-1", "concurrency-1", "conventions-1"]
    disposition = [_entry("correctness-1"), _entry("conventions-1")]
    assert check_disposition(ids, disposition) == ["concurrency-1"]


def test_disposition_empty_with_findings_present() -> None:
    ids = ["correctness-1", "concurrency-1"]
    assert check_disposition(ids, []) == ids


def test_disposition_empty_both_sides() -> None:
    assert check_disposition([], []) == []


def test_disposition_extra_entries_are_not_flagged() -> None:
    # Coverage check only: a disposition entry for a finding we don't know
    # about is not this function's business.
    assert check_disposition(["a-1"], [_entry("a-1"), _entry("ghost-9")]) == []


# --- missing_specialists ----------------------------------------------------


def test_missing_specialists_all_present() -> None:
    expected = ["correctness", "conventions"]
    assert missing_specialists(expected, expected) == []


def test_missing_specialists_one_missing() -> None:
    expected = ["correctness", "conventions"]
    seen = ["correctness"]
    assert missing_specialists(expected, seen) == ["conventions"]


def test_missing_specialists_two_missing_in_expected_order() -> None:
    expected = ["correctness", "conventions", "acme-lens"]
    assert missing_specialists(expected, ["conventions"]) == [
        "correctness",
        "acme-lens",
    ]


def test_missing_specialists_all_missing() -> None:
    expected = ["correctness", "conventions"]
    assert missing_specialists(expected, []) == expected


def test_missing_specialists_duplicates_in_seen_are_fine() -> None:
    # Two findings files for the same specialist is last-write-wins upstream,
    # not a completeness failure.
    expected = ["correctness", "conventions"]
    seen = ["correctness", "correctness", "conventions"]
    assert missing_specialists(expected, seen) == []


def test_missing_specialists_unexpected_seen_is_ignored() -> None:
    # An extra specialist never expected doesn't satisfy (or break) the check.
    expected = ["correctness"]
    assert missing_specialists(expected, ["correctness", "acme-extra"]) == []
    assert missing_specialists(expected, ["acme-extra"]) == ["correctness"]


# --- schema validation ------------------------------------------------------


def _write(path: Path, data: dict) -> str:
    path.write_text(json.dumps(data), encoding="utf-8")
    return str(path)


def _valid_findings() -> dict:
    return {
        "specialist": "correctness",
        "findings": [
            {
                "id": "correctness-1",
                "file": "Sources/Example.swift",
                "line": 42,
                "severity": "HIGH",
                "title": "off-by-one in retry loop",
                "body": "details here",
                "confidence": 0.8,
            },
            {
                "id": "correctness-2",
                "file": "Sources/Other.swift",
                "severity": "MINOR",
                "title": "optional fields omitted",
            },
        ],
    }


def _valid_result() -> dict:
    return {
        "findings": [
            {
                "id": "final-1",
                "file": "Sources/Example.swift",
                "severity": "MINOR",
                "title": "kept as minor",
            }
        ],
        "disposition": [
            {"id": "correctness-1", "action": "kept"},
            {"id": "correctness-2", "action": "merged"},
            {
                "id": "concurrency-1",
                "action": "downgraded",
                "note": "race is unreachable: the actor serializes access",
            },
            {
                "id": "conventions-1",
                "action": "dropped",
                "note": "premise refuted on re-check — grep was misread",
            },
        ],
        "comment_body": "## Review\nAll minor.",
    }


def test_valid_findings_file_passes(tmp_path: Path) -> None:
    path = _write(tmp_path / "findings-correctness.json", _valid_findings())
    data = validate_findings_file(path)
    assert data["specialist"] == "correctness"


def test_valid_result_file_passes(tmp_path: Path) -> None:
    path = _write(tmp_path / "review-result.json", _valid_result())
    data = validate_result_file(path)
    assert data["comment_body"].startswith("## Review")


def test_findings_missing_required_field_names_it(tmp_path: Path) -> None:
    data = _valid_findings()
    del data["findings"][0]["title"]
    path = _write(tmp_path / "findings-correctness.json", data)
    with pytest.raises(SchemaValidationError) as excinfo:
        validate_findings_file(path)
    message = str(excinfo.value)
    assert "findings-correctness.json" in message
    assert "title" in message


def test_findings_bad_severity_names_it(tmp_path: Path) -> None:
    data = _valid_findings()
    data["findings"][0]["severity"] = "CRITICAL"
    path = _write(tmp_path / "findings-correctness.json", data)
    with pytest.raises(SchemaValidationError) as excinfo:
        validate_findings_file(path)
    message = str(excinfo.value)
    assert "findings-correctness.json" in message
    assert "CRITICAL" in message
    assert "severity" in message


def test_findings_smuggled_top_level_verdict_is_stripped_not_fatal(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # A model must not smuggle a verdict into a findings file — and it cannot:
    # the verdict is COMPUTED by verdict_from_findings from the merged
    # severities and is never read from any findings file, so the smuggled key
    # is inert wherever it lands. That makes stripping-with-a-warning the right
    # response rather than the fatal rejection this test used to pin: killing
    # the file would discard the lens's real findings to punish a key nothing
    # reads. See "unknown keys are stripped, not fatal" below for the rationale
    # in full.
    data = _valid_findings()
    data["verdict"] = "APPROVE"
    path = _write(tmp_path / "findings-correctness.json", data)
    parsed = validate_findings_file(path)
    assert "verdict" not in parsed
    assert len(parsed["findings"]) == 2
    out = capsys.readouterr().out
    assert "warning:" in out
    assert "verdict" in out


# --- `line` may be null: findings with no line anchor ----------------------
#
# Repo-wide, convention, and architectural findings have no single line. A
# model writing one emits `"line": null` — the natural JSON — which the schema
# used to reject, failing the whole gate closed on precisely the category of
# finding least amenable to mechanical judgment. Omission was already legal;
# these fixtures pin that null is too.


def _repo_wide_finding() -> dict:
    """The real shape that broke the gate: a file, a body, no line anchor."""
    return {
        "id": "conventions-1",
        "file": "CLAUDE.md",
        "line": None,
        "severity": "MEDIUM",
        "title": "convention applies repo-wide, not at one line",
        "body": "No single line anchors this; it is a property of the tree.",
        "confidence": 0.7,
    }


def test_findings_null_line_is_valid(tmp_path: Path) -> None:
    data = {"specialist": "conventions", "findings": [_repo_wide_finding()]}
    path = _write(tmp_path / "findings-conventions.json", data)
    parsed = validate_findings_file(path)
    assert parsed["findings"][0]["line"] is None


def test_result_null_line_is_valid(tmp_path: Path) -> None:
    data = _valid_result()
    data["findings"] = [_repo_wide_finding()]
    data["disposition"] = [{"id": "conventions-1", "action": "kept"}]
    path = _write(tmp_path / "review-result.json", data)
    parsed = validate_result_file(path)
    assert parsed["findings"][0]["line"] is None


def test_findings_omitted_line_is_still_valid(tmp_path: Path) -> None:
    finding = _repo_wide_finding()
    del finding["line"]
    path = _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": [finding]},
    )
    assert "line" not in validate_findings_file(path)["findings"][0]


@pytest.mark.parametrize("bad_line", ["42", 4.5, [], {}])
def test_findings_non_integer_non_null_line_still_rejected(
    tmp_path: Path, bad_line: object
) -> None:
    # Widening to null must not widen to "anything": a string line number is
    # still a malformed finding.
    finding = _repo_wide_finding()
    finding["line"] = bad_line
    path = _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": [finding]},
    )
    with pytest.raises(SchemaValidationError, match="line"):
        validate_findings_file(path)


def test_main_accepts_a_null_line_finding_end_to_end(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The whole-run shape from the observed failure: every specialist reports,
    # one finding has no line anchor, and the gate reaches a verdict instead of
    # dying in validation.
    _write(
        tmp_path / "findings-correctness.json",
        {"specialist": "correctness", "findings": []},
    )
    _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": [_repo_wide_finding()]},
    )
    _write(
        tmp_path / "review-result.json",
        {
            "findings": [_repo_wide_finding()],
            "disposition": [{"id": "conventions-1", "action": "kept"}],
            "comment_body": "## Review\nOne repo-wide finding.",
        },
    )
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 0
    assert (tmp_path / "verdict.txt").read_text(encoding="utf-8") == "REJECT"


# --- `file` may be null: findings anchored to no one file -------------------
#
# The sibling of the `line` case above, and the same production failure a run
# later: `at findings/1/file: None is not of type 'string'` took the whole gate
# down with no verdict. A finding that is a property of the tree — a convention
# applied repo-wide, an architectural shape spread over many files — has no more
# a single file than it has a single line. `file` stays REQUIRED, so a model
# must still state the anchor; what changed is that "there isn't one" is now a
# sayable answer.
#
# The nullable set stops at the anchors. `id`, `severity`, and `title` are the
# finding's identity, its verdict input, and its content: a null in any of them
# is a malformed finding, not an absent anchor, and must keep failing closed.


def _tree_wide_finding() -> dict:
    """The real shape that broke the gate: no file, no line, still a finding."""
    return {
        "id": "conventions-2",
        "file": None,
        "line": None,
        "severity": "MEDIUM",
        "title": "convention holds across the tree, not at one file",
        "body": "No single file anchors this; it is a property of the repo.",
        "confidence": 0.6,
    }


def test_findings_null_file_is_valid(tmp_path: Path) -> None:
    data = {"specialist": "conventions", "findings": [_tree_wide_finding()]}
    path = _write(tmp_path / "findings-conventions.json", data)
    parsed = validate_findings_file(path)
    assert parsed["findings"][0]["file"] is None


def test_result_null_file_is_valid(tmp_path: Path) -> None:
    data = _valid_result()
    data["findings"] = [_tree_wide_finding()]
    data["disposition"] = [{"id": "conventions-2", "action": "kept"}]
    path = _write(tmp_path / "review-result.json", data)
    parsed = validate_result_file(path)
    assert parsed["findings"][0]["file"] is None


def test_findings_null_file_with_a_line_is_valid(tmp_path: Path) -> None:
    # The two anchors are independent: widening one must not require the other.
    finding = _tree_wide_finding()
    finding["line"] = 42
    path = _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": [finding]},
    )
    assert validate_findings_file(path)["findings"][0]["file"] is None


def test_findings_omitted_file_is_still_rejected(tmp_path: Path) -> None:
    # Deliberate asymmetry with `line`, which may also be omitted. `file` stays
    # required: the key's presence is the cheap proof the model considered the
    # anchor, and null is how it says there is none.
    finding = _tree_wide_finding()
    del finding["file"]
    path = _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": [finding]},
    )
    with pytest.raises(SchemaValidationError, match="file"):
        validate_findings_file(path)


@pytest.mark.parametrize("bad_file", [42, 4.5, [], {}, True])
def test_findings_non_string_non_null_file_still_rejected(
    tmp_path: Path, bad_file: object
) -> None:
    # Widening to null must not widen to "anything": a numeric path is still a
    # malformed finding.
    finding = _tree_wide_finding()
    finding["file"] = bad_file
    path = _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": [finding]},
    )
    with pytest.raises(SchemaValidationError, match="file"):
        validate_findings_file(path)


def test_main_accepts_a_null_file_finding_end_to_end(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The whole-run shape from run 30963170832: both specialists report, one
    # finding is anchored to no file, and the gate reaches a verdict instead of
    # dying in validation with no verdict written.
    _write(
        tmp_path / "findings-correctness.json",
        {"specialist": "correctness", "findings": []},
    )
    _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": [_tree_wide_finding()]},
    )
    _write(
        tmp_path / "review-result.json",
        {
            "findings": [_tree_wide_finding()],
            "disposition": [{"id": "conventions-2", "action": "kept"}],
            "comment_body": "## Review\nOne tree-wide finding.",
        },
    )
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 0
    assert (tmp_path / "verdict.txt").read_text(encoding="utf-8") == "REJECT"


# --- the nulls that must still fail closed ----------------------------------


@pytest.mark.parametrize("field", ["id", "severity", "title"])
def test_findings_null_in_a_load_bearing_field_still_rejected(
    tmp_path: Path, field: str
) -> None:
    # `id` keys the disposition-coverage check, `severity` computes the verdict,
    # `title` IS the finding. None of the three has an "absent" reading, so a
    # null there is garbage the gate must keep rejecting.
    finding = _tree_wide_finding()
    finding[field] = None
    path = _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": [finding]},
    )
    with pytest.raises(SchemaValidationError, match=field):
        validate_findings_file(path)


@pytest.mark.parametrize("field", ["id", "severity", "title"])
def test_result_null_in_a_load_bearing_field_still_rejected(
    tmp_path: Path, field: str
) -> None:
    data = _valid_result()
    data["findings"][0][field] = None
    path = _write(tmp_path / "review-result.json", data)
    with pytest.raises(SchemaValidationError, match=field):
        validate_result_file(path)


def test_findings_null_specialist_still_rejected(tmp_path: Path) -> None:
    # The specialist name is the lens's identity — it is what the completeness
    # check matches expected lenses against.
    path = _write(
        tmp_path / "findings-conventions.json",
        {"specialist": None, "findings": []},
    )
    with pytest.raises(SchemaValidationError, match="specialist"):
        validate_findings_file(path)


@pytest.mark.parametrize("field", ["findings", "disposition"])
def test_result_null_array_still_rejected(tmp_path: Path, field: str) -> None:
    # main() iterates both; a null there is a broken run with no safe reading,
    # not an absent anchor.
    data = _valid_result()
    data[field] = None
    path = _write(tmp_path / "review-result.json", data)
    with pytest.raises(SchemaValidationError, match=field):
        validate_result_file(path)


# --- the optional fields are nullable too -----------------------------------
#
# `body`, `confidence`, `note`, and `comment_body` may all be omitted already,
# so a null is only that same absence spelled the way a model writes it. Each
# has either no consumer at all or one that already treats a non-string as
# blank — rejecting the null buys nothing and costs the whole run.


@pytest.mark.parametrize("field", ["body", "confidence"])
def test_findings_null_optional_field_is_valid(tmp_path: Path, field: str) -> None:
    finding = _tree_wide_finding()
    finding[field] = None
    path = _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": [finding]},
    )
    assert validate_findings_file(path)["findings"][0][field] is None


def test_findings_out_of_range_confidence_still_rejected(tmp_path: Path) -> None:
    # Nullable does not mean unbounded: 0..1 still holds for any number given.
    finding = _tree_wide_finding()
    finding["confidence"] = 1.5
    path = _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": [finding]},
    )
    with pytest.raises(SchemaValidationError, match="confidence"):
        validate_findings_file(path)


def test_result_null_comment_body_is_valid(tmp_path: Path) -> None:
    # render_comment.py already treats a non-string body as blank and posts a
    # machine-rendered fallback with a warning; failing closed here would post
    # nothing at all, which is strictly worse.
    data = _valid_result()
    data["comment_body"] = None
    path = _write(tmp_path / "review-result.json", data)
    assert validate_result_file(path)["comment_body"] is None


@pytest.mark.parametrize("action", ["kept", "merged"])
def test_result_null_note_on_a_kept_entry_is_valid(
    tmp_path: Path, action: str
) -> None:
    data = _valid_result()
    data["disposition"] = [{"id": "correctness-1", "action": action, "note": None}]
    path = _write(tmp_path / "review-result.json", data)
    assert validate_result_file(path)["disposition"][0]["note"] is None


@pytest.mark.parametrize("action", ["downgraded", "dropped"])
def test_result_null_note_does_not_satisfy_the_reason_requirement(
    tmp_path: Path, action: str
) -> None:
    # The one place a note is load-bearing: dropping or downgrading a finding
    # needs a stated reason a human can read. A null must not pass for one just
    # because the key is present.
    data = _valid_result()
    data["disposition"] = [{"id": "correctness-1", "action": action, "note": None}]
    path = _write(tmp_path / "review-result.json", data)
    with pytest.raises(SchemaValidationError, match="note"):
        validate_result_file(path)


def test_result_downgraded_without_note_fails(tmp_path: Path) -> None:
    data = _valid_result()
    del data["disposition"][2]["note"]  # the "downgraded" entry
    path = _write(tmp_path / "review-result.json", data)
    with pytest.raises(SchemaValidationError) as excinfo:
        validate_result_file(path)
    message = str(excinfo.value)
    assert "review-result.json" in message
    assert "note" in message


def test_result_dropped_without_note_fails(tmp_path: Path) -> None:
    data = _valid_result()
    del data["disposition"][3]["note"]  # the "dropped" entry
    path = _write(tmp_path / "review-result.json", data)
    with pytest.raises(SchemaValidationError, match="note"):
        validate_result_file(path)


def test_result_kept_without_note_is_fine(tmp_path: Path) -> None:
    data = _valid_result()
    assert "note" not in data["disposition"][0]  # "kept" needs no note
    path = _write(tmp_path / "review-result.json", data)
    validate_result_file(path)


def test_result_missing_comment_body_names_it(tmp_path: Path) -> None:
    data = _valid_result()
    del data["comment_body"]
    path = _write(tmp_path / "review-result.json", data)
    with pytest.raises(SchemaValidationError, match="comment_body"):
        validate_result_file(path)


def test_result_bad_disposition_action_fails(tmp_path: Path) -> None:
    data = _valid_result()
    data["disposition"][0]["action"] = "ignored"
    path = _write(tmp_path / "review-result.json", data)
    with pytest.raises(SchemaValidationError, match="ignored"):
        validate_result_file(path)


def test_unreadable_json_fails_with_filename(tmp_path: Path) -> None:
    path = tmp_path / "findings-broken.json"
    path.write_text("{not json", encoding="utf-8")
    with pytest.raises(SchemaValidationError, match="findings-broken.json"):
        validate_findings_file(str(path))


# --- main: --expected-specialists completeness (in-process, no subprocess) ---


def _write_specialist_file(tmp_path: Path, name: str) -> None:
    _write(
        tmp_path / f"findings-{name}.json",
        {"specialist": name, "findings": []},
    )


def _write_empty_result(tmp_path: Path) -> None:
    _write(
        tmp_path / "review-result.json",
        {"findings": [], "disposition": [], "comment_body": "## Review\nClean."},
    )


def _run_main(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    expected_specialists: str | None,
) -> int:
    """Run main() against tmp_path fixtures; verdict.txt lands in tmp_path."""
    argv = [
        "validate.py",
        "--specialist-files",
        str(tmp_path / "findings-*.json"),
        "--result-file",
        str(tmp_path / "review-result.json"),
    ]
    if expected_specialists is not None:
        argv += ["--expected-specialists", expected_specialists]
    monkeypatch.setattr(sys, "argv", argv)
    monkeypatch.chdir(tmp_path)
    return main()


def test_main_all_expected_specialists_present_passes(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    for name in ("correctness", "conventions"):
        _write_specialist_file(tmp_path, name)
    _write_empty_result(tmp_path)
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 0
    assert (tmp_path / "verdict.txt").read_text(encoding="utf-8") == "APPROVE"


def test_main_one_missing_specialist_fails_and_names_it(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write_specialist_file(tmp_path, "correctness")
    _write_empty_result(tmp_path)
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 1
    err = capsys.readouterr().err
    assert "conventions" in err
    assert "produced no findings file" in err
    # Fail closed: a partial fan-out must never yield a verdict.
    assert not (tmp_path / "verdict.txt").exists()


def test_main_two_missing_specialists_both_named(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # Generic multi-missing behavior: every absent name is reported, so the
    # expected set here is deliberately wider than the production pair.
    _write_specialist_file(tmp_path, "correctness")
    _write_empty_result(tmp_path)
    exit_code = _run_main(
        monkeypatch, tmp_path, "correctness,conventions,acme-lens"
    )
    assert exit_code == 1
    err = capsys.readouterr().err
    assert "conventions" in err
    assert "acme-lens" in err
    assert not (tmp_path / "verdict.txt").exists()


def test_main_flag_absent_keeps_old_behavior_single_file_ok(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The e2e suite invokes validate.py with a single specialist and no
    # --expected-specialists; that must keep passing.
    _write_specialist_file(tmp_path, "correctness")
    _write_empty_result(tmp_path)
    exit_code = _run_main(monkeypatch, tmp_path, None)
    assert exit_code == 0
    assert (tmp_path / "verdict.txt").read_text(encoding="utf-8") == "APPROVE"


# --- omitted flag vs. supplied-but-empty value ------------------------------
#
# These two must not read alike. An OMITTED --expected-specialists is a caller
# saying "don't check completeness", which is how the e2e suite runs a single
# lens. A SUPPLIED but empty value is a caller that meant to name a set and
# handed over nothing — the shape produced when the workflow's
# `--expected-specialists "$REVIEW_SPECIALISTS"` expands an unset or blank
# variable. Reading the second as the first turns the merge gate fail-OPEN:
# every completeness check is skipped, the stall class is disarmed with it, and
# half a review yields APPROVE.


def test_parse_expected_specialists_omitted_is_no_check() -> None:
    assert parse_expected_specialists(None) == []


def test_parse_expected_specialists_splits_and_strips() -> None:
    assert parse_expected_specialists(" correctness , conventions ") == [
        "correctness",
        "conventions",
    ]


@pytest.mark.parametrize("raw", ["", "   ", "\t\n", ",", " , ", ",,"])
def test_parse_expected_specialists_supplied_but_empty_raises(raw: str) -> None:
    # Whitespace-only and separator-only spellings are the same mistake as "":
    # the flag was given and names no lens.
    with pytest.raises(ValueError, match="--expected-specialists"):
        parse_expected_specialists(raw)


def test_main_omitted_expected_specialists_requests_no_check(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # Half the production set on disk, no flag: passes, because no completeness
    # claim was made. This is the behavior the empty-value failure below must
    # NOT be conflated with.
    _write_specialist_file(tmp_path, "correctness")
    _write_empty_result(tmp_path)
    assert _run_main(monkeypatch, tmp_path, None) == 0
    assert (tmp_path / "verdict.txt").read_text(encoding="utf-8") == "APPROVE"


@pytest.mark.parametrize("raw", ["", "   ", ","])
def test_main_empty_expected_specialists_fails_closed(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    raw: str,
) -> None:
    # The fail-open reproduction, run against exactly the same fixtures as the
    # omitted case above: one lens of two, plus a valid result. Before the fix
    # this returned 0 and wrote APPROVE — a verdict from half a review.
    _write_specialist_file(tmp_path, "correctness")
    _write_empty_result(tmp_path)
    exit_code = _run_main(monkeypatch, tmp_path, raw)
    assert exit_code == 1
    err = capsys.readouterr().err
    assert "--expected-specialists" in err
    assert "REVIEW_SPECIALISTS" in err  # points at the variable that expanded empty
    assert not (tmp_path / "verdict.txt").exists()


def test_main_empty_expected_specialists_fails_even_on_a_complete_run(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # Not "the check found nothing missing" — the invocation itself is
    # unusable, so a run that would otherwise have passed still fails closed.
    for name in ("correctness", "conventions"):
        _write_specialist_file(tmp_path, name)
    _write_empty_result(tmp_path)
    assert _run_main(monkeypatch, tmp_path, "") == 1
    assert not (tmp_path / "verdict.txt").exists()


def test_main_unexpected_extra_specialist_warns_but_passes(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    for name in ("correctness", "conventions", "acme-extra"):
        _write_specialist_file(tmp_path, name)
    _write_empty_result(tmp_path)
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 0
    out = capsys.readouterr().out
    assert "warning" in out
    assert "acme-extra" in out
    assert (tmp_path / "verdict.txt").read_text(encoding="utf-8") == "APPROVE"


# --- the two fail-closed causes must read differently -----------------------
#
# Both fail closed. But "that review lens never ran" sends an operator hunting
# an orchestrator race, and it is false when the lens ran and its file was
# merely rejected by the validator a moment earlier.

_NEVER_RAN = "never ran"
_WAS_REJECTED = "FAILED validation"


def test_specialist_name_from_conventional_filename() -> None:
    assert specialist_name_from_path("findings-conventions.json") == "conventions"
    assert specialist_name_from_path("/a/b/findings-correctness.json") == (
        "correctness"
    )


def test_specialist_name_from_unconventional_filename_is_none() -> None:
    assert specialist_name_from_path("review-result.json") is None
    assert specialist_name_from_path("findings.json") is None


def test_report_absent_says_never_ran_not_rejected() -> None:
    message = missing_specialist_report(["conventions"], [])
    assert _NEVER_RAN in message
    assert _WAS_REJECTED not in message
    assert "conventions" in message


def test_report_rejected_says_rejected_not_never_ran() -> None:
    message = missing_specialist_report(["conventions"], ["conventions"])
    assert _WAS_REJECTED in message
    assert _NEVER_RAN not in message
    assert "conventions" in message


def test_report_distinguishes_the_two_causes_in_one_run() -> None:
    message = missing_specialist_report(
        ["correctness", "conventions"], ["conventions"]
    )
    absent_clause, rejected_clause = (
        clause for clause in message.split("; ") if _NEVER_RAN in clause or
        _WAS_REJECTED in clause
    )
    assert "correctness" in absent_clause and "conventions" not in absent_clause
    assert "conventions" in rejected_clause and (
        "correctness" not in rejected_clause
    )


def test_report_always_says_failing_closed() -> None:
    for rejected in ([], ["conventions"]):
        assert missing_specialist_report(["conventions"], rejected).endswith(
            "failing closed"
        )


def test_main_absent_specialist_reports_never_ran(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write_specialist_file(tmp_path, "correctness")
    _write_empty_result(tmp_path)
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 1
    err = capsys.readouterr().err
    assert _NEVER_RAN in err
    assert _WAS_REJECTED not in err
    assert not (tmp_path / "verdict.txt").exists()


def test_main_rejected_specialist_file_does_not_claim_it_never_ran(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # The observed shape: the conventions lens ran and wrote a file the schema
    # rejected. Saying "never ran" here is the misdiagnosis being fixed.
    _write_specialist_file(tmp_path, "correctness")
    _write(
        tmp_path / "findings-conventions.json",
        {
            "specialist": "conventions",
            "findings": [{"id": "conventions-1", "file": "CLAUDE.md"}],
        },
    )
    _write_empty_result(tmp_path)
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 1
    err = capsys.readouterr().err
    assert _WAS_REJECTED in err
    assert _NEVER_RAN not in err
    # Still fails closed — only the diagnostic changed.
    assert not (tmp_path / "verdict.txt").exists()


def test_main_unparseable_specialist_file_is_reported_as_rejected(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # A file too broken to parse still attributes to its lens by filename.
    _write_specialist_file(tmp_path, "correctness")
    (tmp_path / "findings-conventions.json").write_text("{not json", "utf-8")
    _write_empty_result(tmp_path)
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 1
    err = capsys.readouterr().err
    assert _WAS_REJECTED in err
    assert _NEVER_RAN not in err


def test_main_mixed_causes_are_reported_separately(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": [{"id": "x", "file": "a"}]},
    )
    _write_empty_result(tmp_path)
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 1
    err = capsys.readouterr().err
    assert _NEVER_RAN in err and "correctness" in err
    assert _WAS_REJECTED in err and "conventions" in err


# --- session-stall class ----------------------------------------------------

from validate import STALL_REPORT, is_session_stall  # noqa: E402


_BOTH_LENSES = ["correctness", "conventions"]


def test_stall_is_everything_absent() -> None:
    assert is_session_stall(_BOTH_LENSES, [], [], False, False)


def test_a_result_file_on_disk_is_never_a_stall() -> None:
    """PRESENCE, not validity. A result file the schema rejected still proves
    the session ran far enough to write one, and the parameter that carries
    that fact is named for it."""
    assert not is_session_stall(
        _BOTH_LENSES, [], [], result_present=True, any_specialist_file=False
    )


def test_one_lens_reporting_is_not_a_stall() -> None:
    assert not is_session_stall(_BOTH_LENSES, ["correctness"], [], False, True)


def test_a_rejected_file_is_not_a_stall() -> None:
    """A schema-rejected file proves the session ran and the lens produced
    output — the operator must be sent to the schema error, not to a stall."""
    assert not is_session_stall(_BOTH_LENSES, [], ["conventions"], False, True)


def test_an_unattributable_file_on_disk_is_not_a_stall() -> None:
    """The gap the per-lens lists cannot see: a file matched the glob but its
    lens could not be named, so `seen` and `rejected` are both empty while
    something is demonstrably on disk. A stall means NOTHING reached disk."""
    assert not is_session_stall(_BOTH_LENSES, [], [], False, True)


def test_no_expected_set_means_no_stall_claim() -> None:
    assert not is_session_stall([], [], [], False, False)


def test_stall_report_names_infrastructure_not_verdict() -> None:
    assert "INFRASTRUCTURE" in STALL_REPORT
    assert "not a review verdict" in STALL_REPORT


def test_main_on_a_stall_prints_only_the_stall_diagnosis(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "validate.py",
            "--specialist-files",
            "findings-*.json",
            "--expected-specialists",
            "correctness,conventions",
            "--result-file",
            "review-result.json",
        ],
    )
    assert validate.main() == 1
    err = capsys.readouterr().err
    assert "INFRASTRUCTURE" in err
    # The three misleading lines are suppressed in favour of the one that names
    # the cause; the middle one is worse than noise, because "merged before all
    # specialists completed" describes a merge that never happened.
    assert "no specialist findings files match" not in err
    assert "that review lens never ran" not in err


def test_main_unattributable_broken_file_is_not_a_stall(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A file the glob matched but whose lens cannot be named is still a file.

    `findings-.json` matches `findings-*.json` yet not `findings-<name>.json`,
    so it lands in neither `seen` nor `rejected` — the two lists a stall used to
    be inferred from. Something reached disk and its parse error was printed one
    line earlier, so "the session produced NOTHING" would contradict the
    diagnostic directly above it and send the operator to an infrastructure
    hunt instead of to the broken file.
    """
    monkeypatch.chdir(tmp_path)
    (tmp_path / "findings-.json").write_text("{not json", encoding="utf-8")
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "validate.py",
            "--specialist-files",
            "findings-*.json",
            "--expected-specialists",
            "correctness,conventions",
            "--result-file",
            "review-result.json",
        ],
    )
    assert validate.main() == 1
    err = capsys.readouterr().err
    assert "findings-.json" in err
    assert "not readable as JSON" in err
    assert "INFRASTRUCTURE" not in err
    assert not (tmp_path / "verdict.txt").exists()


def test_main_a_schema_invalid_result_file_is_not_a_stall(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A result file that PARSES but fails the schema is a normal terminal
    state, not a stall.

    The Stop hook releases the session as soon as review-result.json parses as
    JSON, so "present but schema-invalid" is exactly what a session that merged
    badly leaves behind. Calling that "the session produced NOTHING" is
    factually false — something is on disk — and it would suppress the schema
    error that names the real defect, which is the only line an operator can
    act on.
    """
    monkeypatch.chdir(tmp_path)
    # Valid JSON, but missing the required `disposition` and `comment_body`.
    (tmp_path / "review-result.json").write_text(
        json.dumps({"findings": []}), encoding="utf-8"
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "validate.py",
            "--specialist-files",
            "findings-*.json",
            "--expected-specialists",
            "correctness,conventions",
            "--result-file",
            "review-result.json",
        ],
    )
    assert validate.main() == 1
    err = capsys.readouterr().err
    assert "INFRASTRUCTURE" not in err
    assert "schema validation failed" in err
    assert "disposition" in err
    assert not (tmp_path / "verdict.txt").exists()


def test_main_still_reports_a_partial_fan_out_per_lens(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """One lens missing is NOT a stall — the per-lens diagnostic must survive."""
    monkeypatch.chdir(tmp_path)
    (tmp_path / "findings-correctness.json").write_text(
        json.dumps({"specialist": "correctness", "findings": []})
    )
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "validate.py",
            "--specialist-files",
            "findings-*.json",
            "--expected-specialists",
            "correctness,conventions",
            "--result-file",
            "review-result.json",
        ],
    )
    assert validate.main() == 1
    err = capsys.readouterr().err
    assert "that review lens never ran" in err
    assert "INFRASTRUCTURE" not in err


# --- unknown keys are stripped, not fatal -----------------------------------
#
# The observed failure: the correctness lens reported two real findings, each
# carrying one extra key — `failure_scenario`, vocabulary borrowed from a
# different finding format the model knows. `additionalProperties: false`
# rejected the file, BOTH findings were discarded, and the gate failed closed
# with no verdict. Nothing in the pipeline reads that key; the review was lost
# to a typo in a vocabulary.
#
# The invariant these fixtures pin: a lens that RAN never contributes zero
# findings over a cosmetic key. An unknown key carries no meaning to any
# consumer, so the safe reading is to drop it — loudly, so the prompt drift that
# produced it is visible in the log — and validate what remains.
#
# Value strictness is retained, and the distinction is the point. Stripping
# answers only "this key is not in the vocabulary". It says nothing about
# whether the KNOWN fields are well-formed, so a bad severity, an out-of-range
# confidence, or a missing title is still a malformed finding that fails the
# gate closed. Softening the key set must not soften the values the verdict and
# the disposition check are computed from.


def _finding_with_failure_scenario(**overrides: object) -> dict:
    """The real shape from the observed run: a well-formed finding plus one
    borrowed key."""
    finding = {
        "id": "correctness-1",
        "file": "Sources/TBDDaemon/Example.swift",
        "line": 128,
        "severity": "HIGH",
        "title": "retry loop drops the last attempt",
        "body": "The loop exits one iteration early.",
        "confidence": 0.8,
        "failure_scenario": "3 retries configured, only 2 are attempted",
    }
    finding.update(overrides)
    return finding


def test_findings_file_with_a_borrowed_key_passes_and_strips_it(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = _write(
        tmp_path / "findings-correctness.json",
        {"specialist": "correctness", "findings": [_finding_with_failure_scenario()]},
    )
    parsed = validate_findings_file(path)
    finding = parsed["findings"][0]
    assert "failure_scenario" not in finding
    # Everything the pipeline reads survived intact.
    assert finding["id"] == "correctness-1"
    assert finding["severity"] == "HIGH"
    assert finding["title"] == "retry loop drops the last attempt"

    out = capsys.readouterr().out
    assert "warning:" in out
    assert "failure_scenario" in out
    assert "findings/0" in out
    assert "findings-correctness.json" in out


def test_main_a_borrowed_key_does_not_cost_the_lens_end_to_end(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # The whole-run reproduction: the correctness lens reports two real
    # findings, each carrying `failure_scenario`; the conventions lens is clean.
    # Before the fix this discarded both findings, reported the correctness lens
    # as "FAILED validation", and exited 1 with no verdict.
    high = _finding_with_failure_scenario()
    medium = _finding_with_failure_scenario(
        id="correctness-2",
        file="Sources/TBDDaemon/Other.swift",
        line=44,
        severity="MEDIUM",
        title="timeout is not honored on the retry path",
    )
    _write(
        tmp_path / "findings-correctness.json",
        {"specialist": "correctness", "findings": [high, medium]},
    )
    _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": []},
    )
    merged = [
        {key: value for key, value in finding.items() if key != "failure_scenario"}
        for finding in (_finding_with_failure_scenario(), medium)
    ]
    _write(
        tmp_path / "review-result.json",
        {
            "findings": merged,
            "disposition": [
                {"id": "correctness-1", "action": "kept"},
                {"id": "correctness-2", "action": "kept"},
            ],
            "comment_body": "## Review\nTwo findings.",
        },
    )
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 0
    # The findings SURVIVED and drove the verdict — the whole point of the fix.
    assert (tmp_path / "verdict.txt").read_text(encoding="utf-8") == "REJECT"


def test_stripping_does_not_soften_a_bad_severity(tmp_path: Path) -> None:
    # Same finding, one unknown key AND one invalid value: the value still
    # fails the gate closed.
    finding = _finding_with_failure_scenario(severity="CRITICAL")
    path = _write(
        tmp_path / "findings-correctness.json",
        {"specialist": "correctness", "findings": [finding]},
    )
    with pytest.raises(SchemaValidationError) as excinfo:
        validate_findings_file(path)
    message = str(excinfo.value)
    assert "CRITICAL" in message
    assert "severity" in message


def test_stripping_does_not_soften_a_missing_required_field(tmp_path: Path) -> None:
    finding = _finding_with_failure_scenario()
    del finding["title"]
    path = _write(
        tmp_path / "findings-correctness.json",
        {"specialist": "correctness", "findings": [finding]},
    )
    with pytest.raises(SchemaValidationError, match="title"):
        validate_findings_file(path)


def test_result_finding_with_a_borrowed_key_passes_and_strips_it(
    tmp_path: Path,
) -> None:
    # The merged result carries the same vocabulary risk: the orchestrator
    # copies specialist findings forward, borrowed keys and all.
    data = _valid_result()
    data["findings"] = [_finding_with_failure_scenario()]
    data["disposition"] = [{"id": "correctness-1", "action": "kept"}]
    path = _write(tmp_path / "review-result.json", data)
    parsed = validate_result_file(path)
    assert "failure_scenario" not in parsed["findings"][0]
    assert parsed["findings"][0]["severity"] == "HIGH"


def test_result_disposition_entry_with_a_borrowed_key_passes_and_strips_it(
    tmp_path: Path,
) -> None:
    data = _valid_result()
    data["disposition"] = [
        {"id": "correctness-1", "action": "kept", "category": "correctness"}
    ]
    path = _write(tmp_path / "review-result.json", data)
    parsed = validate_result_file(path)
    assert "category" not in parsed["disposition"][0]
    assert parsed["disposition"][0]["action"] == "kept"


def test_a_clean_file_prints_no_warning(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The warning must mean something: a file with nothing to strip is silent.
    path = _write(tmp_path / "findings-correctness.json", _valid_findings())
    validate_findings_file(path)
    assert "warning:" not in capsys.readouterr().out


# --- strip_unknown_keys as a pure function ----------------------------------

from validate import strip_unknown_keys  # noqa: E402


def _findings_validator() -> tuple[dict, type]:
    """The real findings schema plus its validator class — the same pair
    _validate_file builds, so these unit tests exercise production key sets."""
    import jsonschema

    with open(
        validate._SCHEMAS_DIR / "findings.schema.json", encoding="utf-8"
    ) as handle:
        schema = json.load(handle)
    return schema, jsonschema.validators.validator_for(schema)


def test_strip_reports_and_removes_a_nested_unknown_key() -> None:
    schema, validator_cls = _findings_validator()
    data = {
        "specialist": "correctness",
        "findings": [_finding_with_failure_scenario()],
    }
    assert strip_unknown_keys(data, schema, validator_cls) == [
        ("findings/0", ["failure_scenario"])
    ]
    assert "failure_scenario" not in data["findings"][0]
    assert data["findings"][0]["id"] == "correctness-1"


def test_strip_reports_the_root_as_root() -> None:
    schema, validator_cls = _findings_validator()
    data = _valid_findings()
    data["verdict"] = "APPROVE"
    assert strip_unknown_keys(data, schema, validator_cls) == [
        ("<root>", ["verdict"])
    ]
    assert "verdict" not in data


def test_strip_sorts_several_extras_within_one_object() -> None:
    schema, validator_cls = _findings_validator()
    finding = _finding_with_failure_scenario(short_summary="s", category="c")
    data = {"specialist": "correctness", "findings": [finding]}
    assert strip_unknown_keys(data, schema, validator_cls) == [
        ("findings/0", ["category", "failure_scenario", "short_summary"])
    ]


def test_strip_output_is_ordered_by_path() -> None:
    schema, validator_cls = _findings_validator()
    data = {
        "specialist": "correctness",
        "findings": [
            _finding_with_failure_scenario(id="correctness-1"),
            _finding_with_failure_scenario(id="correctness-2"),
        ],
        "verdict": "APPROVE",
    }
    reported = strip_unknown_keys(data, schema, validator_cls)
    assert [path for path, _ in reported] == sorted(path for path, _ in reported)
    assert set(path for path, _ in reported) == {
        "<root>",
        "findings/0",
        "findings/1",
    }


def test_strip_finds_nothing_in_a_clean_document() -> None:
    schema, validator_cls = _findings_validator()
    data = _valid_findings()
    assert strip_unknown_keys(data, schema, validator_cls) == []
    assert data == _valid_findings()


@pytest.mark.parametrize("data", [[], ["a"], "nope", 42, None, True])
def test_strip_tolerates_any_json_type(data: object) -> None:
    # A findings file that decoded to a scalar or a list has no object to strip
    # from. Stripping is not the place that diagnoses that — the strict
    # validation immediately after is — so this must return quietly rather than
    # raise and replace a precise schema error with a traceback.
    schema, validator_cls = _findings_validator()
    assert strip_unknown_keys(data, schema, validator_cls) == []


# --- a misnamed ROOT container must still fail the gate closed --------------
#
# The limit of the soft key set. Stripping an unknown key is safe exactly when
# the key carries nothing a reader would have seen, and at the document ROOT a
# container can carry the review itself: the most likely reason a lens writes
# `{"findings": [], "results": [...]}` is that it reported real findings and
# misnamed the list, and deleting `results` converts a fail-closed schema
# rejection into a silent APPROVE over unread code. `findings` and
# `disposition` are root keys, so the root is the only depth where that
# substitution is possible — the section after this one pins the other side,
# where an unknown key can hold anything and still reach nothing.


def _high_finding(finding_id: str = "correctness-1") -> dict:
    return {
        "id": finding_id,
        "file": "Sources/TBDDaemon/Example.swift",
        "line": 12,
        "severity": "HIGH",
        "title": "the finding that must never be silently deleted",
    }


def test_main_findings_smuggled_under_a_wrong_key_fails_closed(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # The regression this boundary exists for: the correctness lens reports a
    # HIGH finding under `results` and leaves `findings` empty. Stripping
    # `results` would report "0 finding(s)" and write APPROVE.
    _write(
        tmp_path / "findings-correctness.json",
        {
            "specialist": "correctness",
            "findings": [],
            "results": [_high_finding()],
        },
    )
    _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": []},
    )
    _write_empty_result(tmp_path)
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 1
    assert not (tmp_path / "verdict.txt").exists()
    err = capsys.readouterr().err
    assert "results" in err
    assert "Additional properties are not allowed" in err


def test_main_merged_findings_smuggled_under_a_wrong_key_fails_closed(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # The same shape one layer up, where the damage is worse: the specialist
    # file is legitimate and reports a HIGH, and the MERGE misnames the list.
    # Stripping `results` there would leave `findings: []` — an APPROVE over a
    # finding the lens actually reported.
    _write(
        tmp_path / "findings-correctness.json",
        {"specialist": "correctness", "findings": [_high_finding()]},
    )
    _write(
        tmp_path / "findings-conventions.json",
        {"specialist": "conventions", "findings": []},
    )
    _write(
        tmp_path / "review-result.json",
        {
            "findings": [],
            "results": [_high_finding()],
            "disposition": [{"id": "correctness-1", "action": "kept"}],
            "comment_body": "## Review\nOne finding.",
        },
    )
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 1
    assert not (tmp_path / "verdict.txt").exists()
    err = capsys.readouterr().err
    assert "results" in err


@pytest.mark.parametrize(
    "value",
    [
        [{"id": "x"}],
        [1, 2, 3],
        {"nested": "object"},
        {},
        # An EMPTY array is left alone too. The rule reads the value's TYPE, not
        # its content: judging emptiness would make the gate's behavior depend
        # on how much the model happened to write, and failing closed is the
        # deliberately conservative direction when the two cannot be told apart.
        [],
    ],
)
def test_strip_leaves_container_valued_unknown_root_keys_alone(
    value: object,
) -> None:
    schema, validator_cls = _findings_validator()
    data = {"specialist": "correctness", "findings": [], "results": value}
    assert strip_unknown_keys(data, schema, validator_cls) == []
    assert data["results"] == value


def test_strip_takes_the_scalars_and_leaves_the_container_in_one_object() -> None:
    # Mixed: the cosmetic key goes, the suspicious one stays, and what stays is
    # enough to keep the strict pass rejecting the file.
    schema, validator_cls = _findings_validator()
    data = {
        "specialist": "correctness",
        "findings": [],
        "summary": "all clear",
        "results": [_high_finding()],
    }
    assert strip_unknown_keys(data, schema, validator_cls) == [
        ("<root>", ["summary"])
    ]
    assert "summary" not in data
    assert data["results"] == [_high_finding()]


def test_strip_declines_a_schema_whose_key_set_properties_does_not_state() -> None:
    # `patternProperties` makes keys legal that `properties` never names, so
    # `properties` is not the key set and stripping by it would delete legal
    # data. (The schema-valued `additionalProperties` form needs no guard: it
    # validates each extra key against its subschema and reports under that
    # subschema's keyword, never under `additionalProperties`.)
    import jsonschema

    schema = {
        "type": "object",
        "properties": {"known": {"type": "string"}},
        "additionalProperties": False,
        "patternProperties": {"^x-": {}},
    }
    validator_cls = jsonschema.validators.validator_for(schema)
    data = {"known": "a", "extra": 42}
    assert strip_unknown_keys(data, schema, validator_cls) == []
    assert data["extra"] == 42


# --- the container carve-out is a ROOT rule, not a depth-free one ------------
#
# The carve-out above exists because a misnamed container at the document root
# can BE the verdict's input: `findings`, `disposition`, and the severities
# inside them are root-anchored, so deleting `results` there fabricates an
# APPROVE. None of that is reachable below the root. A finding's own keys are
# the ones the schema names — `id`, `severity`, `title` and the rest are KNOWN
# keys and are never candidates for stripping — so an unknown key inside a
# finding or a disposition entry cannot remove a finding, cannot change a
# severity, and cannot alter a disposition's action. Whatever it holds is
# elaboration that had no slot in the format, and the only question is whether
# losing it is worth failing the gate over. It is not: applying the container
# rule at every depth turns `"failure_scenario": ["step one", "step two"]` —
# the same borrowed vocabulary the soft key set exists for, spelled as a list —
# back into a whole discarded lens.


def test_a_container_valued_borrowed_key_inside_a_finding_is_stripped(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The reproduction: the incident's key, written as a list instead of a
    # string. Below the root, the value's type buys nothing.
    finding = _finding_with_failure_scenario(
        failure_scenario=["step one", "step two"]
    )
    path = _write(
        tmp_path / "findings-correctness.json",
        {"specialist": "correctness", "findings": [finding]},
    )
    parsed = validate_findings_file(path)
    assert "failure_scenario" not in parsed["findings"][0]
    assert parsed["findings"][0]["severity"] == "HIGH"
    out = capsys.readouterr().out
    assert "failure_scenario" in out
    assert "findings/0" in out


def test_a_container_valued_unknown_key_in_a_disposition_entry_is_stripped(
    tmp_path: Path,
) -> None:
    data = _valid_result()
    data["disposition"] = [
        {
            "id": "correctness-1",
            "action": "kept",
            "evidence": {"file": "Sources/A.swift", "lines": [1, 2]},
        }
    ]
    path = _write(tmp_path / "review-result.json", data)
    parsed = validate_result_file(path)
    assert "evidence" not in parsed["disposition"][0]
    assert parsed["disposition"][0]["action"] == "kept"


def test_depth_stripping_does_not_soften_a_missing_dropped_note(
    tmp_path: Path,
) -> None:
    # The known keys are never stripped, so the one place a note is load-bearing
    # still fails closed even when the entry also carries an unknown container.
    data = _valid_result()
    data["disposition"] = [
        {"id": "correctness-1", "action": "dropped", "rationale": {"why": "n/a"}}
    ]
    path = _write(tmp_path / "review-result.json", data)
    with pytest.raises(SchemaValidationError, match="note"):
        validate_result_file(path)


# --- the warning is model-written text, and GitHub reads stdout -------------
#
# Every part of the strip warning that varies — the key names, and the path
# components that are themselves object keys — was written by the review
# session. GitHub parses a job's stdout line by line for `::` workflow
# commands, so a key spelled with a newline in it would let the session emit
# its own annotations, or a `::stop-commands::` that switches annotation
# parsing off for the rest of the job. The run that carries it is GREEN — the
# keys were stripped, the file validated — which is what makes it worth
# defending: nothing else is failing to draw attention.


def test_sanitize_flattens_line_breaks() -> None:
    assert validate._sanitize_log_text("a\nb") == "a\\nb"
    assert validate._sanitize_log_text("a\r\nb") == "a\\r\\nb"
    assert validate._sanitize_log_text("plain") == "plain"


def test_a_key_name_cannot_forge_a_second_annotation(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    finding = _finding_with_failure_scenario()
    del finding["failure_scenario"]
    finding["x\n::warning::forged"] = "payload"
    path = _write(
        tmp_path / "findings-correctness.json",
        {"specialist": "correctness", "findings": [finding]},
    )
    validate_findings_file(path)

    lines = capsys.readouterr().out.splitlines()
    warnings = [line for line in lines if line.startswith("::warning::")]
    assert len(warnings) == 1
    # The break is escaped in place, so the forged directive stays inside the
    # one real annotation as text.
    assert "x\\n::warning::forged" in warnings[0]
    assert not any(line.startswith("::warning::forged") for line in lines)


def test_the_strip_warning_is_an_annotation(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # It fires on runs that go on to PASS, so a bare stdout line is where it
    # would go unread.
    path = _write(
        tmp_path / "findings-correctness.json",
        {
            "specialist": "correctness",
            "findings": [_finding_with_failure_scenario()],
        },
    )
    validate_findings_file(path)
    out = capsys.readouterr().out
    assert out.startswith("::warning::")
    assert "failure_scenario" in out


def test_a_file_name_cannot_forge_an_annotation(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The path is model-written too: the specialist names its own file with the
    # Write tool, and the workflow's `findings-*.json` glob matches a name
    # carrying a newline as readily as any other.
    finding = _finding_with_failure_scenario()
    path = _write(
        tmp_path / "findings-a\n::error::forged.json",
        {"specialist": "correctness", "findings": [finding]},
    )
    validate_findings_file(path)

    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 1
    assert "findings-a\\n::error::forged.json" in lines[0]
    assert not any(line.startswith("::error::forged") for line in lines)


def test_finding_shaped_content_below_root_is_dropped_by_design(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A nested container CAN hold finding-shaped content, and it is dropped.

    Pinned so it reads as a decision rather than an accident. The guarantee the
    depth rule makes is narrower than "nothing important can hide below the
    root": a strip there never removes an element of the DECLARED findings array
    and never touches a known field, but content the model wrote into a slot the
    format does not have goes with the key, warning and all.

    Failing closed on it instead is the worse trade. `related_findings` is
    indistinguishable by type from `"failure_scenario": ["step one", "step
    two"]` — the incident's own borrowed vocabulary spelled as a list — so a
    rule that caught one would cost a whole lens for the other. And a rejection
    would not have surfaced the nested finding either: it would have discarded
    the declared ones too and forced a re-run.
    """
    smuggled = _high_finding("correctness-nested")
    finding = _finding_with_failure_scenario()
    del finding["failure_scenario"]
    finding["related_findings"] = [smuggled]
    path = _write(
        tmp_path / "findings-correctness.json",
        {"specialist": "correctness", "findings": [finding]},
    )
    parsed = validate_findings_file(path)

    assert "related_findings" not in parsed["findings"][0]
    # Only the DECLARED array feeds the verdict; the smuggled finding is gone.
    assert [f["id"] for f in parsed["findings"]] == ["correctness-1"]
    out = capsys.readouterr().out
    assert "related_findings" in out
    assert "findings/0" in out


def test_one_annotation_per_file_lists_every_site(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The incident's real shape: a lens that borrows a key name writes it on
    # every finding it reports. One annotation naming every site, not one per
    # site — twenty near-identical notes would hit GitHub's per-step annotation
    # display cap and bury whatever else the run had to say.
    path = _write(
        tmp_path / "findings-correctness.json",
        {
            "specialist": "correctness",
            "findings": [
                _finding_with_failure_scenario(id="correctness-1"),
                _finding_with_failure_scenario(id="correctness-2"),
                _finding_with_failure_scenario(id="correctness-3"),
            ],
        },
    )
    validate_findings_file(path)

    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 1
    for index in range(3):
        assert f"at findings/{index}: failure_scenario" in lines[0]


# --- every model-derived interpolation goes through the choke point ---------
#
# The strip warning is not the only line that carries model-written text into a
# log GitHub parses for `::` commands. A file's PATH is model-written — the
# specialist names its own file with the Write tool, and `findings-*.json`
# matches a newline-bearing name — and it appears in the `ok:` line of a
# perfectly VALID file and in the `error:` line of a rejected one. So does file
# CONTENT: the `specialist` name, and the finding ids the disposition check
# reports. Every one of those is routed through `_sanitize_log_text`, which
# stays the single place the escaping is defined.
#
# The `ok:` line is the sharper of the two, because it prints on success: a
# forged annotation there rides a run that goes on to post a review.

_FORGED_NAME = "findings-a\n::error::forged.json"


def test_a_valid_file_with_a_forged_name_stays_one_ok_line(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write(tmp_path / _FORGED_NAME, {"specialist": "correctness", "findings": []})
    _write_empty_result(tmp_path)
    assert _run_main(monkeypatch, tmp_path, None) == 0

    lines = capsys.readouterr().out.splitlines()
    ok_lines = [line for line in lines if line.startswith("ok: ")]
    assert len(ok_lines) == 2  # the findings file and the result file
    assert "findings-a\\n::error::forged.json" in ok_lines[0]
    assert not any(line.startswith("::error::forged") for line in lines)


def test_a_rejected_file_with_a_forged_name_stays_one_error_line(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write(tmp_path / _FORGED_NAME, {"specialist": "correctness"})  # no findings
    _write_empty_result(tmp_path)
    assert _run_main(monkeypatch, tmp_path, None) == 1

    lines = capsys.readouterr().err.splitlines()
    error_lines = [line for line in lines if line.startswith("error: ")]
    assert len(error_lines) == 1
    assert "findings-a\\n::error::forged.json" in error_lines[0]
    assert not any(line.startswith("::error::forged") for line in lines)


def test_the_strip_warning_does_not_claim_the_file_validated(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    # The annotation is printed BEFORE the strict pass, so it cannot claim the
    # file validated — sometimes the very next line rejects it. Here a `dropped`
    # entry spells its reason `reason` instead of `note`: the unknown key is
    # stripped and annotated, and then the file fails closed for want of the
    # `note` a dropped finding must carry. The annotation stays (it is useful
    # context on a rejected file); what it asserts is narrowed to what has
    # actually happened by the time it prints.
    data = _valid_result()
    data["disposition"] = [
        {"id": "correctness-1", "action": "dropped", "reason": "premise refuted"}
    ]
    path = _write(tmp_path / "review-result.json", data)
    with pytest.raises(SchemaValidationError, match="note"):
        validate_result_file(path)

    lines = capsys.readouterr().out.splitlines()
    assert len(lines) == 1
    assert "reason" in lines[0]
    assert "validated" not in lines[0]
    assert "kept for the validation that follows" in lines[0]


# --- the sanitize invariant is per-SITE, not per-helper ---------------------
#
# `_sanitize_log_text` being correct proves nothing about a print that forgets
# to call it, and a call site is exactly the kind of thing a later edit drops
# while the helper's own tests stay green. So every site that interpolates
# model-written text gets its own test, each crafting input that carries
# "\n::error::forged" through that ONE site — a specialist name, a finding id, a
# value quoted back by a schema error, an exception message — and each failing
# if the call is removed from that site alone.

_FORGED = "\n::error::forged"


def _forged_lines(captured: str) -> list[str]:
    return captured.splitlines()


def _assert_one_line_and_inert(lines: list[str], needle: str) -> None:
    matches = [line for line in lines if needle in line]
    assert len(matches) == 1, f"expected exactly one line carrying {needle!r}"
    assert "\\n::error::forged" in matches[0]
    assert not any(line.startswith("::error::forged") for line in lines)


def test_a_forged_specialist_name_cannot_split_the_unexpected_warning(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # The broadest surface of the four: `specialist` is free-form model-authored
    # content inside a file that passes the schema, and the warning it feeds
    # prints on a run that goes on to PASS.
    _write(
        tmp_path / "findings-correctness.json",
        {"specialist": f"acme{_FORGED}", "findings": []},
    )
    _write_specialist_file(tmp_path, "conventions")
    _write_empty_result(tmp_path)
    assert _run_main(monkeypatch, tmp_path, "conventions") == 0

    lines = _forged_lines(capsys.readouterr().out)
    _assert_one_line_and_inert(lines, "unexpected specialist(s)")


def test_a_forged_finding_id_cannot_split_the_disposition_error(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # Finding ids are model-authored and reach the log whenever the merge fails
    # to account for one.
    _write(
        tmp_path / "findings-correctness.json",
        {
            "specialist": "correctness",
            "findings": [_high_finding(f"correctness-1{_FORGED}")],
        },
    )
    _write_empty_result(tmp_path)
    assert _run_main(monkeypatch, tmp_path, None) == 1

    lines = _forged_lines(capsys.readouterr().err)
    _assert_one_line_and_inert(lines, "disposition list does not account")


def test_a_forged_result_error_cannot_split_its_line(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The result-error site's own test, reached by injecting the raise.

    No crafted review-result.json reaches it. Two things stand in the way, and
    both are worth naming because either could stop being true. jsonschema
    `repr()`s the offending value into its message, so a newline a model writes
    into a value arrives already escaped; and the only raw interpolation in a
    schema error is the FILE PATH, which for the merged result is the
    workflow's own `--result-file` literal rather than anything the session
    named. (The specialist files are different — their names come from the
    session's Write calls through a glob, which is why the sibling test above
    can craft that one for real.)

    The sanitize call stays and is pinned anyway: it costs nothing, and the
    guarantee it backstops is two accidents deep — a schema gaining
    `patternProperties` would put a model-written key straight into the
    instance path this line prints.
    """
    _write_specialist_file(tmp_path, "correctness")
    _write_empty_result(tmp_path)

    def _raise(_path: str) -> dict:
        raise SchemaValidationError(f"review-result.json{_FORGED}: bad")

    monkeypatch.setattr(validate, "validate_result_file", _raise)
    assert _run_main(monkeypatch, tmp_path, None) == 1

    lines = _forged_lines(capsys.readouterr().err)
    _assert_one_line_and_inert(lines, "review-result.json")


def test_a_forged_verdict_error_cannot_split_its_line(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The verdict site's own test, reached by patching the raiser.

    `verdict_from_findings` quotes the offending finding's id and severity, but
    no schema-VALID file can reach it: `severity` is an enum, so anything the
    function would reject the strict pass rejected first. The site is
    defense-in-depth against that guarantee being weakened later, and its
    sanitize call deserves a test regardless — so the raise is injected rather
    than smuggled through a file that cannot exist today.
    """
    _write_specialist_file(tmp_path, "correctness")
    _write_empty_result(tmp_path)

    def _raise(_findings: list[dict]) -> str:
        raise ValueError(f"finding 'x{_FORGED}' has unknown severity")

    monkeypatch.setattr(validate, "verdict_from_findings", _raise)
    assert _run_main(monkeypatch, tmp_path, None) == 1

    lines = _forged_lines(capsys.readouterr().err)
    _assert_one_line_and_inert(lines, "unknown severity")


def test_a_forged_expected_specialists_error_cannot_split_its_line(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The `--expected-specialists` error site, reached by injecting the raise.

    No CLI value reaches it carrying forged text. The raise fires only when the
    value names NO specialist — whitespace or bare separators — so a value with
    `::error::forged` in it parses to a lens name and never raises at all; and
    the message quotes the value with `!r`, which escapes the newline before
    this line is composed. The wrapper is uniform policy rather than a live
    defense here, and it is pinned so that policy cannot quietly lapse at this
    site.
    """
    _write_specialist_file(tmp_path, "correctness")
    _write_empty_result(tmp_path)

    def _raise(_raw: str | None) -> list[str]:
        raise ValueError(f"--expected-specialists was supplied as{_FORGED}")

    monkeypatch.setattr(validate, "parse_expected_specialists", _raise)
    assert _run_main(monkeypatch, tmp_path, "correctness") == 1

    lines = _forged_lines(capsys.readouterr().err)
    _assert_one_line_and_inert(lines, "--expected-specialists")


def test_a_forged_glob_cannot_split_the_empty_glob_error(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The empty-glob line cannot be split — by either of two mechanisms.

    A PROPERTY test rather than a per-site one, and deliberately so. This line
    is defended twice over: `!r` escapes the newline as it quotes the glob, and
    the sanitize wrapper escapes whatever `!r` did not. Removing either alone
    leaves the property intact, so this fails only when BOTH are gone — which is
    the honest shape of the guarantee. What it pins is the thing that matters
    (an operator-supplied glob can never forge an annotation), not which of the
    two redundant mechanisms happens to be carrying it.
    """
    _write_empty_result(tmp_path)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "validate.py",
            "--specialist-files",
            f"findings-a{_FORGED}-*.json",
            "--result-file",
            str(tmp_path / "review-result.json"),
        ],
    )
    assert validate.main() == 1

    lines = _forged_lines(capsys.readouterr().err)
    _assert_one_line_and_inert(lines, "no specialist findings files match")


# --- the infrastructure-failure channel --------------------------------------
#
# The session's deterministic "I cannot review" path. Without it, a session
# whose pinned-SHA diff errors has only bad options: an empty findings array
# computes as APPROVE (an unreviewed PR goes green on the required check), and
# a fabricated HIGH finding computes as REJECT — which the skip cache then
# re-asserts against the diff's patch-id on every re-run. Failing validation
# outright writes no verdict and records no marker, so the next run reviews
# fresh.

from validate import (  # noqa: E402
    infrastructure_failure_message,
    read_infrastructure_failure,
)


def test_infra_failure_preempts_everything_and_fails_closed(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # Even with both specialist files present and valid, the channel wins.
    for name in ("correctness", "conventions"):
        _write_specialist_file(tmp_path, name)
    _write(
        tmp_path / "review-result.json",
        {"infrastructure_failure": "pinned merge-base diff errored"},
    )
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 1
    assert not (tmp_path / "verdict.txt").exists()
    err = capsys.readouterr().err
    assert "review-infrastructure failure" in err
    assert "pinned merge-base diff errored" in err
    assert "NOT a verdict" in err


def test_infra_failure_message_is_single_line_and_capped() -> None:
    # A runaway or multi-line message must not mangle the single-line
    # ::error:: annotation the workflow builds from the last error line.
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "review-result.json"
        path.write_text(
            json.dumps({"infrastructure_failure": "line one\nline two  " + "x" * 900}),
            encoding="utf-8",
        )
        message = read_infrastructure_failure(str(path))
    assert message is not None
    assert "\n" not in message
    assert message.startswith("line one line two x")
    assert len(message) <= 500


@pytest.mark.parametrize(
    "content",
    [
        '{"infrastructure_failure": ""}',
        '{"infrastructure_failure": "   "}',
        '{"infrastructure_failure": 7}',
        '["infrastructure_failure"]',
        "not json at all",
    ],
)
def test_non_messages_do_not_trigger_the_infra_channel(
    tmp_path: Path, content: str
) -> None:
    # Empty, non-string, non-object, and unparseable shapes all fall through to
    # the stall/schema diagnostics, which name those states more precisely.
    path = tmp_path / "review-result.json"
    path.write_text(content, encoding="utf-8")
    assert read_infrastructure_failure(str(path)) is None


def test_missing_result_file_is_not_an_infra_report(tmp_path: Path) -> None:
    assert read_infrastructure_failure(str(tmp_path / "absent.json")) is None


def test_specialist_infra_failure_fails_closed_despite_valid_everything(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # A specialist whose pinned diff errored writes empty findings PLUS the
    # schema-declared infrastructure_failure field. Everything else about the
    # run is green — both lenses present, result file valid — and the run must
    # still fail with no verdict: two empty findings files otherwise compute
    # as APPROVE on a PR nobody reviewed, and the alternative signal (prose in
    # the specialist's returned summary) depends on the orchestrator relaying
    # it.
    _write(
        tmp_path / "findings-correctness.json",
        {
            "specialist": "correctness",
            "findings": [],
            "infrastructure_failure": "git diff <pinned> HEAD exited 128",
        },
    )
    _write_specialist_file(tmp_path, "conventions")
    _write_empty_result(tmp_path)
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 1
    assert not (tmp_path / "verdict.txt").exists()
    err = capsys.readouterr().err
    assert "'correctness'" in err
    assert "git diff <pinned> HEAD exited 128" in err
    assert "NOT a verdict" in err
    # And the lens is not misreported as having never run.
    assert "never produced a findings file" not in err


def test_the_schema_accepts_the_specialist_infra_field(tmp_path: Path) -> None:
    # additionalProperties is false, so the field must be declared or the
    # channel dies at schema validation with a misleading error.
    path = _write(
        tmp_path / "findings-correctness.json",
        {
            "specialist": "correctness",
            "findings": [],
            "infrastructure_failure": "diff errored",
        },
    )
    assert validate_findings_file(path)["infrastructure_failure"] == "diff errored"


def test_the_schema_rejects_findings_alongside_the_infra_field(
    tmp_path: Path,
) -> None:
    # infrastructure_failure means "I could not review"; findings mean the
    # review happened. A file claiming both is self-contradictory, and reading
    # it as an infra abort would discard a run over a subordinate failure the
    # specialist reviewed through — so the schema rejects the combination and
    # the rejected-file diagnostics take over.
    path = _write(
        tmp_path / "findings-correctness.json",
        {
            "specialist": "correctness",
            "findings": [_finding()],
            "infrastructure_failure": "a subordinate git blame was denied",
        },
    )
    with pytest.raises(SchemaValidationError):
        validate_findings_file(path)


def test_specialist_infra_failure_is_the_decisive_last_error_line(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # The workflow annotates the LAST `error:` line. A result file with an
    # uncovered disposition would otherwise print after the specialist's infra
    # report and send the operator after the wrong problem.
    _write(
        tmp_path / "findings-correctness.json",
        {
            "specialist": "correctness",
            "findings": [],
            "infrastructure_failure": "pinned diff errored",
        },
    )
    _write_specialist_file(tmp_path, "conventions")
    _write(
        tmp_path / "review-result.json",
        {
            "findings": [],
            "disposition": [
                {"id": "ghost-1", "action": "kept"}
            ],
            "comment_body": "## Review",
        },
    )
    exit_code = _run_main(monkeypatch, tmp_path, "correctness,conventions")
    assert exit_code == 1
    error_lines = [
        line
        for line in capsys.readouterr().err.splitlines()
        if line.startswith("error: ")
    ]
    assert error_lines
    assert "review-infrastructure failure" in error_lines[-1]
    assert "disposition" not in error_lines[-1]


def test_the_schema_accepts_a_null_infra_field_with_findings(
    tmp_path: Path,
) -> None:
    # Null is a model's natural spelling of absence (matching every optional
    # sibling: file, line, body, confidence). It must read as "no infra
    # report" — findings allowed, if/then not triggered — never as a
    # self-contradiction.
    path = _write(
        tmp_path / "findings-correctness.json",
        {
            "specialist": "correctness",
            "findings": [_finding()],
            "infrastructure_failure": None,
        },
    )
    data = validate_findings_file(path)
    assert data["infrastructure_failure"] is None
    assert len(data["findings"]) == 1


@pytest.mark.parametrize("value", ["", "   \n\t "])
def test_a_blank_infra_field_reads_as_absence_in_schema_and_reader_alike(
    tmp_path: Path, value: str
) -> None:
    # The schema's if/then and infrastructure_failure_message() must share one
    # definition of "a report": substance after stripping. A blank string that
    # the reader ignores but the schema treats as a report would discard a
    # lens's genuine findings over a key that says nothing.
    path = _write(
        tmp_path / "findings-correctness.json",
        {
            "specialist": "correctness",
            "findings": [_finding()],
            "infrastructure_failure": value,
        },
    )
    data = validate_findings_file(path)
    assert len(data["findings"]) == 1
    assert infrastructure_failure_message(data) is None
