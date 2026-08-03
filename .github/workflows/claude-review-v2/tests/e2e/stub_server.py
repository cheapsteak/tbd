"""A fake model API for deterministic, zero-token harness tests.

Part of the claude-review-v2 pipeline
(docs/specs/2026-08-03-pr-review-fanout-design.md §4). The real `claude` CLI is
pointed at this server via ANTHROPIC_BASE_URL; canned turns script the whole
session — text, tool calls, and the final stop — so the e2e test exercises the
actual session contract (Stop hook, findings files, review-result.json) with
zero tokens and full determinism.

CRITICAL — responses MUST be streamed SSE. The CLI sends `stream: true`; a
plain-JSON response makes it silently RETRY a byte-identical request while
executing nothing. A naive request count misreads that retry loop as progress,
which is why `loop_advanced()` exists and why the SSE framing here is
non-negotiable.

Stdlib only. The pure pieces (`Turn.stop_reason`, `sse_events`, `render_sse`,
`loop_advanced`) are unit-tested without the CLI in test_stub_selftest.py.
"""

from __future__ import annotations

import json
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

# The one path this server serves. Anything else — including
# /v1/messages/count_tokens — is a 404 recorded in Capture.unexpected_paths, so
# the e2e can assert the CLI needed nothing the stub doesn't model.
_MESSAGES_PATH = "/v1/messages"

# Overflow answer: a scenario that runs out of scripted turns must terminate,
# never hang the CLI (and, transitively, the pytest timeout).
_OVERFLOW_TEXT = "STUB-TERMINAL"


@dataclass
class ToolCall:
    """One scripted tool_use block."""

    name: str
    input: dict
    id: str = "toolu_stub"


@dataclass
class Turn:
    """One scripted assistant message: optional text, then tool calls."""

    text: str = ""
    tool_calls: list[ToolCall] = field(default_factory=list)

    @property
    def stop_reason(self) -> str:
        return "tool_use" if self.tool_calls else "end_turn"


@dataclass
class Capture:
    """Everything the server observed, for post-run assertions."""

    raw_bodies: list[bytes] = field(default_factory=list)
    requests: list[dict | None] = field(default_factory=list)  # parsed JSON (None if unparseable)
    unexpected_paths: list[str] = field(default_factory=list)


def loop_advanced(capture: Capture) -> bool:
    """Did the CLI actually execute tools, or silently retry?

    False if the first two raw bodies are byte-identical — the signature of the
    silent retry the CLI falls into when a response is not SSE. Otherwise,
    require an actual tool_result block somewhere in a request's
    messages[].content: that block only exists if the CLI ran a tool and sent
    its output back, which is what "the loop advanced" means.
    """
    if len(capture.raw_bodies) >= 2 and capture.raw_bodies[0] == capture.raw_bodies[1]:
        return False
    for request in capture.requests:
        if request is None:
            continue
        for message in request.get("messages", []):
            content = message.get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    return True
    return False


# --- SSE rendering (pure) ----------------------------------------------------


def sse_events(turn: Turn, request_idx: int) -> list[tuple[str, dict]]:
    """The (event_name, payload) sequence for one turn, in wire order.

    message_start → per text block start/delta(text_delta)/stop → per tool call
    start(tool_use)/delta(input_json_delta with the full serialized input)/stop
    → message_delta (carrying stop_reason) → message_stop.

    Tool-use ids are made unique per request (`{base}_{request_idx}_{n}`): the
    CLI keys tool_result blocks on the id, and a reused id across turns would
    corrupt its transcript.
    """
    events: list[tuple[str, dict]] = [
        (
            "message_start",
            {
                "type": "message_start",
                "message": {
                    "id": f"msg_stub_{request_idx}",
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-stub",
                    "content": [],
                    "stop_reason": None,
                    "stop_sequence": None,
                    "usage": {"input_tokens": 1, "output_tokens": 1},
                },
            },
        )
    ]
    index = 0
    if turn.text:
        events.append(
            (
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": index,
                    "content_block": {"type": "text", "text": ""},
                },
            )
        )
        events.append(
            (
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": index,
                    "delta": {"type": "text_delta", "text": turn.text},
                },
            )
        )
        events.append(
            ("content_block_stop", {"type": "content_block_stop", "index": index})
        )
        index += 1
    for n, call in enumerate(turn.tool_calls):
        events.append(
            (
                "content_block_start",
                {
                    "type": "content_block_start",
                    "index": index,
                    "content_block": {
                        "type": "tool_use",
                        "id": f"{call.id}_{request_idx}_{n}",
                        "name": call.name,
                        "input": {},
                    },
                },
            )
        )
        events.append(
            (
                "content_block_delta",
                {
                    "type": "content_block_delta",
                    "index": index,
                    "delta": {
                        "type": "input_json_delta",
                        "partial_json": json.dumps(call.input),
                    },
                },
            )
        )
        events.append(
            ("content_block_stop", {"type": "content_block_stop", "index": index})
        )
        index += 1
    events.append(
        (
            "message_delta",
            {
                "type": "message_delta",
                "delta": {"stop_reason": turn.stop_reason, "stop_sequence": None},
                "usage": {"output_tokens": 1},
            },
        )
    )
    events.append(("message_stop", {"type": "message_stop"}))
    return events


def render_sse(turn: Turn, request_idx: int) -> bytes:
    """The full SSE body for one turn (unchunked; the handler chunks it)."""
    return b"".join(
        f"event: {name}\ndata: {json.dumps(payload)}\n\n".encode("utf-8")
        for name, payload in sse_events(turn, request_idx)
    )


# --- server ------------------------------------------------------------------


class StubServer:
    """Threaded fake of POST /v1/messages on 127.0.0.1:<free port>.

    Context manager. Request N (1-based, /v1/messages only) is answered with
    turns[N-1]; overflow requests get Turn(text=STUB-TERMINAL) so a scenario
    never hangs. Everything observed lands in `.capture`.
    """

    def __init__(self, turns: list[Turn]):
        self.turns = list(turns)
        self.capture = Capture()
        self._lock = threading.Lock()
        self._request_count = 0
        stub = self

        class _Handler(BaseHTTPRequestHandler):
            # HTTP/1.1 so Transfer-Encoding: chunked is legal — SSE framing.
            protocol_version = "HTTP/1.1"

            def log_message(self, *_args: object) -> None:  # silence stderr
                pass

            def _read_body(self) -> bytes:
                length = int(self.headers.get("Content-Length") or 0)
                return self.rfile.read(length) if length else b""

            def _send_404(self) -> None:
                body = json.dumps(
                    {"type": "error", "error": {"type": "not_found_error", "message": "stub: unknown path"}}
                ).encode("utf-8")
                self.send_response(404)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _record_unexpected(self, path: str) -> None:
                with stub._lock:
                    stub.capture.unexpected_paths.append(path)

            def _write_chunk(self, data: bytes) -> None:
                self.wfile.write(f"{len(data):X}\r\n".encode("ascii") + data + b"\r\n")
                self.wfile.flush()

            def do_POST(self) -> None:
                path = urlsplit(self.path).path
                body = self._read_body()
                if path != _MESSAGES_PATH:
                    # count_tokens and anything else the stub doesn't model.
                    self._record_unexpected(path)
                    self._send_404()
                    return
                with stub._lock:
                    stub._request_count += 1
                    request_idx = stub._request_count
                    stub.capture.raw_bodies.append(body)
                    try:
                        stub.capture.requests.append(json.loads(body))
                    except (ValueError, UnicodeDecodeError):
                        stub.capture.requests.append(None)
                if request_idx <= len(stub.turns):
                    turn = stub.turns[request_idx - 1]
                else:
                    turn = Turn(text=_OVERFLOW_TEXT)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for name, payload in sse_events(turn, request_idx):
                    self._write_chunk(
                        f"event: {name}\ndata: {json.dumps(payload)}\n\n".encode("utf-8")
                    )
                self._write_chunk(b"")  # chunked terminator: 0\r\n\r\n

            def do_GET(self) -> None:
                self._record_unexpected(urlsplit(self.path).path)
                self._send_404()

            do_PUT = do_DELETE = do_PATCH = do_HEAD = do_GET

        self._httpd = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)

    @property
    def base_url(self) -> str:
        host, port = self._httpd.server_address[:2]
        return f"http://{host}:{port}"

    def __enter__(self) -> "StubServer":
        self._thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()
        self._thread.join(timeout=5)
