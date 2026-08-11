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


def test_findings_rejects_unknown_top_level_key(tmp_path: Path) -> None:
    data = _valid_findings()
    data["verdict"] = "APPROVE"  # the model must not smuggle a verdict in
    path = _write(tmp_path / "findings-correctness.json", data)
    with pytest.raises(SchemaValidationError, match="verdict"):
        validate_findings_file(path)


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
