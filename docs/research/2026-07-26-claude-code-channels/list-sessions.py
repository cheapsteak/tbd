#!/usr/bin/env python3
"""List live Claude Code sessions from the on-disk session registry.

Usage:
    list-sessions.py
    list-sessions.py --json
    list-sessions.py --registry /path/to/config/sessions

Each session writes a `<pid>.json` row under `$CLAUDE_CONFIG_DIR/sessions`
(`~/.claude/sessions` when that variable is unset) describing itself: pid,
session ID, cwd, version, name and coarse status, and — on most rows, not all
— the path of its inbox socket. Rows whose process is gone are stale; this
script skips them.

The registry lives under the config directory, so it fragments per config
directory: a session started with a different `CLAUDE_CONFIG_DIR` writes its
row somewhere this script will not look unless you point `--registry` there.
The socket directory does not fragment — it is per OS user.

Liveness here is only "a process with that pid exists". A row whose session
died can be resurrected by an unrelated process inheriting its pid, so treat a
listed socket as a candidate rather than a confirmed target. The row's
`procStart` is the discriminator if you need to be sure, and posting a message
with the row's `sessionId` as the frame's `session_id` makes the receiver drop
a misaddressed message rather than act on it.

Python 3 standard library only.
"""

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional


def registry_dir(override: Optional[str]) -> Path:
    if override:
        return Path(override).expanduser()
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    base = Path(config_dir).expanduser() if config_dir else Path.home() / ".claude"
    return base / "sessions"


def process_alive(pid: int) -> bool:
    # pid 0 would signal the caller's whole process group, and bool is an int
    # subclass, so both are rejected before os.kill sees them.
    if isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # exists, owned by another user
    except OverflowError:
        # Too large for a C int. OverflowError is not an OSError, so it would
        # otherwise escape and take down the whole listing over one bad row.
        return False
    except OSError:
        return False
    return True


def read_rows(directory: Path) -> list:
    rows = []
    for path in sorted(directory.glob("*.json")):
        try:
            row = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(row, dict):
            continue
        pid = row.get("pid")
        if not isinstance(pid, int) or not process_alive(pid):
            continue
        rows.append(row)
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(
        description="List live Claude Code sessions and their inbox sockets."
    )
    parser.add_argument(
        "--registry",
        help="registry directory (default: $CLAUDE_CONFIG_DIR/sessions, "
        "else ~/.claude/sessions)",
    )
    parser.add_argument(
        "--json", action="store_true", help="emit the raw rows as a JSON array"
    )
    args = parser.parse_args()

    directory = registry_dir(args.registry)
    if not directory.is_dir():
        print(
            f"list-sessions: no registry at {directory}. Set CLAUDE_CONFIG_DIR "
            "or pass --registry.",
            file=sys.stderr,
        )
        return 2

    rows = read_rows(directory)

    if args.json:
        json.dump(rows, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    if not rows:
        print(f"No live sessions in {directory}.")
        return 0

    for row in sorted(rows, key=lambda r: r["pid"]):
        socket_path = row.get("messagingSocketPath") or "(no socket)"
        print(f'{row["pid"]}  {row.get("name", "?")}  [{row.get("status", "?")}]')
        print(f'    cwd:    {row.get("cwd", "?")}')
        print(f"    socket: {socket_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
