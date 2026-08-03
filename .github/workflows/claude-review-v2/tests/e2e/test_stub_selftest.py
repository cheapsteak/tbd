"""Unit tests for the stub model API server — no `claude` binary required.

Pin the pieces the e2e leans on: SSE event framing/order, stop_reason mapping,
unique tool ids, request→turn indexing (incl. overflow), the count_tokens/404
recording, and loop_advanced rejecting the silent-retry signature.
"""

from __future__ import annotations

import http.client
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from stub_server import (  # noqa: E402
    Capture,
    StubServer,
    ToolCall,
    Turn,
    loop_advanced,
    render_sse,
    sse_events,
)

# --- pure pieces -------------------------------------------------------------


def test_stop_reason_mapping() -> None:
    assert Turn(text="hi").stop_reason == "end_turn"
    assert Turn().stop_reason == "end_turn"
    assert Turn(tool_calls=[ToolCall("Write", {})]).stop_reason == "tool_use"
    assert Turn(text="hi", tool_calls=[ToolCall("Write", {})]).stop_reason == "tool_use"


def test_sse_event_order_text_and_tools() -> None:
    turn = Turn(text="hello", tool_calls=[ToolCall("Write", {"a": 1}), ToolCall("Bash", {"b": 2})])
    names = [name for name, _ in sse_events(turn, request_idx=1)]
    assert names == [
        "message_start",
        "content_block_start",  # text
        "content_block_delta",
        "content_block_stop",
        "content_block_start",  # tool 0
        "content_block_delta",
        "content_block_stop",
        "content_block_start",  # tool 1
        "content_block_delta",
        "content_block_stop",
        "message_delta",
        "message_stop",
    ]


def test_sse_payload_details() -> None:
    tool_input = {"file_path": "/tmp/x.json", "content": "{}"}
    turn = Turn(text="t", tool_calls=[ToolCall("Write", tool_input)])
    events = sse_events(turn, request_idx=3)
    payloads = {name: payload for name, payload in events}
    # stop_reason travels in message_delta, not message_start.
    assert payloads["message_start"]["message"]["stop_reason"] is None
    assert payloads["message_delta"]["delta"]["stop_reason"] == "tool_use"
    # The tool input rides input_json_delta as one full json.dumps.
    deltas = [p for name, p in events if name == "content_block_delta"]
    tool_delta = [d for d in deltas if d["delta"]["type"] == "input_json_delta"]
    assert len(tool_delta) == 1
    assert json.loads(tool_delta[0]["delta"]["partial_json"]) == tool_input
    # Block indices are sequential across text + tool blocks.
    starts = [p for name, p in events if name == "content_block_start"]
    assert [s["index"] for s in starts] == [0, 1]


def test_tool_use_ids_unique_across_calls_and_requests() -> None:
    turn = Turn(tool_calls=[ToolCall("Write", {}), ToolCall("Write", {})])
    ids = []
    for request_idx in (1, 2):
        for name, payload in sse_events(turn, request_idx):
            if name == "content_block_start" and payload["content_block"]["type"] == "tool_use":
                ids.append(payload["content_block"]["id"])
    assert len(ids) == 4
    assert len(set(ids)) == 4, f"tool ids must be unique, got {ids}"


def test_render_sse_is_parseable_event_stream() -> None:
    body = render_sse(Turn(text="x"), request_idx=1).decode("utf-8")
    frames = [f for f in body.split("\n\n") if f]
    for frame in frames:
        lines = frame.split("\n")
        assert lines[0].startswith("event: ")
        assert lines[1].startswith("data: ")
        json.loads(lines[1][len("data: "):])  # every data line is valid JSON
    assert frames[0].startswith("event: message_start")
    assert frames[-1].startswith("event: message_stop")


# --- loop_advanced -----------------------------------------------------------


def _capture(bodies: list[dict]) -> Capture:
    cap = Capture()
    for body in bodies:
        raw = json.dumps(body).encode("utf-8")
        cap.raw_bodies.append(raw)
        cap.requests.append(body)
    return cap


def test_loop_advanced_rejects_byte_identical_retry() -> None:
    # The silent-retry signature: the CLI re-sends the exact same body when it
    # got a non-SSE response — even if a later request carries a tool_result,
    # the first two being identical means the loop stalled.
    req = {"messages": [{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "x"}]}]}
    assert loop_advanced(_capture([req, req])) is False


def test_loop_advanced_requires_a_tool_result() -> None:
    a = {"messages": [{"role": "user", "content": "hi"}]}
    b = {"messages": [{"role": "user", "content": "hi again"}]}
    assert loop_advanced(_capture([a, b])) is False


def test_loop_advanced_true_on_real_tool_result() -> None:
    a = {"messages": [{"role": "user", "content": "go"}]}
    b = {
        "messages": [
            {"role": "user", "content": "go"},
            {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Write", "input": {}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]},
        ]
    }
    assert loop_advanced(_capture([a, b])) is True


def test_loop_advanced_empty_capture_is_false() -> None:
    assert loop_advanced(Capture()) is False


# --- server behavior over real HTTP ------------------------------------------


def _post(base_url: str, path: str, body: dict) -> tuple[int, str, bytes]:
    host_port = base_url.removeprefix("http://")
    host, port = host_port.rsplit(":", 1)
    conn = http.client.HTTPConnection(host, int(port), timeout=10)
    try:
        payload = json.dumps(body).encode("utf-8")
        conn.request(
            "POST", path, body=payload, headers={"Content-Type": "application/json"}
        )
        response = conn.getresponse()
        # http.client transparently de-chunks Transfer-Encoding: chunked.
        return response.status, response.getheader("Content-Type") or "", response.read()
    finally:
        conn.close()


def test_turn_indexing_and_overflow_over_http() -> None:
    turns = [Turn(text="first"), Turn(text="second")]
    with StubServer(turns) as stub:
        for expected in ("first", "second", "STUB-TERMINAL", "STUB-TERMINAL"):
            status, content_type, body = _post(
                stub.base_url, "/v1/messages", {"messages": [], "n": expected}
            )
            assert status == 200
            assert content_type.startswith("text/event-stream")
            assert expected.encode() in body
        assert len(stub.capture.raw_bodies) == 4
        assert stub.capture.requests[0]["n"] == "first"
        assert stub.capture.unexpected_paths == []


def test_count_tokens_and_unknown_paths_get_404_and_are_recorded() -> None:
    with StubServer([Turn(text="unused")]) as stub:
        status, _, _ = _post(stub.base_url, "/v1/messages/count_tokens", {"messages": []})
        assert status == 404
        status, _, _ = _post(stub.base_url, "/v1/complete", {})
        assert status == 404
        assert stub.capture.unexpected_paths == [
            "/v1/messages/count_tokens",
            "/v1/complete",
        ]
        # 404s never consume scripted turns.
        assert stub.capture.raw_bodies == []
        status, _, body = _post(stub.base_url, "/v1/messages", {"messages": []})
        assert status == 200 and b"unused" in body


def test_query_string_does_not_defeat_path_match() -> None:
    with StubServer([Turn(text="beta-ok")]) as stub:
        status, _, body = _post(stub.base_url, "/v1/messages?beta=true", {"messages": []})
        assert status == 200 and b"beta-ok" in body
        assert stub.capture.unexpected_paths == []
