#!/usr/bin/env python3
"""Post a user message into a running Claude Code session's inbox socket.

Usage:
    inject-message.py "text"                          # post to this session
    inject-message.py --socket /tmp/cc-socks/PID.sock "text"
    printf 'text' | inject-message.py --socket /tmp/cc-socks/PID.sock -

The target socket defaults to $CLAUDE_CODE_MESSAGING_SOCKET and the auth frame
to $CLAUDE_CODE_MESSAGING_TOKEN. Both are exported into hooks and Bash tool
calls by the session that owns them. The auth frame is sent only when a token
is available; it does not gate entry to the socket, it establishes the sender's
trust class, which is what the receiver's inbound gate judges. A script that
posts to its own session's socket and then exits should present the token on
macOS, where process evidence of the sender disappears with the process.

Whether the receiving session delivers, holds, or drops the message is decided
there, by its `crossSessionInbound` setting or, when that is unset, by the two
sessions' permission-mode classes. A zero exit means the frames were written,
not that Claude read them.

Python 3 standard library only.
"""

import argparse
import json
import os
import socket
import sys
from typing import NoReturn

MAX_FRAME_BYTES = 1024 * 1024  # the receiver drops the connection past this


def fail(message: str, code: int = 2) -> NoReturn:
    print(f"inject-message: {message}", file=sys.stderr)
    raise SystemExit(code)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Post a user message into a Claude Code session's inbox socket.",
        epilog="Pass - as the message to read it from stdin.",
    )
    parser.add_argument("message", help="message text, or - to read stdin")
    parser.add_argument(
        "--socket",
        default=os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET"),
        help="target socket path (default: $CLAUDE_CODE_MESSAGING_SOCKET)",
    )
    parser.add_argument(
        "--token",
        default=os.environ.get("CLAUDE_CODE_MESSAGING_TOKEN"),
        help="auth token (default: $CLAUDE_CODE_MESSAGING_TOKEN)",
    )
    parser.add_argument(
        "--from",
        dest="sender",
        default="script",
        help="sender label shown to the receiver; asserted, not verified",
    )
    parser.add_argument(
        "--priority",
        choices=("now", "next", "later"),
        default="next",
        help="queue priority (default: next)",
    )
    parser.add_argument(
        "--session-id",
        help="drop the message unless the receiver has this session ID; "
        "guards against a reused pid",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    if not args.socket:
        fail(
            "no target socket. Pass --socket, or run where "
            "CLAUDE_CODE_MESSAGING_SOCKET is set (a hook or a Bash tool call "
            "inside a session with cross-session messaging)."
        )

    text = sys.stdin.read() if args.message == "-" else args.message
    if not text:
        fail("empty message; the receiver ignores a message with no content.")

    frames = []
    if args.token:
        frames.append({"type": "auth", "token": args.token})
    user_frame = {
        "type": "user",
        "from": args.sender,
        "priority": args.priority,
        "message": {"role": "user", "content": text},
    }
    if args.session_id:
        user_frame["session_id"] = args.session_id
    frames.append(user_frame)

    payload = b"".join(
        json.dumps(frame).encode("utf-8") + b"\n" for frame in frames
    )
    for line in payload.split(b"\n"):
        if len(line) + 1 > MAX_FRAME_BYTES:
            fail(
                f"frame is {len(line)} bytes; the receiver drops any connection "
                f"whose line exceeds {MAX_FRAME_BYTES} bytes."
            )

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.connect(args.socket)
            sock.sendall(payload)
    except FileNotFoundError:
        fail(
            f"no socket at {args.socket}. The session may have exited, or it "
            "may be one that binds no socket (bare mode)."
        )
    except ConnectionRefusedError:
        fail(
            f"connection refused at {args.socket}. The socket file is stale — "
            "its session is gone."
        )
    except PermissionError:
        fail(
            f"permission denied on {args.socket}. Sockets are mode 0600 and "
            "restricted to the OS user that owns the session."
        )
    except OSError as error:
        fail(f"could not write to {args.socket}: {error}")

    print(f"posted {len(payload)} bytes to {args.socket}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
