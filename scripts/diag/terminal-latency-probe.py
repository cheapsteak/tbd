#!/usr/bin/env python3
"""Drive a paired terminal latency run inside TBDApp and report it.

It has two modes, with one run rule. TRANSPORT MODE (`--tmux-terminal`,
`--holder-terminal`) compares the two terminal transports. ENGINE MODE
(`--swiftterm-terminal`, `--ghostty-terminal`) compares the two terminal
engines on the holder transport. One run is one mode; the flags of the two
cannot be combined.

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
both transports, so it is the CHECK on the echo comparison -- if the two arms'
draw waits disagree, the arms are not being measured the same way and the echo
comparison is suspect. The report prints both.

ENGINE MODE
-----------
Both arms are holder terminals, one on SwiftTerm and one on libghostty
(`docs/specs/2026-11-07-libghostty-terminal-engine-design.md`), and the two
numbers swap roles. The token enters the outbound path after the engine's own
key handling, and its copy is stamped at the feed seam before the engine
parses it, so the echo is the same loop on both arms: in this mode it is the
CHECK. A gap between the arms' echoes means unmatched arms, or an engine that
keeps the app's main or reader thread busy. The draw wait runs from the feed
seam, parse included, to the engine's own draw start, so it is where the
engines' own work shows. A draw line carries no sequence number, so the
driver records when it issued each request, and the report places each draw
in a load band by time.

WHAT IT CANNOT SHOW
-------------------
- Pixels. The draw endpoint is the start of a draw; nothing here covers the
  compositor.
- An agent's response. `cat` echo is the line discipline (or tmux) answering,
  not a TUI repainting. That is the point -- the transport's cost is isolated
  from the program's -- but it says nothing about how fast Claude Code redraws.
- The wait before the app's read, except through the echo. Bytes queue in the
  kernel before the reader thread wakes, and that queue is a different object
  on each transport.
- A draw wait under SwiftTerm's Metal renderer, which emits no draw lines, or
  anything on the control-mode attach path. libghostty always draws with
  Metal, and does emit draw lines.

THE RUN RULE: A/B/A AND LOAD BANDS
----------------------------------
On this machine a load swing from 7 to 139 once faked a threefold effect that
vanished under matched load. So this driver INTERLEAVES the arms sample by
sample -- both arms see the same machine, sample for sample -- and records
`os.getloadavg()[0]` alongside every request. The report splits echo figures
into idle and load bands and never pools them; in engine mode it splits the
draw waits too. Both modes follow this rule.

ONE invocation has to span both bands. The flatness verdict is p90 load over
p90 idle, computed from the single capture and the single load map this run
produces, so a band that is empty here cannot be filled by another run: start
at idle and induce load partway through, or run long enough to cross a load
change. Nothing heavy may run during the idle stretch, and no build may run at
any point.

HOW ENGINE MODE CONFIRMS EACH ARM'S ENGINE
------------------------------------------
The daemon's terminal rows do not record an engine, and the latency lines do
not name one. So samples go to an arm by terminal id, and each id's engine is
read from the app's own log (`com.tbd.app`, category `terminalEngine`), from
the running TBDApp's launch until now. While the libghostty engine is on, the
app logs a `.notice` line for every terminal build, naming the engine that
build got. A switch's rebuild and a build that fell back log one too. The app
also logs a line whenever the engine's flag changes, at launch included:

    libghostty engine active for <id>
    SwiftTerm engine active for <id>
    libghostty engine unavailable for <id>, fell back to SwiftTerm: <reason>
    libghostty engine experiment turned on
    libghostty engine experiment turned off

`TerminalEngineNotice` in `Sources/TBDApp/Terminal/Engine/
TerminalEngineFactory.swift` holds these words, and its tests pin them.

The latest build line for an id decides its engine. The log store keeps
`.notice` lines longest and drops its oldest lines first, so the latest line
it holds is the terminal's last build. Lines from an earlier app process are
ignored, because a relaunch rebuilds every panel. An app build too old to log
the SwiftTerm line never confirms a SwiftTerm arm, so the check refuses every
run against it.

A build while the engine is off logs nothing, so a libghostty panel rebuilt
then becomes SwiftTerm while its latest line still says libghostty. Two checks
close that gap. The flag itself must read as on, the way the app reads it, in
the app's own defaults domain (`com.github.cheapsteak.tbd` for an app inside a
`.app` bundle, `TBDApp` for an unbundled build). The app takes a boolean, or a
number that is exactly 1 or 0, as the value it holds. An unset key, or any
other value, follows the shipped default, which is on. That includes a string
"1", which `defaults read` prints just as it prints a boolean. And no flag line
may come after an arm's latest build line: the flag was off at some point
since.

The run is refused before any keystroke when the flag is not on, no build
line names an arm's id, the latest one names the other engine, or a flag line
follows it. After the run the flag and the lines are read again, and the
report is refused when the flag is off, a flag line landed, or either arm's
latest build line has changed: an arm that was rebuilt during the run, even
on the same engine, does not hold one panel's samples.

Why the log, and not the caller's word: an A/B that measured one engine twice
by mistake looks like a flat result, and a flat result decides the engine's
future. `--trust-engines` skips the log check, for when the app's log cannot
answer. It prints a banner on stderr and above the report's figures, and the
caller then vouches for each arm from its tab's engine label. The flag check
still runs, since a tab shows no engine label while the flag is off.

SETUP THIS DRIVER CANNOT DO FOR YOU
-----------------------------------
1. `defaults write com.github.cheapsteak.tbd enableTerminalLatencyDiagnostic
   -bool true`, then relaunch the app with `scripts/restart.sh`. The gate
   resolves once at launch; flipping it under a running app does nothing. An
   unbundled `swift run` build reads the `TBDApp` domain instead.
2. Two `cat` shell terminals in a scratch worktree.
   - Transport mode: one on tmux and one on the holder. TBD opens every new
     session on the holder, so the tmux arm has to be a session that predates
     that and has not been moved by `tbd terminal migrate`.
   - Engine mode: two holder terminals, opened while Settings > Terminal >
     Experimental > "Use the libghostty terminal engine" is on, so the app
     logs which engine each one got. Both open on libghostty. Focus one and
     press ⌃⌘E (Terminal > Switch Terminal Engine): it is rebuilt on
     SwiftTerm, its tab label reads SwiftTerm, and it is the SwiftTerm arm.
     While the engine is on, that press is how a holder terminal gets onto
     SwiftTerm. The check reads the rebuild's own line, not the press. Leave
     the engine on until the run ends.
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

    scripts/diag/terminal-latency-probe.py \\
        --worktree my-scratch \\
        --swiftterm-terminal <uuid> --ghostty-terminal <uuid> \\
        --samples 200 --gap-ms 250 --idle-max 8

Either engine-mode terminal flag selects engine mode. Without one, `--help`
lists transport mode's arguments alone; with one, it lists engine mode's.
"""

from __future__ import annotations

import argparse
import datetime
import importlib.util
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

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


# Engine mode's arms, in A/B order, and the one transport both are on, as the
# report labels its figures and looks the load map up by them. `main` loads
# the report again for its run, so `report()` writes to the stdout of that run.
_report_at_import = load_report_module()
ENGINE_ARMS = _report_at_import.ENGINES
ENGINE_TRANSPORT = _report_at_import.ENGINE_TRANSPORT


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


def verify(
    rows: list[dict], terminal_id: str, expected_transport: str, arm: str | None = None
) -> dict:
    """Refuse anything that is not a plain shell on the expected transport.

    This is the driver's half of the refusal the app also enforces. Both exist:
    the app's is the guarantee, this one is the early, readable failure -- and
    it is what keeps the run from silently measuring the wrong session.

    `arm` names the arm. In transport mode it is the transport itself; it
    differs only in engine mode, where both arms must be on the holder
    transport.
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
            if arm is not None and arm != expected_transport:
                raise SystemExit(
                    f"terminal {terminal_id} is on transport={transport!r},"
                    f" but was given as the {arm} arm, and an engine comparison runs"
                    f" both arms on the {expected_transport} transport."
                    " Every new session opens on the pty holder; a tmux session predates that."
                )
            raise SystemExit(
                f"terminal {terminal_id} is on transport={transport!r},"
                f" but was given as the {expected_transport} arm."
                " Every new session opens on the pty holder; a tmux session predates that."
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


# The full path: `log` is a shell builtin in zsh, and this script, and the
# command it prints for a re-run, must reach the macOS tool whatever runs them.
LOG_BINARY = "/usr/bin/log"
APP_SUBSYSTEM = "com.tbd.app"
LATENCY_CATEGORY = "terminallatency"


def log_show(start: datetime.datetime, options: list[str], category: str, consequence: str) -> str:
    """The app's lines in `category` from `start` until now.

    A `log show` that times out or fails ends the run, naming the command,
    how it failed and what that leaves undone: `consequence`.
    """
    command = [
        LOG_BINARY,
        "show",
        "--start",
        start.astimezone().strftime("%Y-%m-%d %H:%M:%S"),
        *options,
        "--predicate",
        f'subsystem == "{APP_SUBSYSTEM}" AND category == "{category}"',
    ]
    try:
        result = subprocess.run(
            command, check=True, capture_output=True, text=True, timeout=LOG_SHOW_TIMEOUT_SECONDS
        )
    except subprocess.TimeoutExpired:
        failure = f"did not return within {LOG_SHOW_TIMEOUT_SECONDS}s"
    except subprocess.CalledProcessError as error:
        failure = f"failed (exit {error.returncode}: {error.stderr.strip()})"
    else:
        return result.stdout
    raise SystemExit(f"`{shlex.join(command)}` {failure}, so {consequence}")


def capture_log(since: datetime.datetime) -> str:
    """The latency lines, `.info` included, for the report."""
    return log_show(
        since,
        ["--info"],
        LATENCY_CATEGORY,
        "this run has no capture to report. The samples were taken and are in the log store;"
        " re-run that command by hand and pipe it to terminal-latency-report.py.",
    )


# ---------------------------------------------------------------------------
# Engine mode: which engine each arm's terminal is on, from the app's log
# ---------------------------------------------------------------------------

APP_PROCESS_NAME = "TBDApp"
ENGINE_CATEGORY = "terminalEngine"
# Taken off the app's age, so a line logged in the launch's first second is
# still inside the window.
LAUNCH_SLACK = datetime.timedelta(seconds=5)
# How long the engine check after the run waits before it reads the app's log
# again. A flag change or a rebuild logged as the run ended reaches the log
# store a moment later, and `log show` reads only what has arrived.
ENGINE_RECHECK_SETTLE_SECONDS = 3.0

# The app's `.notice` build lines, as `TerminalEngineNotice.message`
# (`Sources/TBDApp/Terminal/Engine/TerminalEngineFactory.swift`) words them,
# and the arm each one puts its terminal on. The app follows a fallback line
# with a SwiftTerm line for the same terminal; the fallback line is read as
# well, so the rule holds even without that second line. The ids are UUIDs,
# so a local PTY's lines ("... for a local PTY") match none.
ENGINE_LINE_PATTERNS = (
    (re.compile(r"^libghostty engine active for (?P<terminal>\S+)$"), "libghostty"),
    (re.compile(r"^SwiftTerm engine active for (?P<terminal>\S+)$"), "swiftterm"),
    (
        re.compile(r"^libghostty engine unavailable for (?P<terminal>[^\s,]+), fell back to SwiftTerm: "),
        "swiftterm",
    ),
)
# The line the app logs when the flag's value changes, from the same place.
FLAG_LINE_PATTERN = re.compile(r"^libghostty engine experiment turned (?P<state>on|off)$")

# Each arm's engine as its tab label names it.
ENGINE_LABELS = {"swiftterm": "SwiftTerm", "libghostty": "libghostty"}

# Reads the app's engine lines from a start until now, as `log show --style
# ndjson` prints them. The production reader runs `/usr/bin/log`; a test
# passes canned text.
LogReader = Callable[[datetime.datetime], str]


@dataclass(frozen=True)
class EngineLine:
    """One build line from the app's log: the engine a terminal was built on."""

    at: datetime.datetime
    terminal: str  # lowercase
    engine: str  # the arm label: "swiftterm" or "libghostty"
    message: str


@dataclass(frozen=True)
class FlagLine:
    """One flag line from the app's log: the libghostty engine's flag changed."""

    at: datetime.datetime
    enabled: bool
    message: str


AppLogLine = EngineLine | FlagLine


def parse_log_timestamp(text: object) -> datetime.datetime | None:
    if not isinstance(text, str):
        return None
    try:
        return datetime.datetime.strptime(text, "%Y-%m-%d %H:%M:%S.%f%z")
    except ValueError:
        return None


def parse_engine_lines(text: str, pid: int) -> list[AppLogLine]:
    """The build and flag lines one app process logged, oldest first.

    Only that process: an app relaunch rebuilds every panel and forgets every
    switch, so a line from an earlier process says nothing about a terminal
    now. Filtered here rather than in the predicate, so the filter is the same
    code a test runs. Anything that is not a JSON object is skipped.
    """
    lines: list[AppLogLine] = []
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        try:
            record = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(record, dict):
            continue
        if record.get("subsystem") != APP_SUBSYSTEM or record.get("category") != ENGINE_CATEGORY:
            continue
        if record.get("processID") != pid:
            continue
        at = parse_log_timestamp(record.get("timestamp"))
        message = record.get("eventMessage")
        if at is None or not isinstance(message, str):
            continue
        flag = FLAG_LINE_PATTERN.match(message)
        if flag:
            lines.append(FlagLine(at, flag["state"] == "on", message))
            continue
        for pattern, engine in ENGINE_LINE_PATTERNS:
            match = pattern.match(message)
            if match:
                lines.append(EngineLine(at, match["terminal"].lower(), engine, message))
                break
    # Stable, so lines with one timestamp keep the order `log show` gave.
    lines.sort(key=lambda line: line.at)
    return lines


def short_time(at: datetime.datetime) -> str:
    return at.strftime("%H:%M:%S")


# What to do about an arm the log does not confirm. A terminal built while the
# libghostty engine was off logs no line at all.
ENGINE_HINTS = {
    "swiftterm": "With the libghostty engine on, focus it and press ⌃⌘E until its tab label"
    " reads SwiftTerm.",
    "libghostty": "With Settings > Terminal > Experimental > \"Use the libghostty terminal"
    " engine\" on, open a new holder shell for this arm, or press ⌃⌘E in this one.",
}


def engine_verdict(lines: list[AppLogLine], arm: str, terminal_id: str) -> EngineLine | str:
    """The latest build line that names this terminal, when it puts the
    terminal on `arm`'s engine and no flag line follows it; otherwise why not.
    """
    wanted = terminal_id.lower()
    named = [
        (index, line)
        for index, line in enumerate(lines)
        if isinstance(line, EngineLine) and line.terminal == wanted
    ]
    if not named:
        return (
            f"{arm} arm {terminal_id}: no engine line names it. A terminal built while"
            f" the libghostty engine was off logs none. {ENGINE_HINTS[arm]}"
        )
    index, latest = named[-1]
    if latest.engine != arm:
        return (
            f"{arm} arm {terminal_id}: its latest engine line ({short_time(latest.at)})"
            f" puts it on {latest.engine}: \"{latest.message}\". {ENGINE_HINTS[arm]}"
        )
    # In log order, so a flag line and a build line with one timestamp keep
    # the order the store gave them.
    flips = [line for line in lines[index + 1:] if isinstance(line, FlagLine)]
    if flips:
        flip = flips[0]
        return (
            f"{arm} arm {terminal_id}: \"{flip.message}\" ({short_time(flip.at)}) came after"
            f" its latest engine line ({short_time(latest.at)}). A panel rebuilt while the"
            " engine is off logs nothing, so the log no longer says which engine it is on."
            f" With the engine on and left on, press ⌃⌘E in it, at least once, until its tab"
            f" label reads {ENGINE_LABELS[arm]}."
        )
    return latest


def confirm_engines(
    terminals: dict[str, str], pid: int, since: datetime.datetime, read_log: LogReader
) -> dict[str, EngineLine]:
    """Each arm's evidence line. Raises SystemExit, before any keystroke, when
    the log does not put every arm on its own engine."""
    lines = parse_engine_lines(read_log(since), pid)
    evidence: dict[str, EngineLine] = {}
    reasons: list[str] = []
    for arm, terminal_id in terminals.items():
        verdict = engine_verdict(lines, arm, terminal_id)
        if isinstance(verdict, str):
            reasons.append(verdict)
        else:
            evidence[arm] = verdict
    if reasons:
        raise SystemExit(
            f"REFUSING TO RUN — the app's log (TBDApp pid {pid}, since"
            f" {since.strftime('%Y-%m-%d %H:%M:%S')}) does not confirm each arm's engine:\n"
            + "\n".join(f"  - {reason}" for reason in reasons)
            + "\nNothing has been written to any terminal."
        )
    return evidence


def recheck_engines(
    terminals: dict[str, str],
    pid: int,
    since: datetime.datetime,
    before: dict[str, EngineLine],
    read_log: LogReader,
) -> list[str]:
    """Why an arm's engine is not the one it had before the run, if it is not.

    Any change counts, a rebuild on the same engine included: a panel rebuilt
    mid-run was handed over mid-run, and its samples straddle two panels. So
    does a flag line, which `engine_verdict` refuses.
    """
    lines = parse_engine_lines(read_log(since), pid)
    problems = []
    for arm, terminal_id in terminals.items():
        verdict = engine_verdict(lines, arm, terminal_id)
        if isinstance(verdict, str):
            problems.append(verdict)
        elif verdict != before.get(arm):
            problems.append(
                f"{arm} arm {terminal_id}: a new engine line landed during the run"
                f" ({short_time(verdict.at)}): \"{verdict.message}\""
            )
    return problems


def read_app_log(start: datetime.datetime) -> str:
    """The app's engine lines from `start` until now, as ndjson.

    No `--info`: the engine lines are `.notice`, which the store keeps
    longest, and the rule reads nothing else.
    """
    return log_show(
        start, ["--style", "ndjson"], ENGINE_CATEGORY, "no arm's engine could be checked."
    )


def parse_etime(text: str) -> int:
    """`ps -o etime=` as seconds: `[[dd-]hh:]mm:ss`."""
    days = 0
    text = text.strip()
    if "-" in text:
        day_text, text = text.split("-", 1)
        days = int(day_text)
    parts = [int(part) for part in text.split(":")]
    if not 1 <= len(parts) <= 3:
        raise ValueError(f"not an elapsed time: {text!r}")
    while len(parts) < 3:
        parts.insert(0, 0)
    hours, minutes, seconds = parts
    return ((days * 24 + hours) * 60 + minutes) * 60 + seconds


def resolve_app_pid(given: int | None) -> int:
    """The running TBDApp's pid: `--app-pid`, or the only TBDApp running."""
    if given is not None:
        return given
    result = subprocess.run(
        ["pgrep", "-x", APP_PROCESS_NAME], capture_output=True, text=True, timeout=30
    )
    pids = [int(token) for token in result.stdout.split()]
    if not pids:
        raise SystemExit(
            f"no {APP_PROCESS_NAME} process is running, so no arm's engine can be checked."
        )
    if len(pids) > 1:
        raise SystemExit(
            f"{len(pids)} {APP_PROCESS_NAME} processes are running ({', '.join(map(str, pids))})."
            " Pass --app-pid with the one that shows these terminals."
        )
    return pids[0]


def app_launched_at(pid: int) -> datetime.datetime:
    """When the app process started, a few seconds early."""
    result = subprocess.run(
        ["ps", "-o", "etime=", "-p", str(pid)], capture_output=True, text=True, timeout=30
    )
    try:
        age = parse_etime(result.stdout)
    except ValueError:
        raise SystemExit(f"process {pid} is not running, so no arm's engine can be checked.") from None
    return datetime.datetime.now().astimezone() - datetime.timedelta(seconds=age) - LAUNCH_SLACK


# The defaults domain the app's `UserDefaults.standard` reads: its bundle id
# inside a `.app` bundle, its executable's name in an unbundled `swift run`
# build.
BUNDLED_DOMAIN = "com.github.cheapsteak.tbd"
UNBUNDLED_DOMAIN = APP_PROCESS_NAME
# `AppState.useGhosttyTerminalEngineKey`.
ENGINE_FLAG_KEY = "useGhosttyTerminalEngine"
# `AppState.ghosttyTerminalEngineDefault`: what the app reads when the key is
# unset or holds a value it does not take as a Bool. The probe's tests pin it
# to the Swift constant.
ENGINE_FLAG_DEFAULT = True


@dataclass(frozen=True)
class EngineFlag:
    """The app's libghostty engine flag, as `defaults read` and
    `defaults read-type` give it."""

    domain: str
    value: str | None  # as printed, or None when the key is unset
    value_type: str | None  # "boolean", "string", ..., or None when unset or unread

    @property
    def stored(self) -> bool | None:
        """The key as the app reads it, `object(forKey:) as? Bool`, or None
        where the app gets no Bool and so follows `ENGINE_FLAG_DEFAULT`
        (`AppState.ghosttyTerminalEngineEnabled(stored:shippedDefault:)`).

        A boolean is its own value. Swift bridges an `NSNumber` to `Bool` only
        when it is exactly 1 or 0, so an integer or a float is a Bool at 1 or
        0 and no Bool otherwise. `defaults read` prints a boolean, an integer
        1 and a float 1.0 all as 1; `read-type` tells them apart. A string,
        even "1", and every other type is no Bool.
        """
        if self.value is None or self.value_type not in ("boolean", "integer", "float"):
            return None
        try:
            number = float(self.value)
        except ValueError:
            return None
        if number == 1:
            return True
        if number == 0:
            return False
        return None

    @property
    def enabled(self) -> bool:
        # A value whose type `read-type` did not give is not taken as on:
        # how the app reads it cannot be told.
        if self.value is not None and self.value_type is None:
            return False
        stored = self.stored
        return ENGINE_FLAG_DEFAULT if stored is None else stored


def defaults_domain(executable: str) -> str:
    return BUNDLED_DOMAIN if ".app/Contents/MacOS/" in executable else UNBUNDLED_DOMAIN


def read_engine_flag(pid: int) -> EngineFlag:
    """The flag in the defaults domain of the app running as `pid`."""
    located = subprocess.run(
        ["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True, timeout=30
    )
    executable = located.stdout.strip()
    if located.returncode != 0 or not executable:
        raise SystemExit(
            f"process {pid} is not running, so the libghostty engine flag cannot be read."
        )
    domain = defaults_domain(executable)
    # A missing key and a missing domain both exit non-zero: unset.
    value = subprocess.run(
        ["defaults", "read", domain, ENGINE_FLAG_KEY], capture_output=True, text=True, timeout=30
    )
    if value.returncode != 0:
        return EngineFlag(domain, None, None)
    # Prints "Type is boolean".
    kind = subprocess.run(
        ["defaults", "read-type", domain, ENGINE_FLAG_KEY], capture_output=True, text=True, timeout=30
    )
    value_type = kind.stdout.strip().removeprefix("Type is ") if kind.returncode == 0 else None
    return EngineFlag(domain, value.stdout.strip(), value_type)


def engine_flag_problem(flag: EngineFlag) -> str | None:
    """Why the flag is not on, or None when it is."""
    if flag.enabled:
        return None
    shipped = "on" if ENGINE_FLAG_DEFAULT else "off"
    read_type = f"`defaults read-type {flag.domain} {ENGINE_FLAG_KEY}`"
    if flag.value is None:
        reads = f"nothing (unset, which follows the shipped default, {shipped})"
    elif flag.value_type is None:
        reads = f"{flag.value!r}, but {read_type} gave no type, so how the app reads it cannot be told"
    elif flag.stored is None:
        reads = (
            f"{flag.value!r}, but {read_type} says {flag.value_type}. The app takes no Bool from"
            f" that, so it follows the shipped default, {shipped}"
        )
    else:
        reads = repr(flag.value)
    return (
        f"the libghostty engine flag is not on: `defaults read {flag.domain} {ENGINE_FLAG_KEY}`"
        f" reads {reads}. While it is off, a panel that is rebuilt lands on SwiftTerm and logs"
        " nothing, so an arm's latest engine line can name an engine it has left. Turn on"
        " Settings > Terminal > Experimental > \"Use the libghostty terminal engine\", and"
        " leave it on until the run ends."
    )


# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------


def run_samples(
    directory: Path,
    terminals: dict[str, str],
    samples: int,
    gap_ms: float,
    load_map: dict[str, dict[str, float]],
    requested: dict[str, int],
    arms: tuple[str, ...] = ARMS,
    request_times: dict[str, dict[str, float]] | None = None,
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

    `request_times`, also the caller's when given, gets each request's wall
    time, taken just before its write, so the report can place a draw line,
    which carries no sequence number, by time. Engine mode passes it.
    """
    gap = gap_ms / 1000.0
    seq = 0
    for index in range(samples):
        order = arms if index % 2 == 0 else tuple(reversed(arms))
        for arm in order:
            seq += 1
            # Counted before the write and recorded after it, so a request
            # interrupted mid-write leaves the two disagreeing — which is what
            # `main` refuses to band on, rather than silently banding a sample
            # whose load it never saw.
            requested[arm] += 1
            load = os.getloadavg()[0]
            issued = time.time()
            write_request(directory, terminals[arm], seq)
            load_map[arm][str(seq)] = load
            if request_times is not None:
                request_times[arm][str(seq)] = issued
            time.sleep(gap)


# Either one selects engine mode.
ENGINE_TERMINAL_FLAGS = ("--swiftterm-terminal", "--ghostty-terminal")


def add_run_options(parser: argparse.ArgumentParser) -> None:
    """The options both modes share, after each mode's own."""
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


def build_transport_parser() -> argparse.ArgumentParser:
    """Transport mode's parser. It knows none of engine mode's options, so its
    usage and errors name transport mode's arguments alone; its epilog says how
    to reach engine mode."""
    parser = argparse.ArgumentParser(
        description="Drive a paired terminal-transport latency run and report it.",
        epilog="Engine mode compares the two terminal engines on the holder transport:"
        " pass --swiftterm-terminal and --ghostty-terminal in place of the transport"
        " flags. With them, --help lists engine mode's options.",
    )
    parser.add_argument("--worktree", required=True, help="Worktree name or id holding both terminals.")
    parser.add_argument("--tmux-terminal", required=True, help="Terminal id of the tmux arm.")
    parser.add_argument("--holder-terminal", required=True, help="Terminal id of the holder arm.")
    add_run_options(parser)
    return parser


def build_engine_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Drive a paired terminal-engine latency run and report it: a SwiftTerm"
        " holder terminal against a libghostty one.",
    )
    parser.add_argument("--worktree", required=True, help="Worktree name or id holding both terminals.")
    parser.add_argument(
        "--swiftterm-terminal",
        required=True,
        help="Terminal id of the holder terminal on SwiftTerm (the swiftterm arm).",
    )
    parser.add_argument(
        "--ghostty-terminal",
        required=True,
        help="Terminal id of the holder terminal on libghostty (the libghostty arm).",
    )
    # Transport mode's terminal flags, known here only to refuse a mix of modes.
    parser.add_argument("--tmux-terminal", help=argparse.SUPPRESS)
    parser.add_argument("--holder-terminal", help=argparse.SUPPRESS)
    parser.add_argument(
        "--trust-engines",
        action="store_true",
        help="Skip the log check of each arm's engine, with a banner on the report, for"
        " when the app's log cannot answer. The flag check still runs.",
    )
    parser.add_argument(
        "--app-pid",
        type=int,
        help="The TBDApp whose log and defaults to check, when more than one is running.",
    )
    add_run_options(parser)
    return parser


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """The arguments, plus the mode they select.

    Either engine-mode terminal flag selects engine mode's parser; otherwise
    transport mode's parses them. Adds
    `mode` ("transport" or "engine"), `arms` (labels in A/B order),
    `terminals` (arm -> id) and `transports` (arm -> the transport it must be
    on).
    """
    argv = sys.argv[1:] if argv is None else argv
    if not any(token.split("=", 1)[0] in ENGINE_TERMINAL_FLAGS for token in argv):
        args = build_transport_parser().parse_args(argv)
        args.mode = "transport"
        args.arms = ARMS
        args.terminals = {"tmux": args.tmux_terminal, "holder": args.holder_terminal}
        args.transports = {arm: arm for arm in ARMS}
        args.trust_engines = False
        args.app_pid = None
        return args

    parser = build_engine_parser()
    args = parser.parse_args(argv)
    if args.tmux_terminal is not None or args.holder_terminal is not None:
        parser.error(
            "--swiftterm-terminal and --ghostty-terminal (engine mode) cannot be combined"
            " with --tmux-terminal and --holder-terminal (transport mode)"
        )
    if args.swiftterm_terminal.lower() == args.ghostty_terminal.lower():
        parser.error(
            "--swiftterm-terminal and --ghostty-terminal name the same terminal;"
            " an engine comparison needs one terminal on each engine"
        )
    args.mode = "engine"
    args.arms = ENGINE_ARMS
    swiftterm, libghostty = ENGINE_ARMS
    args.terminals = {swiftterm: args.swiftterm_terminal, libghostty: args.ghostty_terminal}
    args.transports = {arm: ENGINE_TRANSPORT for arm in ENGINE_ARMS}
    return args


def count_answered(capture, terminals: dict[str, str], transports: dict[str, str]) -> dict[str, int]:
    """Echoes per arm, counted exactly as `report()` counts them: by transport
    AND by the id this arm named, case-insensitively. A capture is the whole
    app's window, so another panel on the same transport would otherwise pay
    this arm's debts — and an arm that answered nothing could read as
    complete."""
    counts: dict[str, int] = {}
    for arm, terminal_id in terminals.items():
        wanted = terminal_id.lower()
        counts[arm] = len([
            e for e in capture.echoes
            if e.transport == transports[arm] and e.terminal.lower() == wanted
        ])
    return counts


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if args.samples < 1:
        raise SystemExit("--samples must be at least 1")

    report_module = load_report_module()

    directory = runtime_dir()
    if not directory.is_dir():
        raise SystemExit(
            f"{directory} does not exist. The app creates it when the diagnostic is on —"
            " enable `enableTerminalLatencyDiagnostic` and relaunch TBDApp first."
        )

    engine_mode = args.mode == "engine"
    arms: tuple[str, ...] = args.arms
    terminals: dict[str, str] = args.terminals
    rows = terminal_rows(args.tbd, args.worktree)
    for arm, terminal_id in terminals.items():
        verify(rows, terminal_id, args.transports[arm], arm=arm)

    # Engine mode only. Checked after the daemon's rows and before the first
    # keystroke, and again after the last, against the same evidence.
    engine_evidence: dict[str, EngineLine] | None = None
    engine_pid = 0
    engine_since = datetime.datetime.now().astimezone()
    trust_note = None
    if engine_mode:
        engine_pid = resolve_app_pid(args.app_pid)
        flag_problem = engine_flag_problem(read_engine_flag(engine_pid))
        if flag_problem is not None:
            raise SystemExit(
                f"REFUSING TO RUN — {flag_problem}\nNothing has been written to any terminal."
            )
    if engine_mode and args.trust_engines:
        trust_note = (
            "!!!!  ENGINES NOT VERIFIED — --trust-engines skipped the log check. Each arm's"
            " engine is the caller's word: "
            + ", ".join(f"{arm} {terminals[arm]}" for arm in arms)
            + "  !!!!"
        )
        print(f"\n{trust_note}\n", file=sys.stderr)
    elif engine_mode:
        engine_since = app_launched_at(engine_pid)
        engine_evidence = confirm_engines(terminals, engine_pid, engine_since, read_app_log)
        for arm in arms:
            line = engine_evidence[arm]
            print(
                f"{arm} arm {terminals[arm]}: confirmed by \"{line.message}\""
                f" at {short_time(line.at)}",
                file=sys.stderr,
            )

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
    load_map: dict[str, dict[str, float]] = {arm: {} for arm in arms}
    requested: dict[str, int] = {arm: 0 for arm in arms}
    # Engine mode bands its draw waits by time, so it records when each
    # request was issued. Transport mode compares no draws.
    request_times: dict[str, dict[str, float]] | None = (
        {arm: {} for arm in arms} if engine_mode else None
    )
    try:
        run_samples(
            directory, terminals, args.samples, args.gap_ms, load_map, requested, arms, request_times
        )
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
        kept: dict = dict(load_map)
        if request_times is not None:
            # The report reads this entry back as the request times, not as an arm.
            kept[report_module.REQUEST_TIMES_KEY] = request_times
        Path(args.keep_load_map).write_text(json.dumps(kept, indent=2), encoding="utf-8")

    # An arm whose engine moved during the run holds two engines' samples, or
    # two panels', and no figure of it belongs to either. The flag is read
    # again whether or not the log check ran.
    if engine_mode:
        problems: list[str] = []
        flag_problem = engine_flag_problem(read_engine_flag(engine_pid))
        if flag_problem is not None:
            problems.append(flag_problem)
        if engine_evidence is not None:
            try:
                time.sleep(ENGINE_RECHECK_SETTLE_SECONDS)
            except KeyboardInterrupt:
                # As in the settle before the capture, a Ctrl-C here means
                # "stop waiting": the check still runs, on what has arrived.
                print(
                    f"\ninterrupted — rechecking the engines without the {ENGINE_RECHECK_SETTLE_SECONDS:g}s"
                    " wait for the log, so a change logged as the run ended may be missed",
                    file=sys.stderr,
                )
            problems += recheck_engines(terminals, engine_pid, engine_since, engine_evidence, read_app_log)
        if problems:
            print(
                "\nREFUSING TO REPORT — the engine check no longer holds after the run:",
                file=sys.stderr,
            )
            for problem in problems:
                print(f"  - {problem}", file=sys.stderr)
            return 1

    # An arm whose echoes do not match its requests is not reportable: the
    # missing samples are not random, they are whatever the machine was doing
    # when they went missing.
    incomplete = []
    answered_counts = count_answered(capture, terminals, args.transports)
    for arm in arms:
        if requested[arm] and answered_counts[arm] != requested[arm]:
            incomplete.append(f"{arm}: {answered_counts[arm]} echoes for {requested[arm]} requests")

    # An arm with a load reading missing for some request cannot be banded:
    # the samples it would put in a band are not the samples it measured. Drop
    # that arm's readings so the report shows them as unbanded rather than
    # quietly assigning them a load nobody recorded.
    for arm in arms:
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
        0 <= requested[arm] - answered_counts[arm] <= 1 for arm in arms
    )

    # Whatever else happens, a reader of an interrupted run's figures must know
    # it was interrupted BEFORE they read a number. The banner names each arm's
    # counts, goes to stderr, and is handed to the report so it sits in the
    # header above the table too.
    interrupt_note = None
    if interrupted:
        counts = ", ".join(
            f"{arm} {answered_counts[arm]}/{requested[arm]}" for arm in arms
        )
        interrupt_note = (
            "!!!!  INTERRUPTED — this run did not finish. Answered/requested: "
            + counts
            + "  !!!!"
        )
        print(f"\n{interrupt_note}", file=sys.stderr)
    note = "\n".join(part for part in (trust_note, interrupt_note) if part) or None

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
    # traffic and would pool into the arm it shares a transport with. In
    # engine mode both arms share one transport, so each arm is its terminal.
    if engine_mode:
        swiftterm, libghostty = ENGINE_ARMS
        report_module.report(
            capture,
            idle_max=args.idle_max,
            load_map=load_map,
            note=note,
            arms=report_module.engine_arms(terminals[swiftterm], terminals[libghostty]),
            request_times=request_times,
        )
    else:
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
