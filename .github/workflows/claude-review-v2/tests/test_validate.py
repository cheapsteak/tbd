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
    missing_specialists,
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
    expected = ["correctness", "concurrency", "conventions"]
    assert missing_specialists(expected, expected) == []


def test_missing_specialists_one_missing() -> None:
    expected = ["correctness", "concurrency", "conventions"]
    seen = ["correctness", "conventions"]
    assert missing_specialists(expected, seen) == ["concurrency"]


def test_missing_specialists_two_missing_in_expected_order() -> None:
    expected = ["correctness", "concurrency", "conventions"]
    assert missing_specialists(expected, ["concurrency"]) == [
        "correctness",
        "conventions",
    ]


def test_missing_specialists_all_missing() -> None:
    expected = ["correctness", "concurrency"]
    assert missing_specialists(expected, []) == expected


def test_missing_specialists_duplicates_in_seen_are_fine() -> None:
    # Two findings files for the same specialist is last-write-wins upstream,
    # not a completeness failure.
    expected = ["correctness", "concurrency"]
    seen = ["correctness", "correctness", "concurrency"]
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
    for name in ("correctness", "concurrency", "conventions"):
        _write_specialist_file(tmp_path, name)
    _write_empty_result(tmp_path)
    exit_code = _run_main(
        monkeypatch, tmp_path, "correctness,concurrency,conventions"
    )
    assert exit_code == 0
    assert (tmp_path / "verdict.txt").read_text(encoding="utf-8") == "APPROVE"


def test_main_one_missing_specialist_fails_and_names_it(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    for name in ("correctness", "conventions"):
        _write_specialist_file(tmp_path, name)
    _write_empty_result(tmp_path)
    exit_code = _run_main(
        monkeypatch, tmp_path, "correctness,concurrency,conventions"
    )
    assert exit_code == 1
    err = capsys.readouterr().err
    assert "concurrency" in err
    assert "produced no findings file" in err
    # Fail closed: a partial fan-out must never yield a verdict.
    assert not (tmp_path / "verdict.txt").exists()


def test_main_two_missing_specialists_both_named(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    _write_specialist_file(tmp_path, "correctness")
    _write_empty_result(tmp_path)
    exit_code = _run_main(
        monkeypatch, tmp_path, "correctness,concurrency,conventions"
    )
    assert exit_code == 1
    err = capsys.readouterr().err
    assert "concurrency" in err
    assert "conventions" in err
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
    for name in ("correctness", "concurrency", "conventions", "acme-extra"):
        _write_specialist_file(tmp_path, name)
    _write_empty_result(tmp_path)
    exit_code = _run_main(
        monkeypatch, tmp_path, "correctness,concurrency,conventions"
    )
    assert exit_code == 0
    out = capsys.readouterr().out
    assert "warning" in out
    assert "acme-extra" in out
    assert (tmp_path / "verdict.txt").read_text(encoding="utf-8") == "APPROVE"
