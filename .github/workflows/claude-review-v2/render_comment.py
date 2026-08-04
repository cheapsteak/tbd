#!/usr/bin/env python3
"""Comment-body renderer for the claude-review-v2 pipeline.

Owns the construction of the review comment each full-review run posts
(docs/specs/2026-08-03-pr-review-fanout-design.md §3.5). The workflow calls it
and pipes stdout into the body file; posting the comment — and minimizing the
PR's earlier v2 reviews as outdated — stays in the workflow shell.

The body it renders is one review comment carrying its own machine-read state:
the three marker lines, the model's `comment_body` prose (or a machine-rendered
fallback when that prose is missing), then the attribution line. The next run's
prepare step reads its markers back off the newest such comment.

Invariants every rendered body holds:

- the three marker lines are the first three lines, in a fixed order,
- sections are separated by exactly one blank line,
- model prose is emitted verbatim — never interpolated into a shell command,
  never pattern-matched, never rewritten,
- rendering NEVER fails: unreadable or malformed input yields a valid degraded
  body plus a warning on stderr, which the workflow surfaces as `::warning::`.
  The step's pass/fail is governed by validate.py, never by this script.

All policy lives in pure functions (no clock, no subprocess, no network — every
input is a parameter); main() is the only I/O shell. Python 3 stdlib only.
"""

from __future__ import annotations

import argparse
import json
import sys

# --- sentinel ---------------------------------------------------------------

# Opens every v2 review comment body. The workflow selects prior v2 reviews —
# to read state off the newest and to minimize them all as outdated — by
# matching the App's comments whose body STARTS WITH this line, so it must
# stay line 1.
COMMENT_SENTINEL = "<!-- claude-review-v2 -->"


# --- section assembly -------------------------------------------------------


def _join_sections(sections: list[str]) -> str:
    """Join non-empty sections with exactly one blank line between them."""
    return "\n\n".join(
        section.strip("\n") for section in sections if section.strip() != ""
    )


def marker_block(patch_id: str, verdict: str) -> str:
    """The three machine-read marker lines, in the order prepare.py expects.

    An empty patch id renders an empty marker value, which prepare.py's
    hex-only matcher rejects — the next run then full-reviews, the safe
    direction.
    """
    return "\n".join(
        [
            COMMENT_SENTINEL,
            f"<!-- last-reviewed-patch-id: {patch_id} -->",
            f"<!-- last-verdict: {verdict} -->",
        ]
    )


def attribution_line(repo: str, base_ref: str, patch_id: str = "") -> str:
    """The one-line provenance footer that closes every rendered review body.

    It names the diff this comment reviewed, because a PR accumulates one such
    comment per review: earlier ones are collapsed as outdated, and this line
    says which diff the visible one speaks for.
    """
    scope = (
        f"the review of this PR's diff at patch-id `{patch_id}`"
        if patch_id
        else "the review of this PR's diff as of the time it was posted"
    )
    return (
        f"_Posted by the [claude-review-v2 shadow check](https://github.com/"
        f"{repo}/blob/{base_ref}/.github/workflows/claude-code-review-v2.yml) — "
        f"{scope}. A newer v2 review comment supersedes this one._"
    )


# --- fallback rendering -----------------------------------------------------


def _finding_bullet(finding: dict) -> str:
    """One markdown bullet for a finding: severity, location, title, body."""
    severity = str(finding.get("severity") or "").strip() or "UNKNOWN"
    path = str(finding.get("file") or "").strip()
    line = finding.get("line")
    location = f"{path}:{line}" if path and isinstance(line, int) else path
    title = str(finding.get("title") or "").strip() or "(no title recorded)"

    bullet = f"- **{severity}**"
    if location:
        bullet += f" — `{location}`"
    bullet += f" — {title}"

    body = str(finding.get("body") or "").strip()
    if body:
        indented = "\n".join(
            f"  {row}" if row.strip() else "" for row in body.split("\n")
        )
        bullet += f"\n{indented}"
    return bullet


def fallback_body(findings: list[dict], verdict: str) -> str:
    """Render a review body from the findings alone, for a run whose prose is blank.

    A REJECT is computed from finding severities, independently of the prose —
    so a run can reject with nothing visible to explain it. This renders that
    explanation from the machine-readable record instead of posting markers
    alone.
    """
    if not findings:
        return (
            "_This run produced no review prose and recorded no findings. "
            f"Computed verdict: **{verdict}**._"
        )
    lead = (
        "_This run produced no review prose, so the findings below are "
        "rendered from `review-result.json` by the workflow rather than "
        f"written by the reviewer. Computed verdict: **{verdict}**._"
    )
    bullets = "\n".join(_finding_bullet(finding) for finding in findings)
    return f"{lead}\n\n{bullets}"


def unreadable_result_body(verdict: str) -> str:
    """Body for a run whose review-result.json is missing or unparseable."""
    return (
        "_This run's `review-result.json` could not be read, so neither review "
        "prose nor findings are available here. Computed verdict: "
        f"**{verdict}**._"
    )


# --- review body ------------------------------------------------------------


def prose_of(result: dict | None) -> str:
    """The model's `comment_body`, or "" when absent, non-string, or blank."""
    if not isinstance(result, dict):
        return ""
    prose = result.get("comment_body")
    if not isinstance(prose, str) or prose.strip() == "":
        return ""
    return prose


def findings_of(result: dict | None) -> list[dict]:
    """The merged findings list, or [] when absent or not a list of objects."""
    if not isinstance(result, dict):
        return []
    findings = result.get("findings")
    if not isinstance(findings, list):
        return []
    return [item for item in findings if isinstance(item, dict)]


def render_review_body(
    patch_id: str,
    verdict: str,
    result: dict | None,
    repo: str,
    base_ref: str,
) -> tuple[str, str | None]:
    """Render the review comment body this run posts.

    `result` is review-result.json's parsed contents, or None when the file was
    missing or unparseable. Returns (body, warning) — `warning` is None on the
    normal path and a one-line degradation reason otherwise, which the workflow
    surfaces as a `::warning::`.
    """
    markers = marker_block(patch_id, verdict)
    attribution = attribution_line(repo, base_ref, patch_id)

    if result is None:
        return (
            _join_sections([markers, unreadable_result_body(verdict), attribution]),
            "review-result.json was missing or unreadable — posted the verdict "
            "markers with a note in place of the review",
        )

    prose = prose_of(result)
    if prose:
        return _join_sections([markers, prose, attribution]), None

    findings = findings_of(result)
    warning = (
        f"review-result.json carried no comment_body prose — rendered a "
        f"machine fallback from {len(findings)} finding(s)"
        if findings
        else "review-result.json carried no comment_body prose and no findings "
        "— posted the verdict markers with a note"
    )
    return (
        _join_sections([markers, fallback_body(findings, verdict), attribution]),
        warning,
    )


# --- main (the only I/O shell) ----------------------------------------------


def load_result(path: str) -> tuple[dict | None, str | None]:
    """Read review-result.json; returns (result, warning), never raises.

    A missing file, unreadable file, invalid JSON, or a non-object payload all
    yield (None, reason) — the renderer degrades, it does not fail.
    """
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as exc:
        return None, f"could not read {path}: {exc}"
    except json.JSONDecodeError as exc:
        return None, f"{path} is not valid JSON: {exc}"
    if not isinstance(data, dict):
        return None, f"{path} is not a JSON object (got {type(data).__name__})"
    return data, None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--patch-id", default="", help="head patch-id (hex or empty)")
    parser.add_argument("--verdict", required=True, help="APPROVE or REJECT")
    parser.add_argument("--repo", required=True, help="owner/name")
    parser.add_argument("--base-ref", required=True, help="PR base branch name")
    parser.add_argument(
        "--result-file",
        required=True,
        help="path to review-result.json; missing or malformed degrades to a "
        "machine-rendered body rather than failing",
    )
    args = parser.parse_args(argv)

    result, read_warning = load_result(args.result_file)
    body, render_warning = render_review_body(
        args.patch_id, args.verdict, result, args.repo, args.base_ref
    )
    warning = read_warning or render_warning

    print(body)
    if warning:
        print(warning, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
