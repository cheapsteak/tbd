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
into idle and load bands and never pools them.

ONE invocation has to span both bands. The flatness verdict is p90 load over
p90 idle, computed from the single capture and the single load map this run
produces, so a band that is empty here cannot be filled by another run: start
at idle and induce load partway through, or run long enough to cross a load
change. Nothing heavy may run during the idle stretch, and no build may run at
any point.

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
REQUEST_PREFIX = "terminal-latency-probe."
REQUEST_SUFFIX = ".json"
ARMS = ("tmux", "holder")


def load_report_module():
    """Import the sibling report script as a module.

    Registered in `sys.modules` before `exec_module`: a `@dataclass(slots=True)`
    resolves its own module out of `sys.modules` at class-creation time, so an
    unregistered module raises `AttributeError: 'NoneType' object has no
    attribute '__dict__'` on Python 3.12+.
    """
    spec = importlib.util.spec_from_file_location("terminal_latency_report", REPORT_PATH)
    if spec is None or spec.loader is None:
        raise SystemExit(
            f"cannot import {REPORT_PATH} — this driver only reports through it."
        )
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


# A daemon that is wedged, or a `log show` against a store this run has filled,
# would otherwise hang this script with no output and no way to tell it apart
# from a long capture. Both bounds are far above what either call takes when it
# is healthy, so neither can fire on a slow-but-working machine.
TERMINAL_LIST_TIMEOUT_SECONDS = 30
LOG_SHOW_TIMEOUT_SECONDS = 120


def terminal_rows(tbd: str, worktree: str) -> list[dict]:
    try:
        result = subprocess.run(
            [tbd, "terminal", "list", "--json", worktree],
            check=True,
            capture_output=True,
            text=True,
            timeout=TERMINAL_LIST_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        raise SystemExit(
            f"`{tbd} terminal list --json {worktree}` did not answer within"
            f" {TERMINAL_LIST_TIMEOUT_SECONDS}s. The daemon is probably wedged or not"
            " running; nothing has been written to any terminal."
        ) from None
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


def request_path(directory: Path, seq: int) -> Path:
    """This request's own file. The counter is zero-padded so the app, which
    consumes what it finds in NAME order, consumes them in request order."""
    return directory / f"{REQUEST_PREFIX}{seq:06d}{REQUEST_SUFFIX}"


def write_request(directory: Path, terminal_id: str, seq: int) -> None:
    """Publish one request atomically, under a name no other request uses.

    Written to a temp name in the SAME directory and `os.rename`d into place:
    the app watches the directory for writes and reads the file the moment it
    appears, so a partially written file would be read as malformed. A rename
    within one directory is atomic.

    One file per request, rather than one path renamed over and over. A single
    path silently loses a request whenever two renames land between two of the
    app's main-queue turns — both events name one path, so only the second
    survives — and it makes this script's own cleanup a race against the app's
    read of the last request. Distinct names remove both: nothing overwrites
    anything, and cleanup can wait until the app has had its turn.
    """
    payload = json.dumps({"terminalID": terminal_id, "seq": seq})
    handle, temp_path = tempfile.mkstemp(dir=directory, prefix=".probe-", suffix=".json")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(payload)
        os.rename(temp_path, request_path(directory, seq))
    except BaseException:
        # A temp file left behind would sit in the runtime directory forever;
        # request files themselves are removed by the app, and by our own
        # cleanup for any the app never saw.
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass
        raise


def remove_request_files(directory: Path) -> None:
    """Remove every request file left in the directory, and nothing else.

    Matched by the prefix and suffix the app matches on: the runtime directory
    is shared (`claude-overlay.json` lives there), so a cleanup that swept the
    directory would delete somebody else's state.
    """
    for entry in directory.iterdir():
        if entry.name.startswith(REQUEST_PREFIX) and entry.name.endswith(REQUEST_SUFFIX):
            try:
                entry.unlink()
            except FileNotFoundError:
                pass


def capture_log(since: datetime.datetime) -> str:
    stamp = since.strftime("%Y-%m-%d %H:%M:%S")
    try:
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
            timeout=LOG_SHOW_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        raise SystemExit(
            f"`log show` did not return within {LOG_SHOW_TIMEOUT_SECONDS}s, so this run"
            " has no capture to report. The samples were taken and are in the log store;"
            " re-run `log show --start"
            f" '{stamp}' --info --predicate 'subsystem == \"com.tbd.app\" AND category =="
            " \"terminallatency\"'` by hand and pipe it to terminal-latency-report.py."
        ) from None
    return result.stdout


def run_samples(
    directory: Path,
    terminals: dict[str, str],
    samples: int,
    gap_ms: float,
    load_map: dict[str, dict[str, float]],
    requested: dict[str, int],
) -> None:
    """Interleave the arms A/B/B/A..., one request at a time.

    A/B/B/A rather than a plain alternation: a strict A,B,A,B order gives one
    arm every odd position, so any slow drift in machine state over the run
    lands on the arms unequally. The paired-reversed order cancels a linear
    drift to first order, which is the shape a machine warming up under a
    background task actually has.

    The app holds at most one pending token per panel and retires an older one
    as lost, so requests are never overlapped within an arm.

    `load_map` and `requested` are OWNED BY THE CALLER and filled in place. An
    interrupt is the normal way a long run ends, and a return value would take
    every reading taken before it with it — the caller would then report a full
    capture against an empty map, banding every sample as unknown-load.
    """
    gap = gap_ms / 1000.0
    seq = 0
    for index in range(samples):
        order = ARMS if index % 2 == 0 else tuple(reversed(ARMS))
        for arm in order:
            seq += 1
            # Counted before the write and recorded after it, so a request
            # interrupted mid-write leaves the two disagreeing — which is what
            # `main` refuses to band on, rather than silently banding a sample
            # whose load it never saw.
            requested[arm] += 1
            load = os.getloadavg()[0]
            write_request(directory, terminals[arm], seq)
            load_map[arm][str(seq)] = load
            time.sleep(gap)


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
    # run's first sample: the counter restarts at 1 every run, so an old file
    # can carry a name this run is about to reuse.
    remove_request_files(directory)

    interrupted = False

    def on_sigint(_signum, _frame):
        nonlocal interrupted
        interrupted = True
        raise KeyboardInterrupt

    previous_handler = signal.signal(signal.SIGINT, on_sigint)

    started = datetime.datetime.now() - datetime.timedelta(seconds=2)
    # Owned here, not returned: an interrupt must not take the readings with
    # it. Everything recorded up to the interrupt is still a measurement.
    load_map: dict[str, dict[str, float]] = {arm: {} for arm in ARMS}
    requested: dict[str, int] = {arm: 0 for arm in ARMS}
    try:
        run_samples(directory, terminals, args.samples, args.gap_ms, load_map, requested)
    except KeyboardInterrupt:
        print("\ninterrupted — reporting what was collected", file=sys.stderr)
    finally:
        signal.signal(signal.SIGINT, previous_handler)

    # The last request needs to make its round trip and reach the log store,
    # and the app has to get a main-queue turn to read it at all. Cleanup comes
    # AFTER that wait, never before: a file deleted while the app has not yet
    # turned takes the last sample with it, and the completeness check below
    # then refuses the whole run over a request the app never got to see.
    try:
        time.sleep(1.0)
    except KeyboardInterrupt:
        # The handler above is restored by now, so a SECOND Ctrl-C lands here
        # as a plain KeyboardInterrupt. Swallowed on purpose: everything
        # already collected is still a measurement, and letting it out would
        # skip the capture and the report entirely — the opposite of what a
        # second interrupt means, which is "stop waiting", not "throw the run
        # away". The last sample may be missing from the capture, and the
        # completeness check below is what says so.
        print("\ninterrupted — reporting what was collected", file=sys.stderr)
    finally:
        # Every exit path, including an interrupt inside the settle: a request
        # file left behind is read by the app at its next directory event, long
        # after this run.
        remove_request_files(directory)
    text = capture_log(started)
    capture = report_module.parse(text.splitlines())

    if args.keep_load_map:
        Path(args.keep_load_map).write_text(json.dumps(load_map, indent=2), encoding="utf-8")

    # An arm whose echoes do not match its requests is not reportable: the
    # missing samples are not random, they are whatever the machine was doing
    # when they went missing.
    # Counted exactly as `report()` counts them: by transport AND by the id
    # this arm named, case-insensitively. A capture is the whole app's window,
    # so another panel on the same transport would otherwise pay this arm's
    # debts — and an arm that answered nothing could read as complete.
    incomplete = []
    answered_counts: dict[str, int] = {}
    for arm in ARMS:
        wanted = terminals[arm].lower()
        answered = len([
            e for e in capture.echoes
            if e.transport == arm and e.terminal.lower() == wanted
        ])
        answered_counts[arm] = answered
        if requested[arm] and answered != requested[arm]:
            incomplete.append(f"{arm}: {answered} echoes for {requested[arm]} requests")

    # An arm with a load reading missing for some request cannot be banded:
    # the samples it would put in a band are not the samples it measured. Drop
    # that arm's readings so the report shows them as unbanded rather than
    # quietly assigning them a load nobody recorded.
    for arm in ARMS:
        if requested[arm] != len(load_map[arm]):
            print(
                f"\nNOT BANDING {arm}: {requested[arm]} request(s) issued but"
                f" {len(load_map[arm])} load reading(s) recorded — a sample whose load"
                " is unknown belongs to neither band, so this arm's figures are"
                " reported pooled.",
                file=sys.stderr,
            )
            load_map[arm] = {}

    # An interrupt explains EXACTLY ONE missing echo per arm: the request that
    # was in flight when Ctrl-C landed. It does not explain two, and it does
    # not explain an arm that answered more than it was asked — those are the
    # same unexplained mismatch an uninterrupted run refuses to report, and a
    # run that stopped early is not a licence to publish them as ordinary
    # figures. So the interrupt widens the tolerance by one sample; it does not
    # remove the check.
    explained_by_interrupt = interrupted and all(
        0 <= requested[arm] - answered_counts[arm] <= 1 for arm in ARMS
    )

    # Whatever else happens, a reader of an interrupted run's figures must know
    # it was interrupted BEFORE they read a number. The banner names each arm's
    # counts, goes to stderr, and is handed to the report so it sits in the
    # header above the table too.
    note = None
    if interrupted:
        counts = ", ".join(
            f"{arm} {answered_counts[arm]}/{requested[arm]}" for arm in ARMS
        )
        note = (
            "!!!!  INTERRUPTED — this run did not finish. Answered/requested: "
            + counts
            + "  !!!!"
        )
        print(f"\n{note}", file=sys.stderr)

    if incomplete and not explained_by_interrupt:
        print("\nREFUSING TO REPORT — an arm's echoes do not match its requests:", file=sys.stderr)
        for line in incomplete:
            print(f"  {line}", file=sys.stderr)
        print(
            "\nLikely causes, in the order worth checking:\n"
            "  - the diagnostic is off, or the app was not relaunched after enabling it\n"
            "  - the terminal id names a panel that is not open in the app right now\n"
            "  - the named terminal is not a plain shell, so the app refused the request\n"
            "    (look for `echorefused` lines in the capture)\n"
            "  - the panel's holder attach came apart, so its writes reach nothing\n"
            "    (`reason=noview`, or `reason=unwritable` once the child has exited)\n"
            "  - the session is not echoing: run `cat` in it, not a full-screen TUI",
            file=sys.stderr,
        )
        # Unfiltered on purpose: a refusal the app could not attribute to a
        # terminal (`reason=malformed`) names no id, and this is the one place
        # it has to be visible.
        refusals = capture.refusal_counts()
        if refusals:
            print(f"  refusals seen: {refusals}", file=sys.stderr)
        return 1

    # The capture is the whole app's window, so it holds every panel that was
    # open. Only these two were probed; anything else in it is another panel's
    # traffic and would pool into the arm it shares a transport with.
    report_module.report(
        capture,
        idle_max=args.idle_max,
        load_map=load_map,
        terminals=set(terminals.values()),
        note=note,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
