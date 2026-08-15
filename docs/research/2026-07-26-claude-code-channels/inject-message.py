#!/usr/bin/env python3
"""Post a user message into a running Claude Code session's inbox socket.

Usage:
    inject-message.py "text"                          # post to this session
    inject-message.py --socket /tmp/cc-socks/PID.sock --no-token "text"
    printf 'text' | inject-message.py --socket /tmp/cc-socks/PID.sock -

The target socket defaults to $CLAUDE_CODE_MESSAGING_SOCKET and the auth frame
to $CLAUDE_CODE_MESSAGING_TOKEN. Both are exported into hooks and Bash tool
calls by the session that owns them. The auth frame is sent only when a token
is available; it does not gate entry to the socket, it establishes the sender's
trust class, which is what the receiver's inbound gate judges. A script that
posts to its own session's socket and then exits should present the token on
macOS, where process evidence of the sender disappears with the process.

Those two defaults are a matched pair, so the token default is taken only when
the target really is this session: the environment's token authenticates as a
child of the session that owns the environment's socket, and it means nothing
to any other session. When --socket resolves to some other path, the ambient
token is dropped with a note on stderr rather than written to a stranger.
--token still sends a token you name explicitly, and --no-token suppresses the
frame outright.

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
from typing import NoReturn, Optional

MAX_FRAME_BYTES = 1024 * 1024  # the receiver drops the connection past this


def fail(message: str, code: int = 2) -> NoReturn:
    print(f"inject-message: {message}", file=sys.stderr)
    raise SystemExit(code)


def parse_args() -> argparse.Namespace:
    # add_help is off deliberately. With argparse's default `-h`, a message
    # that begins with a dash — "-hold the release" — is parsed as options:
    # the script prints help and exits 0 having sent nothing, which reads as
    # success to anything scheduling deliveries. Without it, such a message is
    # an unrecognized option and exits non-zero. allow_abbrev is off for the
    # same reason: it would otherwise make "--h", "--he" and "--hel" print help
    # too. A message of exactly "--help" is the one case still left, and `--`
    # sends that one — as it sends any message that begins with a dash.
    parser = argparse.ArgumentParser(
        add_help=False,
        allow_abbrev=False,
        description="Post a user message into a Claude Code session's inbox socket.",
        epilog="Pass - as the message to read it from stdin, and put -- before "
        "a message that begins with a dash.",
    )
    parser.add_argument(
        "--help", action="help", help="show this help message and exit"
    )
    parser.add_argument("message", help="message text, or - to read stdin")
    parser.add_argument(
        "--socket",
        default=os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET"),
        help="target socket path (default: $CLAUDE_CODE_MESSAGING_SOCKET)",
    )
    parser.add_argument(
        "--token",
        help="auth token; defaults to $CLAUDE_CODE_MESSAGING_TOKEN, but only "
        "when --socket resolves to this session's own socket",
    )
    parser.add_argument(
        "--no-token",
        action="store_true",
        help="send no auth frame at all, including one named by --token",
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


def resolve_token(args: argparse.Namespace) -> Optional[str]:
    """Decide which token, if any, to authenticate with.

    An explicit --token is honored as given. The environment's token is taken
    only when the target socket is the one that same environment names, since
    that is the only session it authenticates to; against any other socket it
    is a secret handed to a stranger for nothing.
    """
    if args.no_token:
        return None
    if args.token:
        return args.token

    env_token = os.environ.get("CLAUDE_CODE_MESSAGING_TOKEN")
    if not env_token:
        return None
    env_socket = os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET")
    if env_socket and os.path.realpath(args.socket) == os.path.realpath(
        env_socket
    ):
        return env_token

    print(
        "inject-message: --socket names a session other than this one; "
        "sending no auth frame. Pass --token to send one anyway.",
        file=sys.stderr,
    )
    return None


def main() -> int:
    args = parse_args()

    if not args.socket:
        fail(
            "no target socket. Pass --socket, or run where "
            "CLAUDE_CODE_MESSAGING_SOCKET is set (a hook or a Bash tool call "
            "inside a session with cross-session messaging)."
        )

    if args.message == "-":
        # Drop one trailing newline so `echo text | …` and `printf text | …`
        # put the same content on the wire.
        text = sys.stdin.read()
        if text.endswith("\n"):
            text = text[:-1]
    else:
        text = args.message
    if not text:
        fail("empty message; the receiver ignores a message with no content.")

    frames = []
    token = resolve_token(args)
    if token:
        frames.append({"type": "auth", "token": token})
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
    # Measured against the newline the receiver is scanning for: its buffer
    # holds the frame plus that terminator, so a frame of exactly
    # MAX_FRAME_BYTES bytes is still fine and one byte more is not.
    for line in payload.split(b"\n"):
        if len(line) > MAX_FRAME_BYTES:
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
