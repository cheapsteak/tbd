#!/usr/bin/env python3
"""Drive a paired terminal-transport latency run inside TBDApp and report it.

WHAT THIS MEASURES
------------------
One number per sample: a token written through a terminal panel's REAL
keystroke path, stamped again when its first copy comes back at the app's feed
seam. Both ends are taken inside TBDApp, on one monotonic clock, by the same
code on both transports -- so a tmux sample and a holder sample are comparable
by construction rather than by argument. The loop spans the pty, the line
discipline, and on tmux the server. That span is the transport.

Alongside it the app emits a passive per-draw line: how long the oldest chunk
in a frame sat parsed-but-undrawn. That number is identical in mechanism on
both arms, so it is the CHECK on the echo comparison -- if the two arms' draw
waits disagree, the arms are not being measured the same way and the echo
comparison is suspect. The report prints both.

WHAT IT CANNOT SHOW
-------------------
- Pixels. The draw endpoint is the start of a draw; nothing here covers the
  compositor.
- An agent's response. `cat` echo is the line discipline (or tmux) answering,
  not a TUI repainting. That is the point -- the transport's cost is isolated
  from the program's -- but it says nothing about how fast Claude Code redraws.
- The wait before the app's read, except through the echo. Bytes queue in the
  kernel before the reader thread wakes, and that queue is a different object
  on each arm.
- Anything under the Metal renderer or on the control-mode attach path.

THE RUN RULE: A/B/A AND LOAD BANDS
----------------------------------
On this machine a load swing from 7 to 139 once faked a threefold effect that
vanished under matched load. So this driver INTERLEAVES the arms sample by
sample -- both arms see the same machine, sample for sample -- and records
`os.getloadavg()[0]` alongside every request. The report splits echo figures
into idle and load bands and never pools them. Nothing heavy may run on the
machine during an idle arm, and no build may run during either.

SETUP THIS DRIVER CANNOT DO FOR YOU
-----------------------------------
1. `defaults write TBDApp enableTerminalLatencyDiagnostic -bool true`, then
   relaunch the app with `scripts/restart.sh`. The gate resolves once at
   launch; flipping it under a running app does nothing.
2. Two `cat` shell terminals in a scratch worktree: one spawned with
   `Config.ptyHolderDefault` off (tmux) and one with it on (holder). The flag
   is read at spawn, so a holder session exists only if it was on then.
3. Pass their ids. This driver verifies each one's transport and kind from the
   daemon before the first sample and refuses anything that is not a plain
   shell -- it types into terminals, and an agent session must never be one of
   them.

USAGE
-----
    scripts/diag/terminal-latency-probe.py \\
        --worktree my-scratch \\
        --tmux-terminal <uuid> --holder-terminal <uuid> \\
        --samples 200 --gap-ms 250 --idle-max 8
"""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPORT_PATH = HERE / "terminal-latency-report.py"
REQUEST_FILENAME = "terminal-latency-probe.json"
ARMS = ("tmux", "holder")


def load_report_module():
    """Import the sibling report script as a module.

    Registered in `sys.modules` before `exec_module`: a `@dataclass(slots=True)`
    resolves its own module out of `sys.modules` at class-creation time, so an
    unregistered module raises `AttributeError: 'NoneType' object has no
    attribute '__dict__'` on Python 3.12+.
    """
    spec = importlib.util.spec_from_file_location("terminal_latency_report", REPORT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules["terminal_latency_report"] = module
    spec.loader.exec_module(module)
    return module


def tbd_home() -> Path:
    """TBD's config directory, honouring `TBD_HOME` exactly as the app does."""
    override = os.environ.get("TBD_HOME")
    return Path(override) if override else Path.home() / "tbd"


def runtime_dir() -> Path:
    return tbd_home() / "runtime"


def terminal_rows(tbd: str, worktree: str) -> list[dict]:
    result = subprocess.run(
        [tbd, "terminal", "list", "--json", worktree],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def verify(rows: list[dict], terminal_id: str, expected_transport: str) -> dict:
    """Refuse anything that is not a plain shell on the expected transport.

    This is the driver's half of the refusal the app also enforces. Both exist:
    the app's is the guarantee, this one is the early, readable failure -- and
    it is what keeps the run from silently measuring the wrong session.
    """
    wanted = terminal_id.lower()
    for row in rows:
        if str(row.get("id", "")).lower() != wanted:
            continue
        kind = row.get("kind")
        transport = row.get("transport")
        if kind != "shell":
            raise SystemExit(
                f"terminal {terminal_id} is kind={kind!r}, not a plain shell."
                " This probe writes keystrokes; it will not type into an agent session."
            )
        if transport != expected_transport:
            raise SystemExit(
                f"terminal {terminal_id} is on transport={transport!r},"
                f" but was given as the {expected_transport} arm."
                " A holder session exists only if the pty-holder flag was on when it spawned."
            )
        return row
    raise SystemExit(
        f"terminal {terminal_id} is not in this worktree's terminal list."
        " Check the id and the worktree."
    )


def write_request(directory: Path, terminal_id: str, seq: int) -> None:
    """Publish one request atomically.

    Written to a temp name in the SAME directory and `os.rename`d into place:
    the app watches the directory for writes and reads the file the moment it
    appears, so a partially written file would be read as malformed. A rename
    within one directory is atomic.
    """
    payload = json.dumps({"terminalID": terminal_id, "seq": seq})
    handle, temp_path = tempfile.mkstemp(dir=directory, prefix=".probe-", suffix=".json")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(payload)
        os.rename(temp_path, directory / REQUEST_FILENAME)
    except BaseException:
        # A temp file left behind would sit in the runtime directory forever;
        # the request file itself is removed by the app, and by our own
        # cleanup if the app never saw it.
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass
        raise


def remove_request(directory: Path) -> None:
    try:
        os.unlink(directory / REQUEST_FILENAME)
    except FileNotFoundError:
        pass


def capture_log(since: datetime.datetime) -> str:
    stamp = since.strftime("%Y-%m-%d %H:%M:%S")
    result = subprocess.run(
        [
            "log",
            "show",
            "--start",
            stamp,
            "--info",
            "--predicate",
            'subsystem == "com.tbd.app" AND category == "terminallatency"',
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def run_samples(
    directory: Path, terminals: dict[str, str], samples: int, gap_ms: float
) -> dict[str, dict[str, float]]:
    """Interleave the arms A/B/B/A..., one request at a time.

    A/B/B/A rather than a plain alternation: a strict A,B,A,B order gives one
    arm every odd position, so any slow drift in machine state over the run
    lands on the arms unequally. The paired-reversed order cancels a linear
    drift to first order, which is the shape a machine warming up under a
    background task actually has.

    The app holds at most one pending token per panel and retires an older one
    as lost, so requests are never overlapped within an arm.
    """
    load_map: dict[str, dict[str, float]] = {arm: {} for arm in ARMS}
    gap = gap_ms / 1000.0
    seq = 0
    for index in range(samples):
        order = ARMS if index % 2 == 0 else tuple(reversed(ARMS))
        for arm in order:
            seq += 1
            load_map[arm][str(seq)] = os.getloadavg()[0]
            write_request(directory, terminals[arm], seq)
            time.sleep(gap)
    return load_map


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Drive a paired terminal-transport latency run and report it.",
    )
    parser.add_argument("--worktree", required=True, help="Worktree name or id holding both terminals.")
    parser.add_argument("--tmux-terminal", required=True, help="Terminal id of the tmux arm.")
    parser.add_argument("--holder-terminal", required=True, help="Terminal id of the holder arm.")
    parser.add_argument("--samples", type=int, default=200, help="Samples per arm (default 200).")
    parser.add_argument("--gap-ms", type=float, default=250.0, help="Gap between requests, ms (default 250).")
    parser.add_argument(
        "--idle-max",
        type=float,
        default=8.0,
        help="1-minute load at or below which a sample counts as idle (default 8).",
    )
    parser.add_argument("--tbd", default="tbd", help="Path to the tbd CLI (default: tbd on PATH).")
    parser.add_argument(
        "--keep-load-map",
        help="Also write the per-sample load map to this path, for a later re-report.",
    )
    args = parser.parse_args()

    if args.samples < 1:
        raise SystemExit("--samples must be at least 1")

    report_module = load_report_module()

    directory = runtime_dir()
    if not directory.is_dir():
        raise SystemExit(
            f"{directory} does not exist. The app creates it when the diagnostic is on —"
            " enable `enableTerminalLatencyDiagnostic` and relaunch TBDApp first."
        )

    rows = terminal_rows(args.tbd, args.worktree)
    terminals = {"tmux": args.tmux_terminal, "holder": args.holder_terminal}
    for arm, terminal_id in terminals.items():
        verify(rows, terminal_id, arm)

    # A stale request from an interrupted earlier run would be read as this
    # run's first sample.
    remove_request(directory)

    interrupted = False

    def on_sigint(_signum, _frame):
        nonlocal interrupted
        interrupted = True
        raise KeyboardInterrupt

    previous_handler = signal.signal(signal.SIGINT, on_sigint)

    started = datetime.datetime.now() - datetime.timedelta(seconds=2)
    load_map: dict[str, dict[str, float]] = {arm: {} for arm in ARMS}
    try:
        load_map = run_samples(directory, terminals, args.samples, args.gap_ms)
    except KeyboardInterrupt:
        print("\ninterrupted — reporting what was collected", file=sys.stderr)
    finally:
        # Every exit path, including the interrupt: a request file left behind
        # is read by the app at its next directory event, long after this run.
        remove_request(directory)
        signal.signal(signal.SIGINT, previous_handler)

    # The last request needs to make its round trip and reach the log store.
    time.sleep(1.0)
    text = capture_log(started)
    capture = report_module.parse(text.splitlines())

    if args.keep_load_map:
        Path(args.keep_load_map).write_text(json.dumps(load_map, indent=2), encoding="utf-8")

    # An arm whose echoes do not match its requests is not reportable: the
    # missing samples are not random, they are whatever the machine was doing
    # when they went missing.
    incomplete = []
    for arm in ARMS:
        requested = len(load_map[arm])
        answered = len([e for e in capture.echoes if e.transport == arm])
        if requested and answered != requested:
            incomplete.append(f"{arm}: {answered} echoes for {requested} requests")

    if incomplete and not interrupted:
        print("\nREFUSING TO REPORT — an arm's echoes do not match its requests:", file=sys.stderr)
        for line in incomplete:
            print(f"  {line}", file=sys.stderr)
        print(
            "\nLikely causes, in the order worth checking:\n"
            "  - the diagnostic is off, or the app was not relaunched after enabling it\n"
            "  - the terminal id names a panel that is not open in the app right now\n"
            "  - the named terminal is not a plain shell, so the app refused the request\n"
            "    (look for `echorefused` lines in the capture)\n"
            "  - the session is not echoing: run `cat` in it, not a full-screen TUI",
            file=sys.stderr,
        )
        if capture.refused:
            print(f"  refusals seen: {dict(capture.refused)}", file=sys.stderr)
        return 1

    report_module.report(capture, idle_max=args.idle_max, load_map=load_map)
    return 0


if __name__ == "__main__":
    sys.exit(main())
