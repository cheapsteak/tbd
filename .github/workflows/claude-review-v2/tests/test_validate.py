"""Unit tests for validate.py — pure functions plus schema validation on
hand-built tmp_path fixtures. No subprocess, no network."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from validate import (
    SchemaValidationError,
    check_disposition,
    main,
    missing_specialist_report,
    missing_specialists,
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
