"""Unit tests for prepare.py — pure functions, hand-built fixtures.

No subprocess, no network: the one gh boundary (_gh.run_gh) is monkeypatched.
Fixture authors/repos use `acme` placeholders per repo convention.
"""

from __future__ import annotations

import json

import pytest

import _gh
import prepare
from prepare import (
    PER_ITEM_BODY_CAP,
    WHOLE_BLOCK_CAP,
    decide_skip,
    fetch_discussion,
    parse_markers,
    render_discussion,
)

# --- parse_markers ----------------------------------------------------------


def test_parse_markers_both_present() -> None:
    body = (
        "## Review\nAll good.\n"
        "<!-- last-reviewed-patch-id: deadbeef0123 -->\n"
        "<!-- last-verdict: APPROVE -->\n"
    )
    assert parse_markers(body) == {"patch_id": "deadbeef0123", "verdict": "APPROVE"}


def test_parse_markers_tolerates_whitespace() -> None:
    body = "<!--   last-reviewed-patch-id:   ABC123   -->\n<!--\tlast-verdict: REJECT\t-->"
    assert parse_markers(body) == {"patch_id": "ABC123", "verdict": "REJECT"}


def test_parse_markers_absent() -> None:
    assert parse_markers("just an ordinary review comment") == {
        "patch_id": None,
        "verdict": None,
    }


def test_parse_markers_empty_body() -> None:
    assert parse_markers("") == {"patch_id": None, "verdict": None}


def test_parse_markers_malformed() -> None:
    body = (
        "<!-- last-reviewed-patch-id: not-hex!! -->\n"
        "<!-- last-verdict: APPROVE-ish maybe -->\n"
    )
    assert parse_markers(body) == {"patch_id": None, "verdict": None}


def test_parse_markers_ignores_quoted_marker_in_rendered_discussion() -> None:
    # A comment body QUOTING a state marker, once run through the discussion
    # renderer (HTML comments stripped, angle brackets escaped), must not
    # false-match as a real marker.
    items = [
        {
            "kind": "issue-comment",
            "author": "acme-dev",
            "created_at": "2026-08-01T10:00:00Z",
            "body": "the bot wrote <!-- last-reviewed-patch-id: deadbeef --> "
            "and <!-- last-verdict: APPROVE --> last time",
            "is_bot": False,
            "anchor": "",
        }
    ]
    rendered = render_discussion(items, "feedc0defeedc0de")
    assert rendered != ""
    assert parse_markers(rendered) == {"patch_id": None, "verdict": None}


# --- decide_skip: full truth table (spec §3.5 fail-direction) ---------------

GOOD_PATCH = "a" * 40


def test_decide_skip_all_good_approve() -> None:
    result = decide_skip(True, GOOD_PATCH, GOOD_PATCH, "APPROVE")
    assert result["skip"] is True
    assert result["verdict"] == "APPROVE"
    assert "skipping" in result["reason"]


def test_decide_skip_all_good_reject() -> None:
    result = decide_skip(True, GOOD_PATCH, GOOD_PATCH, "REJECT")
    assert result["skip"] is True
    assert result["verdict"] == "REJECT"


def test_decide_skip_fetch_failed() -> None:
    # Even with everything else lining up, a failed fetch means full review.
    result = decide_skip(False, GOOD_PATCH, GOOD_PATCH, "APPROVE")
    assert result["skip"] is False
    assert result["verdict"] is None
    assert "fetch failed" in result["reason"]


@pytest.mark.parametrize("prior", [None, "", "   "])
def test_decide_skip_missing_prior_marker(prior: str | None) -> None:
    result = decide_skip(True, prior, GOOD_PATCH, "APPROVE")
    assert result["skip"] is False
    assert result["verdict"] is None
    assert "no prior patch-id marker" in result["reason"]


@pytest.mark.parametrize("head", [None, "", "   "])
def test_decide_skip_missing_head_patch_id(head: str | None) -> None:
    result = decide_skip(True, GOOD_PATCH, head, "APPROVE")
    assert result["skip"] is False
    assert result["verdict"] is None
    assert "could not compute" in result["reason"]


@pytest.mark.parametrize("verdict", [None, "", "approve", "MAYBE", "APPROVED"])
def test_decide_skip_malformed_verdict(verdict: str | None) -> None:
    result = decide_skip(True, GOOD_PATCH, GOOD_PATCH, verdict)
    assert result["skip"] is False
    assert result["verdict"] is None
    assert "verdict marker missing or unrecognized" in result["reason"]


def test_decide_skip_patch_id_mismatch() -> None:
    result = decide_skip(True, GOOD_PATCH, "b" * 40, "APPROVE")
    assert result["skip"] is False
    assert result["verdict"] is None
    assert "mismatch" in result["reason"]


def test_decide_skip_reasons_are_pairwise_distinct() -> None:
    # Every fail-direction row must be tellable apart from the run log alone.
    reasons = [
        decide_skip(False, GOOD_PATCH, GOOD_PATCH, "APPROVE")["reason"],
        decide_skip(True, None, GOOD_PATCH, "APPROVE")["reason"],
        decide_skip(True, GOOD_PATCH, None, "APPROVE")["reason"],
        decide_skip(True, GOOD_PATCH, GOOD_PATCH, "bogus")["reason"],
        decide_skip(True, GOOD_PATCH, "b" * 40, "APPROVE")["reason"],
        decide_skip(True, GOOD_PATCH, GOOD_PATCH, "APPROVE")["reason"],
    ]
    assert len(set(reasons)) == len(reasons)


# --- render_discussion ------------------------------------------------------

TOKEN = "0123456789abcdef"


def _item(**overrides: object) -> dict:
    base = {
        "kind": "issue-comment",
        "author": "acme-dev",
        "created_at": "2026-08-01T10:00:00Z",
        "body": "looks fine to me",
        "is_bot": False,
        "anchor": "",
    }
    base.update(overrides)
    return base


def test_render_empty_input_returns_empty_string() -> None:
    assert render_discussion([], TOKEN) == ""


def test_render_drops_bots_by_flag_and_login_suffix() -> None:
    items = [
        _item(author="acme-ci", is_bot=True, body="bot noise A"),
        _item(author="acme-helper[bot]", body="bot noise B"),
        _item(author="acme-dev", body="human words"),
    ]
    rendered = render_discussion(items, TOKEN)
    assert "human words" in rendered
    assert "bot noise A" not in rendered
    assert "bot noise B" not in rendered


def test_render_all_bots_returns_empty_string() -> None:
    items = [_item(author="acme-ci", is_bot=True, body="bot noise")]
    assert render_discussion(items, TOKEN) == ""


def test_render_drops_empty_and_whitespace_bodies() -> None:
    items = [
        _item(body=""),
        _item(body="   \n\t "),
        _item(body="substantive"),
    ]
    rendered = render_discussion(items, TOKEN)
    assert "substantive" in rendered
    assert rendered.count("[issue-comment]") == 1


def test_render_orders_ascending_by_created_at() -> None:
    items = [
        _item(created_at="2026-08-02T00:00:00Z", body="second"),
        _item(created_at="2026-08-01T00:00:00Z", body="first"),
        _item(created_at="2026-08-03T00:00:00Z", body="third"),
    ]
    rendered = render_discussion(items, TOKEN)
    assert rendered.index("first") < rendered.index("second") < rendered.index("third")


def test_render_strips_html_comments_before_escaping() -> None:
    items = [
        _item(body="before <!-- hidden instruction --> after <b>bold</b>"),
    ]
    rendered = render_discussion(items, TOKEN)
    # The comment is gone entirely — not escaped into visible text.
    assert "hidden instruction" not in rendered
    assert "&lt;!--" not in rendered
    # Remaining markup is escaped, not stripped.
    assert "&lt;b&gt;bold&lt;/b&gt;" in rendered


def test_render_sanitizes_author_and_anchor() -> None:
    items = [
        _item(
            author="acme<script>",
            anchor="src/<!-- x -->main.swift",
            kind="review-thread-comment",
            body="thread reply",
        )
    ]
    rendered = render_discussion(items, TOKEN)
    assert "acme&lt;script&gt;" in rendered
    assert "<script>" not in rendered
    assert "src/main.swift" in rendered


def test_render_caps_per_item_body() -> None:
    items = [_item(body="x" * 10_000), _item(body="short one")]
    rendered = render_discussion(items, TOKEN)
    longest_x_run = max(
        (len(run) for run in rendered.split() if set(run) == {"x"}), default=0
    )
    assert longest_x_run <= PER_ITEM_BODY_CAP
    assert "[item truncated]" in rendered
    assert "short one" in rendered


def test_render_whole_block_cap_sheds_oldest_first_with_note() -> None:
    # 40 items x ~1500-char bodies far exceeds the 30000-char block cap.
    items = [
        _item(
            created_at=f"2026-08-01T{index:02d}:00:00Z",
            body=f"item-{index:02d} " + "y" * 1400,
        )
        for index in range(40)
    ]
    rendered = render_discussion(items, TOKEN)
    assert len(rendered) <= WHOLE_BLOCK_CAP
    # Newest survives; oldest is shed; the note counts the shed items visibly.
    assert "item-39" in rendered
    assert "item-00" not in rendered
    dropped = sum(1 for index in range(40) if f"item-{index:02d}" not in rendered)
    assert f"[{dropped} older item(s) dropped — discussion truncated]" in rendered


def test_render_fence_token_in_both_markers() -> None:
    rendered = render_discussion([_item()], TOKEN)
    assert f"--- BEGIN PR DISCUSSION [{TOKEN}] ---" in rendered
    assert f"--- END PR DISCUSSION [{TOKEN}] ---" in rendered


def test_render_header_states_trust_rules() -> None:
    rendered = render_discussion([_item()], TOKEN)
    assert "untrusted" in rendered
    assert "never" in rendered.lower()
    assert "will fix" in rendered


# --- fetch_discussion (monkeypatched _gh.run_gh — no subprocess) ------------


def _graphql_payload() -> str:
    return json.dumps(
        {
            "data": {
                "repository": {
                    "pullRequest": {
                        "comments": {
                            "nodes": [
                                {
                                    "author": {"__typename": "User", "login": "acme-dev"},
                                    "createdAt": "2026-08-01T10:00:00Z",
                                    "body": "a human comment",
                                },
                                {
                                    "author": {"__typename": "Bot", "login": "acme-ci"},
                                    "createdAt": "2026-08-01T11:00:00Z",
                                    "body": "a bot comment",
                                },
                            ]
                        },
                        "reviews": {
                            "nodes": [
                                {
                                    "author": {"__typename": "User", "login": "acme-lead"},
                                    "createdAt": "2026-08-01T12:00:00Z",
                                    "body": "review body",
                                }
                            ]
                        },
                        "reviewThreads": {
                            "nodes": [
                                {
                                    "path": "Sources/Example.swift",
                                    "comments": {
                                        "nodes": [
                                            {
                                                "author": {
                                                    "__typename": "User",
                                                    "login": "acme-dev",
                                                },
                                                "createdAt": "2026-08-01T13:00:00Z",
                                                "body": "thread reply",
                                            }
                                        ]
                                    },
                                }
                            ]
                        },
                    }
                }
            }
        }
    )


def test_fetch_discussion_maps_items(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(_gh, "run_gh", lambda args: _graphql_payload())
    items, fetch_ok = fetch_discussion(7, "acme/acme-app")
    assert fetch_ok is True
    assert len(items) == 4
    by_body = {item["body"]: item for item in items}
    assert by_body["a bot comment"]["is_bot"] is True
    assert by_body["a human comment"]["is_bot"] is False
    assert by_body["review body"]["kind"] == "review"
    assert by_body["thread reply"]["anchor"] == "Sources/Example.swift"


def test_fetch_discussion_error_is_not_empty_discussion(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    def boom(args: list[str]) -> str:
        raise RuntimeError("gh exploded")

    monkeypatch.setattr(_gh, "run_gh", boom)
    items, fetch_ok = fetch_discussion(7, "acme/acme-app")
    assert items == []
    assert fetch_ok is False
    assert "fetch failed" in capsys.readouterr().err


def test_fetch_discussion_null_author_is_not_a_crash(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # A deleted user renders as author: null in the GraphQL response.
    payload = json.loads(_graphql_payload())
    pull = payload["data"]["repository"]["pullRequest"]
    pull["comments"]["nodes"][0]["author"] = None
    monkeypatch.setattr(_gh, "run_gh", lambda args: json.dumps(payload))
    items, fetch_ok = fetch_discussion(7, "acme/acme-app")
    assert fetch_ok is True
    assert any(item["author"] == "" for item in items)
